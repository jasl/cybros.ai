require "test_helper"

class Conversations::RunnerEffectsClaimOrderTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human,
      answering_user: users(:agent), default_runner_executor: suite_runner)
  end

  test "a delayed earlier node does not replace the first claimed write checkpoint" do
    agent_run = create_answered_loop(
      parallel([tool("gate", "read_file"), tool("late_write", "write")], tool("first_write", "write")),
      tool("tail", "read_file"),
      conversation: @conversation, acting_user: @human
    )
    late = agent_run.agent_run_tasks.find_by!(node_key: "late_write")
    first = agent_run.agent_run_tasks.find_by!(node_key: "first_write")
    assert_operator late.id, :<, first.id, "authoring order follows the branches, not their readiness"
    assert_equal "queued", late.status

    finish(agent_run, "first_write", checkpoint: "before-any-write")
    finish(agent_run, "gate")
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
    finish(agent_run, "late_write", checkpoint: "before-any-write")
    assert_operator first.reload.claimed_at, :<, late.reload.claimed_at

    first_write = AgentRuns::RunnerEffects.first_writes([agent_run.id]).fetch(agent_run.id)
    assert_equal first.id, first_write.sole.id, "FIRST CLAIMED is independent of the runner's per-loop checkpoint reuse"
    runner_effects = AgentRuns::RunnerEffects.fact(first_write)
    assert_equal "before-any-write", runner_effects.fetch(:runners).first.fetch(:checkpoint).fetch("hash"),
      "the loop's restore point precedes the first effect, not its first-authored node"
    assert_equal runner_effects, Conversations::RunnerEffectsAt.call(conversation: @conversation, position: -1),
      "the conversation's physical boundary uses the same first-claimed rule"
  end

  test "a previous turn's delayed background write does not replace a successor's earlier checkpoint" do
    agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(agent, tools: [Nexus::ToolRegistry.function_definition("wait"), READ_TOOL,
      { "type" => "function", "function" => { "name" => "write", "parameters" => { "type" => "object" } },
        "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id, "tool_name" => "write" } }])
    agent.update!(runner_executor_public_ids: [suite_runner.public_id])
    post_input!(@conversation, acting_user: @human, text: "the point to restore")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    point = @conversation.conversation_turns.sole
    previous, previous_loop = materialize_loop_reply!(@conversation, agent: agent, text: "work in background")
    schedule_loop!(previous_loop)
    run_loop_round!(previous_loop, sse_success("starting background work", tool_calls: [{
      id: "background", name: "read_file", arguments: "{}",
    }]))
    call = previous_loop.agent_run_tasks.find_by!(tool_call_id: "background")
    append_branch!(call, [tool("#{call.node_key}-gate", "read_file"), tool("#{call.node_key}-late", "write")])
    schedule_loop!(previous_loop)
    run_loop_round!(previous_loop, sse_success("foreground done"))
    Conversations::Turns::Converge.call
    assert_equal "completed", previous.reload.status
    assert_predicate previous_loop.reload, :delivered?
    assert_equal "running", previous_loop.status
    late = previous_loop.agent_run_tasks.find_by!(node_key: "#{call.node_key}-late")
    assert_equal "queued", late.status

    _current, current_loop = materialize_loop_reply!(@conversation, agent: agent, text: "write now")
    schedule_loop!(current_loop)
    run_loop_round!(current_loop, sse_success("writing", tool_calls: [
      { id: "first_write", name: "write", arguments: "{}" },
    ]))
    first = current_loop.agent_run_tasks.find_by!(tool_call_id: "first_write")
    assert_operator late.id, :<, first.id
    finish(current_loop, first.node_key, checkpoint: "before-successor-write")
    finish(previous_loop, "#{call.node_key}-gate")
    schedule_loop!(previous_loop)
    finish(previous_loop, late.node_key, checkpoint: "after-successor-write")
    assert_operator first.reload.claimed_at, :<, late.reload.claimed_at

    runner_effects = Conversations::RunnerEffectsAt.call(conversation: @conversation, position: point.position)
    assert_equal current_loop.public_id, runner_effects.fetch(:runners).first.fetch(:run_public_id),
      "the predecessor's background work may be claimed after a successor's writes"
    assert_equal "before-successor-write", runner_effects.fetch(:runners).first.fetch(:checkpoint).fetch("hash")
  end

  private

    def finish(agent_run, key, checkpoint: nil)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: agent_run, task_key: key, executor: suite_runner
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.to_s
      result = Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: agent_run, task_key: key, executor: suite_runner,
        claim_token: claimed.value.claim_token, content: "done", structured_content: nil,
        result_type: nil, outcome: "completed", is_error: false, title: nil,
        metadata: checkpoint ? { "checkpoint" => { "hash" => checkpoint, "store" => "project" } } : nil
      ))
      assert_predicate result, :applied?, result.outcome.to_s
      clear_enqueued_jobs
    end
end
