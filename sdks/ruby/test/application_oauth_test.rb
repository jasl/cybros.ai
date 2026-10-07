require "test_helper"

class ApplicationOAuthTest < Minitest::Test
  USER = { "public_id" => "human-1", "display_name" => "Owner", "role" => "owner" }.freeze
  HUMAN = { "access_token" => "human-access", "refresh_token" => "human-refresh", "expires_in" => 3600,
    "plane" => "platform", "token_type" => "Bearer", "scope" => "application", "user" => USER,
    "agent_public_id" => "agent-1" }.freeze
  AGENT = { "access_token" => "agent-access", "executor_access_token" => "executor-access",
    "refresh_token" => "agent-refresh", "expires_in" => 3600, "plane" => "member", "token_type" => "Bearer" }.freeze
  RUNNER = { "access_token" => "runner-access", "refresh_token" => "runner-refresh", "expires_in" => 3600,
    "plane" => "executor_transport", "token_type" => "Bearer" }.freeze
  DEVICE = { "device_code" => "device-secret", "user_code" => "ABCD-EFGH",
    "verification_uri" => "http://nexus/oauth/device", "verification_uri_complete" => "http://nexus/oauth/device?user_code=ABCD-EFGH",
    "expires_in" => 900, "interval" => 5 }.freeze

  class Transport
    attr_reader :requests
    def initialize(*responses)
      @responses = responses
      @requests = []
    end
    def call(path, **options)
      @requests << [path, options]
      status, body = @responses.shift
      raise body if status == :raise

      CybrosAgent::Response.new(status: status, body: body, headers: {})
    end
  end

  class MemoryStore
    attr_reader :document
    def read = @document
    def write(document) = @document = document
    def delete = @document = nil
    def description = "memory"
    def with_lock = yield
  end

  def client(*responses)
    @transport = Transport.new(*responses)
    CybrosAgent::ApplicationOAuth::Client.new(base_url: "http://nexus", public_url: "http://10.0.0.115:3300",
      transport: @transport, sleeper: ->(_seconds) { })
  end

  def test_code_flow_uses_public_origin_pkce_and_explicit_instance_claims
    login = client
    url = URI(login.authorization_url(redirect_uri: "http://10.0.0.115:7777/auth/callback", state: "state",
      code_challenge: "challenge", claims: { agent_identifier: "rho.instance", agent_display_name: "rho",
        executor_display_name: "rho" }, connection_mode: "login"))
    assert_equal "10.0.0.115", url.host
    query = URI.decode_www_form(url.query).to_h
    assert_equal "cybros-application", query.fetch("client_id")
    assert_equal "application", query.fetch("scope")
    assert_equal "S256", query.fetch("code_challenge_method")
    assert_equal "login", query.fetch("connection_mode")
    assert_equal "rho.instance", query.fetch("agent_identifier")
  end

  def test_code_exchange_keeps_all_three_lineages_separate
    login = client([200, HUMAN.merge("agent" => AGENT, "runner" => RUNNER)])
    credentials = login.exchange_code(code: "code", redirect_uri: "http://rho/auth/callback", code_verifier: "verifier")
    assert credentials.platform_plane?
    refute credentials.member_plane?
    assert_equal "human-access", credentials.platform_access_token
    assert_equal "agent-access", credentials.agent.access_token
    assert_equal "executor-access", credentials.agent.executor_access_token
    assert_equal "runner-access", credentials.runner.executor_access_token
    refute credentials.runner.member_plane?
    assert_equal "authorization_code", @transport.requests.first.last.fetch(:form).fetch(:grant_type)
    assert_equal "verifier", @transport.requests.first.last.fetch(:form).fetch(:code_verifier)
    refute_includes credentials.inspect, "human-access"
    refute_includes credentials.inspect, "agent-access"
  end

  def test_device_flow_and_human_only_refresh_use_same_application_authority
    login = client([200, DEVICE], [400, { "error" => "authorization_pending" }], [200, HUMAN], [200, HUMAN])
    authorization = login.request_authorization(agent_identifier: "rho.instance", agent_display_name: "rho",
      executor_display_name: "rho", connection_mode: "login")
    assert_equal "http://10.0.0.115:3300/oauth/device", authorization.verification_uri
    grant = login.await_credentials(authorization)
    assert_equal "human-access", grant.platform_access_token
    assert_nil grant.agent
    assert_nil grant.runner
    assert_equal "human-access", login.rotate(refresh_token: grant.refresh_token).platform_access_token
    assert @transport.requests.all? { |_path, options| options.fetch(:form).fetch(:client_id) == "cybros-application" }
  end

  def test_device_browser_origin_replaces_the_machine_base_path_once
    device = DEVICE.merge("verification_uri" => "http://nexus/internal/oauth/device",
      "verification_uri_complete" => "http://nexus/internal/oauth/device?user_code=ABCD-EFGH")
    transport = Transport.new([200, device])
    login = CybrosAgent::ApplicationOAuth::Client.new(base_url: "http://nexus/internal", public_url: "https://public.example/base",
      transport: transport)
    authorization = login.request_device_authorization(claims: { agent_identifier: "rho.instance" })
    assert_equal "https://public.example/base/oauth/device?user_code=ABCD-EFGH", authorization.verification_uri_complete
  end

  def test_uninitialized_device_flow_preserves_the_deployment_public_setup_address
    login = client([409, { "error" => "initialization_required", "initialization_uri" => "http://nexus/setup" }])
    error = assert_raises(CybrosAgent::ApplicationOAuth::InitializationRequired) do
      login.request_device_authorization(claims: { agent_identifier: "rho.instance" })
    end
    assert_equal "http://10.0.0.115:3300/setup", error.initialization_uri
  end

  def test_malformed_or_wrong_plane_response_cannot_be_saved_as_a_human
    [AGENT, HUMAN.merge("user" => {}), HUMAN.merge("expires_in" => 0), HUMAN.merge("scope" => "admin")].each do |body|
      login = client([200, body])
      assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) do
        login.exchange_code(code: "code", redirect_uri: "http://rho/auth/callback", code_verifier: "verifier")
      end
    end
  end

  def test_human_credential_store_never_exposes_member_or_executor_planes
    login = client([200, HUMAN], [200, HUMAN.merge("access_token" => "rotated-human", "refresh_token" => "rotated-refresh")])
    grant = login.exchange_code(code: "code", redirect_uri: "http://rho/auth/callback", code_verifier: "verifier")
    store = MemoryStore.new
    oauth = CybrosAgent::Credentials::OAuth.issue(credentials: grant, authority: login, store: store)
    assert_equal "human-access", oauth.platform_credential
    assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { oauth.member_credential }
    assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { oauth.executor_credential }
    refute store.read.key?("access_token")
    refute store.read.key?("executor_access_token")
    oauth.refresh
    assert_equal "rotated-human", store.read.fetch("platform_access_token")
    assert_equal "rotated-refresh", store.read.fetch("refresh_token")
  end
end
