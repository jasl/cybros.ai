require "test_helper"
require "rho/role_declarations"
require_relative "support/environment_fixtures"

class RoleDeclarationsTest < Minitest::Test
  def preset(name, configuration = {}, role: nil)
    Rho::AgentPresets::Entry.new(public_id: SecureRandom.uuid_v7, name: name, description: name,
      configuration: Rho::AgentPresets::DEFAULT_CONFIGURATION.merge(configuration), role: role)
  end

  def base
    { tool_definitions: [{ "type" => "function", "canonical" => "nexus.conversation.spawn",
        "function" => { "name" => "Agent" }, "params" => { "agent_type" => { "maps_to" => "agent" } } }],
      kernel_tools: %w[nexus.memory.read nexus.memory.write], runner_executor_public_ids: ["runner"],
      runner_tool_names: %w[read bash edit], approval_mode: "bypass", approval_rules: [],
      prompt_mechanism: "assembly", prompt_template: Rho::RunDeclaration::PROMPT_TEMPLATE,
      compaction_policy: { "mode" => "kernel" }, default_model: "base/model", fallback_models: ["base/backup"] }
  end

  def compile(main, roles)
    Rho::RoleDeclarations.compile(preset: main, presets: roles, base: base, wire_names: {})
  end

  def test_roles_capture_independent_configurations_with_the_same_principal_and_own_conversation_memory
    worker = preset("Worker", { "model_mode" => "follow", "system_prompt" => "WORKER-PROMPT" },
      role: Rho::AgentPresets::Role.new(name: "worker", description: "Implement the supplied task"))
    result = compile(preset("Main", { "runner_tool_names" => ["read"] }), [worker])
    entry = result.fetch(:delegation_catalog).first
    child = entry.fetch("declaration")

    assert_equal "caller", entry.fetch("model_mode")
    assert_equal %w[read bash edit], child.fetch("runner_tool_names")
    assert_equal ["read"], result.fetch(:runner_tool_names)
    assert_equal "base/model", child.fetch("default_model")
    assert_equal ["base/backup"], child.fetch("fallback_models")
    assert_equal [{ "name" => "conversation", "source" => { "scope" => "conversation" }, "access" => "read_write" }],
      child.dig("memory_context_limit", "bindings")
    refute child.fetch("prompt_template").fetch("blocks").any? { |row| row["slot"] == "persona" }
    refute child.key?("delegation_catalog")
    refute child.key?("answering_user_public_id")
    assert_includes child.dig("system_prompt", "content"), "WORKER-PROMPT"
    assert_includes child.dig("system_prompt", "content"), "worker: Implement the supplied task"
  end

  def test_spawn_alias_selects_a_declaration_and_never_a_bot_identity
    role = preset("Review", {}, role: Rho::AgentPresets::Role.new(name: "reviewer", description: "Check the result"))
    result = compile(preset("Main"), [role])
    aliased = result.fetch(:tool_definitions).first

    assert_equal "Agent", aliased.dig("function", "name")
    assert_equal "declaration", aliased.dig("params", "agent_type", "maps_to")
    assert_includes aliased.fetch("omit"), "agent"
    assert_includes aliased.dig("params", "agent_type", "description"), "reviewer"
    assert_equal "default", result.fetch(:delegation_catalog).first.fetch("model_mode")
  end

  def test_default_investigation_roles_keep_web_reading_without_editing_tools
    store = RhoTest::EnvironmentFixtures::FakeStore.new
    catalog = Rho::AgentPresets.new(store: -> { store })
    entries = catalog.list
    available = base.merge(runner_tool_names: %w[read grep ls find bash edit write web_fetch browser_navigate])
    result = Rho::RoleDeclarations.compile(preset: catalog.fetch(catalog.main_preset_public_id), presets: entries,
      base: available, wire_names: {})
    roles = result.fetch(:delegation_catalog).to_h do |entry|
      [entry.fetch("name"), entry.fetch("declaration").fetch("runner_tool_names")]
    end

    %w[planner explorer reviewer].each do |name|
      selected = roles.fetch(name)
      assert_includes selected, "web_fetch", "#{name} needs to read referenced web documents"
      %w[edit write browser_navigate].each { |tool| refute_includes selected, tool }
    end
    %w[planner explorer].each { |name| refute_includes roles.fetch(name), "bash" }
    assert_includes roles.fetch("reviewer"), "bash", "reviewers retain the ability to run relevant checks"
  end

  def test_no_published_roles_captures_an_empty_catalog
    declaration = compile(preset("Main"), [])

    assert_empty declaration.fetch(:delegation_catalog)
    assert_includes declaration.dig(:system_prompt, "content"), "No Subagent roles are published"
  end

  def test_roles_inherit_only_the_callers_mcp_surface_and_can_disable_more_for_external_or_owner_audiences
    refs = 2.times.map { { "source" => "nexus", "connection_public_id" => SecureRandom.uuid_v7 } }
    directory = refs.each_with_index.map do |ref, index|
      { "ref" => ref, "available" => true, "tools" => ["read", "write"].map { |name| { "name" => name, "callable_name" => "account_#{index}_#{name}" } } }
    end
    main = preset("Main", { "mcp" => { "disabled_connections" => [refs.last], "disabled_tools" => [] } })
    worker = preset("Worker", { "mcp" => { "disabled_connections" => [], "disabled_tools" => [refs.first.merge("tool_name" => "write")] } },
      role: Rho::AgentPresets::Role.new(name: "worker", description: "Complete the task"))

    %w[owner external].each do |audience|
      result = Rho::RoleDeclarations.compile(preset: main, presets: [worker], base: base.merge(mcp_directory: directory),
        audience: audience, wire_names: { "nexus.memory.read" => "memory_read", "nexus.memory.write" => "memory_write", "nexus.conversation.spawn" => "spawn" })
      assert_equal %w[account_0_read account_0_write], result.fetch(:mcp_tools).map { |tool| tool.fetch("name") }
      child = result.fetch(:delegation_catalog).first
      assert_equal ["account_0_read"], child.fetch("inherited_tool_names")
      assert_empty child.fetch("declaration").fetch("mcp_tools")
      refute child.fetch("declaration").fetch("tool_definitions").any? { |tool| tool.dig("function", "name").start_with?("account_") }
    end
  end

  def test_external_mcp_rules_preserve_restrictions_and_only_authored_allows
    ref = { "source" => "nexus", "connection_public_id" => SecureRandom.uuid_v7 }
    directory = [{ "ref" => ref, "available" => true,
      "tools" => [{ "name" => "read", "callable_name" => "account_read" }] }]
    allow = { "tool" => "account_read", "verdict" => "allow" }
    restrictions = [
      { "tool" => "account_read", "path" => "project", "match" => "protected", "verdict" => "deny" },
      { "tool" => "account_read", "path" => "project", "match" => "shared", "verdict" => "ask" },
    ]
    available = base.merge(mcp_directory: directory, approval_rules: restrictions + [allow])
    original = Marshal.dump(available)
    role = Rho::AgentPresets::Role.new(name: "worker", description: "Complete the task")
    wires = { "nexus.memory.read" => "memory_read", "nexus.memory.write" => "memory_write", "nexus.conversation.spawn" => "spawn" }

    [nil, [allow]].each do |authored|
      main = preset("Main", { "approval_mode" => "rules", "approval_rules" => authored })
      worker = preset("Worker", main.configuration, role: role)
      %w[owner external].each do |audience|
        result = Rho::RoleDeclarations.compile(preset: main, presets: [worker], base: available, wire_names: wires, audience: audience)
        policies = [result.fetch(:approval_rules), result.fetch(:delegation_catalog).first.dig("declaration", "approval_rules")]
        policies.each do |rules|
          restrictions.each { |rule| assert_includes rules, rule }
          if audience == "owner" || authored
            assert_includes rules, allow
          else
            refute_includes rules, allow
          end
        end
        assert_equal ["account_read"], result.fetch(:mcp_tools).map { |tool| tool.fetch("name") }
        assert_equal ["account_read"], result.fetch(:delegation_catalog).first.fetch("inherited_tool_names")
      end
    end
    assert_equal original, Marshal.dump(available), "external compilation does not change the owner's base policy"
  end
end
