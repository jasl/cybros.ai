require "test_helper"

class AgentRuns::Runners::ListTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "listing reports frozen candidates with no selected Runner and ignores later profile and announcement changes" do
    runner = suite_runner
    runner.update!(display_name: "Workstation")
    assert_predicate runner.announce(tools: TEST_SERVED_TOOLS,
      environment: { "fragments" => [{ "text" => "Accepted environment" }] }), :accepted?
    run = seed(model("round1", "kernel_tools" => ["nexus.runners.list"],
      "runner_executor_public_ids" => [runner.public_id], "runner_tool_names" => []),
      default_runner_executor_public_id: nil, creating_user: users(:agent))
    frozen = loop_node(run, "round1").operation_context.fetch("environment").fetch("runner_candidates")
    run.answering_user.update!(runner_executor_public_ids: [])
    runner.update!(display_name: "Renamed")
    runner.announce(tools: [], environment: { "fragments" => [{ "text" => "Later environment" }] })

    start_loop(run)
    run_loop_round!(run, sse_success("list", tool_calls: [{ id: "list", name: "runners_list", arguments: "{}" }]))
    node = loop_node(run, "r1t0")
    assert_equal :applied, AgentRuns::Runners::List.call(node: node)
    result = JSON.parse(node.reload.output_body.effective_text)
    assert_nil result.fetch("current_runner_executor_public_id")
    assert_equal frozen, result.fetch("runners")
    assert_equal "Workstation", result.fetch("runners").sole.fetch("display_name")
    assert_equal "Accepted environment", result.fetch("runners").sole.dig("environment", "fragments", 0, "text")
    assert_not node.output_summary["is_error"]
    assert_equal :not_running, AgentRuns::Runners::List.call(node: node)
  end

  test "listing includes the accepted current Runner without importing unselected tools" do
    runner = suite_runner
    run = seed(model("round1", "kernel_tools" => ["nexus.runners.list"],
      "runner_executor_public_ids" => [runner.public_id], "runner_tool_names" => []),
      default_runner_executor_public_id: runner.public_id)
    assert_equal ["runners_list"], Nexus::ToolDeclarations.names(loop_node(run, "round1").tool_definitions)
    start_loop(run)
    run_loop_round!(run, sse_success("list", tool_calls: [{ id: "list", name: "runners_list", arguments: "{}" }]))
    node = loop_node(run, "r1t0")
    AgentRuns::ToolDiscoveryJob.perform_now(node.id)
    assert_equal runner.public_id, JSON.parse(node.reload.output_body.effective_text).fetch("current_runner_executor_public_id")
  end

  private

    def start_loop(run)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: run, acting_user: run.creating_user)), :accepted?
      schedule_loop!(run)
    end
end
