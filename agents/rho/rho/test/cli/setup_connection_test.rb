require "test_helper"
require "rho/cli/setup"

class SetupConnectionTest < Minitest::Test
  include RhoTest::CliHarness

  class TerminalIO < StringIO
    def tty? = true
  end

  def test_setup_on_a_signed_in_daemon_reads_models_without_starting_another_ceremony
    fixture = { "models" => [{ "ref" => "test/model", "available" => true,
      "capabilities" => { "tool_calls" => true }, "pricing" => { "state" => "priced" } }] }
    seen = []
    endpoint = recording_routed_endpoint(seen, {
      "GET /status" => [[200, { "authority" => { "signed" => "signed_in" } }]],
      "GET /models" => [[200, fixture]],
      "PATCH /settings" => [[200, { "settings" => {} }]],
    })
    announce(endpoint: endpoint)
    input, output = TerminalIO.new("n\n1\n"), TerminalIO.new
    assert Rho::Cli::Setup.new(cli: cli, input: input, output: output, env: {}).run("model")
    saves = seen.grep(/\APATCH \/settings/).map { |request| JSON.parse(request.split("\r\n\r\n", 2).last) }
    assert_equal [{ "nexus_public_url" => "https://nexus.example" }, { "default_model" => "test/model" }], saves
    refute seen.any? { |request| request.start_with?("POST /device/start") }
    assert_includes output.string, "Keeping the existing rho connection"
  end

  def test_public_browser_url_does_not_change_pairing_api_authority
    seen = []
    active = { "state" => "active", "mode" => "agent", "connection" => { "phase" => "active" },
      "identity" => { "user_public_id" => "user-1", "executor_public_id" => "executor-1" } }
    endpoint = recording_routed_endpoint(seen, {
      "POST /device/start" => [[200, pending_start]], "GET /status" => [[200, active]],
    })
    announce(endpoint: endpoint)
    cli.connect(public_url: "https://public.example/nexus")
    assert_includes @out.string, "https://public.example/nexus/oauth/device?user_code=BCDF-GHJK"
    refute_includes @out.string, "https://nexus.example"
    assert_equal 1, seen.count { |request| request.start_with?("POST /device/start") }
    assert_equal "https://nexus.example", home.base_url
  end

  def test_public_browser_base_path_replaces_internal_base_path
    nested = Rho::Home.resolve(base_url: "https://nexus.example/base", root: @root).prepare
    endpoint = recording_routed_endpoint([], {
      "POST /device/start" => [[200, pending_start.transform_values { |value| value.to_s.sub("nexus.example/oauth", "nexus.example/base/oauth") }]],
      "GET /status" => [[200, { "state" => "active", "connection" => { "phase" => "active" } }]],
    })
    Rho::StateFile.new(nested.announcement_path).write("version" => Rho::Daemon::ANNOUNCEMENT_VERSION, "endpoint" => endpoint, "bearer" => "x", "pid" => Process.pid)
    Rho::Cli::Terminal.new(home: nested, out: @out).connect(public_url: "https://public.example/base")
    assert_includes @out.string, "https://public.example/base/oauth/device?user_code=BCDF-GHJK"
    refute_includes @out.string, "/base/base/"
  end
end
