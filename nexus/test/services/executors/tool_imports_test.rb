require "test_helper"

class Executors::ToolImportsTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @runner_a = runner("imports-a", "Local", "path")
    @runner_b = runner("imports-b", "Build", "document")
  end

  test "standalone model imports freeze the selected schema target and ordered candidate environments" do
    run = seed(model("plan", **imports), default_runner_executor_public_id: @runner_b.public_id)
    row = task(run, "plan")
    assert_equal %w[read runners_list], Nexus::ToolDeclarations.names(row.tool_definitions)
    read = row.tool_definitions.find { |entry| entry.dig("function", "name") == "read" }
    assert_equal ["document"], read.dig("function", "parameters", "required")
    assert_equal @runner_b.public_id, read.dig("route", "runner_executor_public_id")
    context = Executors::TaskOperations::Context.defaults(row)
    assert_equal @runner_b.public_id, context.dig("environment", "default_runner_executor_public_id")
    assert_equal [@runner_b.public_id, @runner_a.public_id], context.dig("environment", "runner_candidates")
      .map { |entry| entry.fetch("runner_executor_public_id") }
    assert_equal [], context.dig("environment", "skills")
    assert_empty Nexus::ToolImports::FIELDS.map(&:to_s) & context.keys

    frozen = row.tool_definitions.deep_dup
    @runner_b.announce(services: { @runner_b.executor_kind => { "tools" => [announced("read", "changed")], "environment" => { "fragments" => [{ "text" => "Later" }] } } })
    assert_equal frozen, row.reload.tool_definitions
    assert_equal "Build", row.operation_context.dig("environment", "executors", 0, "environment", "fragments", 0, "text")
  end

  test "standalone continuation defaults import their own environment without changing the explicit execution target" do
    run = seed(tool("program", "code", "route" => {
      "kind" => "runner", "runner_executor_public_id" => @runner_a.public_id,
    }, "model_defaults" => imports.merge("model" => { "model" => "dev/mock-text" })),
      default_runner_executor_public_id: @runner_b.public_id)
    row = task(run, "program")
    assert_equal @runner_a.public_id, row.target_executor_public_id
    context = Executors::TaskOperations::Context.defaults(row)
    assert_equal @runner_b.public_id, context.dig("environment", "default_runner_executor_public_id")
    read = context.fetch("tools").find { |entry| entry.dig("function", "name") == "read" }
    assert_equal @runner_b.public_id, read.dig("route", "runner_executor_public_id")
    assert_empty Nexus::ToolImports::FIELDS.map(&:to_s) & context.keys
  end

  test "model-origin work can narrow frozen tools but cannot introduce import intent" do
    run = seed(model("plan", **imports), default_runner_executor_public_id: @runner_b.public_id)
    source = task(run, "plan")
    lower = Executors::TaskOperations::Lower.new(source)
    Nexus::ToolImports::FIELDS.each do |field|
      error = assert_raises(Executors::TaskOperations::Lower::Refusal) do
        lower.call([{ "model" => { "prompt" => "another model", field.to_s => [] } }])
      end
      assert_equal :context_not_authorable, error.code
    end

    assert_predicate Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
      host: run, executor_public_id: @runner_a.public_id, acting_user: @human)), :accepted?
    children = lower.call([{ "model" => { "key" => "child", "prompt" => "Inspect one file", "tools" => ["read"] } }])
    appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, steps: children, tip: Runs::Tasks::Tip.seed(Runs::Tasks::Compile::BRANCH),
      origin: "model", expansion_parent: source))
    assert_predicate appended, :applied?
    child = task(run, "child")
    assert_equal ["read"], Nexus::ToolDeclarations.names(child.tool_definitions)
    assert_equal @runner_b.public_id, child.tool_definitions.sole.dig("route", "runner_executor_public_id")
    assert_equal source.operation_context.fetch("environment"), child.operation_context.fetch("environment")
  end

  test "an image operation from a text round requires its own model and inherits no text request policy" do
    run = seed(model("plan", **imports, "model" => { "model" => "dev/mock-text", "reasoning_effort" => "high" },
      "instructions" => "Text instructions", "configuration" => { "temperature" => 0.2 },
      "compaction" => { "mode" => "kernel" }, "fan_on_failure" => "absorb",
      "fallback_models" => ["dev/mock-unmetered"]), default_runner_executor_public_id: @runner_b.public_id)
    source = task(run, "plan")
    lower = Executors::TaskOperations::Lower.new(source)
    fields = { "key" => "image", "workload" => "image_generation", "prompt" => "A blue bird" }
    missing = Runs::Tasks::Compile.call(lower.call([{ "model" => fields }]),
      Runs::Tasks::Tip.seed(Runs::Tasks::Compile::BRANCH), kernel: true)
    assert_equal "invalid_model", missing.errors.sole.fetch("code")

    children = lower.call([{ "model" => fields.merge("model" => "dev/mock-image",
      "configuration" => { "result_count" => 2 }) }])
    appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, steps: children, tip: Runs::Tasks::Tip.seed(Runs::Tasks::Compile::BRANCH),
      origin: "model", expansion_parent: source))
    assert_predicate appended, :applied?, appended.errors.inspect
    child = task(run, "image")
    assert_equal "image_generation", child.workload
    assert_equal "mock-image", child.model_ref
    assert_equal "dev/mock-image", child.model_selection.model
    assert_equal({ "result_count" => 2 }, child.request_options)
    assert_empty child.fallback_models
    assert_empty Array(child.tool_definitions)
    assert_nil child.reasoning_effort
    assert_nil child.reasoning_enabled
    assert_nil child.system_instructions
    assert_nil child.compaction
    assert_nil child.fan_on_failure
    assert_nil child.operation_context
    assert_equal source.on_failure, child.on_failure
  end

  test "a selected Runner must be declared and exact import filters cannot widen" do
    refused = create_loop(model("plan", **imports.merge("runner_executor_public_ids" => [@runner_a.public_id])),
      default_runner_executor_public_id: @runner_b.public_id)
    assert_equal :runner_not_declared, refused.outcome
    run = seed(model("plan", **imports.merge("runner_tool_names" => ["missing"])),
      default_runner_executor_public_id: @runner_b.public_id)
    assert_equal ["runners_list"], Nexus::ToolDeclarations.names(task(run, "plan").tool_definitions)

    run = seed(model("plan", **imports.merge("runner_tool_names" => [])),
      default_runner_executor_public_id: @runner_b.public_id)
    assert_equal ["runners_list"], Nexus::ToolDeclarations.names(task(run, "plan").tool_definitions)
  end

  test "model steps and continuation defaults use the Profile import grammar at their own boundary" do
    invalid = imports.merge("kernel_tools" => ["runners_list"])
    result = create_loop(model("plan", **invalid), default_runner_executor_public_id: @runner_b.public_id)
    assert_equal :invalid_steps, result.outcome
    assert_equal "invalid_kernel_tools", result.errors.sole.fetch("code")
    assert_equal "steps[0].kernel_tools", result.errors.sole.fetch("path")
    result = create_loop(tool("program", "code", "model_defaults" => invalid),
      default_runner_executor_public_id: @runner_b.public_id)
    assert_equal :invalid_steps, result.outcome
    assert_equal "invalid_kernel_tools", result.errors.sole.fetch("code")
    assert_equal "steps[0].model_defaults.kernel_tools", result.errors.sole.fetch("path")
  end

  test "an explicitly frozen empty skill catalog is never refreshed while inheriting work" do
    run = seed(model("plan", **imports), default_runner_executor_public_id: @runner_b.public_id)
    source = task(run, "plan")
    assert_equal [], source.operation_context.dig("environment", "skills")
    @runner_b.announce(services: { @runner_b.executor_kind => { "tools" => [announced("read", "document"), announced("skill", "name")],
      "documents" => [{ "name" => "new-skill", "description" => "Published after acceptance" }] } })
    payload = {
      "type" => Tasks::ModelTask.sti_name, "tool_definitions" => source.tool_definitions,
      "operation_context" => source.operation_context.deep_dup,
    }
    assert_nil Executors::Targets.prepare(run: run, payload: payload, model_origin: true)
    assert_equal [], payload.dig("operation_context", "environment", "skills")
  end

  test "candidate environment facts obey the accepted context bound in aggregate" do
    candidates = 18.times.map do |index|
      row = runner("large-candidate-#{index}", "Build #{index}", "path")
      assert_predicate row.announce(services: { row.executor_kind => { "tools" => [], "environment" => { "text" => "x" * 60_000 } } }), :accepted?
      row.public_id
    end
    assert_no_difference -> { Run.count } do
      result = create_loop(model("plan", "kernel_tools" => ["nexus.runners.list"],
        "runner_executor_public_ids" => candidates, "runner_tool_names" => []), default_runner_executor_public_id: nil)
      assert_equal :content_too_large, result.outcome
    end
  end

  private

    def imports
      { "kernel_tools" => ["nexus.runners.list"], "runner_executor_public_ids" => [@runner_b.public_id, @runner_a.public_id],
        "runner_tool_names" => ["read"] }
    end

    def task(run, key) = run.tasks.find_by!(node_key: key)

    def announced(name, parameter)
      { "name" => name, "description" => "#{name} in this environment", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
        "input_schema" => { "type" => "object", "properties" => { parameter => { "type" => "string" } },
          "required" => [parameter], "additionalProperties" => false } }
    end

    def runner(identifier, display_name, parameter)
      connect_runner(manager: users(:owner), registration_identifier: identifier,
        display_name: display_name, assignment_scope: :account_wide).executor_access_token.executor.tap do |row|
        outcome = row.announce(services: { row.executor_kind => { "tools" => [announced("read", parameter), announced("code", "code")],
          "environment" => { "fragments" => [{ "text" => display_name }] } } })
        assert_predicate outcome, :accepted?
      end
    end
end
