require "test_helper"

# Asset: the shell-capable local browser session. An unrelated browser may
# reach the public login page but cannot complete somebody else's transaction
# without its initiating secret. Nexus remains the Human authority on every
# protected request; its revoked credential must never fall back to the CLI.
class OAuthLoginTest < Minitest::Test
  include RhoTest::DaemonHarness

  class Nexus
    attr_reader :requests
    attr_accessor :connected, :human_valid, :role, :device_pending, :initialized, :profile_barrier, :token_barrier, :bootstrap_failed, :announcement_barrier

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
      @announcement_barrier&.call if path == "/agent_api/v1/executor/announcement" && method == :put
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

  def test_api_key_connection_human_login_uses_imported_identity_without_repairing_runtime
    daemon = login_daemon
    imported = request(daemon, :post, "/connection/api_keys", token: bearer(daemon), body: {
      access_token: NexusDoubles::MEMBER_TOKEN, executor_access_token: NexusDoubles::TRANSPORT_TOKEN,
    })
    assert_equal "200", imported.code, imported.body
    before = daemon.identity.vault.read
    @nexus.connected = true

    started = begin_login(daemon)
    query = URI.decode_www_form(URI(started.fetch("authorization_url")).query).to_h
    assert_equal "login", query.fetch("connection_mode")
    assert_equal "rho.imported-agent", query.fetch("agent_identifier")
    completed = request(daemon, :post, "/auth/complete",
      body: started.slice("state", "login_secret").merge("code" => "code"))
    assert_equal "200", completed.code, completed.body
    assert_equal before, daemon.identity.vault.read
    assert_equal "api_key", daemon.lineage.credentials.agent.authentication_kind
    human = JSON.parse(completed.body).fetch("bearer")
    assert_equal "human-1", JSON.parse(request(daemon, :get, "/auth/status", token: human).body).dig("human", "public_id")
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
    # The gate opens nothing before pairing, whatever its mode.
    unpaired = request(daemon, :post, "/auth/unlock", body: {})
    assert_equal "409", unpaired.code
    assert_equal "connection_required", JSON.parse(unpaired.body).dig("error", "code")
    assert_equal({ "mode" => "open", "configured" => nil, "password_set" => false }, JSON.parse(public_status.body).fetch("access"))
    assert_equal false, JSON.parse(public_status.body).fetch("paired")
  end

  def test_supplementary_runner_login_selects_the_existing_agent_in_both_browser_flows
    daemon = login_daemon
    sign_in(daemon)
    daemon.stop
    full = boot(config: Rho::Config.from_hash({ "mode" => "full", "executor_socket" => false,
      "nexus_public_url" => "http://10.0.0.115:3300", "public_url" => "http://10.0.0.115:7777" }),
      api_transport: @nexus, realtime_factory: ->(*) { })

    started = begin_login(full)
    query = URI.decode_www_form(URI(started.fetch("authorization_url")).query).to_h
    assert_equal "0199-user", query.fetch("assignment_agent_public_id")
    assert_equal "runner", query.fetch("executor_kind")
    refute query.key?("agent_identifier")

    response = request(full, :post, "/auth/device/start", body: {})
    assert_equal "200", response.code, response.body
    form = @nexus.requests.reverse.find { |row| row.fetch(:path) == "/oauth/device_authorization" }.fetch(:form)
    assert_equal "0199-user", form.fetch(:assignment_agent_public_id)
    assert_equal "runner", form.fetch(:executor_kind)
    refute form.key?(:agent_identifier)
  end

  # Asset: the paired rho's service. On loopback the gate is open by default —
  # the same person's processes already hold the operator bearer — so a page
  # unlocks by itself, but holds no Human: the Human plane still asks for a
  # Nexus sign-in, and `nexus` mode ends every unlock session at once.
  def test_an_open_gate_admits_a_paired_loopback_rho_without_a_human_and_nexus_mode_closes_it
    daemon = login_daemon
    human = sign_in(daemon)
    unlocked = request(daemon, :post, "/auth/unlock", body: {})
    assert_equal "200", unlocked.code, unlocked.body
    token = JSON.parse(unlocked.body).fetch("bearer")
    refute_equal human, token
    assert_equal "200", request(daemon, :get, "/status", token: token).code
    status = JSON.parse(request(daemon, :get, "/auth/status", token: token).body)
    assert_equal [true, "unlock", nil, true], status.values_at("authenticated", "session", "human", "paired")
    proxied = request(daemon, :post, "/nexus/request", token: token, body: { path: "/api/v1/profile" })
    assert_equal "403", proxied.code, "the page's grant stands; the Human plane needs a Human"
    assert_equal "human_login_required", JSON.parse(proxied.body).dig("error", "code")
    stored = Dir[File.join(daemon.home.browser_sessions_root, "*.json")].map { |path| JSON.parse(File.read(path)) }
    assert_equal 1, stored.count { |row| row["kind"] == "unlock" }, "an unlock session is a private file like a Human's"
    refute_includes JSON.generate(stored), token

    daemon.stop
    restarted = boot(api_transport: @nexus)
    assert_equal "200", request(restarted, :get, "/status", token: token).code, "an unlocked tab survives a restart"

    closed = request(restarted, :patch, "/settings", token: human, body: { webui_access: "nexus" })
    assert_equal "200", closed.code, closed.body
    assert_equal "401", request(restarted, :get, "/status", token: token).code, "nexus mode ends unlock sessions at once"
    assert_equal "200", request(restarted, :get, "/status", token: human).code
    refused = request(restarted, :post, "/auth/unlock", body: {})
    assert_equal "409", refused.code
    assert_equal "nexus_login_required", JSON.parse(refused.body).dig("error", "code")
    assert_equal "nexus", JSON.parse(request(restarted, :get, "/auth/status").body).dig("access", "mode")
    assert_equal "200", request(restarted, :post, "/auth/logout", token: token, body: {}).code, "logging out a dead session is quiet"
  end

  # Asset: the unlock password. It is required before the mode may ask for it,
  # stored only as a salted digest, bounded against guessing, and its change
  # ends the sessions it admitted.
  def test_switching_from_open_to_password_requires_the_password_for_existing_open_sessions
    daemon = login_daemon
    human = sign_in(daemon)
    assert_equal "200", request(daemon, :post, "/auth/password", token: human,
      body: { password: "already saved password" }).code
    token = JSON.parse(request(daemon, :post, "/auth/unlock", body: {}).body).fetch("bearer")
    assert_equal "200", request(daemon, :get, "/status", token: token).code

    assert_equal "200", request(daemon, :patch, "/settings", token: human, body: { webui_access: "password" }).code
    assert_equal "401", request(daemon, :get, "/status", token: token).code,
      "an open session has never supplied the saved password"
    assert_equal false, JSON.parse(request(daemon, :get, "/auth/status", token: token).body).fetch("authenticated")

    daemon.stop
    restarted = boot(api_transport: @nexus)
    assert_equal "401", request(restarted, :get, "/status", token: token).code,
      "loading the session from disk preserves its admission mode"
    unlocked = request(restarted, :post, "/auth/unlock", body: { password: "already saved password" })
    assert_equal "200", unlocked.code
    assert_equal "200", request(restarted, :get, "/status", token: JSON.parse(unlocked.body).fetch("bearer")).code
  end

  def test_a_password_gate_admits_the_password_and_forgets_sessions_when_it_changes
    daemon = login_daemon
    human = sign_in(daemon)
    early = request(daemon, :patch, "/settings", token: human, body: { webui_access: "password" })
    assert_equal "422", early.code
    assert_includes JSON.parse(early.body).dig("error", "message"), "Set an unlock password"
    short = request(daemon, :post, "/auth/password", token: human, body: { password: "short" })
    assert_equal "400", short.code
    set = request(daemon, :post, "/auth/password", token: human, body: { password: "correct horse battery" })
    assert_equal "200", set.code, set.body
    assert_equal true, JSON.parse(set.body).fetch("password_set")
    stored = JSON.parse(File.read(daemon.home.webui_password_path))
    assert_equal "scrypt", stored.fetch("algorithm")
    refute_includes File.read(daemon.home.webui_password_path), "correct horse battery"
    assert_equal 0o600, File.stat(daemon.home.webui_password_path).mode & 0o777
    assert_equal "200", request(daemon, :patch, "/settings", token: human, body: { webui_access: "password" }).code
    assert_equal({ "mode" => "password", "configured" => "password", "password_set" => true },
      JSON.parse(request(daemon, :get, "/auth/status").body).fetch("access"))

    wrong = request(daemon, :post, "/auth/unlock", body: { password: "wrong" })
    assert_equal "401", wrong.code
    assert_equal "unlock_refused", JSON.parse(wrong.body).dig("error", "code")
    assert_equal "401", request(daemon, :post, "/auth/unlock", body: {}).code, "an empty password is a wrong one"
    unlocked = request(daemon, :post, "/auth/unlock", body: { password: "correct horse battery" })
    assert_equal "200", unlocked.code, unlocked.body
    token = JSON.parse(unlocked.body).fetch("bearer")
    assert_equal "200", request(daemon, :get, "/status", token: token).code

    assert_equal "400", request(daemon, :post, "/auth/password", token: human, body: { password: nil }).code,
      "clearing the password under password mode would leave only Nexus"
    other = JSON.parse(request(daemon, :post, "/auth/unlock", body: { password: "correct horse battery" }).body).fetch("bearer")
    changed = request(daemon, :post, "/auth/password", token: token, body: { password: "a different passphrase" })
    assert_equal "200", changed.code, "an unlocked page may change the password like any owner"
    assert_equal "200", request(daemon, :get, "/status", token: token).code, "the page that changed it stays in"
    assert_equal "401", request(daemon, :get, "/status", token: other).code, "every other session of the old password ends"
    again = request(daemon, :post, "/auth/unlock", body: { password: "a different passphrase" })
    assert_equal "200", again.code
    assert_equal "200", request(daemon, :patch, "/settings", token: human, body: { webui_access: "open" }).code
    cleared = request(daemon, :post, "/auth/password", token: human, body: { password: nil })
    assert_equal "200", cleared.code
    assert_equal false, JSON.parse(cleared.body).fetch("password_set")
    assert_equal "401", request(daemon, :get, "/status", token: JSON.parse(again.body).fetch("bearer")).code
    assert_equal "200", request(daemon, :post, "/auth/unlock", body: {}).code, "open again"
  end

  def test_the_page_changing_access_mode_stays_admitted_during_publication_and_after_restart
    daemon = login_daemon
    human = sign_in(daemon)
    token = JSON.parse(request(daemon, :post, "/auth/unlock", body: {}).body).fetch("bearer")
    assert_equal "200", request(daemon, :post, "/auth/password", token: token,
      body: { password: "new page password" }).code
    other = JSON.parse(request(daemon, :post, "/auth/unlock", body: {}).body).fetch("bearer")
    entered, release = Queue.new, Queue.new
    @nexus.announcement_barrier = -> {
      @nexus.announcement_barrier = nil
      entered << true
      sleep 0.001 while release.empty?
      release.pop
    }
    writer = Thread.new do
      request(daemon, :patch, "/settings", token: token, body: { webui_access: "password" })
    end
    Timeout.timeout(5) { entered.pop }
    assert_equal "200", request(daemon, :get, "/settings", token: token).code,
      "the current writer stays admitted while remote publication is pending"
    assert_equal "401", request(daemon, :get, "/settings", token: other).code,
      "another open session has not changed the gate or proved the password"
    release << true
    assert_equal "200", writer.value.code
    @nexus.announcement_barrier = nil

    daemon.stop
    restarted = boot(api_transport: @nexus)
    assert_equal "200", request(restarted, :get, "/settings", token: token).code
    assert_equal "401", request(restarted, :get, "/settings", token: other).code
    assert_equal "200", request(restarted, :patch, "/settings", token: token, body: { webui_access: "open" }).code
    assert_equal "200", request(restarted, :get, "/settings", token: token).code
    assert_equal "200", request(restarted, :patch, "/settings", token: token, body: { webui_access: "nexus" }).code
    assert_equal "401", request(restarted, :get, "/settings", token: token).code
    assert_equal "200", request(restarted, :get, "/settings", token: human).code
  ensure
    @nexus.announcement_barrier = nil
    release << true if release
    writer&.join(5)
  end

  def test_a_refused_access_mode_preparation_keeps_the_writer_in_the_restored_mode
    daemon = login_daemon
    sign_in(daemon)
    token = JSON.parse(request(daemon, :post, "/auth/unlock", body: {}).body).fetch("bearer")
    assert_equal "200", request(daemon, :post, "/auth/password", token: token,
      body: { password: "new page password" }).code

    daemon.define_singleton_method(:replace_extensions) do |**|
      raise Rho::Settings::PreparationError, "extension preparation failed"
    end
    begin
      response = request(daemon, :patch, "/settings", token: token, body: { webui_access: "password" })
      assert_equal "503", response.code
      assert_equal false, JSON.parse(response.body).dig("error", "applied")
    ensure
      daemon.singleton_class.remove_method(:replace_extensions)
    end

    assert_equal "open", JSON.parse(request(daemon, :get, "/auth/status", token: token).body).dig("access", "mode")
    assert_equal "200", request(daemon, :get, "/settings", token: token).code
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
    # The daemon may announce its executor after the proxy request returns.
    # Assert against this request, not the last activity on a shared transport.
    sent_requests = @nexus.requests.select { |entry| entry.fetch(:path) == "/api/v1/admin/models?ref=provider%2Fmodel" }
    assert_equal 1, sent_requests.length
    sent = sent_requests.fetch(0)
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
