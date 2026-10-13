require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# A late provider result and the late-evidence closer are genuine overlapping
# owners. They converge through the Invocation lock onto one immutable receipt
# and one matching Attempt settlement state, whichever reaches the lock first.
class ModelInvocations::CloseAbandonedSettlementsConcurrencyTest < ActiveJob::TestCase
  include InvocationHarness
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @attempt, @outcome = dispatched(behaviour: sse_success("late"))
    @invocation = @attempt.model_invocation
    @inference_request = @invocation.inference_request
    @fragment_ids = ContentBodyEntry
      .joins(:content_body)
      .where(content_bodies: { inference_request_id: @inference_request.id })
      .pluck(:content_fragment_id)

    ModelInvocationAttempt.where(id: @attempt.id).update_all(deadline_at: 9.days.ago)
    assert_equal 1, ModelInvocations::DeadlineSweep.call[:timed_out]
    ModelInvocationAttempt.where(id: @attempt.id).update_all(terminal_at: 8.days.ago)
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
    UsageRecord.where(
      account_id: @account.id,
      model_invocation_public_id: @invocation&.public_id
    ).delete_all
    InferenceRequests::Drain.call(inference_request_ids: [@inference_request.id]) if @inference_request
    if @fragment_ids
      ContentFragment.where(id: @fragment_ids).where.missing(:content_body_entries).delete_all
    end
  end

  test "a real receipt and abandonment commit one matching winner" do
    held = hold_row_lock(ModelInvocation, @invocation.id)
    closer = start_database_call do
      ModelInvocations::CloseAbandonedSettlements.new(batch_size: 1).call
    end
    real_writer = start_database_call do
      UsageRecords::Record.call(
        attempt: ModelInvocationAttempt.find(@attempt.id),
        outcome: @outcome,
        status: "discarded"
      )
    end
    wait_until_transitively_blocked_by(held.pid, closer.pid, real_writer.pid)

    release_row_lock(held)
    held = nil
    finish_database_call(closer)
    closer = nil
    finish_database_call(real_writer)
    real_writer = nil

    identity = {
      account_id: @account.id,
      model_invocation_public_id: @invocation.public_id,
      attempt_ordinal: @attempt.ordinal,
    }
    assert_equal 1, UsageRecord.where(identity).count
    receipt = UsageRecord.find_by!(identity)
    attempt = @attempt.reload

    case receipt.status
    when UsageRecord::ABANDONED
      assert_equal "abandoned", attempt.settlement_state
      assert_equal "settlement_abandoned", receipt.error_code
      assert_nil receipt.provider_request_id
      assert_nil receipt.input_tokens
      assert_nil receipt.total_tokens
    when "discarded"
      assert_equal "settled", attempt.settlement_state
      assert_equal "req_1", receipt.provider_request_id
      assert_equal 2, receipt.input_tokens
      assert_equal 5, receipt.total_tokens
    else
      flunk "unexpected receipt winner: #{receipt.status.inspect}"
    end
  ensure
    release_row_lock(held) if held
    stop_database_call(closer) if closer
    stop_database_call(real_writer) if real_writer
  end

  private

    def dispatched(behaviour:)
      attempt = admitted_attempt
      started = start(attempt)
      built = build(attempt)
      raise "build refused: #{built.refusal.inspect}" unless built.built?

      outcome = fake_dispatch(behaviour) do
        ModelInvocations::Dispatch.call(
          attempt: started.attempt, context: started.context, request: built.request
        )
      end
      [started.attempt, outcome]
    end
end
