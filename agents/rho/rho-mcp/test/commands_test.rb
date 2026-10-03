require "test_helper"
require "stringio"

# THE CLI: `rho mcp`'s blocks from the daemon's
# document, the probe's honest print — non-printables escaped, the byte
# count beside each description, a `$ref` flagged — every value masked.
class CommandsTest < Minitest::Test
  # The terminal a handler receives answers its core; the double is its own.
  Cli = Struct.new(:out, :home, :daemon, :document, :updated, keyword_init: true) do
    def core = self
    def running_daemon = daemon
    def get(_daemon, _path) = :response
    def parse(_response) = document
    def update_settings(changes) = (updated << changes; changes)
  end
  Home = Data.define(:root, :settings_path)

  def cli(document: nil, daemon: nil)
    Cli.new(out: StringIO.new, home: Home.new(root: Dir.tmpdir, settings_path: "/nowhere/settings.json"),
      daemon: daemon, document: document, updated: [])
  end

  def teardown = Rho::Mcp.reset!

  def test_escape_shows_what_the_model_reads
    assert_equal "a\\u{200B}b\\nc\\u{202E}d\\u{1B}[31m", Rho::Mcp::Commands.escape("a\u200Bb\nc\u202Ed\e[31m")
    assert_equal "plain text — fine", Rho::Mcp::Commands.escape("plain text — fine")
  end

  def test_the_list_prints_one_block_per_server_with_masked_names_and_the_total
    document = { "servers" => [
      { "key" => "fx", "transport" => "stdio", "launch" => "ruby srv.rb", "serves" => "runner", "state" => "connected",
        "pid" => 4242, "pgid" => 4241, "protocol_version" => "2025-11-25", "server_name" => nil, "server_version" => nil,
        "tools" => [{ "name" => "mcp__fx__echo", "bytes" => 712, "profile" => Rho::Mcp::Curation::WORST_CASE, "profile_source" => "worst case", "underivable" => [] },
                    { "name" => "mcp__fx__lookup", "bytes" => 1132, "profile" => { "kind" => "read_only", "destructive" => false, "world" => "closed" }, "profile_source" => "operator", "underivable" => ["file.path"] }],
        "skipped" => [{ "raw" => "write", "reason" => "not in tools" }], "bytes" => 1844, "env" => ["FX_TOKEN"], "headers" => [],
        "documents" => [{ "name" => "fx-summarize", "kind" => "prompt", "raw" => "summarize", "mime_type" => nil },
                        { "name" => "fx-readme", "kind" => "resource", "raw" => "readme", "mime_type" => "text/markdown" },
                        { "name" => "fx-notes", "kind" => "resource", "raw" => "notes", "mime_type" => nil }],
        "skipped_documents" => [{ "name" => "fx-greet", "kind" => "prompt", "reason" => 'prompt: required argument "who"' },
                                { "name" => "fx-logo", "kind" => "resource", "reason" => "resource: application/octet-stream" }],
        "auth" => { "kind" => "none" } },
      { "key" => "old", "transport" => "stdio", "launch" => nil, "serves" => "runner", "state" => "down", "detail" => "config: no tools",
        "tools" => [], "skipped" => [], "bytes" => 0, "documents" => [], "skipped_documents" => [], "env" => [], "headers" => [],
        "auth" => { "kind" => "none" } },
      { "key" => "dead", "transport" => "stdio", "launch" => "ruby x", "serves" => "runner", "state" => "down", "detail" => "exited (status 1) at 10:32:07",
        "tools" => [{ "name" => "mcp__dead__x", "bytes" => 10, "profile" => Rho::Mcp::Curation::WORST_CASE, "profile_source" => "worst case", "underivable" => [] }],
        "skipped" => [], "bytes" => 10, "documents" => [], "skipped_documents" => [], "env" => [], "headers" => ["Authorization", "X-Api-Key"],
        "auth" => { "kind" => "none" } },
      { "key" => "remote", "transport" => "http", "launch" => "https://mcp.example.com/mcp", "serves" => "agent", "state" => "connected",
        "pid" => nil, "pgid" => nil, "protocol_version" => "2026-07-28", "server_name" => "fx-server", "server_version" => "1.0.0",
        "tools" => [{ "name" => "mcp__remote__echo", "bytes" => 700, "profile" => Rho::Mcp::Curation::WORST_CASE, "profile_source" => "worst case", "underivable" => [] }],
        "skipped" => [], "bytes" => 700, "documents" => [], "skipped_documents" => [], "env" => [], "headers" => ["Authorization"],
        "auth" => { "kind" => "header" } },
    ], "total" => { "tools" => 4, "bytes" => 2554, "documents" => 3 } }
    c = cli(document: document, daemon: {})
    Rho::Mcp::Commands.run(c, [], {})
    assert_equal <<~TEXT, c.out.string
      server:    fx  stdio  ruby srv.rb  serves runner  connected (pid 4242, pgid 4241)  2025-11-25  (unnamed)
        tools:   2 announced of 3 listed — 1,844 bytes
          mcp__fx__echo    712 bytes  write/destructive/open (worst case)
          mcp__fx__lookup  1,132 bytes  read_only/closed (operator)
                           incubation deny not derivable for "file.path"
          skipped: write (not in tools)
        documents: 3 announced of 5 listed
          fx-summarize (prompt)  fx-readme (resource, text/markdown)  fx-notes (resource)
          skipped: fx-greet (prompt: required argument "who"), fx-logo (resource: application/octet-stream)
        env:     FX_TOKEN=•••
      server:    old  stdio  serves runner  down: config: no tools
      server:    dead  stdio  ruby x  serves runner  down: exited (status 1) at 10:32:07
        tools:   1 announced of 1 listed — 10 bytes
          mcp__dead__x  10 bytes  write/destructive/open (worst case)
        headers: Authorization: •••  X-Api-Key: •••
      server:    remote  http  https://mcp.example.com/mcp  serves agent  connected  2026-07-28  fx-server 1.0.0
        tools:   1 announced of 1 listed — 700 bytes
          mcp__remote__echo  700 bytes  write/destructive/open (worst case)
        headers: Authorization: •••
      total:     4 tools announced, 2,554 bytes; 3 documents
    TEXT
  end

  # NO DAEMON: the shipped row is listed from the settings alone, after the
  # person's rows, disabled, with its `auth:` line (this double has no home
  # to hold a login).
  def test_without_a_daemon_the_list_names_the_probe_and_the_shipped_row
    c = cli
    Rho::Mcp::Commands.run(c, [], {})
    assert_equal <<~TEXT, c.out.string
      no daemon running — `rho mcp probe NAME` connects from here
      server:    context7  http  https://mcp.context7.com/mcp  serves agent  disabled — `rho mcp enable context7`
        auth:    oauth — needs login (this host has no rho home to hold a login — declare the server on a rho home)
    TEXT
  end

  # A DISABLED ROW in the daemon's document: the switch named on the server
  # line, the `auth:` line kept (a person may log in before enabling), and
  # nothing more — a row with no tools prints no tools, as a `down:
  # config:` row does.
  def test_the_list_prints_a_disabled_row_with_the_switch_and_its_auth_line
    document = { "servers" => [
      { "key" => "context7", "transport" => "http", "launch" => "https://mcp.context7.com/mcp", "serves" => "agent", "state" => "disabled",
        "detail" => nil, "tools" => [], "skipped" => [], "bytes" => 0, "documents" => [], "skipped_documents" => [], "env" => [], "headers" => [],
        "auth" => { "kind" => "oauth", "state" => "needs_login", "reason" => "no tokens" } },
      { "key" => "parked", "transport" => "stdio", "launch" => "ruby srv.rb", "serves" => "runner", "state" => "disabled", "detail" => nil,
        "tools" => [], "skipped" => [], "bytes" => 0, "documents" => [], "skipped_documents" => [], "env" => ["FX_TOKEN"], "headers" => [],
        "auth" => { "kind" => "none" } },
    ], "total" => { "tools" => 0, "bytes" => 0, "documents" => 0 } }
    c = cli(document: document, daemon: {})
    Rho::Mcp::Commands.run(c, [], {})
    assert_equal <<~TEXT, c.out.string
      server:    context7  http  https://mcp.context7.com/mcp  serves agent  disabled — `rho mcp enable context7`
        auth:    oauth — needs login (no tokens)
      server:    parked  stdio  ruby srv.rb  serves runner  disabled — `rho mcp enable parked`
      total:     0 tools announced, 0 bytes; 0 documents
    TEXT
  end

  # AN EDITOR'S ROW: listed after the boot
  # rows with its owner — the conversation — after the address; a
  # faulted transport `down:` with its sentence; the boot row's line as
  # it was.
  def test_the_list_prints_a_conversation_row_with_its_owner_after_the_boot_rows
    document = { "servers" => [
      { "key" => "fx", "transport" => "stdio", "launch" => "ruby srv.rb", "serves" => "runner", "state" => "connected",
        "pid" => 4242, "pgid" => 4241, "protocol_version" => "2025-11-25", "server_name" => "fx-server", "server_version" => "1.0.0",
        "tools" => [], "skipped" => [], "bytes" => 0, "documents" => [], "skipped_documents" => [], "env" => [], "headers" => [],
        "auth" => { "kind" => "none" } },
      { "key" => "fx", "transport" => "http", "launch" => "http://127.0.0.1:4000/mcp", "serves" => "agent", "owner" => "cnv_01HX", "state" => "connected",
        "pid" => nil, "pgid" => nil, "protocol_version" => "2026-07-28", "server_name" => "fx-server", "server_version" => "1.0.0",
        "tools" => [{ "name" => "mcp__fx__lookup", "bytes" => 700, "profile" => Rho::Mcp::Curation::WORST_CASE, "profile_source" => "worst case", "underivable" => [] }],
        "skipped" => [], "bytes" => 700, "documents" => [], "skipped_documents" => [], "env" => [], "headers" => ["X-Api-Key"],
        "auth" => { "kind" => "none" } },
      { "key" => "events", "transport" => "sse", "launch" => nil, "serves" => "agent", "owner" => "cnv_01HX", "state" => "down",
        "detail" => "transport sse unsupported", "tools" => [], "skipped" => [], "bytes" => 0, "documents" => [], "skipped_documents" => [],
        "env" => [], "headers" => [], "auth" => { "kind" => "none" } },
    ], "total" => { "tools" => 1, "bytes" => 700, "documents" => 0 } }
    c = cli(document: document, daemon: {})
    Rho::Mcp::Commands.run(c, [], {})
    assert_equal <<~TEXT, c.out.string
      server:    fx  stdio  ruby srv.rb  serves runner  connected (pid 4242, pgid 4241)  2025-11-25  fx-server 1.0.0
      server:    fx  http  http://127.0.0.1:4000/mcp  serves agent  conversation cnv_01HX  connected  2026-07-28  fx-server 1.0.0
        tools:   1 announced of 1 listed — 700 bytes
          mcp__fx__lookup  700 bytes  write/destructive/open (worst case)
        headers: X-Api-Key: •••
      server:    events  sse  serves agent  conversation cnv_01HX  down: transport sse unsupported
      total:     1 tools announced, 700 bytes; 0 documents
    TEXT
  end

  # THE OPTIONAL-AUTHORIZATION WORD on the `auth:` line: the store's mark,
  # inside the logged-in parenthesis, after the refresh-token word.
  def test_the_auth_line_says_when_the_authorization_is_optional
    auth = { "kind" => "oauth", "state" => "logged_in", "issued_at" => "2027-01-15T08:00:00Z", "issuer" => "https://as.example/oauth",
             "scope" => "fx:read", "refresh_token" => true }
    shown = ->(text) { text.to_s }
    plain = Rho::Mcp::Commands.auth_line(auth, shown)
    assert_match(%r{\Aoauth — logged in \(tokens issued .*; issuer https://as\.example/oauth; scope fx:read; refresh token held\)\z}, plain)
    assert_equal "#{plain.delete_suffix(")")}; optional: the server answers anonymously too)",
      Rho::Mcp::Commands.auth_line(auth.merge("optional" => true), shown)
    assert_equal plain, Rho::Mcp::Commands.auth_line(auth.merge("optional" => false), shown)
    assert_equal "oauth — needs login (no tokens)",
      Rho::Mcp::Commands.auth_line({ "state" => "needs_login", "reason" => "no tokens", "optional" => true }, shown),
      "the word rides only on a logged-in line"
  end

  # THE SWITCH (`rho mcp enable NAME` / `rho mcp disable NAME`): the
  # person's file is the one place — `mcp_servers.NAME.enabled`, sent
  # through Core's settings operation with the whole `mcp_servers` object rebuilt around
  # that one member: the shipped row gets a partial row that overlays it, a
  # hand-written row keeps every other member, a state already held writes
  # nothing.
  def test_enable_and_disable_write_the_rows_switch_into_the_persons_table
    fx = { "transport" => "stdio", "command" => "ruby", "tools" => ["echo"] }
    Rho::Mcp.settings_table = { "fx" => fx }
    c = cli
    Rho::Mcp::Commands.run(c, %w[enable context7], {})
    assert_equal [{ "mcp_servers" => { "fx" => fx, "context7" => { "enabled" => true } } }], c.updated
    assert_equal "enabled context7\n", c.out.string

    Rho::Mcp.settings_table = { "fx" => fx, "context7" => { "enabled" => true } }
    c = cli
    Rho::Mcp::Commands.run(c, %w[enable context7], {})
    assert_empty c.updated, "already enabled: nothing written"
    assert_equal "context7 is already enabled\n", c.out.string

    c = cli
    Rho::Mcp::Commands.run(c, %w[disable context7], {})
    assert_equal [{ "mcp_servers" => { "fx" => fx, "context7" => { "enabled" => false } } }], c.updated
    assert_equal "disabled context7\n", c.out.string

    c = cli
    Rho::Mcp::Commands.run(c, %w[disable fx], {})
    assert_equal [{ "mcp_servers" => { "fx" => fx.merge("enabled" => false), "context7" => { "enabled" => true } } }], c.updated,
      "a hand-written row keeps every other member"
    c = cli
    Rho::Mcp::Commands.run(c, %w[enable fx], {})
    assert_empty c.updated
    assert_equal "fx is already enabled\n", c.out.string

    Rho::Mcp.settings_table = { "fx" => fx.merge("enabled" => false) }
    c = cli
    Rho::Mcp::Commands.run(c, %w[enable fx], {})
    assert_equal [{ "mcp_servers" => { "fx" => fx.merge("enabled" => true) } }], c.updated
  end

  def test_the_switch_refuses_a_name_neither_built_in_nor_configured_and_a_fresh_home_holds_the_shipped_row_disabled
    Rho::Mcp.settings_table = {}
    c = cli
    error = assert_raises(Rho::Error) { Rho::Mcp::Commands.run(c, %w[enable nope], {}) }
    assert_equal 'no mcp server named "nope" — not built in, and not in /nowhere/settings.json', error.message
    assert_raises(Rho::Error) { Rho::Mcp::Commands.run(c, %w[disable nope], {}) }
    assert_empty c.updated
    Rho::Mcp::Commands.run(c, %w[disable context7], {})
    assert_equal "context7 is already disabled\n", c.out.string
    assert_empty c.updated
    c = cli
    Rho::Mcp::Commands.run(c, %w[enable context7], {})
    assert_equal [{ "mcp_servers" => { "context7" => { "enabled" => true } } }], c.updated, "a fresh home: the one partial row"
  end

  # The probe (and the login) reach the shipped row by name while it is
  # disabled: the switch is the daemon's, the CLI connects on demand.
  def test_the_probe_reaches_the_shipped_row_while_disabled
    server = McpTest::FixtureServer.build(tools: %w[echo], documents: [])
    rows = []
    Rho::Mcp.transport_factory = ->(row, read_timeout:, oauth: nil) { rows << row; McpTest::FakeTransport.new(server).tap { |t| t.read_timeout = read_timeout } }
    Rho::Mcp.settings_table = {}
    c = cli
    Rho::Mcp::Commands.run(c, %w[probe context7], {})
    assert_match(%r{\Aserver:    context7  http  https://mcp\.context7\.com/mcp  serves agent  connected(?: \(pid \d+, pgid \d+\))?  \S+  fx-server 1\.0\.0\n},
      c.out.string)
    assert_includes c.out.string, "    mcp__context7__echo  "
    assert_equal ["context7", false], [rows.fetch(0).key, rows.fetch(0).enabled?]
  end

  def test_the_probe_prints_the_tools_honestly_and_flags_a_ref_and_leaves_no_connection
    server = McpTest::FixtureServer.build(tools: %w[echo blank], documents: %w[summarize greet readme blob template])
    server.define_tool(name: "sneaky", description: "Read\u200B this\n carefully",
      input_schema: { properties: { path: { "$ref" => "#/$defs/p" } }, "$defs" => { p: { type: "string" } } }) { MCP::Tool::Response.new([]) }
    transports = []
    Rho::Mcp.transport_factory = ->(_row, read_timeout:, oauth: nil) { McpTest::FakeTransport.new(server).tap { |t| t.read_timeout = read_timeout; transports << t } }
    row = Rho::Mcp::Settings.parse({ "fx" => { "transport" => "stdio", "command" => "ruby", "tools" => ["echo"], "env" => { "FX_TOKEN" => "${FX_TOKEN}" } } },
      env: { "FX_TOKEN" => "fx-secret-token-0123456789" }).fetch(0)
    c = cli
    Rho::Mcp::Commands.probe_row(c, row)
    out = c.out.string
    assert_match(/\Aserver:    fx  stdio  ruby  serves runner  connected \(pid 4242, pgid 4241\)  2025-11-25  fx-server 1\.0\.0\n/, out)
    assert_includes out, "  instructions: Be kind to the operator.\n"
    assert_includes out, "  tools:   3 listed — 1 would be announced, "
    assert_includes out, "    mcp__fx__echo  "
    assert_includes out, "  (worst case)\n      description (#{McpTest::FixtureServer::ECHO_DESCRIPTION.bytesize} bytes): #{McpTest::FixtureServer::ECHO_DESCRIPTION}\n"
    assert_includes out, "    mcp__fx__blank  "
    assert_includes out, "  skipped: not in tools\n      description (0 bytes): \n"
    assert_includes out, "      description (23 bytes): Read\\u{200B} this\\n carefully\n      $defs: a provider may refuse this schema\n"
    assert_includes out, "  documents: 4 listed — 2 would be announced\n"
    assert_includes out, "    fx-summarize  (prompt)\n      description (#{McpTest::FixtureServer::SUMMARIZE_DESCRIPTION.bytesize} bytes): " \
                         "#{McpTest::FixtureServer::SUMMARIZE_DESCRIPTION}\n"
    assert_includes out, "    fx-greet  (prompt)  skipped: prompt: required argument \"who\"\n"
    assert_includes out, "    fx-readme  (resource, text/markdown)\n"
    assert_includes out, "    fx-blob  (resource, application/octet-stream)  skipped: resource: application/octet-stream\n"
    assert_includes out, "  resource_templates: 1 listed (never a document)\n    note  fx://notes/{id}\n"
    assert_includes out, "  env:     FX_TOKEN=•••\n"
    refute_includes out, "fx-secret-token"
    assert_equal 1, transports.fetch(0).closes, "the probe's connection is torn down in an ensure"
  end

  def test_the_probe_of_a_faulted_row_prints_the_sentence
    c = cli
    fault = Rho::Mcp::Settings::Fault.new(key: "fx", transport: "stdio", serves: "runner", sentence: "names no tools")
    assert_nil Rho::Mcp::Commands.send(:probe_row, c, fault) rescue nil
  end

  # `Rho::Error` where rho's errors are loaded (the suite loads them for
  # the credential store; every process with these verbs has them).
  def test_a_bad_verb_shape_is_refused_by_usage
    usage = "usage: rho mcp | mcp probe NAME | mcp enable NAME | mcp disable NAME | mcp login NAME [--no-browser] | mcp logout NAME"
    error = assert_raises(Rho::Error) { Rho::Mcp::Commands.run(cli, ["sync"], {}) }
    assert_equal usage, error.message
    error = assert_raises(Rho::Error) { Rho::Mcp::Commands.run(cli, ["login"], {}) }
    assert_equal usage, error.message
    error = assert_raises(Rho::Error) { Rho::Mcp::Commands.run(cli, ["enable"], {}) }
    assert_equal usage, error.message
  end
end
