require "support/daemon_run_helpers"

class DaemonNexusMcpTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  CONNECTION = "019b1000-0000-7000-8000-000000000099".freeze
  MODEL = { "ref" => "dev/model", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
    "unavailable_reason" => nil, "capabilities" => {}, "pricing" => { "state" => "unknown" } }.freeze

  class LocalRead
    NAME = "mcp__files__read".freeze
    DESCRIPTION = "Read through the existing local MCP server".freeze
    SCHEMA = { "type" => "object", "properties" => { "path" => { "type" => "string" } } }.freeze
    EFFECT_PROFILE = Rho::Env::Tools::Read::EFFECT_PROFILE
    MCP = { "server_key" => "files", "tool_name" => "read" }.freeze
    def initialize(**) = nil
    def call(_arguments) = Rho::Env::Result.ok("Local MCP result")
  end

  module LocalMcp
    NAME = "test.local_mcp".freeze
    def self.register(api) = api.register_tool(LocalRead, serves: :agent)
  end

  def ready(connections: {}, extensions: Rho::Extensions::DEFAULT_EXTENSIONS, task_detail: nil)
    @api = kernel_api(user_public_id: IDENTITY.user_public_id, events: [], models: [MODEL],
      workspaces: [{ public_id: "ws-1", name: "Home", dedicated: false }], mcp_connections: connections, task_detail: task_detail)
    @daemon = member_ready(boot(config: catalog_config("default_model" => "dev/model"), extensions: extensions,
      realtime_factory: ->(*) { nil }), @api)
  end

  def connection(tool = "read")
    { "public_id" => CONNECTION, "name" => "Work", "account_label" => "Work account", "enabled" => true, "available" => true,
      "tools" => [{ "name" => tool, "description" => "Use the work account", "input_schema" => { "type" => "object", "properties" => {} } }] }
  end

  def ref = { "source" => "nexus", "connection_public_id" => CONNECTION }

  def selection(tool = "read")
    { "connection_public_id" => CONNECTION, "tool_name" => tool, "name" => Rho::PresetExecution::Mcp.callable_name(ref, tool) }
  end

  def catalog = @daemon.context.agent_presets { |presets| presets }

  def select_main(**configuration)
    preset = catalog.fetch(catalog.main_preset_public_id)
    catalog.replace(preset.public_id, name: preset.name, description: preset.description, configuration: configuration)
  end

  def say(public_id, **fields)
    request(@daemon, :post, "/say", token: bearer(@daemon), body: { public_id: public_id, text: "Use the selected tool", wait: false }.merge(fields))
  end

  def open_bot
    preset = catalog.create(name: "Account tools", description: "Use the shared account", configuration: {
      "tools" => [], "runner_tool_names" => [], "model" => "dev/model",
    })
    bot = @daemon.context.declare_named_agent(name: "account", description: "Help with account work", preset_public_id: preset.public_id)
    @api.stock_principals([bot.to_h.transform_keys(&:to_s).slice("public_id", "handle", "kind", "display_name", "agent_identifier", "steward_public_id")])
    @daemon.context.replace_bot_settings(agent_public_id: bot.public_id, home_workspace_public_id: "ws-1")
    opened = request(@daemon, :post, "/bots/current", token: bearer(@daemon), body: { agent_public_id: bot.public_id, operation_id: "open-account" })
    assert_equal "200", opened.code, opened.body
    [bot, JSON.parse(opened.body).dig("current", "public_id")]
  end

  def test_default_mcp_reaches_declarations_inputs_and_standalone_and_explicit_off_changes_future_work
    ready(connections: { IDENTITY.user_public_id => [connection] })
    select_main(tools: [], runner_tool_names: [])
    store.remember(conversation_host("c-1"), workspace: "ws-1")

    before_reads = @api.requests.count { |path, _credential, _params| path == "/agent_api/v1/mcp_connections" }
    response = say("c-1", code_mode: false)
    assert_equal "200", response.code, response.body
    assert_equal before_reads + 1, @api.requests.count { |path, _credential, _params| path == "/agent_api/v1/mcp_connections" },
      "profile, Bot and role compilation share one live directory read for an input"
    first = @api.inputs.last.fetch("input")
    assert_equal [selection], first.dig("agent_configuration", "mcp_tools")
    assert_nil first["tool_names"], "the input keeps its complete explicit MCP selection"
    assert_equal [selection], @api.configuration_declarations.last.dig("configuration", "mcp_tools")
    assert_equal @api.configuration_declarations.last.dig("configuration", "delegation_catalog"), first.dig("agent_configuration", "delegation_catalog")
    assert_equal [selection], @api.tool_assemblies.last.dig("configuration", "mcp_tools")
    refute @api.tool_assemblies.last.key?("agent_public_id")
    declarations = @api.configuration_declarations.length

    response = say("c-1")
    assert_equal "200", response.code, response.body
    assert_equal declarations, @api.configuration_declarations.length
    assert @api.requests.any? { |path, _credential, _params| path == "/agent_api/v1/mcp_connections" }

    run = request(@daemon, :post, "/runs", token: bearer(@daemon), body: { prompt: "Account work", model: "dev/model", code_mode: false })
    assert_equal "201", run.code, run.body
    assert_includes JSON.parse(run.body).fetch("tools"), selection.fetch("name")
    assert_equal [selection], @api.run_creates.last.dig("run", "steps", 0, "model", "mcp_tools")

    select_main(mcp: { "disabled_connections" => [ref], "disabled_tools" => [] })
    response = say("c-1")
    assert_equal "200", response.code, response.body
    assert_empty @api.inputs.last.dig("input", "agent_configuration", "mcp_tools")
    assert_empty @api.configuration_declarations.last.dig("configuration", "mcp_tools")
    assert_equal [selection], first.dig("agent_configuration", "mcp_tools")
  end

  def test_bot_uses_the_same_human_connection_and_remote_code_is_not_rho_code_mode
    ready(connections: { IDENTITY.user_public_id => [connection("code")] })
    bot, conversation = open_bot

    response = say(conversation)

    assert_equal "200", response.code, response.body
    assert_equal bot.public_id, @api.tool_assemblies.last.fetch("agent_public_id")
    assert_equal [selection("code")], @api.tool_assemblies.last.dig("configuration", "mcp_tools")
    assert_equal [selection("code").fetch("name")], @api.inputs.last.dig("input", "tool_names")
    assert_equal [selection("code")], @api.configuration_declarations.last.dig("configuration", "mcp_tools")
    assert_nil @api.conversation_creates.last.dig("conversation", "default_runner_executor_public_id")
  end

  def test_external_bot_retains_mcp_while_keeping_its_private_runner_unselected
    ready(connections: { IDENTITY.user_public_id => [connection("code")] })
    bot, conversation = open_bot
    @daemon.context.replace_bot_settings(agent_public_id: bot.public_id, audience: "external")

    response = say(conversation)

    assert_equal "200", response.code, response.body
    declaration = @api.inputs.last.dig("input", "agent_configuration")
    assert_equal [selection("code")], declaration.fetch("mcp_tools")
    assert_empty declaration.fetch("runner_executor_public_ids")
    assert_includes declaration.fetch("approval_rules"), { "tool" => selection("code").fetch("name"), "verdict" => "allow" }
  end

  def test_private_session_mcp_grants_do_not_enter_external_bot_or_role_declarations
    held = { "kind" => "tool_task", "status" => "needs_approval", "tool_name" => "read", "tool_alias" => selection.fetch("name"),
      "tool_input" => {}, "on_failure" => "absorb", "visibility" => "visible", "created_at" => "2026-09-15T00:00:00Z",
      "target" => { "kind" => "mcp", "connection_public_id" => CONNECTION, "tool_name" => "read" } }
    ready(connections: { IDENTITY.user_public_id => [connection] }, task_detail: held)
    bot, conversation = open_bot
    preset = catalog.list.find { |entry| entry.name == "Account tools" }
    catalog.replace(preset.public_id, name: preset.name, description: preset.description,
      configuration: preset.configuration.merge("approval_mode" => "rules"))
    catalog.publish(preset.public_id, name: "account-worker", description: "Use the same account selection")
    @daemon.context.replace_bot_settings(agent_public_id: bot.public_id, audience: "external")
    store.remember(conversation_host("c-owner"), workspace: "ws-1", run_public_id: "al-9")

    approved = request(@daemon, :post, "/runs/approve", token: bearer(@daemon),
      body: { public_id: "al-9", task_key: "r1t0", always: true })
    assert_equal "200", approved.code, approved.body
    allow = { "tool" => selection.fetch("name"), "verdict" => "allow" }
    assert_equal allow, JSON.parse(approved.body).dig("grant", "rule")
    assert_includes @api.configuration_declarations.last.dig("configuration", "approval_rules"), allow

    response = say(conversation)
    assert_equal "200", response.code, response.body
    declaration = @api.inputs.last.dig("input", "agent_configuration")
    role = declaration.fetch("delegation_catalog").find { |entry| entry.fetch("name") == "account-worker" }
    assert_equal [selection], declaration.fetch("mcp_tools")
    assert_equal [selection.fetch("name")], role.fetch("inherited_tool_names")
    refute_includes declaration.fetch("approval_rules"), allow
    refute_includes role.dig("declaration", "approval_rules"), allow

    preset = catalog.fetch(preset.public_id)
    catalog.replace(preset.public_id, name: preset.name, description: preset.description,
      configuration: preset.configuration.merge("approval_rules" => [allow]))
    response = say(conversation)
    assert_equal "200", response.code, response.body
    declaration = @api.inputs.last.dig("input", "agent_configuration")
    role = declaration.fetch("delegation_catalog").find { |entry| entry.fetch("name") == "account-worker" }
    assert_includes declaration.fetch("approval_rules"), allow
    assert_includes role.dig("declaration", "approval_rules"), allow
  end

  def test_local_and_nexus_mcp_tools_with_the_same_remote_name_keep_distinct_callables
    ready(connections: { IDENTITY.user_public_id => [connection] }, extensions: Rho::Extensions::DEFAULT_EXTENSIONS + [LocalMcp])
    select_main(tools: [], runner_tool_names: [])
    store.remember(conversation_host("c-1"), workspace: "ws-1")

    response = say("c-1", code_mode: false)

    assert_equal "200", response.code, response.body
    names = @api.tool_assemblies.last.dig("configuration", "tool_definitions").map { |tool| tool.dig("function", "name") } +
      @api.tool_assemblies.last.dig("configuration", "mcp_tools").map { |tool| tool.fetch("name") }
    assert_includes names, "mcp__files__read"
    assert_includes names, selection.fetch("name")
    declaration = @api.configuration_declarations.last.fetch("configuration")
    local = declaration.fetch("tool_definitions").find { |tool| tool.dig("function", "name") == "mcp__files__read" }
    assert_equal LocalRead::SCHEMA, local.dig("function", "parameters")
    assert_equal [selection], declaration.fetch("mcp_tools")
    assert_empty declaration.fetch("runner_executor_public_ids")
  end
end
