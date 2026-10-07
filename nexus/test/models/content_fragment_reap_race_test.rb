require "test_helper"
require_relative "../test_helpers/row_lock_test_helper"

# The adopt-vs-reap race, driven for real.
#
# The reaper's candidate scan is deliberately unlocked, so a fragment can be
# adopted between the scan and the DELETE. The contract is that the reaper
# loses THAT ROW and nothing else: the writer's adoption always survives, the
# rest of the already-plucked batch is still collected, and the scheduled
# command returns rather than raising.
#
# This cannot be expressed in a transactional test — the adoption has to
# commit on another connection while the DELETE is blocked — which is exactly
# how the previous version of this test passed while the backstop it named
# was unreachable: it created the entry BEFORE calling reap, so the fragment
# was never a candidate and no DELETE was ever issued.
class ContentFragmentReapRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @fragment_ids = []
    @inference_request_ids = []
  end

  # Bounded to this test's own rows. A blunt `delete_all` here would take
  # fixture rows with it and break whatever runs next in the same process.
  teardown do
    ContentBodyEntry.where(content_fragment_id: @fragment_ids).delete_all
    ContentBody.where(inference_request_id: @inference_request_ids).delete_all
    ModelInvocation.where(inference_request_id: @inference_request_ids).delete_all
    InferenceRequest.where(id: @inference_request_ids).delete_all
    ContentFragment.where(id: @fragment_ids).delete_all
    # Without a wrapping transaction, the policy row DevModelLane enabled
    # would outlive this test and defeat the disabled-by-default lane gate
    # other tests assert.
  end

  def stale_orphan
    payload = { "text" => "race-#{SecureRandom.hex(6)}" }
    address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
    @account.content_fragments.create!(
      payload: payload, digest: address.digest
    ).tap do |record|
      @fragment_ids << record.id
      ContentFragment.where(id: record.id).update_all(created_at: 2.days.ago)
    end
  end

  def body
    inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
    @inference_request_ids << inference_request.id
    ContentBody.create!(
      account: @account, inference_request: inference_request, role: "input"
    )
  end

  # PostgreSQL reports an ON DELETE RESTRICT refusal as SQLSTATE 23001, which
  # Rails does not map onto ActiveRecord::InvalidForeignKey. Rescuing the AR
  # class let one lost race abort every remaining candidate and fail the
  # scheduled command outright.
  def test_an_adoption_between_the_scan_and_the_delete_loses_only_its_own_row
    contested = stale_orphan
    later = stale_orphan
    assert_operator contested.id, :<, later.id,
      "the contested row must be reached first, or this proves nothing about the rest of the batch"
    target = body

    held = hold_row_lock(ContentFragment, contested.id, before_commit: ->(locked) {
      target.content_body_entries.create!(
        account: @account, content_fragment_id: locked.id, position: 0
      )
    })
    reaping = start_database_call do
      result = nil
      connection = ApplicationRecord.lease_connection
      ApplicationRecord.transaction do
        result = ContentFragment.reap(batch: 2)
        # The rescued savepoint must leave its caller's outer transaction usable.
        connection.select_value("SELECT 1")
      end
      result
    end
    wait_until_transitively_blocked_by(held.pid, reaping.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(reaping)
    reaping = nil

    assert_not_kind_of Exception, result,
      "a lost race must be an outcome, never an exception that fails the daily command"
    assert ContentFragment.exists?(id: contested.id),
      "the writer's adoption always wins; the reaper is the one that loses"
    assert_not ContentFragment.exists?(id: later.id),
      "one contested row must not take the rest of the plucked batch down with it"
    assert_equal 2, result[:scanned]
    assert_equal 1, result[:reaped]
    assert result.more?,
      "a full scanned window continues even when one guarded delete loses"
  ensure
    begin
      release_row_lock(held) if held
    ensure
      stop_database_call(reaping) if reaping
    end
  end

  # The other half: an uncontested batch is unaffected by the rescue, so the
  # guard above cannot be hiding a reaper that silently collects nothing.
  def test_an_uncontested_batch_is_collected_whole
    ids = 3.times.map { stale_orphan.id }

    result = ContentFragment.reap

    assert_equal 3, result[:scanned]
    assert_equal 3, result[:reaped]
    assert_not result.more?

    assert_equal 0, ContentFragment.where(id: ids).count
  end
end
