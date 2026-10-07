require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# A reaper pass may select many aggregates, but each InferenceRequest teardown commits
# independently. If a later aggregate blocks, already-drained aggregates must
# be absent to another connection rather than waiting in one batch-wide
# transaction.
class InferenceRequests::ReapTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @inference_request_ids = []
    @fragment_ids = []
    @upload_ids = []
    @blob_ids = []
  end

  teardown do
    body_ids = ContentBody.where(inference_request_id: @inference_request_ids).pluck(:id)
    ContentBody.where(id: body_ids).delete_all
    InferenceRequestCreateReceipt.where(inference_request_id: @inference_request_ids).delete_all
    ModelInvocation.where(inference_request_id: @inference_request_ids).delete_all
    InferenceRequest.where(id: @inference_request_ids).delete_all
    ContentFragment.where(id: @fragment_ids).delete_all
    ActiveStorage::Attachment.where(
      record_type: "ContentUpload", record_id: @upload_ids
    ).delete_all
    ContentUpload.where(id: @upload_ids).delete_all
    ActiveStorage::Blob.where(id: @blob_ids).find_each(&:purge)
  end

  test "each aggregate commits before the reaper starts the next aggregate" do
    first = aged_tombstone(tombstoned_at: 32.days.ago)
    second = aged_tombstone(tombstoned_at: 31.days.ago)

    held = hold_row_lock(ModelInvocation, second.model_invocation.id)
    reaping = start_database_call { InferenceRequests::Reap.call(batch: 2) }
    wait_until_transitively_blocked_by(held.pid, reaping.pid)

    observer = ApplicationRecord.lease_connection
    observer_pid = observer.select_value("SELECT pg_backend_pid()").to_i
    visible_ids = observer.select_values(<<~SQL).map!(&:to_i)
      SELECT id
      FROM inference_requests
      WHERE id IN (#{first.id}, #{second.id})
      ORDER BY id
    SQL

    assert_not_includes [held.pid, reaping.pid], observer_pid,
      "visibility must be checked from a third database connection"
    assert_equal [second.id], visible_ids,
      "the first aggregate commits before the second waits on its invocation"

    release_row_lock(held)
    held = nil
    result = finish_database_call(reaping)
    reaping = nil

    assert_equal [2, 2, true], [result[:scanned], result[:reaped], result.more?]
    assert_equal 0, InferenceRequest.where(id: [first.id, second.id]).count
  ensure
    begin
      release_row_lock(held) if held
    ensure
      stop_database_call(reaping) if reaping
    end
  end

  test "a full scanned window continues after a competing collector wins one aggregate" do
    first = aged_tombstone(tombstoned_at: 32.days.ago)
    second = aged_tombstone(tombstoned_at: 31.days.ago)
    original_drain = InferenceRequests::Drain.method(:call)

    competing_drain = lambda do |inference_request_ids:|
      assert_equal [first.id, second.id], inference_request_ids
      assert_equal 1, original_drain.call(inference_request_ids: [first.id]),
        "the competing collector must win one scanned aggregate"
      original_drain.call(inference_request_ids: inference_request_ids)
    end

    result = InferenceRequests::Drain.stub(:call, competing_drain) do
      InferenceRequests::Reap.call(batch: 2)
    end

    assert_equal 2, result[:scanned]
    assert_equal 1, result[:reaped]
    assert result.more?,
      "continuation follows the full scanned window, not the smaller delete count"
    assert_equal 0, InferenceRequest.where(id: [first.id, second.id]).count
  end

  test "competing collectors cascade one aggregate's upload join only once" do
    shared = upload
    candidate = aged_tombstone(tombstoned_at: 31.days.ago, upload: shared)
    retained = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
    @inference_request_ids << retained.id
    ContentBodies::Replace.call(
      owner: retained, role: "input", entries: [{ "text" => "still bound" }],
      uploads: [shared], seal: true
    )
    @fragment_ids.concat(
      retained.content_bodies.sole.content_body_entries.pluck(:content_fragment_id)
    )
    assert_equal 2, ContentBodyUpload.where(content_upload: shared).count

    held = hold_row_lock(InferenceRequest, candidate.id)
    reapers = 2.times.map do
      start_database_call { InferenceRequests::Reap.call(batch: 1) }
    end
    wait_until_transitively_blocked_by(held.pid, *reapers.map(&:pid))
    release_row_lock(held)
    held = nil
    results = reapers.map { |call| finish_database_call(call) }
    reapers = []

    assert_equal [1, 1], results.map { |pass| pass[:scanned] }
    assert_equal 1, results.sum { |pass| pass[:reaped] }, "only one collector can own the aggregate delete"
    assert_not InferenceRequest.exists?(id: candidate.id)
    assert InferenceRequest.exists?(id: retained.id)
    assert_equal [retained.id], shared.content_body_uploads
      .joins(:content_body).pluck("content_bodies.inference_request_id")
  ensure
    begin
      release_row_lock(held) if held
    ensure
      Array(reapers).each { |call| stop_database_call(call) }
    end
  end

  test "the tombstone scan has its matching partial index" do
    index = ApplicationRecord.with_connection do |connection|
      connection.indexes(:inference_requests).find do |candidate|
        candidate.name == "index_inference_requests_on_tombstoned_at_and_id"
      end
    end

    assert index
    assert_equal %w[tombstoned_at id], index.columns
    assert_includes index.where, "tombstoned_at IS NOT NULL"
  end

  private

    def aged_tombstone(tombstoned_at:, upload: nil)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
      @inference_request_ids << inference_request.id
      invocation = DevModelLane.create_invocation!(inference_request: inference_request)
      ModelInvocation.where(id: invocation.id).update_all(status: "completed")
      ContentBodies::Replace.call(
        owner: inference_request, role: "input", entries: [{ "text" => SecureRandom.hex(6) }],
        uploads: Array(upload).compact, seal: true
      )
      @fragment_ids.concat(
        inference_request.content_bodies.sole.content_body_entries.pluck(:content_fragment_id)
      )
      InferenceRequest.where(id: inference_request.id).update_all(tombstoned_at: tombstoned_at)
      inference_request
    end

    def upload
      bytes = "reap-#{SecureRandom.hex(6)}"
      @account.content_uploads.create!(
        creating_user: users(:member),
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "reap.txt", content_type: "text/plain"
        )
      ).tap do |record|
        @upload_ids << record.id
        @blob_ids << record.file.blob_id
      end
    end
end
