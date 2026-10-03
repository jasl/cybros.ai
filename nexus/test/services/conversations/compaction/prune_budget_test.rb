require "test_helper"

class Conversations::Compaction::PruneBudgetTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    declare_tools!(@agent)
  end

  test "a fan's first read contributes no byte or token savings to a prune" do
    start_loop
    complete_read("fresh", "Read the current file", "x" * 100)
    target = loop_node(@agent_loop, "r2")
    history = Conversations::Compaction::Serialize.loop_history(target)
    assert_equal 0, history.prunable_bytes
    profile = DevModelLane.selection(workload: "text_generation", account: @agent.account).execution_profile
    assert_equal 0, history.prunable_tokens(profile)

    repair = Conversations::Compaction::Arm.call(agent_loop: @agent_loop, node: target,
      trigger: Conversations::Compaction::Trigger.wall(target,
        overshoot: Conversations::Compaction::Overshoot.bytes(100 - Conversations::Compaction::Serialize::CLEARED_BYTES)))
    assert_equal "kernel", repair.mode
    assert_nil target.reload.pruned_before
    schedule_loop!(@agent_loop)
    run_loop_round!(@agent_loop, sse_success("Summary of consumed history"))
    outputs = round_request_entries(target.reload).select { |entry| entry["type"] == "tool_result_item" }
    assert_equal [["fresh", "x" * 100]], outputs.map { |entry| entry.fetch("payload").values_at("call_id", "output") }
  end

  [false, true].each do |hooked|
    test "a token wall remains repairable when result bytes overstate token savings with hook #{hooked}" do
      if hooked
        @agent.update!(lifecycle_hooks: { "pre_compact" => { "tool" => "check_lifecycle", "timeout_ms" => 30_000 } })
        announce_tools!(@agent, ["read_file", "check_lifecycle"])
      end
      start_loop
      complete_read("first", "the quick brown fox files a report. " * 625, "x" * 12_000)
      schedule_loop!(@agent_loop)
      assert_equal "running", loop_node(@agent_loop, "r2").status

      complete_read("second", "the quick brown fox files a report. " * 425, "done")
      schedule_loop!(@agent_loop)
      if hooked
        hook = @agent_loop.agent_loop_nodes.where(lifecycle_event: "pre_compact").last!
        assert_operator hook.tool_input.fetch("overshoot_tokens"), :>, 0
        assert_equal hook.tool_input.fetch("overshoot_tokens") * 4, hook.tool_input.fetch("overshoot_bytes")
        settle_hook(hook)
        2.times { schedule_loop!(@agent_loop) }
      end

      round = loop_node(@agent_loop, "r3")
      assert_not_equal "failed", round.status,
        "an insufficient token reduction must not spend the round's only compaction opportunity"
      assert_not_nil round.compaction[AgentLoopNodes::ModelTask::SUMMARY_SOURCE]
      run_loop_round!(@agent_loop, sse_success("Summary of the earlier work"))
      assert_equal "running", round.reload.status
    end
  end

  ["missing", "unavailable"].each do |counter_state|
    test "a token wall summarizes when its local counter is #{counter_state}" do
      start_loop
      complete_read("first", "Read a file", "x" * 12_000)
      target = loop_node(@agent_loop, "r2")
      selection = DevModelLane.selection(workload: "text_generation", account: @agent.account)
      profile = selection.execution_profile
      counter = profile.token_counter.with(encoding: "not_a_tokenizer") if counter_state == "unavailable"
      selection = selection.with(execution_profile: profile.with(token_counter: counter))
      trigger = Conversations::Compaction::Trigger.wall(target,
        overshoot: Conversations::Compaction::Overshoot.tokens(100))

      ModelSelection.stub(:resolve, ModelSelection::Result.resolved(selection)) do
        @agent_loop.with_lock do
          Conversations::Compaction::Arm.call(agent_loop: @agent_loop, node: target, trigger: trigger)
        end
      end

      assert_not_nil target.reload.compaction[AgentLoopNodes::ModelTask::SUMMARY_SOURCE]
      assert_nil target.compaction[AgentLoopNodes::ModelTask::PRUNED_BEFORE]
    end
  end

  private

    def start_loop
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member),
        answering_user: @agent)
      _turn, @agent_loop = materialize_loop_reply!(conversation, agent: @agent, text: "Review the files")
      schedule_loop!(@agent_loop)
    end

    def settle_hook(hook)
      address = TaskExecutor.address_for(@agent)
      claim = Executors::Claim.call(Executors::Claim::Command.new(
        agent_loop: @agent_loop, task_key: hook.node_key, executor: address
      ))
      assert_predicate claim, :accepted?, claim.outcome.inspect
      result = Executors::Commit.call(Executors::Commit::Command.new(
        agent_loop: @agent_loop, task_key: hook.node_key, executor: address, claim_token: claim.value.claim_token,
        content: "Lifecycle check", structured_content: { "continue" => false }, result_type: nil,
        outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate result, :applied?, result.outcome.inspect
    end

    def complete_read(call_id, words, content)
      run_loop_round!(@agent_loop, sse_success(words, tool_calls: [
        { id: call_id, name: "read_file", arguments: { path: "#{call_id}.txt" }.to_json },
      ]))
      result = AgentLoops::Parks::Settle.call(
        node: @agent_loop.agent_loop_nodes.find_by!(tool_call_id: call_id), trusted: true,
        content: content, outcome: "completed"
      )
      assert_predicate result, :applied?
      clear_enqueued_jobs
    end
end
