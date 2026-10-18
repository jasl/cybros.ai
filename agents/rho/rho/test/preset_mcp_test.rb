require "test_helper"
require "rho/preset_execution"

class PresetMcpTest < Minitest::Test
  SELECTION = { "disabled_connections" => [], "disabled_tools" => [] }.freeze
  AGENT = "019b1000-0000-7000-8000-000000000001".freeze
  RUNNER = "019b1000-0000-7000-8000-000000000002".freeze

  def served(name = "mcp__files__read", remote: "read", server: "files")
    { "name" => name, "description" => "Read a document", "input_schema" => { "type" => "object", "properties" => {} },
      "mcp" => { "server_key" => server, "tool_name" => remote } }
  end

  def test_executor_identity_separates_same_servers_and_raw_tools_and_builds_existing_runner_routes
    agent = Rho::PresetExecution::Mcp.executor_connections(AGENT, [served], runner: false)
    runner = Rho::PresetExecution::Mcp.executor_connections(RUNNER, [served], runner: true, label: "Remote")
    directory = agent + runner
    base = { tool_definitions: [], mcp_tools: [] }
    declaration = Rho::PresetExecution::Mcp.apply(base, directory, SELECTION)
    definitions = declaration.fetch(:tool_definitions)

    assert_equal 2, definitions.length
    assert_equal 2, definitions.map { |tool| tool.dig("function", "name") }.uniq.length
    assert_nil definitions.first["route"]
    assert_equal({ "kind" => "runner", "runner_executor_public_id" => RUNNER, "tool_name" => "mcp__files__read" }, definitions.last.fetch("route"))
    assert definitions.all? { |tool| tool.fetch("defer_loading") }
    assert_equal "Remote", runner.first.fetch("account_label")
    refute Rho::PresetExecution::Mcp.public_directory(directory).to_json.include?("definition")

    off = SELECTION.merge("disabled_connections" => [agent.first.fetch("ref")])
    assert_equal [definitions.last], Rho::PresetExecution::Mcp.apply(base, directory, off).fetch(:tool_definitions)
    off = SELECTION.merge("disabled_tools" => [runner.first.fetch("ref").merge("tool_name" => "read")])
    assert_equal [definitions.first], Rho::PresetExecution::Mcp.apply(base, directory, off).fetch(:tool_definitions)
  end

  def test_only_explicit_metadata_classifies_mcp_and_reserved_characters_have_stable_bounded_callables
    ref = { "source" => "executor", "executor_public_id" => RUNNER, "server_key" => "Editor server / alpha" }
    ordinary = served.except("mcp")
    assert_empty Rho::PresetExecution::Mcp.executor_connections(RUNNER, [ordinary], runner: true)
    name = Rho::PresetExecution::Mcp.callable_name(ref, "検索/" + "long" * 100)
    assert_match(/\A[a-zA-Z0-9_-]{1,64}\z/, name)
    assert_equal name, Rho::PresetExecution::Mcp.callable_name(ref.to_a.reverse.to_h, "検索/" + "long" * 100)
    refute_equal name, Rho::PresetExecution::Mcp.callable_name(ref.merge("executor_public_id" => AGENT), "検索/" + "long" * 100)
  end

  def test_executor_aliases_preserve_served_name_rules_without_copying_each_guard
    directory = Rho::PresetExecution::Mcp.executor_connections(RUNNER, [served], runner: true)
    rules = [
      { "tool" => "mcp__files__read", "path" => "path", "match" => "/protected/*", "verdict" => "deny" },
      { "tool" => "mcp__files__*", "path" => "account", "match" => "work", "verdict" => "ask", "origin" => "author" },
      { "tool" => "mcp__files__read|read", "verdict" => "allow" },
    ]
    declaration = Rho::PresetExecution::Mcp.apply({ tool_definitions: [], approval_rules: rules }, directory, SELECTION)
    assert_equal rules, declaration.fetch(:approval_rules)
    assert_equal JSON.generate(rules).bytesize, JSON.generate(declaration.fetch(:approval_rules)).bytesize
    assert_equal declaration, Rho::PresetExecution::Mcp.apply(declaration, directory, SELECTION), "recompilation does not accumulate rules"
    assert_equal ["literal[tool]"], Rho::PresetExecution::Mcp.matching_names("literal[tool]", ["literalt", "literal[tool]"])
  end

  def test_renaming_a_nexus_connection_does_not_change_its_callable
    connection = CybrosAgent::Api::McpConnection.new(public_id: AGENT, name: "First label", account_label: "Work", enabled: true,
      available: true, tools: [{ "name" => "search", "description" => "Search" }])
    provider = Object.new
    provider.define_singleton_method(:list) { |**| Struct.new(:items, :next_after).new([connection], nil) }
    client = Struct.new(:mcp_connections).new(provider)
    first = Rho::PresetExecution::Mcp.directory(client: client, candidates: [], agent_public_id: AGENT, agent_tools: [])
    connection = connection.with(name: "Changed label", account_label: "Other display label")
    second = Rho::PresetExecution::Mcp.directory(client: client, candidates: [], agent_public_id: AGENT, agent_tools: [])
    assert_equal first.first.fetch("tools").first.fetch("callable_name"), second.first.fetch("tools").first.fetch("callable_name")
    assert_equal "Changed label", second.first.fetch("name")
  end

  def test_local_mcp_external_guards_and_default_roles_fit_the_existing_approval_bound
    schemas = { "echo" => { "text" => { "type" => "string" } }, "lookup" => { "key" => { "type" => "string" } },
      "paths" => { "paths" => { "type" => "array", "items" => { "type" => "string" } } }, "write" => { "text" => { "type" => "string" } } }
    entries = lambda do |server, names|
      names.map do |remote|
        served("mcp__#{server}__#{remote}", remote: remote, server: server)
          .merge("input_schema" => { "type" => "object", "properties" => schemas.fetch(remote, {}) })
      end
    end
    runner = entries.call("fx", %w[echo lookup paths hang exit])
    agent = entries.call("remote", %w[echo lookup paths hang exit write env])
    directory = Rho::PresetExecution::Mcp.executor_connections(AGENT, agent, runner: false) +
      Rho::PresetExecution::Mcp.executor_connections(RUNNER, runner, runner: true)
    roles = Rho::AgentPresets::SEEDS.filter_map { |entry| entry["role"] } + [{ "name" => "local-child", "description" => "Use local services." }]

    Dir.mktmpdir("rho-mcp-e2e") do |root|
      home = Rho::Home.new(base_url: "https://nexus.example", root: root, work_root: File.join(root, "work"))
      rules = Rho::RunDeclaration.approval_rules(roots: Rho.protected_roots(home), entries: runner + agent)
      base = { tool_definitions: [], kernel_tools: ["nexus.conversation.spawn"], approval_rules: rules, approval_mode: "bypass", prompt_template: nil }
      selected = Rho::PresetExecution::Mcp.apply(base, directory, SELECTION)
      names = Rho::PresetExecution::Mcp.names(directory, SELECTION)
      external = Rho::BotPolicy.external(selected, send_targets: [], spawn_roles: roles,
        wire_names: { "nexus.conversation.spawn" => "spawn" }, mcp_names: names)
      bytes = JSON.generate(external.fetch(:approval_rules)).bytesize
      assert_operator bytes, :<, 64 * 1024, "the real home roots, local tools and all published roles produced #{bytes} approval bytes"
      assert_equal 12, (external.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") } & names).length
      assert_equal roles.length, external.fetch(:approval_rules).count { |rule| rule["path"] == "declaration" }
    end
  end

  def test_exact_callable_collisions_preserve_ordinary_definitions_for_kernel_rejection
    runner = Rho::PresetExecution::Mcp.executor_connections(RUNNER, [served], runner: true)
    imported = runner.first.fetch("tools").first.fetch("definition")
    different_runner = imported.merge("route" => imported.fetch("route").merge("runner_executor_public_id" => AGENT))
    plain = imported.except("route")
    base = { tool_definitions: [plain, different_runner], approval_rules: [] }
    result = Rho::PresetExecution::Mcp.apply(base, runner, SELECTION)
    assert_equal [plain, different_runner, imported], result.fetch(:tool_definitions)
    assert_equal [plain, different_runner], Rho::PresetExecution::Mcp.without_imports(result.fetch(:tool_definitions), runner)

    nexus = [{ "ref" => { "source" => "nexus", "connection_public_id" => AGENT }, "available" => true,
      "tools" => [{ "name" => "read", "callable_name" => plain.fetch("function").fetch("name") }] }]
    result = Rho::PresetExecution::Mcp.apply(base, nexus, SELECTION)
    assert_equal [plain, different_runner], result.fetch(:tool_definitions)
    assert_equal 1, result.fetch(:mcp_tools).length
  end

  def test_recompilation_replaces_prior_executor_imports_instead_of_leaking_disabled_tools
    directory = Rho::PresetExecution::Mcp.executor_connections(RUNNER, [served], runner: true)
    selected = Rho::PresetExecution::Mcp.apply({ tool_definitions: [], mcp_tools: [] }, directory, SELECTION)
    disabled = SELECTION.merge("disabled_connections" => [directory.first.fetch("ref")])
    narrowed = Rho::PresetExecution::Mcp.apply(selected, directory, disabled)

    assert_empty narrowed.fetch(:tool_definitions)
    assert_equal 1, selected.fetch(:tool_definitions).length
  end
end
