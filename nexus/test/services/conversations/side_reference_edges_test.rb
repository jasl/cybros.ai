require "test_helper"

class Conversations::SideReferenceEdgesTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: @agent)
  end

  test "an unfinished compaction reference never cuts the settled history it has not summarized" do
    settled_reply!("The original question names the orchard ledger.", "The orchard ledger has been inspected.")
    declare_tools!(@agent, compaction_policy: { "mode" => "delegate", "tool_name" => "summary_delegate" })
    announce_tools!(@agent, ["read_file", "summary_delegate"])
    requested = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: @conversation.reload, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate requested, :accepted?, requested.outcome.inspect
    summary = requested.value.turn
    run = summary.active_variant.agent_run
    schedule_loop!(run)
    assert_equal "running", summary.reload.status

    side = side_fork!
    reference = side.conversation_turns.sole
    captured = entries(side)

    assert_predicate reference, :reference?
    assert_equal "message", reference.kind, "a frozen pending summary cannot become a completed history cut"
    assert_equal summary.public_id, reference.forked_from_turn_public_id
    assert_includes captured.to_json, "The original question names the orchard ledger."
    assert_includes captured.to_json, "The orchard ledger has been inspected."
    assert_includes captured.to_json, "run status running"
    assert_equal 0, AgentRun.where(conversation_turn_variant_id: side.conversation_turn_variants.select(:id)).count

    settle_delegate!(run, "A completed summary now replaces the parent's orchard history.")
    Conversations::Turns::Converge.call(conversation_id: @conversation.id, agent_run_id: run.id)

    assert_equal "completed", summary.reload.status
    assert_not_includes entries(@conversation).to_json, "The original question names the orchard ledger."
    assert_includes entries(@conversation).to_json, "A completed summary now replaces the parent's orchard history."
    assert_equal captured, entries(side), "the parent's later history cut cannot change the side's reference"
  end

  test "a side freezes the running regeneration instead of the displayed completed candidate" do
    turn, = settled_reply!("Inspect the current candidate.", "The previously displayed answer.")
    original = turn.active_variant
    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
    candidate = regenerated.value
    run = candidate.agent_run
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Inspecting the replacement candidate.", tool_calls: [
      { id: "landed", name: "read_file", arguments: { path: "current" }.to_json },
      { id: "pending", name: "read_file", arguments: { path: "next" }.to_json },
    ]))
    settle_tool!(run, "landed", "The running candidate's persisted evidence.")
    assert_equal original.id, turn.reload.active_variant_id
    assert_equal "running", candidate.reload.status

    side = side_fork!
    reference = side.conversation_turns.sole
    captured = entries(side)

    assert_equal candidate.public_id, side.forked_from_variant_public_id
    assert_equal candidate.public_id, reference.forked_from_variant_public_id
    assert_includes captured.to_json, "Inspect the current candidate."
    assert_includes captured.to_json, "Inspecting the replacement candidate."
    assert_includes captured.to_json, "The running candidate's persisted evidence."
    assert_not_includes captured.to_json, "The previously displayed answer."
    assert_equal %w[landed pending], captured.filter_map { |entry|
      entry.dig("payload", "call_id") if entry["type"] == "tool_call_item"
    }
    assert_nil reference.active_variant.agent_run

    settle_tool!(run, "pending", "Evidence arriving after the fork.")
    schedule_loop!(run)
    run_loop_round!(run, sse_success("The newly displayed answer."))
    Conversations::Turns::Converge.call

    assert_equal candidate.id, turn.reload.active_variant_id
    assert_equal "completed", turn.status
    assert_equal captured, entries(side), "adopting the regenerated candidate cannot update its frozen reference"
  end

  private

    def settled_reply!(question, answer)
      turn, run = materialize_loop_reply!(@conversation, agent: @human, text: question)
      schedule_loop!(run)
      run_loop_round!(run, sse_success(answer))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      [turn, run]
    end

    def side_fork!
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: @conversation.reload, turn_public_id: nil, variant_public_id: nil,
        acting_user: @human, title: nil, side: true
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def entries(conversation)
      history = Conversations::ContextAssembly::ChatHistory.call(conversation: conversation.reload, answerer: @agent)
      Nexus::InputEntries.for(history.segments.flat_map(&:elements))
    end

    def settle_delegate!(run, text)
      executor = TaskExecutor.address_for(@agent)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: run, task_key: "k1", executor: executor
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.inspect
      committed = Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: run, task_key: "k1", executor: executor, claim_token: claimed.value.claim_token,
        content: text, is_error: false, outcome: "completed", structured_content: nil,
        result_type: nil, title: nil, metadata: nil
      ))
      assert_predicate committed, :applied?, committed.outcome.inspect
    end

    def settle_tool!(run, id, text)
      result = AgentRuns::Parks::Settle.call(node: run.agent_run_tasks.find_by!(tool_call_id: id),
        trusted: true, content: text, outcome: "completed")
      assert_predicate result, :applied?
    end
end
