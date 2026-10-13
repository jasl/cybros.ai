require "test_helper"

class AgentRuns::ToolSurfaceWorkTest < ActiveJob::TestCase
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

  test "a multi-runner round expands a declaration larger than one operation envelope with one validation" do
    agent_run = seed(model("round1", "tools" => multi_runner_declarations,
      "model" => { "model" => "dev/mock-windowless" }))
    inherited = node(agent_run, "round1").tool_definitions
    assert_operator Nexus::SizeBounds.json_bytesize(inherited), :>, Nexus::SizeBounds.fetch(:envelope_bound)
    start!(agent_run)
    apply_via(attempt(agent_run), sse_success("Reading the file.", tool_calls: [
      { id: "call_read", name: "read_file", arguments: '{"path":"README.md"}' },
    ]))

    work = capture_work(Nexus::ToolDeclarations, :refusal) do
      AgentRuns::ConvergeTerminalSteps.call
    end

    assert_equal "completed", node(agent_run, "round1").status
    assert_equal inherited, node(agent_run, "r1").tool_definitions
    assert_equal ["read_file", { "path" => "README.md" }],
      node(agent_run, "r1t0").attributes.values_at("tool_name", "tool_input")
    assert_operator work.fetch(:calls), :<=, 1,
      "one compilation must not repeat the same declaration refusal: #{measurement(inherited, work)}"

    standalone = seed(tool("large-context", "read_file", "model_defaults" => {
      "model" => { "model" => "dev/mock-windowless" }, "tools" => inherited,
    }))
    frozen = node(standalone, "large-context").operation_context
    assert_operator Nexus::SizeBounds.json_bytesize(frozen), :>, Nexus::SizeBounds.fetch(:envelope_bound)
    assert_equal inherited, frozen.fetch("tools"), "a standalone continuation freezes the same aggregate declaration"
  end

  test "a model task accepts the exact declaration field bound and refuses the next byte" do
    agent_run = seed(model("round1", "tools" => declarations))
    task = node(agent_run, "round1").dup
    task.node_key = "large-declaration"
    tools = [READ_TOOL.deep_merge("function" => { "description" => "" })]
    bound = Nexus::SizeBounds.fetch(:tool_definitions_bound)
    tools.first.fetch("function")["description"] = "x" * (bound - Nexus::SizeBounds.json_bytesize(tools))
    task.tool_definitions = tools

    assert_equal bound, Nexus::SizeBounds.json_bytesize(task.tool_definitions)
    assert_predicate task, :valid?
    task.tool_definitions.first.fetch("function")["description"] += "x"
    assert_not task.valid?
    assert task.errors.of_kind?(:tool_definitions, :content_too_large)
  end

  test "running and completing a round does not reencode its immutable tool declarations" do
    agent_run = seed(model("round1", "tools" => declarations))
    inherited = node(agent_run, "round1").tool_definitions

    work = capture_work(Nexus::CanonicalJson, :encode, only: inherited) do
      start!(agent_run)
      assert_equal "running", node(agent_run, "round1").status
      apply_via(attempt(agent_run), sse_success("Finished."))
      AgentRuns::ConvergeTerminalSteps.call
    end

    assert_equal "completed", node(agent_run, "round1").status
    assert_equal inherited, node(agent_run, "round1").tool_definitions
    assert_equal 0, work.fetch(:calls),
      "status writes must reuse the declaration accepted at task creation: #{measurement(inherited, work)}"
  end

  test "new model tasks still reject unstorable request JSON" do
    agent_run = seed(model("round1", "tools" => declarations))
    task = node(agent_run, "round1").dup
    task.node_key = "new-round"
    task.request_options["invalid"] = "unstorable\u0000"
    task.tool_definitions.first.fetch("function")["description"] = "unstorable\u0000"

    assert_predicate task, :new_record?
    assert_not task.valid?
    assert task.errors.of_kind?(:request_options, :unsupported_text)
    assert task.errors.of_kind?(:tool_definitions, :unsupported_text)
  end

  test "in-place changes to readonly request JSON still get their boundary refusal" do
    agent_run = seed(model("round1", "tools" => declarations))
    task = node(agent_run, "round1")
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

    # Each environment owns its function schemas even when another Runner serves
    # matching tool names. Their aggregate may outgrow a single operation envelope.
    def multi_runner_declarations
      names = (1..40).map { |index| "read_file_#{index}" }
      routed = (1..4).flat_map do |index|
        runner = connect_runner(manager: users(:owner), registration_identifier: "tool-surface-#{index}",
          display_name: "Environment #{index}", assignment_scope: :account_wide).executor_access_token.task_executor
        assert_predicate runner.announce(tools: names.map { |name|
          { "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
        }), :accepted?
        names.map do |name|
          READ_TOOL.deep_merge("function" => { "name" => "environment_#{index}_#{name}" }).merge(
            "route" => { "kind" => "runner", "runner_executor_public_id" => runner.public_id, "tool_name" => name })
        end
      end
      declarations + routed
    end

    # The actual kernel schemas, with the reference Agent spelling and one
    # runner tool: size and nesting come from usable declarations, not padding.
    def declarations
      Nexus::ToolRegistry::LIVE.except("nexus.graph.delegate_task").values.map(&:function_definition) +
        [RunLaneTestHelper::AGENT_ALIAS, READ_TOOL]
    end

    def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

    def start!(agent_run)
      AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
      clear_enqueued_jobs
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      clear_enqueued_jobs
    end

    def attempt(agent_run)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      node(agent_run, "round1").selected_model_invocation.attempts.order(:ordinal).last
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
