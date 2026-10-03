require "test_helper"

class AgentLoops::Scripts::ModelResultTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "an internal model can expand repeatedly without becoming outside history" do
    agent_loop = seed(model("prefix"), script, model("report", "prompt" => "Report final result", "results" => ["workflow"]))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("OUTER PREFIX"))
    root = loop_node(agent_loop, "workflow")
    AgentLoops::ScriptJob.perform_now(root.id, root.execution_generation)
    schedule_loop!(agent_loop)
    internal = children(root).sole
    assert_equal "branch", internal.continuation_source
    assert_equal [internal.node_key], loop_node(agent_loop, "report").result_from_node_keys
    run_loop_round!(agent_loop, sse_success("INTERNAL PLANNING SECRET", tool_calls: [
      { id: "internal_call", name: "read_file", arguments: { path: "inside" }.to_json },
    ]))

    generated = children(internal)
    tool = generated.find(&:tool_call?)
    continuation = generated.find(&:round?)
    assert_equal [continuation.node_key], loop_node(agent_loop, "report").result_from_node_keys
    assert_equal "branch", continuation.continuation_source
    assert_equal "model", tool.authored_by
    assert_predicate AgentLoops::Parks::Settle.call(
      node: tool, trusted: true, outcome: "completed", content: "INTERNAL TOOL SECRET"
    ), :applied?
    schedule_loop!(agent_loop)
    run_loop_round!(agent_loop, sse_success("FINAL CHECK RESULT"))

    report = loop_node(agent_loop, "report")
    assert_equal ["prefix"], report.input_from_node_keys
    assert_equal [continuation.node_key], report.result_from_node_keys
    request = round_request_entries(report).to_json
    assert_includes request, "OUTER PREFIX"
    assert_includes request, "FINAL CHECK RESULT"
    assert_not_includes request, "INTERNAL PROMPT SECRET"
    assert_not_includes request, "INTERNAL PLANNING SECRET"
    assert_not_includes request, "INTERNAL TOOL SECRET"
    assert_equal %w[prefix report], agent_loop.spine_nodes.order(:id).pluck(:node_key)
    owned = AgentLoops::ExpansionOwnership.descendants(root).map(&:id)
    assert_equal [internal.id, tool.id, continuation.id].sort, owned.sort
  end

  test "canceling a script includes later model expansions but leaves its outside reader alive" do
    agent_loop = seed(script, model("report", "results" => ["workflow"]))
    start!(agent_loop)
    root = loop_node(agent_loop, "workflow")
    AgentLoops::ScriptJob.perform_now(root.id, root.execution_generation)
    schedule_loop!(agent_loop)
    internal = children(root).sole
    run_loop_round!(agent_loop, sse_success("inspection", tool_calls: [
      { id: "read", name: "read_file", arguments: { path: "inside" }.to_json },
    ]))
    tool = children(internal).find(&:tool_call?)
    continuation = children(internal).find(&:round?)
    assert_equal "dispatched", tool.status
    assert_predicate AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
      agent_loop: agent_loop, task_key: root.node_key, acting_user: @human
    )), :accepted?

    assert_equal "completed", internal.reload.status
    assert_equal "canceled", tool.reload.status
    assert_equal "canceled", continuation.reload.status
    schedule_loop!(agent_loop)
    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    assert_includes round_request_entries(report).to_json, "task canceled by the person"
  end

  private

    def script
      { "script" => {
        "key" => "workflow", "script" => 'g.model({prompt: "INTERNAL PROMPT SECRET"});',
        "model_defaults" => { "model" => { "model" => "dev/mock-text" }, "tools" => [READ_TOOL] },
      } }
    end

    def start!(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_loop)
    end

    def children(node)
      node.agent_loop.agent_loop_nodes.where(expansion_parent_id: node.id).order(:id).to_a
    end
end
