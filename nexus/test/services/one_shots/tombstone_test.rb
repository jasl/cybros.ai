require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# Terminal-only DELETE and its fixed-window reaper. Cleanup is orthogonal to execution status: the
# command marks finished work for reclamation and refuses live work, and it never cancels anything
# on the caller's behalf — cancel is a different command with a different meaning.
class OneShots::TombstoneTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_the_terminal_decision_is_not_served_from_the_query_cache

  setup do
    @account = accounts(:cybros)
  end

  def one_shot(status: "completed", uploads: 0)
    record = OneShot.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: record)
    ModelInvocation.where(id: invocation.id).update_all(status: status)
    ContentBodies::Replace.call(
      owner: record, role: "input", entries: [{ "text" => "tombstone me" }],
      uploads: Array.new(uploads) { upload }, seal: true
    )
    record
  end

  def upload
    bytes = "tomb-#{SecureRandom.hex(4)}"
    @account.content_uploads.create!(
      creating_user: users(:member),
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(bytes), filename: "t.png", content_type: "image/png"
      )
    )
  end

  test "a terminal one shot is tombstoned and the reclamation clock starts" do
    record = one_shot(status: "completed")

    result = OneShots::Tombstone.call(one_shot: record)

    assert_predicate result, :accepted?
    assert_predicate record.reload, :tombstoned?
    assert_not_nil record.tombstoned_at
  end

  ModelInvocation::TERMINAL_STATUSES.each do |status|
    test "#{status} is terminal enough to tombstone" do
      assert_predicate OneShots::Tombstone.call(one_shot: one_shot(status: status)), :accepted?
    end
  end

  # 409 at the adapter. The refusal is the whole point of "terminal-only":
  # reclaiming live work would destroy an invocation a provider is still
  # running against.
  ModelInvocation::NONTERMINAL_STATUSES.each do |status|
    test "#{status} work refuses the tombstone" do
      record = one_shot(status: status)

      result = OneShots::Tombstone.call(one_shot: record)

      assert_equal :not_terminal, result.outcome
      assert_not_predicate record.reload, :tombstoned?
    end
  end

  test "tombstoning twice is reported rather than moving the clock" do
    record = one_shot
    assert_predicate OneShots::Tombstone.call(one_shot: record), :accepted?
    first_marker = record.reload.tombstoned_at

    result = OneShots::Tombstone.call(one_shot: record)

    assert_equal :already_tombstoned, result.outcome
    assert_equal first_marker, record.reload.tombstoned_at,
      "a repeated DELETE must never extend the retention window"
  end

  test "the marker removes it from listable surfaces" do
    record = one_shot
    assert_includes OneShot.listable, record

    OneShots::Tombstone.call(one_shot: record)

    assert_not_includes OneShot.listable, record.reload
  end

  # Prime the real request/job query cache, then commit the terminal transition
  # on another connection. The locked decision must see the newly committed
  # status instead of conservatively refusing from the cached queued row.
  test "the terminal decision is not served from the query cache" do
    record = one_shot(status: "queued")
    body_ids = ContentBody.where(one_shot_id: record.id).pluck(:id)
    fragment_ids = ContentBodyEntry.where(content_body_id: body_ids)
      .pluck(:content_fragment_id)
    invocation_id = record.model_invocation.id

    ApplicationRecord.cache do
      assert_equal "queued", record.reload_model_invocation.status

      terminalizing = start_database_call do
        ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(id: invocation_id), reason: "workspace_deleted"
        )
      end
      assert_equal 1, finish_database_call(terminalizing)

      assert_predicate OneShots::Tombstone.call(one_shot: record), :accepted?
    end
  ensure
    # `uses_transaction` is required so the second connection can commit, but
    # there is no OneShot fixture set, so fixture reload does not truncate its
    # table. Keep cleanup bounded to the rows created here so later tests never
    # observe committed model work from this test.
    ContentBody.where(id: body_ids).delete_all if body_ids
    ModelInvocation.where(one_shot_id: record.id).delete_all if record
    OneShot.where(id: record.id).delete_all if record
    ContentFragment.where(id: fragment_ids).delete_all if fragment_ids
  end

  test "a one shot inside its window is not reaped" do
    record = one_shot
    OneShots::Tombstone.call(one_shot: record)

    result = OneShots::Reap.call(batch: 10)

    assert_equal 0, result[:scanned]
    assert_equal 0, result[:reaped]
    assert OneShot.exists?(id: record.id)
  end

  test "a one shot that never got a marker is never reaped however old" do
    record = one_shot
    OneShot.where(id: record.id).update_all(created_at: 400.days.ago)

    result = OneShots::Reap.call(batch: 10)

    assert_equal 0, result[:scanned]
    assert_equal 0, result[:reaped]
    assert OneShot.exists?(id: record.id),
      "the reap gate is the tombstone marker, never age alone"
  end

  test "past the window the whole aggregate goes down leaves-first" do
    record = one_shot(uploads: 1)
    body = record.content_bodies.sole
    fragment_id = body.content_body_entries.sole.content_fragment_id
    bound = body.content_uploads.sole
    OneShots::Tombstone.call(one_shot: record)
    OneShot.where(id: record.id).update_all(tombstoned_at: 31.days.ago)

    result = OneShots::Reap.call(batch: 10)

    assert_equal 1, result[:scanned]
    assert_equal 1, result[:reaped]
    assert_not OneShot.exists?(id: record.id)
    assert_not ContentBody.exists?(id: body.id)
    assert_equal 0, ContentBodyEntry.where(content_body_id: body.id).count
    assert_equal 0, ContentBodyUpload.where(content_body_id: body.id).count
    assert_equal 0, ModelInvocation.where(one_shot_id: record.id).count
    assert ContentFragment.exists?(id: fragment_id),
      "fragments are stranded for their own age-gated reaper, never cascaded here"
    assert ContentUpload.exists?(id: bound.id), "the upload outlives the work that bound it"
    assert_predicate bound.reload.file, :attached?
  end

  test "the reap is bounded and restartable" do
    3.times do
      record = one_shot
      OneShots::Tombstone.call(one_shot: record)
      OneShot.where(id: record.id).update_all(tombstoned_at: 31.days.ago)
    end

    first = OneShots::Reap.call(batch: 2)
    second = OneShots::Reap.call(batch: 2)
    third = OneShots::Reap.call(batch: 2)

    assert_equal [2, 2, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal [1, 1, false], [second[:scanned], second[:reaped], second.more?]
    assert_equal [0, 0, false], [third[:scanned], third[:reaped], third.more?]
  end

  test "the reaper is wired to the recurring schedule" do
    production = recurring_schedule

    assert_equal OneShots::ReapJob.name,
      production.dig("reap_tombstoned_one_shots", "class")
    assert_equal "every day at 4:25am",
      production.dig("reap_tombstoned_one_shots", "schedule")
  end
end
