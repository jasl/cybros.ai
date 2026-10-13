require "test_helper"

# THE VERBS: the roster from the settings file with
# the daemon's live children, the probe from this process, the switch into
# the person's file, the sessions, a kill through the daemon, the capture
# printed.
class CommandsTest < Minitest::Test
  include RhoAcpClientTest::Helpers

  Commands = Rho::AcpClient::Commands

  # The terminal a handler receives answers its core; the double is its own.
  Cli = Struct.new(:out, :home, :daemon, :documents, :posted, :updated, :configuration_result, keyword_init: true) do
    def core = self
    def running_daemon = daemon
    def get(_daemon, path) = [:get, path]
    def post(_daemon, path, body = nil, budget:) = (posted << [path, body, budget]; [:post, path])
    def parse(response) = documents.fetch(response)
    def configure_extension(id, operations:) = (updated << [id, operations]; configuration_result)
  end
  Home = Data.define(:root, :settings_path)

  def cli(documents: {}, daemon: nil, configuration_result: { "saved" => true, "applied" => false, "restart_required" => false })
    Cli.new(out: StringIO.new, home: Home.new(root: Dir.tmpdir, settings_path: "/nowhere/settings.json"),
      daemon: daemon, documents: documents, posted: [], updated: [], configuration_result: configuration_result)
  end

  def teardown = Rho::AcpClient.reset!

  def table
    { "opencode" => { "command" => "opencode", "args" => ["acp"], "env" => { "OPENROUTER_API_KEY" => "${OPENROUTER_API_KEY}" },
                      "description" => "OpenCode on OpenRouter", "timeout_ms" => 60_000 },
      "off" => { "command" => "x", "description" => "parked", "enabled" => false },
      "broken" => { "command" => "" } }
  end

  def report
    { "agents" => [
      { "key" => "opencode", "launch" => "opencode acp", "description" => "OpenCode on OpenRouter", "permissions" => "allow",
        "timeout_ms" => 60_000, "enabled" => true, "state" => "enabled", "detail" => nil, "env" => ["OPENROUTER_API_KEY"], "children" => 1 },
    ], "sessions" => [
      { "session" => "acp-0123456789ab", "agent" => "opencode", "conversation" => "conv-1", "cwd" => "/work", "pid" => 4242, "pgid" => 4241,
        "acp_session" => "s1", "opened_at" => "2026-09-17T10:00:00Z", "last_prompt_at" => "2026-09-17T10:01:00Z", "calls" => 2,
        "capture" => "/work/.artifacts/acp/opencode-acp-0123456789ab.jsonl" },
    ] }
  end

  def test_the_list_prints_the_rows_masked_with_the_daemons_children_and_no_daemon_says_so
    Rho::AcpClient.settings_table = table
    Rho::AcpClient.settings_env = { "OPENROUTER_API_KEY" => RhoAcpClientTest::SECRET }
    c = cli(documents: { [:get, "/acp"] => report }, daemon: {})
    Commands.run(c, [], {})
    assert_equal <<~TEXT, c.out.string
      agent:     opencode  opencode acp  allow  60s  OpenCode on OpenRouter  enabled
        env:     OPENROUTER_API_KEY=•••
        session: acp-0123456789ab  conversation conv-1  pid 4242  pgid 4241  calls 2  cwd /work
      agent:     off  x  allow  600s  parked  disabled — `rho acp-agents enable off`
      agent:     broken  down: config: acp agent "broken": a row needs a "command" (a string)
    TEXT
    refute_includes c.out.string, RhoAcpClientTest::SECRET

    quiet = cli
    Commands.run(quiet, [], {})
    assert_match(/\Ano daemon running — `rho acp-agents probe NAME` connects from here\n/, quiet.out.string)
    assert_match(/^agent:     opencode  opencode acp  allow  60s  OpenCode on OpenRouter  enabled$/, quiet.out.string)
  end

  def test_sessions_prints_the_daemons_table_and_kill_goes_through_the_route
    c = cli(documents: { [:get, "/acp"] => report, [:post, "/acp/kill"] => { "killed" => true, "session" => "acp-0123456789ab", "agent" => "opencode", "pid" => 4242 } }, daemon: {})
    Commands.run(c, ["sessions"], {})
    assert_equal "session:   acp-0123456789ab  opencode  conversation conv-1  pid 4242  pgid 4241  calls 2  cwd /work  " \
                 "capture /work/.artifacts/acp/opencode-acp-0123456789ab.jsonl\n", c.out.string

    c.out.truncate(0)
    c.out.rewind
    Commands.run(c, ["kill", "acp-0123456789ab"], {})
    assert_equal [["/acp/kill", { "session" => "acp-0123456789ab" }, Rho::Core::Budget::LOCAL]], c.posted
    assert_equal "killed acp-0123456789ab (opencode, pid 4242)\n", c.out.string

    refused = cli(documents: { [:post, "/acp/kill"] => { "error" => { "code" => "acp_session_not_found", "message" => "no session acp-x" } } }, daemon: {})
    error = assert_raises(Rho::Error) { Commands.run(refused, ["kill", "acp-x"], {}) }
    assert_equal "no session acp-x", error.message

    error = assert_raises(Rho::Error) { Commands.run(cli, ["sessions"], {}) }
    assert_equal "no daemon running — nothing to list", error.message
  end

  def test_logs_prints_the_sessions_capture
    Dir.mktmpdir do |dir|
      path = File.join(dir, "capture.jsonl")
      File.write(path, %({"dir":"out","message":{"method":"initialize"}}\n{"dir":"in","message":{"result":{}}}\n))
      document = report.merge("sessions" => [report.fetch("sessions").fetch(0).merge("capture" => path)])
      c = cli(documents: { [:get, "/acp"] => document }, daemon: {})
      Commands.run(c, ["logs", "acp-0123456789ab"], {})
      assert_equal File.read(path), c.out.string
      error = assert_raises(Rho::Error) { Commands.run(c, ["logs", "acp-nope"], {}) }
      assert_equal "no session acp-nope on this daemon", error.message
    end
  end

  def test_the_switch_writes_the_persons_row
    Rho::AcpClient.settings_table = table
    c = cli
    Commands.run(c, ["disable", "opencode"], {})
    assert_equal ["rho.acp-client", [{ "op" => "set", "path" => ["agents", "opencode", "enabled"], "value" => false }]], c.updated.fetch(0)
    assert_equal "disabled opencode\n", c.out.string

    c = cli
    Commands.run(c, ["enable", "off"], {})
    assert_equal ["rho.acp-client", [{ "op" => "set", "path" => ["agents", "off", "enabled"], "value" => true }]], c.updated.fetch(0)
    assert_equal "enabled off\n", c.out.string

    c = cli
    Commands.run(c, ["enable", "opencode"], {})
    assert_empty c.updated
    assert_equal "opencode is already enabled\n", c.out.string

    error = assert_raises(Rho::Error) { Commands.run(cli, ["enable", "nope"], {}) }
    assert_equal 'no acp agent named "nope" in /nowhere/settings.json', error.message
    error = assert_raises(Rho::Error) { Commands.run(cli, ["frobnicate"], {}) }
    assert_equal "usage: rho #{Commands::USAGE}", error.message
  end

  def test_the_switch_reports_a_saved_change_that_requires_a_restart
    Rho::AcpClient.settings_table = table
    c = cli(configuration_result: { "saved" => true, "applied" => false, "restart_required" => true })

    result = Commands.run(c, ["disable", "opencode"], {})

    assert_equal false, result.fetch("opencode").fetch("enabled")
    assert_equal ["rho.acp-client", [{ "op" => "set", "path" => ["agents", "opencode", "enabled"], "value" => false }]], c.updated.fetch(0)
    assert_equal "saved opencode: enabled=false; restart rho to apply\n", c.out.string
  end

  # THE PROBE spawns from this process in its own group, prints the
  # agent's identity, capabilities and each auth method's type, and stores
  # nothing; the group is gone when it returns.
  def test_probe_connects_from_here_prints_the_identity_and_leaves_no_group
    Rho::AcpClient.settings_table = { "fx" => RhoAcpClientTest.raw_row("terminal_auth_only", "env" => { "FX_TOKEN" => "${FX_TOKEN}" }) }
    Rho::AcpClient.settings_env = { "FX_TOKEN" => RhoAcpClientTest::SECRET }
    c = cli
    Commands.run(c, ["probe", "fx"], {})
    printed = c.out.string
    pgid = printed[/^agent:     fx  .* connected \(pid \d+, pgid (\d+)\)  protocol 1  acp-fixture-agent 1$/, 1]
    refute_nil pgid, printed
    assert_includes printed, "  capabilities: loadSession=false, prompt=text, mcp=none, session=close\n"
    assert_includes printed, "  auth methods: login (terminal)\n"
    assert_includes printed, "  env:     FX_TOKEN=•••\n"
    refute_includes printed, RhoAcpClientTest::SECRET
    assert await(seconds: 5) { process_group_alive?(Integer(pgid)) ? nil : true }, "the probe left its group #{pgid}"
    assert_empty Rho::AcpClient.report.fetch("sessions"), "the probe stores nothing"

    Rho::AcpClient.settings_table = { "fx" => { "command" => "/nonexistent/agent", "description" => "gone" } }
    c = cli
    Commands.run(c, ["probe", "fx"], {})
    assert_match(/\Aagent:     fx  \/nonexistent\/agent  down: acp agent "fx": failed to start: /, c.out.string)

    Rho::AcpClient.settings_table = { "fx" => { "command" => "" } }
    c = cli
    Commands.run(c, ["probe", "fx"], {})
    assert_equal "agent:     fx  down: config: acp agent \"fx\": a row needs a \"command\" (a string)\n", c.out.string
  end
end
