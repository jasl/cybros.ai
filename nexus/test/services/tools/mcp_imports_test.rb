require "test_helper"

class Tools::McpImportsTest < ActiveSupport::TestCase
  setup do
    @agent = users(:agent)
    @personal = connection("Personal")
    @work = connection("Work")
    @agent.update!(approval_mode: "ask", runner_tool_names: [])
  end

  test "omission and empty imports expose no tool and selection freezes both same-named authorities" do
    assert_empty assemble.definitions
    @agent.update!(mcp_tools: [])
    assert_empty assemble.definitions
    @agent.update!(mcp_tools: [selection(@personal, "personal_search"), selection(@work, "work_search")])

    result = assemble
    assert_predicate result, :accepted?
    assert_equal %w[personal_search work_search], Nexus::ToolDeclarations.names(result.definitions)
    routes = result.definitions.map { |entry| entry.fetch("route") }
    assert_equal [@personal.public_id, @work.public_id], routes.map { |route| route.fetch("connection_public_id") }
    assert_equal ["search", "search"], routes.map { |route| route.fetch("tool_name") }
    assert_empty result.environment.fetch("executors")
    assert result.definitions.all? { |entry| entry.fetch("effect_profile") == McpConnection::EFFECT_PROFILE }
    assert result.definitions.all? { |entry| entry.fetch("output_schema") == { "type" => "object" } }
    assert Nexus::ToolDeclarations.wire(result.definitions).all? { |entry| (entry.keys & %w[route output_schema effect_profile defer_loading]).empty? }
  end

  test "catalog updates affect the next assembly but never a captured declaration or its target" do
    @agent.update!(mcp_tools: [selection(@work, "work_search")])
    captured = AgentConfiguration.capture(@agent)
    initial = assemble(declaration: captured)
    frozen = captured.with_tools(initial.definitions)
    assert_empty frozen.mcp_tools
    assert_equal ["search", { "query" => "q" }, "work_search"],
      Nexus::ToolDeclarations.resolve_call(initial.definitions, "work_search", { "query" => "q" })
    changed = @work.tools_catalog.map { |tool| tool.merge("description" => "New description") }
    @work.update!(name: "Renamed", catalog: changed)
    @agent.update!(mcp_tools: [])

    assert_empty assemble.definitions
    assert_equal "New description", assemble(declaration: captured).definitions.sole.dig("function", "description")
    retained = assemble(declaration: frozen)
    assert_equal initial.definitions, retained.definitions
    assert_equal @work.public_id, retained.definitions.sole.dig("route", "connection_public_id")
    @work.update!(enabled: false)
    assert_equal :mcp_connection_unavailable, assemble(declaration: frozen).refusal
  end

  test "connection state and the current catalog still gate a selected tool" do
    @agent.update!(mcp_tools: [selection(@work, "work_search")])
    @work.update!(enabled: false)
    assert_equal :mcp_connection_unavailable, assemble.refusal
    @work.update!(enabled: true, catalog: [])
    assert_equal :mcp_tool_unavailable, assemble.refusal
    assert_equal ["search"], @personal.tools_catalog.pluck("name")
  end

  test "named identities use their Human's connection with their own selected tools" do
    other = @agent.named_agents.create!(account: @agent.account, steward: @agent.steward,
      agent_identifier: "#{@agent.agent_identifier}/mcp-worker", named_agent_scope: "instance",
      kind: "agent", role: "member", handle: "mcp-worker", display_name: "MCP worker", description: "Searches work documents")
    other.update!(approval_mode: "ask", mcp_tools: [selection(@work, "work_search")])
    assert_predicate Tools::Assemble.for_agent(agent: other), :accepted?
    assert_empty assemble.definitions
    other.update!(mcp_tools: [])
    assert_empty Tools::Assemble.for_agent(agent: other).definitions
  end

  test "another Human's connection is unavailable through imports or an explicit route" do
    foreign = users(:member).mcp_connections.create!(name: "Other Human", endpoint_url: "https://other.example.test/mcp",
      auth_type: "none", catalog: @work.tools_catalog)
    @agent.update!(mcp_tools: [selection(foreign, "foreign_search")])
    assert_equal :mcp_connection_unavailable, assemble.refusal

    @agent.update!(mcp_tools: [], tool_definitions: [{ "type" => "function",
      "function" => { "name" => "foreign_search", "parameters" => { "type" => "object" } },
      "route" => { "kind" => "mcp", "connection_public_id" => foreign.public_id, "tool_name" => "search" } }])
    assert_equal :mcp_connection_unavailable, assemble.refusal
  end

  test "imports require exact fields and unique non-kernel callable names" do
    valid = selection(@work, "work_search")
    assert_nil Nexus::ToolImports.field_refusal(field: :mcp_tools, value: [valid])
    [valid.except("name"), valid.merge("name" => "memory_read"), valid.merge("connection_public_id" => "all"),
      valid.merge("extra" => true)].each do |entry|
      assert_equal :invalid, Nexus::ToolImports.field_refusal(field: :mcp_tools, value: [entry])
    end
    assert_equal :invalid, Nexus::ToolImports.field_refusal(field: :mcp_tools,
      value: [valid, selection(@personal, "work_search")])
    @agent.update!(mcp_tools: [valid], tool_definitions: [{ "type" => "function",
      "function" => { "name" => "work_search", "description" => "Application search", "parameters" => { "type" => "object" } } }])
    assert_equal :duplicate_tool_name, assemble.refusal
  end

  test "explicit routes require a connection and keep remote kernel-like names in that connection" do
    route = { "kind" => "mcp", "connection_public_id" => @work.public_id, "tool_name" => "memory_read" }
    assert_nil Nexus::ToolRoute.refusal(route, declaration: true)
    assert_equal "mcp_target_required", Nexus::ToolRoute.refusal(route.except("connection_public_id"), declaration: true)
    assert_equal "invalid_tool_route", Nexus::ToolRoute.refusal(route.merge("runner_executor_public_id" => @work.public_id), declaration: true)
  end

  test "authored model declarations normalize a connection UUID before freezing its route" do
    DevModelLane.ensure_enabled!(@agent.account)
    declaration = { "type" => "function", "function" => { "name" => "work_search", "parameters" => { "type" => "object" } },
      "route" => { "kind" => "mcp", "connection_public_id" => @work.public_id.upcase, "tool_name" => "search" } }
    run = seed(model("plan", "tools" => [declaration]), workspace: workspaces(:shared), creating_user: @agent,
      default_runner_executor_public_id: nil)

    stored = run.tasks.find_by!(node_key: "plan").tool_definitions.sole
    assert_equal @work.public_id, stored.dig("route", "connection_public_id")
    assert_equal stored, Nexus::ToolDeclarations.render([stored]).sole
    assert_equal @work.public_id.upcase, declaration.dig("route", "connection_public_id")
  end

  private

    def assemble(**options) = Tools::Assemble.for_agent(agent: @agent.reload, **options)

    def selection(connection, name)
      { "connection_public_id" => connection.public_id, "tool_name" => "search", "name" => name }
    end

    def connection(name)
      users(:owner).mcp_connections.create!(name: name, endpoint_url: "https://tools.example/mcp", auth_type: "none",
        enabled: true, catalog: [
          { "name" => "search", "description" => "Search documents", "input_schema" => { "type" => "object" },
            "output_schema" => { "type" => "object" }, "annotations" => { "readOnlyHint" => true } },
        ])
    end
end
