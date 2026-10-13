require "test_helper"

# THE ANNOUNCEMENT: verbatim names, descriptions and
# schemas under the prefix; the worst-case profile unless the operator
# overrides; INTERNAL_CLAMP always; the skips and the faults with reasons.
class CurationTest < Minitest::Test
  def tools_of(server) = MCP::Client.new(transport: McpTest::FakeTransport.new(server)).tap { |c| c.connect(mode: :legacy) }.tools

  def row(tools: ["*"], profiles: {}, timeout: nil)
    raw = { "transport" => "stdio", "command" => "ruby", "tools" => tools, "effect_profiles" => profiles }
    raw["timeout_ms"] = timeout if timeout
    Rho::Mcp::Settings.parse({ "fx" => raw }, env: {}).fetch(0)
  end

  def test_every_allowed_tool_becomes_a_class_with_verbatim_bytes_and_the_worst_case
    listed = tools_of(McpTest::FixtureServer.build(tools: %w[echo lookup blank]))
    curated = Rho::Mcp::Curation.curate(row(timeout: 5000), listed, caller: ->(*) { nil })
    assert_nil curated.fault
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], curated.announced.map(&:public_name)
    assert_equal [["blank", "mcp__fx__blank has no description; the model could not choose it"]],
      curated.skipped.map { |s| [s.raw_name, s.reason] }

    echo = curated.announced.fetch(0)
    listed_echo = listed.find { |t| t.name == "echo" }
    assert_equal McpTest::FixtureServer::ECHO_DESCRIPTION, echo.klass::DESCRIPTION
    assert_equal listed_echo.input_schema, echo.klass::SCHEMA, "the schema byte for byte, `$schema` and all"
    assert_predicate echo.klass::SCHEMA, :frozen?
    assert_equal Rho::Mcp::Curation::WORST_CASE, echo.klass::EFFECT_PROFILE
    assert_equal 5000, echo.klass::TIMEOUT_MS
    assert_equal true, echo.klass::INTERNAL_CLAMP
    assert_equal ["fx", "echo"], [echo.klass::SERVER_KEY, echo.klass::RAW_NAME]
    assert_equal "worst case", echo.profile_source
    assert_equal "Rho::Mcp::Tools[mcp__fx__echo]", echo.klass.name
    expected = JSON.generate(CybrosAgent::Api::ToolLowering.function_entry(
      "name" => "mcp__fx__echo", "description" => McpTest::FixtureServer::ECHO_DESCRIPTION, "inputSchema" => listed_echo.input_schema
    )).bytesize
    assert_equal expected, echo.bytes
    assert_equal curated.announced.sum(&:bytes), curated.bytes
    curated.classes.each { |klass| Rho::Runner::Extensions::Tool.validate(klass, extension: "rho.mcp") }
  end

  def test_the_class_calls_through_with_its_server_and_raw_name_and_the_env
    calls = []
    curated = Rho::Mcp::Curation.curate(row(tools: ["echo"]), tools_of(McpTest::FixtureServer.build(tools: %w[echo])),
      caller: ->(server, raw, args, env:, public_name:) { calls << [server, raw, args, env, public_name]; :answered })
    klass = curated.classes.fetch(0)
    assert_equal :answered, klass.new(env: :the_env).call({ "text" => "hi" })
    assert_equal [["fx", "echo", { "text" => "hi" }, :the_env, "mcp__fx__echo"]], calls
    assert_nil Rho::Runner::Extensions::Tool.timeout_ms(klass), "no row timeout: the kernel's default park"
  end

  def test_budget_projections_match_registration_without_compiling_schemas
    configured = row(timeout: 5000)
    curated = Rho::Mcp::Curation.curate(configured, tools_of(McpTest::FixtureServer.build(tools: %w[echo lookup])), caller: ->(*) { nil })
    api = Rho::Runner::Extensions::Api.new(extension_name: "rho.mcp", source: "<test>")
    curated.classes.each { |klass| api.register_tool(klass) }
    expected = Rho::Runner::Extensions::Registry.new.commit(api).announcement
    budget = Rho::Mcp::Budget.new({})
    calls = 0
    trace = TracePoint.new(:call) do |event|
      calls += 1 if event.self == Rho::Runner::InputSchema && event.method_id == :compile
    end
    projected = trace.enable do
      assert_same curated, budget.judge(configured, curated)
      Rho::Mcp::Budget.entries_for(curated)
    end

    assert_equal 0, calls
    assert_equal JSON.generate(expected), JSON.generate(projected)
    assert_equal expected, budget.ledger.fetch(:runner)
  end

  def test_an_operator_override_replaces_the_profile_for_one_tool
    profile = { "kind" => "read_only", "destructive" => false, "effect_scope" => "open", "idempotency" => "intrinsic",
                "reconciliation" => "none" }
    curated = Rho::Mcp::Curation.curate(row(profiles: { "lookup" => profile }),
      tools_of(McpTest::FixtureServer.build(tools: %w[echo lookup])), caller: ->(*) { nil })
    by_name = curated.announced.to_h { |a| [a.raw_name, a] }
    assert_equal [profile, "operator"], [by_name.fetch("lookup").profile, by_name.fetch("lookup").profile_source]
    assert_equal [Rho::Mcp::Curation::WORST_CASE, "worst case"], [by_name.fetch("echo").profile, by_name.fetch("echo").profile_source]
  end

  def test_the_allowlist_skips_the_rest_and_a_stale_name_is_the_rows_fault
    listed = tools_of(McpTest::FixtureServer.build(tools: %w[echo lookup write]))
    curated = Rho::Mcp::Curation.curate(row(tools: %w[echo lookup]), listed, caller: ->(*) { nil })
    assert_equal %w[echo lookup], curated.announced.map(&:raw_name)
    assert_equal [["write", "not in tools"]], curated.skipped.map { |s| [s.raw_name, s.reason] }

    stale = Rho::Mcp::Curation.curate(row(tools: %w[echo gone]), listed, caller: ->(*) { nil })
    assert_equal 'mcp server "fx": tools names "gone", which the server did not list (it lists: echo, lookup, write)', stale.fault
    assert_empty stale.classes, "nothing of a stale list is announced"
  end

  def test_an_allowlisted_tool_without_a_description_is_the_rows_fault_and_a_star_skips_it
    listed = tools_of(McpTest::FixtureServer.build(tools: %w[echo blank]))
    named = Rho::Mcp::Curation.curate(row(tools: %w[echo blank]), listed, caller: ->(*) { nil })
    assert_equal 'mcp server "fx": mcp__fx__blank has no description; the model could not choose it', named.fault
    star = Rho::Mcp::Curation.curate(row, listed, caller: ->(*) { nil })
    assert_nil star.fault
    assert_equal ["blank"], star.skipped.map(&:raw_name)
  end

  def test_a_duplicate_raw_name_is_the_rows_fault_before_the_registry_sees_it
    doubled = [MCP::Client::Tool.new(name: "echo", description: "x", input_schema: { "type" => "object" }),
               MCP::Client::Tool.new(name: "echo", description: "y", input_schema: { "type" => "object" })]
    assert_equal 'mcp server "fx": tools/list names "echo" twice', Rho::Mcp::Curation.curate(row, doubled, caller: ->(*) { nil }).fault
  end

  def test_a_schema_the_validator_refuses_is_skipped_never_a_crash
    bad = MCP::Client::Tool.new(name: "bad", description: "x", input_schema: { "type" => "object", "required" => "path" })
    not_object = MCP::Client::Tool.new(name: "str", description: "x", input_schema: { "type" => "string" })
    curated = Rho::Mcp::Curation.curate(row, [bad, not_object], caller: ->(*) { nil })
    assert_nil curated.fault
    reasons = curated.skipped.to_h { |s| [s.raw_name, s.reason] }
    assert_match(/\Amcp__fx__bad's schema was refused: /, reasons.fetch("bad"))
    assert_equal "mcp__fx__str's schema is not a JSON Schema object", reasons.fetch("str")
  end

  def test_a_lossy_raw_name_is_announced_under_its_hashed_public_name
    listed = [MCP::Client::Tool.new(name: "dotted.name/with space", description: "A name the provider floor refuses.",
      input_schema: { "type" => "object", "properties" => {} })]
    curated = Rho::Mcp::Curation.curate(row, listed, caller: ->(*) { nil })
    announced = curated.announced.fetch(0)
    assert_equal Rho::Mcp::Naming.tool("fx", "dotted.name/with space"), announced.public_name
    assert_equal "dotted.name/with space", announced.klass::RAW_NAME
    Rho::Runner::Extensions::Tool.validate(announced.klass, extension: "rho.mcp")
  end
end
