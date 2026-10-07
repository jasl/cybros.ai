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
    endpoint = recording_routed_endpoint(seen, {
      "GET /agent_api/v1/models" => [[200, fixture]],
      "GET /api/v1/profile" => [[200, { "member" => { "public_id" => "human-1", "kind" => "human", "role" => "owner" },
        "credential_plane" => "platform" }]],
    })
    local_home = Rho::Home.resolve(base_url: endpoint, root: @root).prepare
    oauth = NexusDoubles::FakeOAuth.new
    connection = Rho::Connection.new(home: local_home, mode: "agent", display_name: "Test",
      device_flow: CybrosAgent::DeviceFlow::Client.new(base_url: endpoint, transport: oauth, sleeper: ->(_) { }),
      api_transport: NexusDoubles::FakeAgentApi.new)
    connection.start
    connection.await
    grant = CybrosAgent::ApplicationOAuth::Credentials.new(access_token: "human-access", refresh_token: "human-refresh",
      expires_in: 3600, token_type: "Bearer", user: CybrosAgent::ApplicationOAuth::User.new(
        public_id: "human-1", display_name: "Owner", role: "owner"), agent_public_id: "0199-user", agent: nil, runner: nil)
    CybrosAgent::Credentials::OAuth.issue(credentials: grant,
      authority: CybrosAgent::ApplicationOAuth::Client.new(base_url: endpoint),
      store: Rho::StateFile.new(local_home.operator_credentials_path))
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
    assert_includes output.string, "Keeping the existing rho and Nexus login"
    assert_equal 3, seen.length, "model and Human profile reads need no second OAuth ceremony"
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

  def test_stopped_live_connection_uses_human_login_without_replacing_runtime_credentials
    api = NexusDoubles::FakeAgentApi.new
    profile = api.call("/agent_api/v1/profile", credential: NexusDoubles::MEMBER_TOKEN, timeout: 1).body
    executor = api.call("/agent_api/v1/executor", credential: NexusDoubles::TRANSPORT_TOKEN, timeout: 1).body
    seen = []
    endpoint = recording_routed_endpoint(seen, {
      "GET /agent_api/v1/profile" => [[200, profile]],
      "GET /agent_api/v1/executor" => [[200, executor]],
      "POST /oauth/device_authorization" => [[200, { "device_code" => "device-secret", "user_code" => "ABCD-EFGH",
        "verification_uri" => "http://nexus/oauth/device", "verification_uri_complete" => "http://nexus/oauth/device?user_code=ABCD-EFGH",
        "expires_in" => 900, "interval" => 1 }]],
      "POST /oauth/token" => [[200, { "access_token" => "human-access", "refresh_token" => "human-refresh",
        "expires_in" => 3600, "plane" => "platform", "token_type" => "Bearer", "scope" => "application",
        "user" => { "public_id" => "human-1", "display_name" => "Owner", "role" => "owner" }, "agent_public_id" => "0199-user" }]],
    })
    local_home = Rho::Home.resolve(base_url: endpoint, root: @root).prepare
    local_home.write_setting("mode", "agent")
    owner = CybrosAgent::DeviceFlow::Client.new(base_url: endpoint, transport: NexusDoubles::FakeOAuth.new, sleeper: ->(_) { })
    connection = Rho::Connection.new(home: local_home, mode: "agent", device_flow: owner, api_transport: api)
    connection.start
    connection.await
    before = File.read(connection.identity.vault.path)

    logged_in = Rho::Core.new(home: local_home).connect_in_process
    assert_equal connection.identity.user_public_id, logged_in.user_public_id
    assert_equal connection.identity.executor_public_id, logged_in.executor_public_id
    assert_equal before, File.read(connection.identity.vault.path)
    assert_path_exists local_home.operator_credentials_path
    start = seen.find { |row| row.start_with?("POST /oauth/device_authorization") }
    assert_equal "login", URI.decode_www_form(start.split("\r\n\r\n", 2).last).to_h.fetch("connection_mode")
    assert_equal 1, seen.count { |row| row.start_with?("POST /oauth/token") }
  end
end
