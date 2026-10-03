require "test_helper"

class AgentLoops::AppendScriptBoundaryTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a later authored append keeps a script model's final output separate from its history" do
    agent_loop = seed(model("history"), script("workflow", 'g.model({prompt: "PRIVATE SCRIPT PROMPT"});', "model_defaults" => {
      "model" => MOCK_MODEL, "tools" => [READ_TOOL],
    }), tool("checkpoint", "read_file"))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("OUTER HISTORY"))
    workflow = loop_node(agent_loop, "workflow")
    run_script!(workflow)
    first = agent_loop.agent_loop_nodes.find_by!(expansion_parent_id: workflow.id)
    assert_equal "branch", first.continuation_source
    run_loop_round!(agent_loop, sse_success("PRIVATE SCRIPT REASONING", tool_calls: [
      { id: "read", name: "read_file", arguments: '{"path":"private"}' },
    ]))
    generated = agent_loop.agent_loop_nodes.where(expansion_parent_id: first.id).to_a
    internal_read = generated.find(&:tool_call?)
    final = generated.find(&:round?)
    settle!(internal_read, "PRIVATE RAW TOOL DATA")
    run_loop_round!(agent_loop, sse_success("FINAL SCRIPT RESULT"))

    assert_equal "completed", final.reload.status
    assert_equal "history", agent_loop.reload.spine_tail.node_key
    grow!(agent_loop, model("report", "results" => %w[workflow checkpoint]))
    report = loop_node(agent_loop, "report")
    assert_equal %w[history], report.input_from_node_keys
    assert_equal [final.node_key, "checkpoint"], report.result_from_node_keys

    settle!(loop_node(agent_loop, "checkpoint"), "OUTER CHECKPOINT")
    request = round_request_entries(report.reload).to_json
    assert_includes request, "OUTER HISTORY"
    assert_includes request, "OUTER CHECKPOINT"
    assert_includes request, "FINAL SCRIPT RESULT"
    assert_not_includes request, "PRIVATE SCRIPT PROMPT"
    assert_not_includes request, "PRIVATE SCRIPT REASONING"
    assert_not_includes request, "PRIVATE RAW TOOL DATA"
  end

  test "a later authored append naming a model step that used tools reads its final answer" do
    agent_loop = seed(parallel(model("producer", "tools" => [READ_TOOL]), tool("side", "read_file")),
      tool("checkpoint", "read_file"))
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("PRIVATE PRODUCER DRAFT", tool_calls: [
      { id: "read", name: "read_file", arguments: '{"path":"source"}' },
    ]))
    generated = agent_loop.agent_loop_nodes.where(expansion_parent_id: loop_node(agent_loop, "producer").id).to_a
    settle!(generated.find(&:tool_call?), "PRIVATE PRODUCER TOOL DATA")
    run_loop_round!(agent_loop, sse_success("FINAL PRODUCER RESULT"))
    settle!(loop_node(agent_loop, "side"), "SIDE")

    final = generated.find(&:round?)
    assert_equal "completed", final.reload.status
    grow!(agent_loop, model("report", "results" => %w[producer]))
    report = loop_node(agent_loop, "report")
    assert_equal [final.node_key], report.result_from_node_keys
    assert agent_loop.agent_loop_edges.exists?(from_node_id: final.id, to_node_id: report.id, structural: false)

    settle!(loop_node(agent_loop, "checkpoint"), "CHECKPOINT")
    request = round_request_entries(report.reload).to_json
    assert_includes request, "FINAL PRODUCER RESULT"
    assert_not_includes request, "PRIVATE PRODUCER DRAFT"
    assert_not_includes request, "PRIVATE PRODUCER TOOL DATA"
  end

  test "model expansion preserves wait-only result-only and structural consumers together" do
    agent_loop = seed(parallel(
      [model("producer", "tools" => [READ_TOOL]),
       tool("structural", "read_file", "after" => ["producer"])],
      tool("wait-only", "read_file", "after" => ["producer"]),
      script("selected", "return results[0].output;", "results" => ["producer"])
    ), model("report"))
    producer = loop_node(agent_loop, "producer")
    assert_edge(agent_loop, producer, "structural", structural: true)
    assert_edge(agent_loop, producer, "wait-only", structural: false)
    assert_edge(agent_loop, producer, "selected", structural: false)
    start!(agent_loop)
    run_loop_round!(agent_loop, sse_success("PRIVATE PRODUCER DRAFT", tool_calls: [
      { id: "read", name: "read_file", arguments: '{"path":"source"}' },
    ]))
    generated = agent_loop.agent_loop_nodes.where(expansion_parent_id: producer.id).to_a
    internal_read = generated.find(&:tool_call?)
    final = generated.find(&:round?)

    %w[structural wait-only selected].each do |key|
      assert_equal "queued", loop_node(agent_loop, key).status
    end
    assert_edge(agent_loop, final, "structural", structural: true)
    assert_edge(agent_loop, final, "wait-only", structural: false)
    assert_edge(agent_loop, final, "selected", structural: false)
    wait_only = loop_node(agent_loop, "wait-only")
    assert_nil wait_only.input_from_node_keys
    assert_nil wait_only.result_from_node_keys
    selected = loop_node(agent_loop, "selected")
    assert_nil selected.input_from_node_keys
    assert_equal [final.node_key], selected.result_from_node_keys

    settle!(internal_read, "PRIVATE PRODUCER TOOL DATA")
    run_loop_round!(agent_loop, sse_success("FINAL PRODUCER RESULT"))
    assert_equal "dispatched", wait_only.reload.status
    assert_equal "dispatched", loop_node(agent_loop, "structural").status
    run_script!(selected.reload)
    assert_equal "Mock: FINAL PRODUCER RESULT",
      AgentLoops::TaskResultProjection.call(selected.reload).fetch("structured_content")
  end

  private

    def script(key, source, **fields)
      { "script" => { "key" => key, "script" => source }.merge(fields) }
    end

    def start!(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_loop)
    end

    def run_script!(node)
      assert_equal "running", node.status
      AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
      schedule_loop!(node.agent_loop)
    end

    def settle!(node, text)
      assert_predicate AgentLoops::Parks::Settle.call(
        node: node, trusted: true, outcome: "completed", content: text
      ), :applied?
      schedule_loop!(node.agent_loop)
    end

    def assert_edge(agent_loop, from, to, structural:)
      target = loop_node(agent_loop, to)
      edges = agent_loop.agent_loop_edges.where(from_node_id: from.id, to_node_id: target.id)
      assert_equal 1, edges.count
      assert_equal structural, edges.sole.structural
    end
end
