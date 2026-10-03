require "test_helper"

class AgentLoops::ToolSurfaceWorkTest < ActiveJob::TestCase
  include InvocationHarness

  READ_TOOL = {
    "type" => "function",
    "function" => {
      "name" => "read_file", "description" => "Read a file from the working directory.",
      "parameters" => {
        "type" => "object", "properties" => { "path" => { "type" => "string" } },
        "required" => ["path"],
      },
    },
  }.freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "a real round expansion validates its inherited declaration at most once" do
    agent_loop = seed(model("round1", "tools" => declarations))
    inherited = node(agent_loop, "round1").tool_definitions
    start!(agent_loop)
    apply_via(attempt(agent_loop), sse_success("Reading the file.", tool_calls: [
      { id: "call_read", name: "read_file", arguments: '{"path":"README.md"}' },
    ]))

    work = capture_work(Nexus::ToolDeclarations, :refusal) do
      AgentLoops::ConvergeTerminalSteps.call
    end

    assert_equal "completed", node(agent_loop, "round1").status
    assert_equal inherited, node(agent_loop, "r1").tool_definitions
    assert_equal ["read_file", { "path" => "README.md" }],
      node(agent_loop, "r1t0").attributes.values_at("tool_name", "tool_input")
    assert_operator work.fetch(:calls), :<=, 1,
      "one compilation must not repeat the same declaration refusal: #{measurement(inherited, work)}"
  end

  test "running and completing a round does not reencode its immutable tool declarations" do
    agent_loop = seed(model("round1", "tools" => declarations))
    inherited = node(agent_loop, "round1").tool_definitions

    work = capture_work(Nexus::CanonicalJson, :encode, only: inherited) do
      start!(agent_loop)
      assert_equal "running", node(agent_loop, "round1").status
      apply_via(attempt(agent_loop), sse_success("Finished."))
      AgentLoops::ConvergeTerminalSteps.call
    end

    assert_equal "completed", node(agent_loop, "round1").status
    assert_equal inherited, node(agent_loop, "round1").tool_definitions
    assert_equal 0, work.fetch(:calls),
      "status writes must reuse the declaration accepted at task creation: #{measurement(inherited, work)}"
  end

  test "new model tasks still reject unstorable request JSON" do
    agent_loop = seed(model("round1", "tools" => declarations))
    task = node(agent_loop, "round1").dup
    task.node_key = "new-round"
    task.request_options["invalid"] = "unstorable\u0000"
    task.tool_definitions.first.fetch("function")["description"] = "unstorable\u0000"

    assert_predicate task, :new_record?
    assert_not task.valid?
    assert task.errors.of_kind?(:request_options, :unsupported_text)
    assert task.errors.of_kind?(:tool_definitions, :unsupported_text)
  end

  test "in-place changes to readonly request JSON still get their boundary refusal" do
    agent_loop = seed(model("round1", "tools" => declarations))
    task = node(agent_loop, "round1")
    accepted = task.tool_definitions.deep_dup
    task.request_options["invalid"] = "unstorable\u0000"
    task.tool_definitions.first.fetch("function")["description"] = "unstorable\u0000"

    assert_not task.valid?
    assert task.errors.of_kind?(:request_options, :unsupported_text)
    assert task.errors.of_kind?(:tool_definitions, :unsupported_text)
    assert_equal({}, task.reload.request_options)
    assert_equal accepted, task.tool_definitions
  end

  private

    # The actual kernel schemas, with the reference Agent spelling and one
    # runner tool: size and nesting come from usable declarations, not padding.
    def declarations
      Nexus::ToolRegistry::LIVE.except("nexus.graph.task").values.map(&:function_definition) +
        [LoopLaneTestHelper::AGENT_ALIAS, READ_TOOL]
    end

    def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

    def start!(agent_loop)
      AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      clear_enqueued_jobs
      AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      clear_enqueued_jobs
    end

    def attempt(agent_loop)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      node(agent_loop, "round1").selected_model_invocation.attempts.order(:ordinal).last
    end

    # Count work while calling the real implementation. Timing and allocation
    # observations explain a failure; only the repeat count is a stable budget.
    def capture_work(receiver, name, only: nil)
      original = receiver.method(name)
      work = { calls: 0, allocated_objects: 0, elapsed_ms: 0.0 }
      counted = lambda do |value|
        next original.call(value) unless only.nil? || value == only

        before = GC.stat(:total_allocated_objects)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = original.call(value)
        work[:elapsed_ms] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
        work[:allocated_objects] += GC.stat(:total_allocated_objects) - before
        work[:calls] += 1
        result
      end
      receiver.stub(name, counted) { yield }
      work
    end

    def measurement(declarations, work)
      work.merge(declaration_bytes: JSON.generate(declarations).bytesize,
        elapsed_ms: work.fetch(:elapsed_ms).round(3)).inspect
    end
end
