require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class Conversations::UsageReapConcurrencyTest < ActiveJob::TestCase
  include RowLockTestHelper
  include LockOrderTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
    @agent_run = create_answered_loop(model("r1", "prompt" => "answer"),
      conversation: @conversation, acting_user: @human)
    @attempt = loop_attempt(@agent_run)
    built = build(@attempt)
    assert_predicate built, :built?, built.refusal.inspect
    started = start(@attempt)
    @outcome = fake_dispatch(sse_success("late answer")) do
      ModelInvocations::Dispatch.call(attempt: started.attempt,
        context: started.context, request: built.request)
    end
    @invocation_id = @attempt.model_invocation_id

    canceled = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation.reload, acting_user: @human
    ))
    assert_predicate canceled, :accepted?, canceled.outcome.inspect
    AgentRuns::ConvergeTerminalSteps.call
    schedule_loop!(@agent_run)
    Conversations::Turns::Converge.call
    turn = @agent_run.conversation_turn.reload
    assert_equal "canceled", turn.status
    assert_equal "pending", @attempt.reload.settlement_state
    deleted = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human
    ))
    assert_predicate deleted, :accepted?, deleted.outcome.inspect
    assert_nil @agent_run.reload.conversation_turn_variant_id
    assert_equal @conversation.public_id, @agent_run.conversation_public_id
    assert_predicate Conversations::Tombstone.call(conversation: @conversation.reload), :accepted?
    Conversation.where(id: @conversation.id).update_all(
      tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago
    )
  end

  teardown do
    if (agent_run = AgentRun.find_by(id: @agent_run&.id))
      agent_run.with_lock { AgentRuns::Reap.destroy_aggregate(agent_run) }
    end
    Conversation.find_by(id: @conversation&.id)&.destroy!
    UsageRecord.where(conversation_public_id: @conversation&.public_id).delete_all
    ModelUsageSummary.where(subject_kind: "conversation", subject_id: @conversation&.id).delete_all
  end

  test "a winning receipt commits before collection removes the cumulative cache" do
    held = hold_row_lock(ModelInvocation, @invocation_id, before_commit: lambda { |_invocation|
      record_receipt
    })
    reaping = start_database_call { reap }
    wait_until_transitively_blocked_by(held.pid, reaping.pid)

    release_row_lock(held)
    held = nil
    assert_equal 1, finish_database_call(reaping).value[:reaped]
    reaping = nil
    assert_collected_with_receipt
  ensure
    begin
      release_row_lock(held) if held
    ensure
      stop_database_call(reaping) if reaping
    end
  end

  test "a winning collection leaves the late receipt without resurrecting its cache" do
    held = hold_row_lock(ModelInvocation, @invocation_id)
    reaping = start_database_call { reap }
    wait_until_transitively_blocked_by(held.pid, reaping.pid)
    recording = start_database_call { record_receipt }
    wait_until_transitively_blocked_by(reaping.pid, recording.pid)

    release_row_lock(held)
    held = nil
    assert_equal 1, finish_database_call(reaping).value[:reaped]
    reaping = nil
    assert_equal @conversation.public_id, finish_database_call(recording).conversation_public_id
    recording = nil
    assert_collected_with_receipt
  ensure
    begin
      release_row_lock(held) if held
    ensure
      stop_database_call(reaping) if reaping
      stop_database_call(recording) if recording
    end
  end

  test "collection locks the detached writer below its conversation and settlement never locks the conversation" do
    sequences = assert_ladder_order("conversation usage collection") do
      assert_equal 1, reap.value[:reaped]
    end
    seen = sequences.flatten.uniq
    assert_operator seen.index("conversations"), :<, seen.index("model_invocations")

    sequences = assert_ladder_order("late conversation receipt") { record_receipt }
    assert_not_includes sequences.flatten, "conversations",
      "settlement must not add an inverse invocation-to-conversation lock"
    assert_collected_with_receipt
  end

  private

    def reap = Conversations::Reap.call(batch: 10)

    def record_receipt
      UsageRecords::Record.call(attempt: ModelInvocationAttempt.find(@attempt.id),
        outcome: @outcome, status: "discarded")
    end

    def assert_collected_with_receipt
      assert_not Conversation.exists?(@conversation.id)
      assert_not ModelUsageSummary.exists?(subject_kind: "conversation", subject_id: @conversation.id)
      receipt = UsageRecord.where(conversation_public_id: @conversation.public_id).sole
      assert_equal "discarded", receipt.status
      assert_equal 5, receipt.total_tokens
      assert_equal "settled", @attempt.reload.settlement_state
    end
end
