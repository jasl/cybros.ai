require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/platform_http"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# Agent provisioning, key import and later Human login use the shipped HTTP,
# browser and CLI paths. No OAuth ceremony supplies the runtime's credentials.
class ApiKeyConnectionTest < Minitest::Test
  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    E2E::SessionSignInBudget.consume
    @session = CybrosAgent::Platform::Sessions.new(base_url: @base_url).create(email: @steward.email, password: @steward.password)
    E2E::SecretHygiene.register(@session.token)
    @http = E2E::PlatformHttp.new(@base_url)
    @keys = []
    @key_revocations = []
  end

  def teardown
    unless passed? || !@daemon
      directory = File.expand_path("../artifacts/api_key_connection/#{name}-#{Process.pid}", __dir__)
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "rho.log"), E2E::SecretHygiene.redact(@daemon.log_text))
    end
  ensure
    if (result = @daemon&.dispose_connection)
      output, status = result
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
    end
    @key_revocations&.each do |path|
      response = @http.post(path, bearer: @session.token)
      assert_equal 204, response.status, response.body.inspect
    end
    CybrosAgent::PlatformClient.new(base_url: @base_url, credential: @session.token).session.revoke if @session
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_member_key_works_without_an_executor_and_revocation_is_independent
    agent = create_agent_in_browser("API-only Agent")
    path = agent_path(agent)
    first = issue_key_in_browser(agent, "First client")
    second = issue_key("#{path}/api_keys", "Second client")
    profile = member_client(first).profile.fetch
    assert_equal agent.fetch("public_id"), profile.member.public_id
    assert_equal "agent", profile.member.kind
    assert_nil profile.credential.expires_at
    refute_empty profile.member.agent_identifier
    assert_raises(CybrosAgent::Api::Unauthorized) { executor_client(first).executor }
    assert_equal 401, @http.get("/api/v1/agents", bearer: first).status,
      "Agent authority cannot issue credentials"

    listed = @http.get("#{path}/api_keys", bearer: @session.token)
    assert_equal 200, listed.status
    assert_equal 2, listed.body.fetch("api_keys").length
    refute_includes JSON.generate(listed.body), first
    refute_includes JSON.generate(listed.body), second

    revoke(first)
    assert_raises(CybrosAgent::Api::Unauthorized) { member_client(first).profile.fetch }
    assert_equal agent.fetch("public_id"), member_client(second).profile.fetch.member.public_id

    response = @http.post("#{path}/connection_revocation", bearer: @session.token)
    assert_equal 200, response.status, response.body.inspect
    assert_raises(CybrosAgent::Api::Unauthorized) { member_client(second).profile.fetch }
    replacement = issue_key("#{path}/api_keys", "Replacement connection")
    assert_equal agent.fetch("public_id"), member_client(replacement).profile.fetch.member.public_id
    response = @http.post("#{path}/removal", bearer: @session.token)
    assert_equal 200, response.status, response.body.inspect
    assert_raises(CybrosAgent::Api::Unauthorized) { member_client(replacement).profile.fetch }
    response = @http.post("#{path}/restoration", bearer: @session.token)
    assert_equal 200, response.status, response.body.inspect
    assert_raises(CybrosAgent::Api::Unauthorized) { member_client(replacement).profile.fetch }
    restored = issue_key("#{path}/api_keys", "Restored Agent")
    assert_equal agent.fetch("public_id"), member_client(restored).profile.fetch.member.public_id
  end

  def test_rho_import_rejects_mixed_keys_then_restarts_runs_tools_and_logs_in_without_repairing
    agent = create_agent("API-key rho")
    path = agent_path(agent)
    member_key = issue_key("#{path}/api_keys", "rho member")
    application_key = issue_key("#{path}/executor/api_keys", "rho application")
    foreign = create_agent("Other API-key Agent")
    foreign_application_key = issue_key("#{agent_path(foreign)}/executor/api_keys", "Other application")
    application = executor_client(application_key).executor.executor
    assert_equal agent.fetch("public_id"), application.agent_public_id

    start_daemon
    imported = { access_token: member_key, executor_access_token: application_key }
    output, status = @daemon.cli("connect", "--api-key-stdin",
      stdin: JSON.generate(imported.merge(executor_access_token: foreign_application_key)))
    refute_predicate status, :success?, E2E::SecretHygiene.redact(output)
    assert_nil @daemon.status["identity"], "a mixed import must not publish a connection"
    assert_equal foreign.fetch("public_id"), executor_client(foreign_application_key).executor.executor.agent_public_id,
      "a rejected import must not revoke an unrelated key"

    output, status = @daemon.cli("connect", "--api-key-stdin", stdin: JSON.generate(imported))
    assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
    @keys.each { |key| refute_includes output, key }
    await_adopted
    identity = @daemon.status.fetch("identity")
    assert_equal agent.fetch("public_id"), identity.fetch("user_public_id")
    assert_equal application.public_id, identity.fetch("executor_public_id")
    assert_equal "unauthorized", @daemon.control(:post, "/nexus/request",
      body: { method: "GET", path: "/api/v1/profile" }).dig("error", "code")

    @daemon.stop
    @daemon.start
    await_adopted
    assert_equal identity, @daemon.status.fetch("identity")
    assert_equal application.credential_epoch, executor_client(application_key).executor.executor.credential_epoch
    @daemon.await_announced(address: "runner")
    E2E.enable_dev_lane!
    E2E.hosts.start
    note = File.join(@project, "api-key.txt")
    arguments = CGI.escape(JSON.generate(path: note, content: "API key Runner works\n"))
    output, status = @daemon.cli("run", "!mock tool_call=write tool_args=#{arguments} -- write the note",
      "--dir", @project, "--model", "dev/mock-text", "--output-format", "json", "--timeout", "90")
    assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
    assert_equal "API key Runner works\n", File.read(note, encoding: Encoding::UTF_8)

    actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    E2E::Ceremony.confirm(actor: actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    assert_equal identity, @daemon.status.fetch("identity")
    profile = @daemon.control(:post, "/nexus/request", body: { method: "GET", path: "/api/v1/profile" })
    assert_equal @steward.public_id, profile.dig("body", "member", "public_id")
    assert_equal application.credential_epoch, executor_client(application_key).executor.executor.credential_epoch,
      "Human login must preserve the API-key application transport"
    assert_equal agent.fetch("public_id"), member_client(member_key).profile.fetch.member.public_id
  end

  private

    def create_agent(name)
      response = @http.post("/api/v1/agents", body: { agent: { display_name: name } }, bearer: @session.token)
      assert_equal 201, response.status, response.body.inspect
      response.body.fetch("agent")
    end

    def create_agent_in_browser(name)
      @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
      page = @actor.page
      @actor.visit("/agents")
      page.click_link "Connect agent"
      page.assert_current_path "/agent_connection"
      page.click_link "Create agent"
      page.fill_in "Name", with: name
      page.click_button "Create agent"
      page.assert_text("Agent created.")
      response = @http.get("/api/v1#{page.current_path}", bearer: @session.token)
      assert_equal 200, response.status
      response.body.fetch("agent")
    end

    def issue_key_in_browser(agent, name)
      page = @actor.page
      page.click_link "Agent API keys"
      page.click_link "Create API key"
      page.fill_in "Name", with: name
      key = E2E::SecretHygiene.during_reveal do
        page.click_button "Create API key"
        page.assert_text("API key created")
        secret = E2E::SecretHygiene.register(page.find("input[name='api_key_secret']").value)
        page.click_link "Done"
        page.assert_text("Agent API keys")
        refute page.has_selector?("input[name='api_key_secret']", wait: 0)
        refute_includes page.html, secret
        secret
      end
      id = page.find("tr[data-api-key-id]", text: name)["data-api-key-id"]
      @keys << key
      @key_revocations << "#{agent_path(agent)}/api_keys/#{id}/revocation"
      key
    end

    def agent_path(agent) = "/api/v1/agents/#{agent.fetch("public_id")}"

    def issue_key(path, name)
      # Other journeys share this steward's issuance quota. Wait only for an
      # explicit refusal before continuing the credential lifecycle assertions.
      response = @http.post(path, body: { api_key: { name: name } }, bearer: @session.token, retry_rate_limit: true)
      assert_equal 201, response.status, E2E::SecretHygiene.redact(response.body.inspect)
      key = E2E::SecretHygiene.register(response.body.fetch("secret"))
      @keys << key
      @key_revocations << "#{path}/#{response.body.fetch("api_key").fetch("public_id")}/revocation"
      key
    end

    def member_client(key) = CybrosAgent::Client.new(base_url: @base_url, credential: key)
    def executor_client(key) = CybrosAgent::ExecutorClient.new(base_url: @base_url, credential: key)

    def revoke(key)
      CybrosAgent::DeviceFlow::Client.new(base_url: @base_url).revoke(token: key)
    end

    def start_daemon
      @root = Dir.mktmpdir("rho-api-key-e2e")
      @project = File.join(@root, "project")
      home = File.join(@root, "home")
      FileUtils.mkdir_p([@project, home])
      File.write(File.join(home, "settings.json"), JSON.generate("settings_version" => 1, "plugins" => {}), perm: 0o600)
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: home, tools_root: @project, env: { "RHO_MODE" => "full" })
      @daemon.start
    end

    def await_adopted
      @daemon.await("API-key rho did not adopt a workspace") do
        state = @daemon.status.fetch("workspace")
        flunk state.inspect if state.fetch("state") == "error"
        state.fetch("state") == "adopted"
      end
    end
end
