require "test_helper"

class AgentLoops::Scripts::LifecycleTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a lost script worker expires through the ordinary park sweep" do
    agent_loop = seed(script("lost", "return 1;", "on_failure" => "absorb"), model("report", "results" => ["lost"]))
    start!(agent_loop)
    node = loop_node(agent_loop, "lost")
    assert_equal "running", node.status
    assert_equal AgentLoopNodes::ToolTask::DEFAULT_TIMEOUT_MS, node.effective_timeout_ms

    travel_to(node.deadline_at + 1.second) do
      DatabaseClock.stub(:now, Time.current) do
        assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
      end
    end

    assert_equal %w[timed_out script_timeout], node.reload.values_at(:status, :error_key)
    schedule_loop!(agent_loop)
    assert_equal "running", loop_node(agent_loop, "report").status
    assert_includes round_request_entries(loop_node(agent_loop, "report")).to_json, "script_timeout"
    AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
    assert_nil node.reload.output_body
  end

  test "pause freezes the script park while its already started computation may settle" do
    agent_loop = seed(script("paused", 'g.tool({name: "read_file", input: {path: "a"}});'), model("report"))
    start!(agent_loop)
    node = loop_node(agent_loop, "paused")
    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    travel_to(node.deadline_at + 1.hour) do
      assert_not node.reload.deadline_passed?
      DatabaseClock.stub(:now, Time.current) do
        assert_equal 0, AgentLoops::Parks::TimeoutSweep.call[:expired]
      end
      AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
      assert_equal "completed", node.reload.status
      child = children(node).sole
      assert_equal "queued", child.status
      assert_predicate AgentLoops::Resume.call(AgentLoops::Resume::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_loop)
      assert_equal "dispatched", child.reload.status
    end
  end

  test "force stop while the isolate computes prevents publication" do
    agent_loop = seed(script("stopped", 'g.tool({name: "read_file", input: {path: "a"}});'), model("report"))
    start!(agent_loop)
    node = loop_node(agent_loop, "stopped")
    evaluate = Nexus::Compose::Evaluator.method(:stage)
    Nexus::Compose::Evaluator.stub(:stage, ->(**arguments) {
      result = evaluate.call(**arguments)
      assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.forced(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      result
    }) do
      AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
    end

    assert_equal "canceled", node.reload.status
    assert_empty children(node)
    assert_nil node.output_body
    assert_equal "canceled", loop_node(agent_loop, "report").status
  end

  test "expiry wins against a computed expansion before the timeout sweep" do
    agent_loop = seed(script("late", 'g.tool({name: "read_file", input: {path: "a"}});', "on_failure" => "absorb"), model("report"))
    start!(agent_loop)
    node = loop_node(agent_loop, "late")
    travel_to(node.deadline_at, with_usec: true) do
      AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
    end

    assert_equal %w[timed_out script_timeout], node.reload.values_at(:status, :error_key)
    assert_empty children(node)
    assert_nil node.output_body
  end

  test "explicit retry advances the generation and an old job cannot settle it" do
    agent_loop = seed(script("retry", 'throw new Error("no data");'), model("report"))
    start!(agent_loop)
    node = loop_node(agent_loop, "retry")
    old_generation = node.execution_generation
    AgentLoops::ScriptJob.perform_now(node.id, old_generation)
    schedule_loop!(agent_loop)
    assert_equal "needs_attention", agent_loop.reload.status
    assert_predicate AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: node.node_key, acting_user: @human
    )), :accepted?
    schedule_loop!(agent_loop)

    assert_equal old_generation + 1, node.reload.execution_generation
    assert_equal "running", node.status
    AgentLoops::ScriptJob.perform_now(node.id, old_generation)
    assert_equal "running", node.reload.status
    AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
    assert_equal "failed", node.reload.status
  end

  test "canceling a completed script reaches its reducer after an internal race settled" do
    agent_loop = seed(script("workflow", <<~JS), model("report", "results" => ["workflow"]))
      g.parallel([
        g.tool({name: "read_file", input: {path: "fast"}}),
        g.tool({name: "read_file", input: {path: "slow"}})
      ], {until: "any"});
      g.script({script: 'return "reduced";'});
    JS
    start!(agent_loop)
    root = loop_node(agent_loop, "workflow")
    AgentLoops::ScriptJob.perform_now(root.id, root.execution_generation)
    schedule_loop!(agent_loop)
    fast, slow = children(root).select(&:tool_call?).sort_by { |task| task.tool_input.fetch("path") }
    reducer = children(root).find(&:script?)
    settle!(fast, "winner")
    assert_equal "completed", root.reload.status
    assert_equal "running", reducer.reload.status
    assert_equal "canceled", slow.reload.status

    assert_predicate cancel(agent_loop, root), :accepted?
    assert_equal "completed", root.reload.status
    assert_equal "completed", fast.reload.status
    assert_equal %w[canceled canceled], [slow.reload.status, reducer.reload.status]
    assert_equal "queued", loop_node(agent_loop, "report").status
    schedule_loop!(agent_loop)
    report = loop_node(agent_loop, "report")
    assert_equal "running", report.status
    assert_includes round_request_entries(report).to_json, 'status=\\"canceled\\"'
  end

  test "canceling a script does not own the peer producer or its independent consumer" do
    agent_loop = seed(parallel(
      tool("shared", "read_file"),
      script("owner", "return 1;", "after" => ["shared"]),
      tool("consumer", "read_file", "after" => ["shared"])
    ), model("report"))
    start!(agent_loop)
    owner = loop_node(agent_loop, "owner")
    assert_equal "queued", owner.status
    assert_predicate cancel(agent_loop, owner), :accepted?
    assert_equal "dispatched", loop_node(agent_loop, "shared").status
    assert_equal "queued", loop_node(agent_loop, "consumer").status
    settle!(loop_node(agent_loop, "shared"), "SHARED")
    assert_equal "dispatched", loop_node(agent_loop, "consumer").status
  end

  test "canceling an expanded script closes its entire pending fan and final reducer" do
    agent_loop = seed(script("workflow", <<~JS), model("report"))
      g.parallel([
        g.tool({name: "read_file", input: {path: "one"}}),
        g.tool({name: "read_file", input: {path: "two"}})
      ]);
      g.script({script: 'return "reduced";'});
    JS
    start!(agent_loop)
    root = loop_node(agent_loop, "workflow")
    AgentLoops::ScriptJob.perform_now(root.id, root.execution_generation)
    schedule_loop!(agent_loop)
    tasks = children(root)
    assert_equal %w[dispatched dispatched queued], tasks.map(&:status)
    assert_predicate cancel(agent_loop, root), :accepted?
    assert tasks.all? { |task| task.reload.status == "canceled" }
    schedule_loop!(agent_loop)
    assert_equal "running", loop_node(agent_loop, "report").status
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

    def settle!(node, text)
      assert_predicate AgentLoops::Parks::Settle.call(
        node: node, trusted: true, outcome: "completed", content: text
      ), :applied?
      schedule_loop!(node.agent_loop)
    end

    def children(node)
      node.agent_loop.agent_loop_nodes.where(expansion_parent_id: node.id).order(:id).to_a
    end

    def cancel(agent_loop, node)
      AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
        agent_loop: agent_loop, task_key: node.node_key, acting_user: @human
      ))
    end
end
