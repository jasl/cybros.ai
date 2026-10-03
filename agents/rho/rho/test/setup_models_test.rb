require "test_helper"
require "rho/cli/setup"

class SetupModelsTest < Minitest::Test
  include RhoTest::CliHarness

  class TerminalIO < StringIO
    def tty? = true
  end

  def test_stopped_connected_home_reads_models_with_existing_member_credential
    fixture = JSON.parse(File.read(File.expand_path("../../../../contracts/nexus/v1/models.json", __dir__))).fetch("valid_fixture")
    seen = []
    endpoint = recording_routed_endpoint(seen, { "GET /agent_api/v1/models" => [[200, fixture]] })
    local_home = Rho::Home.resolve(base_url: endpoint, root: @root).prepare
    oauth = NexusDoubles::FakeOAuth.new
    connection = Rho::Connection.new(home: local_home, mode: "agent", display_name: "Test",
      device_flow: CybrosAgent::DeviceFlow::Client.new(base_url: endpoint, transport: oauth, sleeper: ->(_) { }),
      api_transport: NexusDoubles::FakeAgentApi.new)
    connection.start
    connection.await
    control = Rho::Core.new(home: local_home)
    rows = control.models(workload: "text_generation")
    assert_equal fixture.fetch("models"), rows
    assert_equal 1, seen.length
    assert_includes seen.first, "workload=text_generation"
    assert_includes seen.first, "Bearer #{NexusDoubles::MEMBER_TOKEN}"
    assert_nil control.running_daemon
    output = TerminalIO.new
    terminal = Rho::Cli::Terminal.new(home: local_home, out: output)
    assert Rho::Cli::Setup.new(cli: terminal, input: TerminalIO.new("n\n1\n"), output: output, env: {}).run("model")
    assert_includes output.string, "Keeping the existing rho connection"
    assert_equal 2, seen.length, "only model reads, no second OAuth ceremony"
    Rho::Lock.acquire(local_home.boot_lock_path).release
  end

  def test_unconnected_or_held_home_never_sends_a_model_request
    error = assert_raises(Rho::Error) { core.models }
    assert_includes error.message, "not connected"
    lock = Rho::Lock.acquire(home.boot_lock_path)
    assert_raises(Rho::Lock::AlreadyHeld) { core.models }
  ensure
    lock&.release
  end
end
