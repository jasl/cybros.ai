require "test_helper"

# Asset: the shell-capable local browser session. An unrelated browser may
# reach the public login page but cannot complete somebody else's transaction
# without its initiating secret. Nexus remains the Human authority on every
# protected request; its revoked credential must never fall back to the CLI.
class OAuthLoginTest < Minitest::Test
  include RhoTest::DaemonHarness

  class Nexus
    attr_reader :requests
    attr_accessor :connected, :human_valid, :role, :device_pending, :initialized, :profile_barrier, :token_barrier, :bootstrap_failed

    def initialize
      @requests = []
      @agent = NexusDoubles::FakeAgentApi.new
      @connected = false
      @human_valid = true
      @role = "owner"
      @device_pending = false
      @initialized = true
    end

    def call(path, method: :get, credential: nil, body: nil, form: nil, params: nil, headers: {}, timeout:)
      @requests << { path: path, credential: credential, form: form, headers: headers, timeout: timeout }
      if @bootstrap_failed && path == "/agent_api/v1/executor"
        return response(503, { "error" => { "code" => "unavailable", "message" => "Retry later" } })
      end
      case path
      when "/oauth/token"
        @token_barrier&.call
        if form[:grant_type] == "refresh_token" && form[:refresh_token] == "agent-refresh"
          return response(200, agent_credentials)
        end
        return response(400, { "error" => "authorization_pending" }) if @device_pending

        response(200, grant)
      when "/oauth/device_authorization"
        return response(409, { "error" => "initialization_required" }) unless @initialized

        response(200, { "device_code" => "device-secret", "user_code" => "ABCD-EFGH",
          "verification_uri" => "https://nexus.example/oauth/device", "verification_uri_complete" => "https://nexus.example/oauth/device?user_code=ABCD-EFGH",
          "expires_in" => 900, "interval" => 5 })
      when "/oauth/revoke"
        response(200, nil)
      when "/api/v1/profile"
        @profile_barrier&.call
        return response(401, { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }) unless @human_valid

        response(200, { "member" => { "public_id" => "human-1", "kind" => "human", "role" => @role }, "credential_plane" => "platform" })
      else
        if path.start_with?("/api/v1/")
          response(429, { "error" => { "code" => "rate_limited" } }, { "retry-after" => "7" })
        else
          @agent.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
        end
      end
    end

    def grant
      document = { "access_token" => "human-access", "refresh_token" => "human-refresh", "expires_in" => 3600,
        "plane" => "platform", "token_type" => "Bearer", "scope" => "application",
        "user" => { "public_id" => "human-1", "display_name" => "Owner", "role" => @role }, "agent_public_id" => "0199-user" }
      unless @connected
        document["agent"] = agent_credentials
      end
      document
    end

    def agent_credentials
      { "access_token" => NexusDoubles::MEMBER_TOKEN, "executor_access_token" => NexusDoubles::TRANSPORT_TOKEN,
        "refresh_token" => "agent-refresh", "expires_in" => 1_209_600, "plane" => "member", "token_type" => "Bearer" }
    end

    def response(status, body, headers = {}) = CybrosAgent::Response.new(status: status, body: body, headers: headers)
  end

  def login_daemon
    @nexus = Nexus.new
    boot(config: Rho::Config.from_hash({ "mode" => "agent", "executor_socket" => false,
      "nexus_public_url" => "http://10.0.0.115:3300", "public_url" => "http://10.0.0.115:7777" }), api_transport: @nexus)
  end

  def begin_login(daemon)
    response = request(daemon, :post, "/auth/start", body: {})
    assert_equal "200", response.code, response.body
    JSON.parse(response.body)
  end

  def sign_in(daemon)
    started = begin_login(daemon)
    response = request(daemon, :post, "/auth/complete", body: started.slice("state", "login_secret").merge("code" => "code"))
    assert_equal "200", response.code, response.body
    @nexus.connected = true
    JSON.parse(response.body).fetch("bearer")
  end

  def test_public_page_and_status_expose_no_credentials_and_code_login_binds_its_initiating_browser
    daemon = login_daemon
    started = begin_login(daemon)
    url = URI(started.fetch("authorization_url"))
    assert_equal "10.0.0.115", url.host
    query = URI.decode_www_form(url.query).to_h
    assert_equal "http://10.0.0.115:7777/auth/callback", query.fetch("redirect_uri")
    assert_equal "rho.#{daemon.home.instance_id}", query.fetch("agent_identifier")
    wrong = request(daemon, :post, "/auth/complete", body: { state: started.fetch("state"), login_secret: "wrong", code: "code" })
    assert_equal "401", wrong.code
    refute @nexus.requests.any? { |row| row.fetch(:path) == "/oauth/token" }
    public_status = request(daemon, :get, "/auth/status")
    assert_equal false, JSON.parse(public_status.body).fetch("authenticated")
    refute_includes public_status.body, bearer(daemon)
    assert_equal "404", request(daemon, :post, "/unlock", body: {}).code
    assert_equal "404", request(daemon, :post, "/console/session", body: {}).code
  end

  def test_login_installs_runtime_and_human_credentials_in_separate_files
    daemon = login_daemon
    token = sign_in(daemon)
    refute_equal bearer(daemon), token
    assert_equal "200", request(daemon, :get, "/status", token: token).code
    profile = JSON.parse(request(daemon, :get, "/auth/status", token: token).body)
    assert_equal "human-1", profile.dig("human", "public_id")
    stored = JSON.parse(File.read(Dir[File.join(daemon.home.browser_sessions_root, "*.json")].fetch(0)))
    assert_equal "human-access", stored.dig("credentials", "platform_access_token")
    refute stored.fetch("credentials").key?("access_token")
    refute_includes JSON.generate(daemon.lineage.identity.vault.read), "human-access"
    assert_equal 0o600, File.stat(Dir[File.join(daemon.home.browser_sessions_root, "*.json")].fetch(0)).mode & 0o777
  end

  def test_later_login_preserves_runtime_and_logout_revokes_only_human
    daemon = login_daemon
    first = sign_in(daemon)
    runtime = daemon.lineage.credentials
    started = begin_login(daemon)
    query = URI.decode_www_form(URI(started.fetch("authorization_url")).query).to_h
    assert_equal "login", query.fetch("connection_mode")
    second = JSON.parse(request(daemon, :post, "/auth/complete", body: started.slice("state", "login_secret").merge("code" => "second")).body).fetch("bearer")
    assert_same runtime, daemon.lineage.credentials
    assert_equal "200", request(daemon, :post, "/auth/logout", token: first, body: {}).code
    assert_equal "401", request(daemon, :get, "/status", token: first).code
    assert_equal "200", request(daemon, :get, "/status", token: second).code
    assert_same runtime, daemon.lineage.credentials
    revocations = @nexus.requests.select { |row| row.fetch(:path) == "/oauth/revoke" }
    assert_equal ["human-refresh"], revocations.map { |row| row.fetch(:form).fetch(:token) }
  end

  def test_live_human_revoke_and_role_changes_are_applied_to_browser_requests
    daemon = login_daemon
    token = sign_in(daemon)
    @nexus.role = "member"
    assert_equal "member", JSON.parse(request(daemon, :get, "/auth/status", token: token).body).dig("human", "role")
    @nexus.human_valid = false
    assert_equal "401", request(daemon, :get, "/status", token: token).code
    assert_equal "200", request(daemon, :get, "/status", token: bearer(daemon)).code
    assert_equal false, JSON.parse(request(daemon, :get, "/auth/status", token: token).body).fetch("authenticated")
  end

  def test_device_login_reports_initialization_then_polls_without_a_callback
    daemon = login_daemon
    @nexus.initialized = false
    refused = request(daemon, :post, "/auth/device/start", body: {})
    assert_equal "409", refused.code
    assert_equal "http://10.0.0.115:3300/setup", JSON.parse(refused.body).dig("error", "initialization_uri")
    @nexus.initialized = true
    started = JSON.parse(request(daemon, :post, "/auth/device/start", body: {}).body)
    assert_equal "http://10.0.0.115:3300/oauth/device?user_code=ABCD-EFGH", started.fetch("verification_uri_complete")
    response = request(daemon, :post, "/auth/device/poll", body: started.slice("state", "login_secret"))
    assert_equal "200", response.code, response.body
    assert_equal "active", JSON.parse(response.body).fetch("phase")
  end

  def test_platform_proxy_preserves_encoded_queries_and_retry_headers_without_crossing_its_api_boundary
    daemon = login_daemon
    token = sign_in(daemon)
    response = request(daemon, :post, "/nexus/request", token: token,
      body: { path: "/api/v1/admin/models?ref=provider%2Fmodel", method: "GET", headers: { "If-Match" => "version" }, timeout: 10 })
    assert_equal "200", response.code, response.body
    envelope = JSON.parse(response.body)
    assert_equal 429, envelope.fetch("status")
    assert_equal "7", envelope.dig("headers", "retry-after")
    sent = @nexus.requests.last
    assert_equal "human-access", sent.fetch(:credential)
    assert_equal({ "if-match" => "version" }, sent.fetch(:headers))
    assert_equal 10, sent.fetch(:timeout)
    ["https://other.example/api/v1/profile", "/api/v1/%2e%2e/secret", "/agent_api/v1/profile"].each do |path|
      assert_equal "400", request(daemon, :post, "/nexus/request", token: token, body: { path: path }).code
    end
  end

  def test_a_browser_session_survives_restart_and_configuration_changes
    daemon = login_daemon
    token = sign_in(daemon)
    saved = request(daemon, :patch, "/extensions/rho.codemode/configuration", token: token,
      body: { operations: [{ op: "set", path: ["default"], value: "off" }] })
    assert_equal "200", saved.code, saved.body
    assert_equal "200", request(daemon, :get, "/status", token: token).code
    daemon.stop
    restarted = boot(api_transport: @nexus)
    assert_equal "200", request(restarted, :get, "/status", token: token).code
    assert_equal "human-1", JSON.parse(request(restarted, :get, "/auth/status", token: token).body).dig("human", "public_id")
    assert_equal "401", request(restarted, :get, "/status", token: "rho-browser-v1-#{"x" * 43}").code
  end

  def test_retry_resumes_a_won_runtime_grant_before_starting_new_human_login
    daemon = login_daemon
    @nexus.bootstrap_failed = true
    started = begin_login(daemon)
    response = request(daemon, :post, "/auth/complete", body: started.slice("state", "login_secret").merge("code" => "first"))
    assert_equal "502", response.code
    assert_path_exists daemon.home.pending_connection_path
    @nexus.bootstrap_failed = false
    @nexus.connected = true
    restarted = begin_login(daemon)
    query = URI.decode_www_form(URI(restarted.fetch("authorization_url")).query).to_h
    assert_equal "login", query.fetch("connection_mode")
    refute_path_exists daemon.home.pending_connection_path
    assert_equal :active, daemon.lineage.phase
    assert_equal 1, @nexus.requests.count { |row| row.fetch(:path) == "/oauth/token" && row.fetch(:form)[:grant_type] == "authorization_code" }
  end

  def test_terminal_human_storage_failure_preserves_the_won_runtime_bundle_for_resume
    daemon = login_daemon
    daemon.stop
    File.write(daemon.home.operator_credentials_path, "{}")
    File.chmod(0o644, daemon.home.operator_credentials_path)
    owner = Rho::ApplicationConnection.new(home: daemon.home, transport: @nexus)
    connection = Rho::Connection.new(home: daemon.home, mode: "agent", device_flow: owner, api_transport: @nexus)
    connection.start
    assert_raises(CybrosAgent::Credentials::NotDurable) { connection.await }
    assert_equal :error, connection.phase
    assert_path_exists daemon.home.pending_connection_path
    resumed = Rho::Connection.new(home: daemon.home, mode: "agent", device_flow: owner, api_transport: @nexus)
    assert resumed.resume
    assert_equal :active, resumed.phase
    refute_path_exists daemon.home.pending_connection_path
    assert_equal 1, @nexus.requests.count { |row| row.fetch(:path) == "/oauth/device_authorization" }
  end

  def test_terminal_login_on_a_connected_daemon_reuses_runtime_and_authorizes_the_platform_proxy
    daemon = login_daemon
    sign_in(daemon)
    runtime = daemon.lineage.credentials
    response = request(daemon, :post, "/device/start", token: bearer(daemon), body: {})
    assert_equal "200", response.code, response.body
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      state = JSON.parse(request(daemon, :get, "/status", token: bearer(daemon)).body)
      break if state.dig("connection", "phase") == "active"
      raise "terminal login did not complete" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    assert_same runtime, daemon.lineage.credentials
    start = @nexus.requests.reverse.find { |row| row.fetch(:path) == "/oauth/device_authorization" }
    assert_equal "login", start.fetch(:form).fetch(:connection_mode)
    assert_path_exists daemon.home.operator_credentials_path
    proxy = request(daemon, :post, "/nexus/request", token: bearer(daemon), body: { path: "/api/v1/profile" })
    assert_equal "200", proxy.code, proxy.body
    assert_equal "human-access", @nexus.requests.last.fetch(:credential)
  end

  def test_empty_cross_origin_forms_cannot_allocate_public_login_transactions
    daemon = login_daemon
    assert_equal "400", request(daemon, :post, "/auth/start").code
    assert_equal "400", request(daemon, :post, "/auth/device/start").code
    assert_empty @nexus.requests
  end

  def test_browser_authority_checks_hold_the_shutdown_admission_until_the_request_finishes
    daemon = login_daemon
    token = sign_in(daemon)
    entered, release = Queue.new, Queue.new
    @nexus.profile_barrier = -> { entered << true; release.pop }
    caller = Thread.new { route(daemon, "GET", "/status").call(json_request({}, token: token)) }
    entered.pop
    daemon.lineage.begin_stop
    waiting = Thread.new { daemon.lineage.quiesce(deadline: 5) }
    sleep 0.02
    assert waiting.alive?, "live Human validation belongs to the admitted request"
    denied = route(daemon, "POST", "/auth/start").call(json_request({}))
    assert_equal 503, denied.status
    release << true
    refute_nil caller.join(2)
    refute_nil waiting.join(2)
  ensure
    release << true if release
    @nexus.profile_barrier = nil
    daemon&.lineage&.abort_stop
    caller&.join(2)
    waiting&.join(2)
  end

  def test_browser_and_terminal_completion_share_one_connection_slot
    daemon = login_daemon
    started = begin_login(daemon)
    entered, release = Queue.new, Queue.new
    @nexus.token_barrier = -> { entered << true; release.pop }
    caller = Thread.new do
      route(daemon, "POST", "/auth/complete").call(json_request(started.slice("state", "login_secret").merge("code" => "code")))
    end
    entered.pop
    competing = route(daemon, "POST", "/device/start").call(json_request({}, token: bearer(daemon)))
    assert_equal "starting", competing.last.fetch("phase")
    refute @nexus.requests.any? { |row| row.fetch(:path) == "/oauth/device_authorization" }
    release << true
    refute_nil caller.join(2)
    assert_equal 200, caller.value.first
  ensure
    release << true if release
    @nexus.token_barrier = nil
    caller&.join(2)
  end
end
