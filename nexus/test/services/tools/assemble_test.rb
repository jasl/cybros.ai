require "test_helper"

class Tools::AssembleTest < ActiveSupport::TestCase
  setup do
    @agent = users(:agent)
    @runner_a = runner("assembly-a", "Local", tools: [announced("read"), announced("code"), announced("skill")])
    @runner_b = runner("assembly-b", "Build", tools: [announced("read", required: %w[path encoding])])
    @agent.update!(approval_mode: "bypass", runner_executor_public_ids: [@runner_b.public_id, @runner_a.public_id])
  end

  test "only the selected Runner contributes exact schemas while candidates retain declared order" do
    selected = assemble(runner: @runner_a)
    assert_predicate selected, :accepted?
    assert_equal %w[code read skill], selected.definitions.map { |entry| entry.fetch("route").fetch("tool_name") }
    read = selected.definitions.find { |entry| entry.dig("function", "name") == "read" }
    assert_equal @runner_a.serving("read").fetch("input_schema"), read.dig("function", "parameters")
    assert_equal @runner_a.public_id, read.dig("route", "runner_executor_public_id")
    assert_equal [@runner_b.public_id, @runner_a.public_id], selected.environment.fetch("runner_candidates")
      .map { |entry| entry.fetch("runner_executor_public_id") }
    assert_equal [@runner_a.public_id], selected.environment.fetch("executors").map { |entry| entry.fetch("runner_executor_public_id") }

    remote = assemble(runner: @runner_b)
    assert_equal %w[path encoding], remote.definitions.sole.dig("function", "parameters", "required")
    assert_equal @runner_b.public_id, remote.definitions.sole.dig("route", "runner_executor_public_id")
    assert_equal selected.environment.fetch("runner_candidates"), remote.environment.fetch("runner_candidates")
  end

  test "no selected Runner keeps candidate knowledge without importing tools" do
    result = assemble
    assert_predicate result, :accepted?
    assert_empty result.definitions
    assert_nil result.environment.fetch("default_runner_executor_public_id")
    assert_empty result.environment.fetch("executors")
    assert_equal 2, result.environment.fetch("runner_candidates").length
  end

  test "Runner allowlists import only the selected Runner's exact available model tools" do
    @agent.update!(runner_tool_names: [])
    result = assemble(runner: @runner_a)
    assert_predicate result, :accepted?
    assert_empty result.definitions

    @agent.update!(runner_tool_names: %w[read code missing])
    local = assemble(runner: @runner_a)
    assert_predicate local, :accepted?
    assert_equal %w[code read], Nexus::ToolDeclarations.names(local.definitions)
    remote = assemble(runner: @runner_b)
    assert_predicate remote, :accepted?
    assert_equal ["read"], Nexus::ToolDeclarations.names(remote.definitions)
    assert_equal @runner_b.public_id, remote.definitions.sole.dig("route", "runner_executor_public_id")
    assert_equal @runner_b.serving("read").fetch("input_schema"), remote.definitions.sole.dig("function", "parameters")

    @agent.update!(runner_tool_names: %w[missing Read])
    result = assemble(runner: @runner_a)
    assert_predicate result, :accepted?
    assert_empty result.definitions
    assert_equal :tool_not_declared, assemble(runner: @runner_a, tool_names: ["missing"]).refusal
  end

  test "operator-only announcements do not become model tools" do
    @runner_a.announce(tools: [announced("read"), { "name" => "capture", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }])
    assert_equal ["read"], Nexus::ToolDeclarations.names(assemble(runner: @runner_a).definitions)
    @agent.update!(runner_tool_names: ["capture"])
    result = assemble(runner: @runner_a)
    assert_predicate result, :accepted?
    assert_empty result.definitions
  end

  test "kernel plain selection and aliases compose through the existing rendering grammar" do
    alias_entry = { "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.conversation.spawn" }
    @agent.update!(tool_definitions: Nexus::ToolDeclarations.render([alias_entry]))
    assert_equal ["Agent"], Nexus::ToolDeclarations.names(assemble.definitions)
    @agent.update!(kernel_tools: %w[nexus.conversation.spawn nexus.runners.list])
    result = assemble
    assert_equal %w[Agent runners_list spawn], Nexus::ToolDeclarations.names(result.definitions)
    assert_nil Nexus::ToolDeclarations.refusal(result.definitions)
    assert_includes result.definitions.find { |entry| entry.dig("function", "name") == "runners_list" }
      .dig("function", "description"), "pass its UUID to spawn"

    @agent.update!(tool_definitions: [Nexus::Tools::SPAWN])
    assert_equal %w[runners_list spawn], Nexus::ToolDeclarations.names(assemble.definitions), "an explicitly declared plain tool is not duplicated"
  end

  test "Runner name collisions receive stable qualified callables without changing schemas or routes" do
    custom = { "type" => "function", "function" => { "name" => "code", "description" => "Application orchestration",
      "parameters" => { "type" => "object" } } }
    @agent.update!(tool_definitions: [custom], kernel_tools: ["nexus.skill.load"])
    result = assemble(runner: @runner_a)
    assert_predicate result, :accepted?
    assert_includes result.definitions, custom
    assert_includes Nexus::ToolDeclarations.names(result.definitions), "skill"
    %w[code skill].each do |name|
      routed = result.definitions.find { |entry| entry.dig("route", "tool_name") == name }
      assert_match(/\A#{name}__[a-f0-9]{12}\z/, Nexus::ToolDeclarations.name_of(routed))
      assert_equal @runner_a.public_id, routed.dig("route", "runner_executor_public_id")
      assert_equal @runner_a.serving(name).fetch("input_schema"), routed.dig("function", "parameters")
      assert_equal Nexus::ToolDeclarations.name_of(routed), Nexus::ToolDeclarations.name_of(
        assemble(runner: @runner_a).definitions.find { |entry| entry.dig("route", "tool_name") == name })
    end
    collision = result.definitions.find { |entry| entry.dig("route", "tool_name") == "code" }.except("route")
    @agent.update!(tool_definitions: [custom, collision])
    assert_equal :duplicate_tool_name, assemble(runner: @runner_a).refusal
  end

  test "a compact identity declaration keeps explicit deferral while deduplicating a selected plain import" do
    identity = { "type" => "function", "function" => { "name" => "skill" },
      "canonical" => "nexus.skill.load", "defer_loading" => true }
    @agent.update!(tool_definitions: Nexus::ToolDeclarations.render([identity]), kernel_tools: ["nexus.skill.load"])
    result = assemble
    assert_predicate result, :accepted?
    assert_equal ["skill"], Nexus::ToolDeclarations.names(result.definitions)
    assert_equal true, result.definitions.sole.fetch("defer_loading")
  end

  test "candidate eligibility is current at assembly and does not depend on connection presence" do
    assert_nil @runner_b.presence_connection_id
    assert_predicate assemble(runner: @runner_b), :accepted?
    @agent.update!(runner_executor_public_ids: [@runner_a.public_id])
    assert_equal :runner_not_declared, assemble(runner: @runner_b).refusal
    @agent.update!(runner_executor_public_ids: [@runner_b.public_id, @runner_a.public_id])
    @runner_b.revoke_credentials
    assert_equal :runner_not_eligible, assemble(runner: @runner_b).refusal
    assert_equal [@runner_a.public_id], assemble.environment.fetch("runner_candidates").map { |entry| entry.fetch("runner_executor_public_id") }
  end

  test "explicit Runner routes remain independent capabilities and freeze their environment" do
    explicit = { "type" => "function", "function" => { "name" => "remote_read", "description" => "Read on Build",
      "parameters" => @runner_b.serving("read").fetch("input_schema") },
      "route" => { "kind" => "runner", "runner_executor_public_id" => @runner_b.public_id, "tool_name" => "read" } }
    @agent.update!(runner_executor_public_ids: [], tool_definitions: [explicit])
    result = assemble
    assert_predicate result, :accepted?
    assert_equal [explicit], result.definitions
    assert_empty result.environment.fetch("runner_candidates")
    assert_equal [@runner_b.public_id], result.environment.fetch("executors").map { |entry| entry.fetch("runner_executor_public_id") }
    frozen = result.environment.deep_dup
    @runner_b.announce(tools: [], environment: { "fragments" => [{ "text" => "Changed machine" }] })
    assert_equal frozen, result.environment
    assert_equal :tool_not_served, assemble.refusal
    @runner_b.revoke_credentials
    assert_equal :runner_not_eligible, assemble.refusal
  end

  test "turn narrowing is exact and retains candidate knowledge" do
    result = assemble(runner: @runner_a, tool_names: ["read"])
    assert_equal ["read"], Nexus::ToolDeclarations.names(result.definitions)
    assert_equal 2, result.environment.fetch("runner_candidates").length
    assert_equal :tool_not_declared, assemble(runner: @runner_a, tool_names: ["missing"]).refusal
  end

  test "narrowing re-renders macros when it removes the preferred alias" do
    aliases = %w[AgentA AgentB].map { |name| { "name" => name, "canonical" => "nexus.graph.delegate_task" } }
    @agent.update!(tool_definitions: Nexus::ToolDeclarations.render(aliases + [Nexus::Tools::SPAWN]))
    result = assemble(tool_names: %w[AgentB spawn])
    assert_predicate result, :accepted?
    assert_nil Nexus::ToolDeclarations.refusal(result.definitions)
    spawn = result.definitions.find { |entry| Nexus::ToolDeclarations.name_of(entry) == "spawn" }
    assert_includes spawn.dig("function", "description"), "AgentB"
    assert_not_includes spawn.dig("function", "description"), "AgentA"
  end

  test "UUID case does not change a declared candidate identity" do
    @agent.update!(runner_executor_public_ids: [@runner_a.public_id.upcase])
    result = assemble(runner: @runner_a)
    assert_predicate result, :accepted?
    assert_equal @runner_a.public_id, result.environment.fetch("runner_candidates").sole.fetch("runner_executor_public_id")
    @agent.runner_executor_public_ids = [@runner_a.public_id, @runner_a.public_id.upcase]
    assert_not @agent.valid?
    assert @agent.errors.of_kind?(:runner_executor_public_ids, :invalid)
  end

  test "explicit routes use the same UUID identity normalization as candidates" do
    explicit = { "type" => "function", "function" => { "name" => "remote_read", "description" => "Read on Build",
      "parameters" => @runner_b.serving("read").fetch("input_schema") },
      "route" => { "kind" => "runner", "runner_executor_public_id" => @runner_b.public_id.upcase, "tool_name" => "read" } }
    @agent.update!(runner_executor_public_ids: [], tool_definitions: [explicit])
    result = assemble
    assert_predicate result, :accepted?
    assert_equal @runner_b.public_id, result.definitions.sole.dig("route", "runner_executor_public_id")
    assert_equal @runner_b.public_id, result.environment.fetch("executors").sole.fetch("runner_executor_public_id")
    assert_equal explicit.fetch("function"), result.definitions.sole.fetch("function")
    assert_equal @runner_b.public_id.upcase, @agent.tool_definitions.sole.dig("route", "runner_executor_public_id")
  end

  private

    def assemble(**options) = Tools::Assemble.for_profile(profile: @agent, **options)

    def announced(name, required: ["path"])
      { "name" => name, "description" => "#{name} in this environment", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
        "input_schema" => { "type" => "object", "properties" => { "path" => { "type" => "string" },
          "encoding" => { "type" => "string" } }, "required" => required, "additionalProperties" => false } }
    end

    def runner(identifier, display_name, tools:)
      connect_runner(manager: users(:owner), registration_identifier: identifier,
        display_name: display_name, assignment_scope: :account_wide).executor_access_token.task_executor.tap do |row|
        outcome = row.announce(tools: tools, environment: { "fragments" => [{ "text" => display_name }] })
        assert_predicate outcome, :accepted?
      end
    end
end
