require "test_helper"

# THE DOOR IT COMES THROUGH is the loader's:
# tools announced per server at load, faults per server, the CLI host
# connecting nothing, the shutdown hook, the report `GET /mcp` answers.
class ExtensionTest < Minitest::Test
  def setup
    @transports = []
    @server = McpTest::FixtureServer.build(tools: %w[echo lookup write blank], documents: McpTest::FixtureServer::DOCUMENTS)
    install_fake_factory
  end

  def environment = Rho::Runner::Environment.local(root: Dir.tmpdir)

  def tool_env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: Dir.tmpdir)

  DOCUMENT_NAMES = ["fx-summarize", "fx-chatty-prompt-#{Rho::Mcp::Naming.digest("fx", "Chatty Prompt")}", "fx-asker", "fx-readme",
                    "fx-notes", "fx-logo"].freeze

  # `Rho::Mcp.reset!` forgets the seams too; a test that loads twice
  # re-installs the fake before its second load, or the real factory
  # would reach for the network.
  def install_fake_factory
    Rho::Mcp.transport_factory = lambda do |_row, read_timeout:, oauth: nil|
      McpTest::FakeTransport.new(@server).tap do |t|
        t.read_timeout = read_timeout
        @transports << t
      end
    end
  end

  def teardown = Rho::Mcp.reset!

  def stdio(tools: %w[echo lookup], **extra)
    { "transport" => "stdio", "command" => "ruby", "args" => ["srv.rb"], "tools" => tools }.merge(extra)
  end

  def http(tools: "*", **extra)
    { "transport" => "http", "url" => "https://mcp.example.com/mcp", "tools" => tools,
      "headers" => { "X-Api-Key" => "literal-remote-key-0123" } }.merge(extra)
  end

  def load(table, host = nil)
    Rho::Mcp.settings_table = table
    Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp], api_options: (host ? { host: host } : {}), api_class: api_class(host))
  end

  # A handle without the daemon gem: the base handle plus the daemon's
  # conversation seam (`register_conversation_servers`, the ONE registrar a daemon accepts; recorded here so a test can call it) and, given a host, the two members the extension
  # reads (`host`, `serves?`); the document verbs go through the base
  # handle's own `serves?` refusal.
  def api_class(host)
    Class.new(Rho::Runner::Extensions::Api) do
      attr_reader :conversation_registrar

      define_method(:register_conversation_servers) do |&registrar|
        @conversation_registrar = registrar
        self
      end
      next if host.nil?

      define_method(:serves?) { |source| host.mode == "full" || (host.mode == "runner" && source == :runner) || (host.mode == "agent" && source == :agent) }
      define_method(:register_tool) do |klass, serves: :runner|
        raise Rho::Runner::Extensions::RegistrationError, "mode refuses #{serves}" unless serves?(serves)

        Rho::Runner::Extensions::Tool.validate!(klass, extension: extension_name)
        @tools << Rho::Runner::Extensions::Api::Registration.new(klass: klass, serves: serves)
        self
      end
    end
  end

  Host = Struct.new(:home, :config, :serving_tools, :mode, keyword_init: true)
  Config = Struct.new(:mcp_servers, :mode, keyword_init: true)
  Home = Struct.new(:root, keyword_init: true)

  def host(mode: "full", serving: true, table: nil)
    Host.new(home: Home.new(root: Dir.tmpdir), config: Config.new(mcp_servers: table, mode: mode), serving_tools: serving, mode: mode)
  end

  def test_it_announces_the_allowlisted_tools_a_shutdown_hook_and_the_verbs
    result = load({ "fx" => stdio })
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort
    assert_equal ["rho.mcp"], result.registry.extension_names
    hook = result.committed.flat_map(&:lifecycle).find { |h| h.event == :shutdown }
    refute_nil hook, "no shutdown hook; the servers would outlive their host"
    entry = Rho::Mcp.entries.fetch("fx")
    assert_equal "connected", entry.state
    assert_equal %w[write blank], entry.curated.skipped.map(&:raw_name)
    assert_equal 1, @transports.length, "one process per server"

    report = Rho::Mcp.report
    server = report.fetch("servers").fetch(0)
    assert_equal ["fx", "stdio", "runner", "connected", nil, 4242, 4241], server.values_at("key", "transport", "serves", "state", "detail", "pid", "pgid")
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], server.fetch("tools").map { |t| t.fetch("name") }
    assert_equal [{ "raw" => "write", "reason" => "not in tools" }, { "raw" => "blank", "reason" => "not in tools" }], server.fetch("skipped")
    assert_equal server.fetch("tools").sum { |t| t.fetch("bytes") }, server.fetch("bytes")
    assert_equal({ "tools" => 2, "bytes" => server.fetch("bytes"), "documents" => 6 }, report.fetch("total"))

    hook.handler.call
    assert_equal 1, @transports.fetch(0).closes
    assert_empty Rho::Mcp.entries
    error = assert_raises(Rho::Mcp::Closed) { Rho::Mcp.call("fx", "echo", {}) }
    assert_equal "the mcp host is shutting down", error.message
  end

  # THE DOCUMENTS ON THE PLANE SEAM: a stdio server's curated
  # prompts and resources ride the RUNNER address's list, loaded by the
  # runner's `skill` (Coding's, here the plane's own walk); the report
  # carries them with the skips; nothing rides the agent address, and no
  # `skill` is registered there.
  def test_a_stdio_servers_documents_ride_the_runner_address_and_load_through_it
    Rho::Mcp.settings_table = { "fx" => stdio }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding, Rho::Mcp], api_class: api_class(nil))
    assert_predicate result, :ok?, result.failures.inspect
    registry = result.registry
    assert_equal 1, registry.names.count("skill"), "Coding's skill alone; nothing on the agent address"
    assert_empty registry.serving(:agent).names
    assert_equal DOCUMENT_NAMES, registry.serving(:runner).documents(environment).map { |e| e.fetch("name") }
    assert_equal DOCUMENT_NAMES, registry.documents(environment).map { |e| e.fetch("name") }
    assert_equal({ "name" => "fx-summarize", "description" => McpTest::FixtureServer::SUMMARIZE_DESCRIPTION },
      registry.documents(environment).fetch(0))

    skill = registry.serving(:runner).toolset(env: tool_env).fetch("skill")
    load = ->(name) { Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { skill.handler.call({ "name" => name }, nil) } }
    assert_equal "Summarize the notes.\nBe brief.", load.call("fx-summarize").content
    assert_equal "# Readme\n\nRead me.", load.call("fx-readme").content
    assert_equal "note one\nnote two", load.call("fx-notes").content
    assert_equal ["skill_unknown: fx-greet", true], [load.call("fx-greet").content, load.call("fx-greet").is_error],
      "a skipped prompt was never announced: nobody's"
    assert_equal "skill_unknown: deploy-notes", load.call("deploy-notes").content

    server = Rho::Mcp.report.fetch("servers").fetch(0)
    assert_equal DOCUMENT_NAMES, server.fetch("documents").map { |d| d.fetch("name") }
    assert_equal({ "name" => "fx-readme", "kind" => "resource", "raw" => "readme", "mime_type" => "text/markdown" },
      server.fetch("documents").fetch(3))
    assert_equal [{ "name" => "fx-greet", "kind" => "prompt", "reason" => 'prompt: required argument "who"' },
                  { "name" => "fx-blob", "kind" => "resource", "reason" => "resource: application/octet-stream" },
                  { "name" => "fx-nodesc", "kind" => "resource", "reason" => "resource: no description" }],
      server.fetch("skipped_documents")
    assert_equal 6, Rho::Mcp.report.fetch("total").fetch("documents")
  end

  # AN HTTP SERVER'S DOCUMENTS RIDE THE AGENT ADDRESS, and the extension
  # registers the plane's `skill` there itself (in agent mode Coding is
  # not loaded at all; in full mode the per-address key keeps the two
  # apart); a load of an agent-announced name through the agent's `skill`
  # reaches the http server, and the runner's `skill` never answers it.
  def test_an_http_servers_documents_ride_the_agent_address_with_the_planes_skill
    result = load({ "remote" => http }, host(mode: "agent"))
    assert_predicate result, :ok?, result.failures.inspect
    registry = result.registry
    assert_includes registry.serving(:agent).names, "skill"
    assert_equal Rho::Runner::Tools::Skill, registry.serving(:agent).entries.find { |e| e.name == "skill" }.klass
    assert_equal "rho.mcp", registry.serving(:agent).entries.find { |e| e.name == "skill" }.extension
    assert_equal ["remote-summarize", "remote-chatty-prompt-#{Rho::Mcp::Naming.digest("remote", "Chatty Prompt")}", "remote-asker",
                  "remote-readme", "remote-notes", "remote-logo"], registry.serving(:agent).documents(environment).map { |e| e.fetch("name") }
    assert_empty registry.serving(:runner).documents(environment)
    skill = registry.serving(:agent).toolset(env: tool_env).fetch("skill")
    loaded = Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { skill.handler.call({ "name" => "remote-summarize" }, nil) }
    assert_equal "Summarize the notes.\nBe brief.", loaded.content

    Rho::Mcp.reset!
    @transports.clear
    install_fake_factory
    Rho::Mcp.settings_table = { "fx" => stdio, "remote" => http }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding, Rho::Mcp],
      api_options: { host: host(mode: "full") }, api_class: api_class(host(mode: "full")))
    assert_predicate result, :ok?, result.failures.inspect
    registry = result.registry
    assert_equal 2, registry.names.count("skill"), "one per address under full mode"
    assert_equal %w[rho.coding rho.mcp], registry.entries.select { |e| e.name == "skill" }.map(&:extension)
    assert_equal DOCUMENT_NAMES, registry.serving(:runner).documents(environment).map { |e| e.fetch("name") }
    assert_equal 6, registry.serving(:agent).documents(environment).length
    runner_skill = registry.serving(:runner).toolset(env: tool_env).fetch("skill")
    assert_equal "skill_unknown: remote-summarize",
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { runner_skill.handler.call({ "name" => "remote-summarize" }, nil) }.content,
      "the runner's skill never answers the agent's document"

    Rho::Mcp.reset!
    @transports.clear
    install_fake_factory
    result = load({ "remote" => http }, host(mode: "runner"))
    assert_predicate result, :ok?
    assert_empty result.registry.names, "a row the mode refuses announces nothing, and no skill is registered"
  end

  # A NAME TWO SERVERS FOLD TO (`a-b` + `c`, `a` + `b-c`) is announced once,
  # by the first in settings order; the second lists it skipped naming
  # the first — the kernel refuses a repeated name for the whole announcement.
  def test_a_document_name_two_servers_fold_to_is_announced_once
    first = McpTest::FixtureServer.build(tools: %w[echo], documents: [])
    first.define_prompt(name: "c", description: "From a-b.") { |_a, server_context:| MCP::Prompt::Result.new(messages: []) }
    second = McpTest::FixtureServer.build(tools: %w[echo], documents: [])
    second.define_prompt(name: "b-c", description: "From a.") { |_a, server_context:| MCP::Prompt::Result.new(messages: []) }
    Rho::Mcp.transport_factory = ->(row, read_timeout:, oauth: nil) { McpTest::FakeTransport.new(row.key == "a-b" ? first : second).tap { |t| t.read_timeout = read_timeout } }
    result = load({ "a-b" => stdio(tools: ["echo"]), "a" => stdio(tools: ["echo"]) })
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal ["a-b-c"], result.registry.documents(environment).map { |e| e.fetch("name") }
    assert_equal "From a-b.", result.registry.documents(environment).fetch(0).fetch("description")
    entries = Rho::Mcp.entries
    assert_equal ["a-b-c"], entries.fetch("a-b").documents.names
    assert_empty entries.fetch("a").documents.names
    assert_equal [["a-b-c", 'prompt: name a-b-c is already announced by server "a-b"']],
      entries.fetch("a").documents.skipped.map { |s| [s.name, s.reason] }
  end

  def test_the_registered_class_answers_through_the_module
    result = load({ "fx" => stdio })
    klass = result.registry.entries.find { |e| e.name == "mcp__fx__echo" }.klass
    answer = Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { klass.new(env: nil).call({ "text" => "hi" }) }
    assert_equal "hi", answer.content
  end

  def test_faults_are_per_server_and_only_a_malformed_table_refuses_the_extension
    result = load({ "bad" => stdio.except("command"), "fx" => stdio, "nolist" => stdio.except("tools") })
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort, "the other servers are announced"
    entries = Rho::Mcp.entries
    assert_equal ["down", 'config: mcp server "bad": a stdio server needs a "command" (a string)'],
      [entries.fetch("bad").state, entries.fetch("bad").fault]
    assert_equal "down", entries.fetch("nolist").state
    assert_match(/\Aconfig: mcp server "nolist" names no tools — /, entries.fetch("nolist").fault)
    assert_equal 1, @transports.length, "nothing was spawned to count"
    assert_equal ["bad", "fx", "nolist", "context7"], Rho::Mcp.report.fetch("servers").map { |s| s.fetch("key") }

    Rho::Mcp.reset!
    result = load(["fx"])
    refute_predicate result, :ok?
    assert_equal "mcp_servers must be an object of objects", result.failures.fetch(0).message
    assert_empty result.registry.names
  end

  # THE SHIPPED EXAMPLE (`Builtin`): a fresh
  # table lists Context7 after the person's rows, DISABLED — no transport
  # built, no tool registered, no document, the report's state `disabled`
  # with no detail, `call` answering `ServerGone`; a row a person parks
  # with `enabled: false` is the same; a disabled row on an address the
  # mode refuses is just disabled. The switch is judged BEFORE the mode.
  def test_the_shipped_row_is_listed_disabled_never_connected_never_announced
    result = load({ "fx" => stdio, "parked" => stdio(enabled: false), "remote" => http(enabled: false) })
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort
    assert_equal %w[fx parked remote context7], Rho::Mcp.entries.keys
    entry = Rho::Mcp.entries.fetch("context7")
    assert_equal ["disabled", nil, nil, nil, nil], [entry.state, entry.fault, entry.connection, entry.curated, entry.documents]
    refute_predicate entry.row, :enabled?
    assert_equal %w[disabled disabled], %w[parked remote].map { |key| Rho::Mcp.entries.fetch(key).state }
    assert_nil Rho::Mcp.entries.fetch("remote").fault, "disabled is judged before the mode; nothing to say"
    assert_equal 1, @transports.length, "nothing was built for a disabled row"
    servers = Rho::Mcp.report.fetch("servers")
    context7 = servers.fetch(3)
    assert_equal ["context7", "http", "agent", "https://mcp.context7.com/mcp", "disabled", nil, [], [], [], []],
      context7.values_at("key", "transport", "serves", "launch", "state", "detail", "tools", "skipped", "documents", "skipped_documents")
    assert_equal "oauth", context7.fetch("auth").fetch("kind")
    assert_equal({ "tools" => 2, "bytes" => servers.fetch(0).fetch("bytes"), "documents" => 6 }, Rho::Mcp.report.fetch("total"))
    assert_empty Rho::Mcp.documents_for(:agent)
    error = assert_raises(Rho::Mcp::ServerGone) { Rho::Mcp.call("context7", "echo", {}) }
    assert_equal "mcp server context7 is not connected in this process", error.message
  end

  # `rho mcp enable context7` writes `{"enabled": true}` under the key —
  # the overlay — and the next load connects and announces the row as any
  # other, in the person's order, on the agent address (here through the
  # fake factory; the URL is the shipped one).
  def test_the_switch_written_under_the_key_makes_the_next_load_connect_and_announce_it
    result = load({ "context7" => { "enabled" => true }, "fx" => stdio }, host(mode: "full"))
    assert_predicate result, :ok?, result.failures.inspect
    names = result.registry.names
    assert_includes names, "mcp__context7__echo"
    assert_includes names, "mcp__context7__lookup"
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], names.grep(/\Amcp__fx__/).sort
    assert_equal %w[context7 fx], Rho::Mcp.entries.keys, "the person's order, where the person named the key"
    entry = Rho::Mcp.entries.fetch("context7")
    assert_equal ["connected", nil, :agent, "https://mcp.context7.com/mcp", true],
      [entry.state, entry.fault, entry.row.serves, entry.row.url, entry.row.enabled?]
    assert_equal 2, @transports.length
    server = Rho::Mcp.report.fetch("servers").fetch(0)
    assert_equal ["context7", "connected"], server.values_at("key", "state")
    assert_equal :agent, result.registry.entries.find { |e| e.name == "mcp__context7__echo" }.serves
  end

  def test_a_server_down_at_boot_costs_its_own_tools_and_a_stale_list_is_its_fault
    dying = McpTest::FakeTransport.new(@server)
    dying.spawn_error = "Failed to spawn server process: No such file or directory - nope"
    calls = 0
    Rho::Mcp.transport_factory = lambda do |row, read_timeout:, oauth: nil|
      calls += 1
      next dying if row.key == "gone"

      McpTest::FakeTransport.new(@server).tap { |t| t.read_timeout = read_timeout; @transports << t }
    end
    result = load({ "gone" => stdio, "fx" => stdio, "stale" => stdio(tools: %w[echo vanished]) })
    assert_predicate result, :ok?
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort
    entries = Rho::Mcp.entries
    assert_equal ["down", "could not connect: Failed to spawn server process: No such file or directory - nope"],
      [entries.fetch("gone").state, entries.fetch("gone").fault]
    assert_equal 'mcp server "stale": tools names "vanished", which the server did not list (it lists: echo, lookup, write, blank)',
      entries.fetch("stale").fault
    assert_equal 1, @transports.fetch(1).closes, "the stale server's child is closed"
    assert_equal 3, calls
  end

  def test_under_a_host_that_serves_no_tools_nothing_is_spawned_and_the_verbs_register
    result = load({ "fx" => stdio }, host(serving: false))
    assert_predicate result, :ok?, result.failures.inspect
    assert_empty result.registry.names
    assert_empty @transports, "the CLI process spawns nothing"
    assert_equal "unconnected", Rho::Mcp.entries.fetch("fx").state
    assert_equal "unconnected", Rho::Mcp.report.fetch("servers").fetch(0).fetch("state")
  end

  def test_the_host_table_is_read_when_no_seam_names_one
    Rho::Mcp.settings_table = nil
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp],
      api_options: { host: host(table: { "fx" => stdio }) }, api_class: api_class(host))
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort
  end

  def test_the_mode_refusal_is_a_row_level_fault_and_the_loader_serves_the_runner_address_under_mode_runner
    result = load({ "fx" => stdio, "remote" => stdio(serves: "agent") }, host(mode: "runner"))
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort
    assert result.registry.entries.all? { |e| e.serves == :runner }
    assert_equal 'config: mcp server "remote" serves the agent (transport stdio); this rho runs in mode runner — ' \
                 'set "serves": "runner" for a server this machine owns, or declare it in the agent\'s settings',
      Rho::Mcp.entries.fetch("remote").fault
    assert_equal 1, @transports.length

    Rho::Mcp.reset!
    result = load({ "fx" => stdio }, host(mode: "agent"))
    assert_predicate result, :ok?
    assert_equal 'config: mcp server "fx" serves the runner (transport stdio); this rho runs in mode agent and serves ' \
                 "no tool of its own — declare the server on the runner's home, or use mode full", Rho::Mcp.entries.fetch("fx").fault
  end

  # THE ADDRESS BY TRANSPORT: an http row serves the agent
  # by default — refused as that ROW's fault under mode runner, the
  # stdio servers still announced; announced on the agent address under
  # mode agent, where a stdio row is the one refused; both under full.
  def test_an_http_row_serves_the_agent_by_default_and_the_mode_refusal_names_its_transport
    result = load({ "fx" => stdio, "remote" => http }, host(mode: "runner"))
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort
    assert_equal 'config: mcp server "remote" serves the agent (transport http); this rho runs in mode runner — ' \
                 'set "serves": "runner" for a server this machine owns, or declare it in the agent\'s settings',
      Rho::Mcp.entries.fetch("remote").fault
    assert_equal 1, @transports.length, "nothing connected for a row the mode refuses"

    Rho::Mcp.reset!
    @transports.clear
    install_fake_factory
    result = load({ "fx" => stdio, "remote" => http }, host(mode: "agent"))
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %w[mcp__remote__echo mcp__remote__lookup mcp__remote__write skill], result.registry.names.sort,
      "under \"*\" the undescribed `blank` is skipped; the plane's skill serves the row's documents"
    assert result.registry.entries.all? { |e| e.serves == :agent }, "an http server's tools ride the agent address"
    assert_equal 1, @transports.length
    remote = Rho::Mcp.report.fetch("servers").find { |s| s.fetch("key") == "remote" }
    assert_equal ["http", "agent", "connected", "https://mcp.example.com/mcp", ["X-Api-Key"]],
      remote.values_at("transport", "serves", "state", "launch", "headers"), "the launch line is the url; header NAMES only"
    assert_equal 60_000, result.registry.entries.fetch(0).klass::TIMEOUT_MS, "the http park, and Faraday's read timeout"

    Rho::Mcp.reset!
    @transports.clear
    install_fake_factory
    result = load({ "fx" => stdio, "remote" => http(serves: "runner") }, host(mode: "full"))
    assert_predicate result, :ok?
    assert_equal 5, result.registry.entries.count { |e| e.serves == :runner },
      "`serves: runner` re-addresses an http server this machine owns"
    assert_equal 0, result.registry.entries.count { |e| e.serves == :agent }
  end

  def test_a_raise_out_of_register_after_a_spawn_tears_the_children_down
    api_klass = Class.new(Rho::Runner::Extensions::Api) do
      def register_route(*) = raise("the route door is broken")
    end
    Rho::Mcp.settings_table = { "fx" => stdio }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp], api_class: api_klass)
    refute_predicate result, :ok?
    assert_equal 1, @transports.fetch(0).closes, "a handle that raised commits no shutdown hook; the child is closed here"
    assert_empty Rho::Mcp.entries
  end

  def test_the_warn_line_past_the_reference_bytes
    log = []
    logger = Object.new
    %i[debug info warn error].each { |level| logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
    wide = McpTest::FixtureServer.build(tools: [])
    wide.define_tool(name: "wide", description: "w" * 6000, input_schema: { properties: {} }) { MCP::Tool::Response.new([]) }
    Rho::Mcp.transport_factory = ->(_row, read_timeout:, oauth: nil) { McpTest::FakeTransport.new(wide).tap { |t| t.read_timeout = read_timeout } }
    Rho::Mcp.settings_table = { "wide" => stdio(tools: "*") }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp], log: logger, api_class: api_class(nil))
    assert_predicate result, :ok?, result.failures.inspect
    announced = log.find { |entry| entry[1] == "mcp.announced" }
    assert_equal :warn, announced.fetch(0)
    assert_operator announced.fetch(2).fetch(:bytes), :>, Rho::Mcp::REFERENCE_TOOLSET_BYTES
    assert_equal 4971, Rho::Mcp::REFERENCE_TOOLSET_BYTES
    connected = log.find { |entry| entry[1] == "mcp.connected" }
    assert_equal({ server: "wide", protocol_version: MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
                   server_name: "fx-server", server_version: "1.0.0", tools: 1, prompts: 0, resources: 0 }, connected.fetch(2))
    assert_equal 0, log.find { |entry| entry[1] == "mcp.announced" }.fetch(2).fetch(:documents)
  end

  # A server of `count` tools, each description `bytes` wide.
  def wide_server(count, bytes)
    McpTest::FixtureServer.build(tools: []).tap do |server|
      count.times do |index|
        server.define_tool(name: "wide#{index}", description: "w" * bytes, input_schema: { properties: {} }) { MCP::Tool::Response.new([]) }
      end
    end
  end

  # One fake per row, the server chosen by the row's key.
  def serve(servers)
    Rho::Mcp.transport_factory = lambda do |row, read_timeout:, oauth: nil|
      McpTest::FakeTransport.new(servers.fetch(row.key)).tap do |t|
        t.read_timeout = read_timeout
        @transports << t
      end
    end
  end

  def canonical_bytes(entries) = CybrosAgent::SizeBounds.canonical_bytesize(entries)

  def coding_bytes
    canonical_bytes(Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry.announcement)
  end

  BOUND_SENTENCE = /\Amcp server "(?<key>\w+)": its (?<count>\d+) tools \((?<mine>[\d,]+) bytes as the kernel measures an announcement\) would put the runner address's announcement at (?<total>[\d,]+) bytes, past the kernel's envelope_bound \(65,536 bytes\); (?<before>[\d,]+) bytes were announced there before it\z/

  def numbers(fault)
    match = BOUND_SENTENCE.match(fault)
    refute_nil match, fault
    %w[mine total before].to_h { |name| [name, Integer(match[name].delete(","), 10)] }
  end

  # THE KERNEL'S BOUND, MET PER SERVER AT CURATION: an address's announcement is ONE PUT the kernel judges whole
  # under `envelope_bound`, so one server's verbatim descriptions could
  # void the host's own tools and every other server's. Each server's
  # kernel-shaped entries are measured as the kernel measures them,
  # cumulatively in settings order, on top of what the host already
  # announces on that address; the server that would cross the bound is
  # faulted as a ROW — its child closed, nothing of it announced, the
  # sentence naming its bytes, the total and the bound — and the host's
  # own tools and every other server announce.
  def test_a_server_past_the_envelope_bound_is_faulted_as_a_row_and_everything_else_announces
    serve("wide" => wide_server(12, 6_000), "fx" => @server)
    Rho::Mcp.settings_table = { "wide" => stdio(tools: "*"), "fx" => stdio }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding, Rho::Mcp], api_class: api_class(nil))
    assert_predicate result, :ok?, result.failures.inspect
    assert_includes result.registry.names, "bash", "the host's own tools announce"
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.grep(/\Amcp__/).sort, "the other server announces"
    assert_operator canonical_bytes(result.registry.serving(:runner).announcement), :<=, CybrosAgent::SizeBounds::ENVELOPE_BOUND

    entry = Rho::Mcp.entries.fetch("wide")
    assert_equal "down", entry.state
    assert_nil entry.connection
    assert_empty entry.curated.announced
    counted = numbers(entry.fault)
    assert_equal coding_bytes, counted.fetch("before"), "the bytes the host announced before this extension"
    assert_operator counted.fetch("mine"), :>, CybrosAgent::SizeBounds::ENVELOPE_BOUND
    assert_operator counted.fetch("total"), :>, CybrosAgent::SizeBounds::ENVELOPE_BOUND
    assert_equal 1, @transports.fetch(0).closes, "the refused server's child is closed"
    assert_equal "connected", Rho::Mcp.entries.fetch("fx").state

    server = Rho::Mcp.report.fetch("servers").find { |row| row.fetch("key") == "wide" }
    assert_equal ["down", entry.fault, [], 0], server.values_at("state", "detail", "tools", "bytes")
  end

  # Cumulative, in settings order, over the host's own: ten 6,000-byte
  # descriptions fit an empty address and not one that holds Coding's
  # tools; two servers of five each — the first fits on top of Coding's,
  # the second would cross and is the one faulted, the ledger it is judged
  # on naming exactly what the address announces without it.
  def test_the_bound_is_cumulative_in_settings_order_over_the_hosts_own_tools
    serve("tall" => wide_server(10, 6_000))
    Rho::Mcp.settings_table = { "tall" => stdio(tools: "*") }
    alone = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp], api_class: api_class(nil))
    assert_equal "connected", Rho::Mcp.entries.fetch("tall").state, Rho::Mcp.entries.fetch("tall").fault
    tall_bytes = canonical_bytes(alone.registry.announcement)
    assert_operator tall_bytes, :<=, CybrosAgent::SizeBounds::ENVELOPE_BOUND, "fits an empty address"
    assert_operator tall_bytes + coding_bytes, :>, CybrosAgent::SizeBounds::ENVELOPE_BOUND, "the fixture crosses only beside Coding"

    Rho::Mcp.reset!
    serve("tall" => wide_server(10, 6_000))
    Rho::Mcp.settings_table = { "tall" => stdio(tools: "*") }
    beside = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding, Rho::Mcp], api_class: api_class(nil))
    assert_predicate beside, :ok?, beside.failures.inspect
    assert_equal "down", Rho::Mcp.entries.fetch("tall").state
    assert_equal coding_bytes, numbers(Rho::Mcp.entries.fetch("tall").fault).fetch("before")
    assert_empty beside.registry.names.grep(/\Amcp__/)

    Rho::Mcp.reset!
    serve("a" => wide_server(5, 6_000), "b" => wide_server(5, 6_000))
    Rho::Mcp.settings_table = { "a" => stdio(tools: "*"), "b" => stdio(tools: "*") }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding, Rho::Mcp], api_class: api_class(nil))
    assert_predicate result, :ok?, result.failures.inspect
    assert_equal "connected", Rho::Mcp.entries.fetch("a").state, Rho::Mcp.entries.fetch("a").fault
    assert_equal "down", Rho::Mcp.entries.fetch("b").state
    assert_equal 5, result.registry.names.grep(/\Amcp__a__/).length
    assert_empty result.registry.names.grep(/\Amcp__b__/)
    assert_equal canonical_bytes(result.registry.serving(:runner).announcement), numbers(Rho::Mcp.entries.fetch("b").fault).fetch("before"),
      "b is judged on what the address announces without it: Coding's tools and a's"
  end

  # THE SEAM: `register`
  # hands the daemon the one registrar; a call opens a conversation set
  # through the boot path — its classes ready for the agent slot, the
  # report listing its rows after the boot rows with their owner — the
  # budget on top of the boot ledger; the shutdown hook closes the set
  # with the boot connections, and the registrar answers `Closed` after.
  def test_the_registrar_opens_a_conversation_set_beside_the_boot_table_and_the_ladder_closes_both
    result = load({ "fx" => stdio })
    assert_predicate result, :ok?, result.failures.inspect
    api = result.committed.fetch(0)
    registrar = api.conversation_registrar
    refute_nil registrar, "register handed the daemon no conversation registrar"

    set = registrar.call("cnv_1", [{ "type" => "http", "name" => "fx", "url" => "https://mcp.example.com/mcp" }])
    assert_kind_of Rho::Mcp::Conversations::Set, set
    assert_equal %w[mcp__fx__echo mcp__fx__lookup mcp__fx__write], set.classes.map { |k| k::NAME },
      "the editor's `fx` takes every tool; the boot `fx` its allowlist — the collision is the daemon's to judge"
    assert_equal [{ name: "fx", state: "connected", fault: nil, transport: "http" }], set.report
    assert_equal 2, @transports.length
    assert_equal %w[mcp__fx__echo mcp__fx__lookup], result.registry.names.sort, "the registry is the boot table's alone"
    servers = Rho::Mcp.report.fetch("servers")
    assert_equal [["fx", nil, "runner"], ["context7", nil, "agent"], ["fx", "cnv_1", "agent"]],
      servers.map { |s| s.values_at("key", "owner", "serves") }, "the boot rows in settings order, then the conversation's with its owner"
    refute servers.fetch(0).key?("owner"), "a boot row carries no owner member"
    assert_equal 5, Rho::Mcp.report.fetch("total").fetch("tools")
    assert_equal [2, 3], [Rho::Mcp.ledger.fetch(:runner).length, Rho::Mcp.ledger.fetch(:agent).length],
      "the ledger: the boot table's entries, plus the live set's on the agent's"

    hook = result.committed.flat_map(&:lifecycle).find { |h| h.event == :shutdown }
    hook.handler.call
    assert_equal [1, 1], @transports.map(&:closes), "one ladder closes the boot connection and the set's"
    assert_predicate set, :closed?
    assert_empty Rho::Mcp.conversations
    error = assert_raises(Rho::Mcp::Closed) { registrar.call("cnv_2", [{ "name" => "late", "command" => "ruby" }]) }
    assert_equal "the mcp host is shutting down", error.message
    assert_equal 2, @transports.length, "the gate is met before anything spawns"
  end

  def test_reloading_settings_reuses_unchanged_servers_and_retires_only_changed_or_removed_connections
    first = load({ "keep" => stdio, "change" => stdio, "remove" => stdio })
    assert_predicate first, :ok?, first.failures.inspect
    before = Rho::Mcp.connections
    original_class = Rho::Mcp.entries.fetch("keep").curated.classes.first

    changed = load({ "keep" => stdio, "change" => stdio(tools: ["lookup"]) })
    assert_predicate changed, :ok?, changed.failures.inspect
    assert_same before.fetch("keep"), Rho::Mcp.connections.fetch("keep")
    assert_same original_class, Rho::Mcp.entries.fetch("keep").curated.classes.first
    refute_same before.fetch("change"), Rho::Mcp.connections.fetch("change")
    refute Rho::Mcp.entries.key?("remove")
    assert_equal [0, 1, 1, 0], @transports.map(&:closes)
    assert_equal %w[mcp__change__lookup mcp__keep__echo mcp__keep__lookup], changed.registry.names.sort
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "still here", original_class.new(env: nil).call({ "text" => "still here" }).content
      assert_equal "record for new-row", Rho::Mcp.call("change", "lookup", { "key" => "new-row" }).content
    end
  end

  def test_settings_reload_preserves_editor_servers_and_counts_them_once_in_the_announcement
    first = load({ "fx" => stdio })
    set = first.committed.fetch(0).conversation_registrar.call("cnv-editor", [
      { "name" => "editor", "command" => "ruby", "args" => ["editor.rb"] },
    ])
    editor_connection = set.entries.fetch(0).connection
    editor_class = set.classes.find { |klass| klass::RAW_NAME == "echo" }

    2.times do
      changed = load({ "fx" => stdio(tools: ["write"]) })
      assert_predicate changed, :ok?, changed.failures.inspect
      assert_equal [set], Rho::Mcp.conversations
      refute_predicate set, :closed?
      assert_same editor_connection, set.entries.fetch(0).connection
      assert_equal set.kernel_entries, Rho::Mcp.ledger.fetch(:agent)
    end
    assert_equal [1, 0, 0], @transports.map(&:closes)
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "editor alive", editor_class.new(env: nil).call({ "text" => "editor alive" }).content
    end
  end

  def test_a_failed_reload_closes_its_new_connection_and_keeps_the_previous_server_usable
    first = load({ "fx" => stdio })
    assert_predicate first, :ok?, first.failures.inspect
    previous = Rho::Mcp.entries.fetch("fx")
    broken = Class.new(api_class(nil)) do
      def register_route(*) = raise("the route door is broken")
    end
    Rho::Mcp.settings_table = { "fx" => stdio(tools: ["write"]) }
    result = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Mcp], api_class: broken)
    refute_predicate result, :ok?
    assert_same previous, Rho::Mcp.entries.fetch("fx")
    assert_equal [0, 1], @transports.map(&:closes)
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "previous row", Rho::Mcp.call("fx", "echo", { "text" => "previous row" }).content
    end
  end

  def test_an_extension_removed_and_added_again_can_open_connections_again
    result = load({ "fx" => stdio })
    result.committed.fetch(0).lifecycle.find { |hook| hook.event == :shutdown }.handler.call
    assert_raises(Rho::Mcp::Closed) { Rho::Mcp.call("fx", "echo", {}) }
    readded = load({ "fx" => stdio })
    assert_predicate readded, :ok?, readded.failures.inspect
    assert_equal [1, 0], @transports.map(&:closes)
    Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
      assert_equal "reopened", Rho::Mcp.call("fx", "echo", { "text" => "reopened" }).content
    end
  end

  # THE SCRUB: the runner's `ChildEnv` (Bundler's trail
  # dropped — by name on top, since a nested `bundle exec` leaves one)
  # minus credential-shaped names and rho's own, plus the row's `env` on
  # top. `ChildEnv` reads the environment Bundler STARTED from, never a
  # variable planted at run time, so the pin reads the result's shape.
  def test_child_env_replaces_never_merges_and_withholds_credential_shaped_names
    row = Rho::Mcp::Settings.parse({ "fx" => stdio("env" => { "FX_TOKEN" => "given-token-1234", "BUNDLE_GEMFILE" => "/g" }) },
      env: {}).fetch(0)
    env = Rho::Mcp.child_env(row)
    refute_nil env["PATH"]
    assert_equal "given-token-1234", env["FX_TOKEN"], "the row's env lands on top of the scrub"
    assert_equal "/g", env["BUNDLE_GEMFILE"], "a row may re-add a trail of its own"
    leaked = env.keys.reject { |name| row.env.key?(name) }.select do |name|
      name.match?(Rho::Runner::Secrets::CREDENTIAL_SHAPED) || name.start_with?("RHO_", "BUNDLE_", "BUNDLER_") ||
        name.match?(Rho::Runner::ChildEnv::BUNDLER_KEYS)
    end
    assert_empty leaked, "credential-shaped, rho's or Bundler's names reached the child's environment"
    assert_equal "1", env["PYTHONUNBUFFERED"]
  end
end
