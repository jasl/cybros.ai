require "test_helper"

# THE EDITOR'S SERVERS, PER CONVERSATION over the fake transport: a set opened from the ACP shape —
# classes named `mcp__<name>__<tool>` closing over THAT connection, the
# seam's report, the digest over names, launch and keys, close idempotent,
# a down row its own, a malformed entry nothing's, the module's list and
# ladder, the budget on top of the boot ledger and the sets before.
class ConversationsTest < Minitest::Test
  include McpTest::Helpers

  Api = Struct.new(:host, :log, keyword_init: true)
  Host = Struct.new(:home, keyword_init: true)
  Home = Struct.new(:root, keyword_init: true)

  STDIO = { "name" => "fx", "command" => "ruby", "args" => ["srv.rb"],
            "env" => [{ "name" => "FX_TOKEN", "value" => McpTest::FX_TOKEN }] }.freeze
  HTTP = { "type" => "http", "name" => "remote", "url" => "https://mcp.example.com/mcp",
           "headers" => [{ "name" => "X-Api-Key", "value" => "literal-key-123" }] }.freeze
  SSE = { "type" => "sse", "name" => "events", "url" => "https://mcp.example.com/sse" }.freeze

  def setup
    @transports = []
    @server = McpTest::FixtureServer.build(tools: %w[echo lookup write blank])
    @servers = {}
    @spawn_errors = {}
    Rho::Mcp.transport_factory = lambda do |row, read_timeout:, oauth: nil|
      McpTest::FakeTransport.new(@servers.fetch(row.key, @server)).tap do |transport|
        transport.read_timeout = read_timeout
        transport.spawn_error = @spawn_errors[row.key]
        transport.pid = 4242 + @transports.length
        @transports << transport
      end
    end
    @log = []
    logger = Object.new
    log = @log
    %i[debug info warn error].each { |level| logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
    @api = Api.new(host: Host.new(home: Home.new(root: "/home/x")), log: logger)
  end

  def teardown = Rho::Mcp.reset!

  def open(anchor = "cnv_1", entries = [STDIO, HTTP, SSE])
    Rho::Mcp::Conversations.open(anchor, entries, api: @api)
  end

  def call(klass, args = {})
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { klass.new(env: nil).call(args) }
  end

  def klass(set, name) = set.classes.find { |k| k::NAME == name }

  def test_open_connects_each_row_through_the_boot_path_and_the_classes_close_over_their_connection
    set = open
    assert_equal ["cnv_1", 2], [set.anchor, @transports.length], "the sse row spawned nothing"
    assert_equal %w[mcp__fx__echo mcp__fx__lookup mcp__fx__write mcp__remote__echo mcp__remote__lookup mcp__remote__write],
      set.classes.map { |k| k::NAME }, "under \"*\" the undescribed `blank` is skipped, as at boot"
    set.classes.each { |k| Rho::Runner::Extensions::Tool.validate!(k, extension: "rho.mcp") }
    echo = klass(set, "mcp__fx__echo")
    assert_equal [McpTest::FixtureServer::ECHO_DESCRIPTION, "object", Rho::Mcp::Curation::WORST_CASE, "fx", "echo"],
      [echo::DESCRIPTION, echo::SCHEMA["type"], echo::EFFECT_PROFILE, echo::SERVER_KEY, echo::RAW_NAME]
    refute echo.const_defined?(:TIMEOUT_MS, false), "a stdio row's park is the kernel's default"
    assert_equal 60_000, klass(set, "mcp__remote__echo")::TIMEOUT_MS, "the http park"
    assert_equal set.classes.length, set.kernel_entries.length

    assert_equal [{ name: "fx", state: "connected", fault: nil, transport: "stdio" },
                  { name: "remote", state: "connected", fault: nil, transport: "http" },
                  { name: "events", state: "down", fault: "transport sse unsupported", transport: "sse" }], set.report
    fx = set.entries.fetch(0)
    assert_equal [:agent, "/home/x", [McpTest::FX_TOKEN], "connected"], [fx.row.serves, fx.row.cwd, fx.row.secrets, fx.state]
    assert_equal ["literal-key-123"], set.entries.fetch(1).row.secrets

    assert_equal "hi", call(echo, { "text" => "hi" }).content
    assert_equal "record for k1", call(klass(set, "mcp__remote__lookup"), { "key" => "k1" }).content
    assert_equal [1, 1], @transports.map { |t| t.requests.count { |r| r[:method] == "tools/call" } }, "each class calls ITS connection"
    assert_empty Rho::Mcp.entries, "the boot table knows nothing of an editor's row"
    assert_raises(Rho::Mcp::ServerGone) { Rho::Mcp.call("fx", "echo", {}) }
    assert_equal [set], Rho::Mcp.conversations

    connected = @log.find { |entry| entry[1] == "mcp.connected" }
    assert_equal ["fx", "cnv_1", 4], [connected[2][:server], connected[2][:conversation], connected[2][:tools]]
    assert_includes @log, [:warn, "mcp.server_config_invalid", { server: "events", conversation: "cnv_1", sentence: "transport sse unsupported" }]
    opened = @log.find { |entry| entry[1] == "mcp.conversation_servers" }
    assert_equal [:info, { conversation: "cnv_1", servers: 3, connected: 2, tools: 6, digest: set.digest }], [opened[0], opened[2]]
  end

  # `GET /mcp` lists a conversation row with its owner, in the boot
  # table's shape; an editor's https row has no login door in rho — its
  # headers are the editor's credential.
  def test_the_report_lists_the_rows_with_their_owner_and_no_login_door
    set = open
    servers = Rho::Mcp.report.fetch("servers")
    assert_equal [%w[fx cnv_1 connected], %w[remote cnv_1 connected], %w[events cnv_1 down]],
      servers.map { |s| s.values_at("key", "owner", "state") }
    remote = servers.fetch(1)
    assert_equal [{ "kind" => "none" }, ["X-Api-Key"], "https://mcp.example.com/mcp", "agent"],
      remote.values_at("auth", "headers", "launch", "serves")
    assert_equal ["FX_TOKEN"], servers.fetch(0).fetch("env"), "names only"
    assert_equal ["transport sse unsupported", "sse", []], servers.fetch(2).values_at("detail", "transport", "tools")
    assert_equal({ "tools" => 6, "bytes" => servers.sum { |s| s.fetch("bytes") }, "documents" => 0 }, Rho::Mcp.report.fetch("total"))
    refute_includes Rho::Mcp.report.to_s, McpTest::FX_TOKEN
    set.close
    assert_empty Rho::Mcp.report.fetch("servers")
  end

  # A row's secrets are under its own `Redact`: what the server answers
  # and what the notice quotes reach the model masked.
  def test_the_editors_secret_reaches_the_model_and_the_notice_redacted
    token = McpTest::FX_TOKEN
    @server.define_tool(name: "reveal", description: "Answer the token.", input_schema: { properties: {} }) do
      MCP::Tool::Response.new([{ type: "text", text: "the token is #{token}" }], structured_content: { "token" => token })
    end
    set = open("cnv_1", [STDIO])
    revealed = call(klass(set, "mcp__fx__reveal"))
    assert_equal ["the token is •••", { "token" => "•••" }], [revealed.content, revealed.structured_content]
    @transports.fetch(0).die!(status: 3, tail: "fixture: leaving now (#{token})\n")
    result = call(klass(set, "mcp__fx__echo"), { "text" => "again" })
    assert_match(/\Anote: mcp server fx had exited \(status 3 at \d\d:\d\d:\d\d; its stderr ended: fixture: leaving now \(•••\)\)/, result.content)
    assert_equal 2, @transports.length, "a connection that died is restarted for the call, as a boot row's is"
    refute_includes @log.inspect, token
  end

  # THE DIGEST (the daemon's gate on a re-assertion): name + launch +
  # env/header KEYS, never a value; order-free.
  def test_the_digest_is_stable_across_values_and_order_and_moves_across_names_launch_and_keys
    digest = ->(entries) { Rho::Mcp::Conversations.digest(Rho::Mcp::Settings.from_acp(entries)) }
    base = digest.call([STDIO, HTTP, SSE])
    assert_match(/\A[0-9a-f]{64}\z/, base)
    other_values = [STDIO.merge("env" => [{ "name" => "FX_TOKEN", "value" => "another-value-0123456789" }]),
                    HTTP.merge("headers" => [{ "name" => "X-Api-Key", "value" => "other-key" }]), SSE]
    assert_equal base, digest.call(other_values), "a value is not in the digest"
    assert_equal base, digest.call([SSE, HTTP, STDIO]), "the order is not in the digest"
    assert_equal base, digest.call([STDIO, HTTP, SSE.merge("url" => "https://elsewhere/sse")]), "an unsupported row's launch is nobody's"

    moved = [
      [STDIO.merge("name" => "fy"), HTTP, SSE],
      [STDIO.merge("args" => ["srv.rb", "--debug"]), HTTP, SSE],
      [STDIO.merge("command" => "python"), HTTP, SSE],
      [STDIO, HTTP.merge("url" => "https://mcp.example.com/other"), SSE],
      [STDIO.merge("env" => [*STDIO["env"], { "name" => "MORE", "value" => "x" }]), HTTP, SSE],
      [STDIO, HTTP.merge("headers" => [*HTTP["headers"], { "name" => "X-More", "value" => "x" }]), SSE],
      [STDIO, HTTP],
      [STDIO, HTTP, SSE.merge("type" => "acp")],
    ]
    digests = moved.map { |entries| digest.call(entries) }
    assert_equal digests.uniq, digests
    refute_includes digests, base
    assert_equal 0, @transports.length, "a digest connects nothing"
  end

  def test_close_closes_every_connection_once_forgets_the_set_and_a_later_call_is_closed
    set = open
    echo = klass(set, "mcp__fx__echo")
    assert_nil set.close
    assert_equal [1, 1], @transports.map(&:closes)
    assert_predicate set, :closed?
    assert_empty Rho::Mcp.conversations
    set.close
    assert_equal [1, 1], @transports.map(&:closes), "idempotent: a second close finds nothing to take"
    error = assert_raises(Rho::Mcp::Closed) { call(echo, { "text" => "late" }) }
    assert_equal "conversation cnv_1's mcp servers are closed", error.message
    assert_equal 0, @transports.fetch(0).requests.count { |r| r[:method] == "tools/call" }, "nothing was sent"
    assert_equal 3, set.report.length, "the rows are still readable; the daemon dropped the set"
  end

  def test_a_row_down_at_open_is_its_own_and_a_malformed_list_connects_nothing
    @spawn_errors["gone"] = "Failed to spawn server process: No such file or directory - nope"
    set = open("cnv_2", [{ "name" => "gone", "command" => "nope" }, STDIO])
    assert_equal [{ name: "gone", state: "down", fault: "could not connect: Failed to spawn server process: No such file or directory - nope", transport: "stdio" },
                  { name: "fx", state: "connected", fault: nil, transport: "stdio" }], set.report
    assert_equal %w[mcp__fx__echo mcp__fx__lookup mcp__fx__write], set.classes.map { |k| k::NAME }
    assert_equal 1, @transports.fetch(0).closes, "the failed spawn is torn down"
    assert_includes @log.map { |entry| [entry[0], entry[1], entry[2][:conversation], entry[2][:server]] },
      [:warn, "mcp.server_unavailable", "cnv_2", "gone"]

    error = assert_raises(ArgumentError) { open("cnv_3", [{ "name" => "ok", "command" => "ruby" }, { "command" => "ruby" }]) }
    assert_equal 'mcpServers[1] needs a "name" (a string)', error.message
    assert_equal 2, @transports.length, "a malformed list is judged whole before anything connects"
    assert_equal [set], Rho::Mcp.conversations
  end

  # THE LADDER: `Rho::Mcp.close!` (the shutdown hook) closes every live set
  # with the boot connections; a set opened past it is refused `Closed`
  # and what it built is closed.
  def test_after_the_ladder_a_set_is_refused_closed_and_what_it_built_is_closed
    set = open
    Rho::Mcp.close!
    assert_equal [1, 1], @transports.map(&:closes)
    assert_predicate set, :closed?
    assert_empty Rho::Mcp.conversations
    error = assert_raises(Rho::Mcp::Closed) { open("cnv_9", [STDIO]) }
    assert_equal "the mcp host is shutting down", error.message
    assert_equal 3, @transports.length
    assert_equal 1, @transports.fetch(2).closes, "the connection built before the refusal is closed"
    assert_empty Rho::Mcp.conversations
  end

  # A server of `count` tools, each description `bytes` wide (the boot
  # suite's fixture): six of 6,000 fit the agent address alone, two sets
  # of six do not.
  def wide_server(count, bytes)
    McpTest::FixtureServer.build(tools: []).tap do |server|
      count.times do |index|
        server.define_tool(name: "wide#{index}", description: "w" * bytes, input_schema: { properties: {} }) { MCP::Tool::Response.new([]) }
      end
    end
  end

  # THE BUDGET, per row on top of the boot
  # ledger AND every live set's entries — the agent slot announces the
  # union: the second set that would cross the bound is faulted as a
  # row naming the agent address; the ledger reads the LIVE sets, so a
  # closed set frees its bytes.
  def test_the_budget_is_met_per_row_over_the_sets_before_and_a_closed_set_frees_its_bytes
    @servers["wide"] = wide_server(6, 6_000)
    entries = [{ "name" => "wide", "command" => "x" }]
    first = open("cnv_a", entries)
    assert_equal "connected", first.report.fetch(0).fetch(:state), first.report.inspect
    assert_equal 6, first.classes.length
    second = open("cnv_b", entries)
    row = second.report.fetch(0)
    assert_equal "down", row.fetch(:state)
    assert_match(/\Amcp server "wide": its 6 tools \([\d,]+ bytes as the kernel measures an announcement\) would put the agent address's announcement at [\d,]+ bytes, past the kernel's envelope_bound \(65,536 bytes\); [\d,]+ bytes were announced there before it\z/,
      row.fetch(:fault))
    assert_empty second.classes
    assert_equal 1, @transports.fetch(1).closes, "the refused row's child is closed"
    assert_equal [first, second], Rho::Mcp.conversations
    first.close
    third = open("cnv_c", entries)
    assert_equal "connected", third.report.fetch(0).fetch(:state), "the first set's bytes left with it"
  end
end
