require "test_helper"

# A delegate's execution can complete without producing a summary. Drive
# its actual claim/commit and the next model request: an error or empty
# answer must never become the timeline's history cut.
class Conversations::Compaction::SummaryResultTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  TOOL = "summary_delegate".freeze
  HISTORY = "The original history names the orchard ledger.".freeze
  SUMMARY = "The prior summary points to the orchard ledger.".freeze
  RECENT = "The later message names the harbor ledger.".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, compaction_policy: { "mode" => "delegate", "tool_name" => TOOL })
    announce_tools!(@agent, [TOOL])
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @agent)
    append_message!(HISTORY)
  end

  test "a completed delegate error preserves history in the next sealed request" do
    turn, agent_run = compact!(content: "The delegate could not summarize.", is_error: true)

    request = next_request
    assert_includes request, HISTORY
    assert_not_includes request, "The delegate could not summarize."
    assert_failed_summary(turn, agent_run)
  end

  test "a completed empty delegate answer preserves history in the next sealed request" do
    turn, agent_run = compact!(content: "")

    assert_includes next_request, HISTORY
    assert_failed_summary(turn, agent_run)
  end

  test "a failed replacement summary keeps the previous summary and subsequent history" do
    previous, = compact!(content: SUMMARY)
    assert_equal "completed", previous.reload.status
    append_message!(RECENT)
    turn, agent_run = compact!(content: "Replacement failed.", is_error: true)

    request = next_request
    assert_includes request, SUMMARY
    assert_includes request, RECENT
    assert_not_includes request, HISTORY
    assert_not_includes request, "Replacement failed."
    assert_failed_summary(turn, agent_run)
  end

  test "a successful replacement summary becomes the next sealed request's history" do
    compact!(content: SUMMARY)
    append_message!(RECENT)
    replacement = "The replacement summary points to both ledgers."
    turn, = compact!(content: replacement)

    assert_equal "completed", turn.reload.status
    request = next_request
    assert_includes request, replacement
    [HISTORY, SUMMARY, RECENT].each { |text| assert_not_includes request, text }
  end

  test "an explicitly failed delegate neither replaces history nor blocks the next input" do
    turn, agent_run = compact!(content: "The delegate failed.", outcome: "failed")
    assert_equal "failed", turn.reload.status
    assert_equal "needs_attention", agent_run.reload.status
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "k2")

    request = next_request
    assert_includes request, HISTORY
    assert_not_includes request, "The delegate failed."
  end

  test "a canceled summary neither replaces history nor blocks the next input" do
    turn, agent_run = start_compaction!
    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @agent
    ))
    assert_predicate stopped, :accepted?
    schedule_loop!(agent_run)
    converge!(agent_run)
    assert_equal "canceled", turn.reload.status
    assert_equal "canceled", agent_run.reload.status
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "k2")

    assert_includes next_request, HISTORY
  end

  test "deleting the summary tail restores history while retaining its current view state" do
    append_message!(RECENT)
    recent = @conversation.conversation_turns.order(:position).last
    summary, agent_run = compact!(content: SUMMARY)
    excluded = Conversations::Turns::SetViewState.call(Conversations::Turns::SetViewState::Command.new(
      conversation: @conversation, turn_public_id: recent.public_id, acting_user: @human,
      visibility: "excluded_from_context", concealed: nil
    ))
    assert_predicate excluded, :accepted?
    deleted = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: @conversation, turn_public_id: summary.public_id, acting_user: @human
    ))
    assert_predicate deleted, :accepted?
    assert_predicate agent_run.reload, :tombstoned?

    request = next_request
    assert_includes request, HISTORY
    assert_not_includes request, RECENT
    assert_not_includes request, SUMMARY
  end

  private

    def append_message!(text)
      post_input!(@conversation, acting_user: @human, text: text)
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    end

    def start_compaction!
      result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
        conversation: @conversation, acting_user: @agent, model: "dev/mock-text"
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      turn = result.value.turn
      agent_run = turn.active_variant.agent_run
      schedule_loop!(agent_run)
      [turn, agent_run]
    end

    def compact!(content:, is_error: false, outcome: "completed")
      turn, agent_run = start_compaction!
      address = TaskExecutor.address_for(@agent)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: agent_run, task_key: "k1", executor: address
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.inspect
      committed = Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: agent_run, task_key: "k1", executor: address, claim_token: claimed.value.claim_token,
        content: content, is_error: is_error, outcome: outcome, structured_content: nil,
        result_type: nil, title: nil, metadata: nil
      ))
      assert_predicate committed, :applied?, committed.outcome.inspect
      converge!(agent_run)
      [turn, agent_run]
    end

    def converge!(agent_run)
      assert_enqueued_with(job: Conversations::Inputs::DrainJob, args: [@conversation.id]) do
        Conversations::Turns::Converge.call(conversation_id: @conversation.id, agent_run_id: agent_run.id)
      end
      assert_nil @conversation.reload.active_turn_id
    end

    def next_request
      _turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(agent_run)
      round_request_entries(agent_run.mainline_nodes.first).to_json
    end

    def assert_failed_summary(turn, agent_run)
      assert_equal "completed", agent_run.reload.status, "the tool's execution completed"
      assert_equal "failed", turn.reload.status, "but it did not produce a usable summary"
      assert_equal "failed", turn.active_variant.status
      assert_nil agent_run.agent_run_tasks.find_by(node_key: "k2"), "an answered delegate gets no fallback"
      settled = @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence)
        .map(&:payload).select { |payload| payload["turn_public_id"] == turn.public_id }
      assert_equal "failed", settled.last.fetch("status")
      assert_equal "failed", settled.last.fetch("variant_status")
      assert_equal "deliverable_unresolved", settled.last.fetch("failure_reason_key")
      sequence = @conversation.conversation_event_items.maximum(:sequence)
      Conversations::Turns::Converge.call(conversation_id: @conversation.id, agent_run_id: agent_run.id)
      assert_equal sequence, @conversation.conversation_event_items.maximum(:sequence), "a second convergence is a no-op"
      assert_equal "failed", turn.reload.status
    end
end
