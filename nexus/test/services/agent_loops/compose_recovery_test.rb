require "test_helper"

class AgentLoops::ComposeRecoveryTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a worker retry after append preserves the composed graph and its waiting reader" do
    agent_loop = interrupted_compose
    call = loop_node(agent_loop, "r1t0")
    task = loop_node(agent_loop, "r1t0-patch")
    reader = loop_node(agent_loop, "r1")
    assert_equal "running", call.reload.status
    assert_equal "queued", task.status
    assert_equal [call.node_key], dependencies(task)
    assert_equal %w[r1t0 r1t0-patch], dependencies(reader)
    assert_equal %w[round1 r1t0 r1t0-patch], reader.input_from_node_keys
    node_ids = agent_loop.agent_loop_nodes.order(:id).pluck(:id)
    edge_ids = agent_loop.agent_loop_edges.order(:id).pluck(:id)

    AgentLoops::ComposeJob.perform_now(call.id)

    assert_equal node_ids, agent_loop.agent_loop_nodes.order(:id).pluck(:id)
    assert_equal edge_ids, agent_loop.agent_loop_edges.order(:id).pluck(:id)
    assert_equal "completed", call.reload.status
    assert_not call.output_summary["is_error"]
    assert_includes call.output_body.effective_text, "Composed 1 task: r1t0-patch."
    assert_equal %w[r1t0 r1t0-patch], dependencies(reader.reload)
    assert_equal %w[round1 r1t0 r1t0-patch], reader.input_from_node_keys

    finish_patch(agent_loop)
  end

  test "a lost worker without redelivery expires the call and releases the already composed work" do
    agent_loop = interrupted_compose
    call = loop_node(agent_loop, "r1t0")
    assert_equal "queued", loop_node(agent_loop, "r1t0-patch").status

    travel_to(call.deadline_at + 1.second) do
      DatabaseClock.stub(:now, Time.current) do
        assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
      end
    end

    assert_equal %w[timed_out tool_timeout], call.reload.values_at(:status, :error_key)
    assert_nil call.output_body
    request = finish_patch(agent_loop)
    assert_includes request.to_json, "tool_timeout",
      "the caller sees the lost worker as well as the composed tool's eventual result"
  end

  private

    def interrupted_compose
      agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION, READ_TOOL]))
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      ))
      assert_predicate started, :accepted?
      schedule_loop!(agent_loop)
      run_loop_round!(agent_loop, sse_success("composing", tool_calls: [
        { id: "compose_call", name: "compose", arguments: {
          script: 'g.tool({ name: "read_file", input: { path: "patch.diff" }, key: "patch" });',
          wait: true,
        }.to_json },
      ]))
      call = loop_node(agent_loop, "r1t0")
      assert_equal "running", call.status
      AgentLoops::KernelTool.stub(:settle, ->(*) { raise IOError, "worker disappeared after append" }) do
        assert_raises(IOError) { AgentLoops::ComposeJob.perform_now(call.id) }
      end
      agent_loop
    end

    def finish_patch(agent_loop)
      task = loop_node(agent_loop, "r1t0-patch")
      reader = loop_node(agent_loop, "r1")
      schedule_loop!(agent_loop)
      assert_equal "dispatched", task.reload.status
      assert_equal "queued", reader.reload.status
      settled = AgentLoops::Parks::Settle.call(
        node: task, trusted: true, outcome: "completed", content: "PATCH RESULT"
      )
      assert_predicate settled, :applied?
      schedule_loop!(agent_loop)
      assert_equal "running", reader.reload.status
      request = round_request_entries(reader)
      results = request.filter_map { |entry| entry.dig("parts", 0, "text") }
        .select { |text| text.include?('<task_result task="r1t0-patch"') }
      assert_equal 1, results.length
      assert_includes results.sole, "PATCH RESULT"
      request
    end

    def dependencies(node)
      node.incoming_edges.includes(:from_node).map { |edge| edge.from_node.node_key }.sort
    end
end
