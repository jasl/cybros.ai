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
    assert_equal [{ "name" => "conversation", "scope" => "conversation", "access" => "read_write" }],
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
end
