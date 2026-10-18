require "test_helper"

class APIKeyConnectionTest < Minitest::Test
  include RhoTest::DaemonHarness

  def home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root)

  def keys
    { "access_token" => NexusDoubles::MEMBER_TOKEN,
      "executor_access_token" => NexusDoubles::TRANSPORT_TOKEN,
      "runner_access_token" => NexusDoubles::RUNNER_TOKEN }
  end

  def import(daemon, document = keys)
    request(daemon, :post, "/connection/api_keys", token: bearer(daemon), body: document)
  end

  def test_import_restart_and_renewal_keep_static_keys_without_an_oauth_exchange
    oauth = NexusDoubles::FakeOAuth.new
    daemon = connected_boot(device_flow: connection_device_flow(oauth))
    response = import(daemon)
    assert_equal 200, response.code.to_i, response.body
    assert_equal :active, daemon.phase
    identity = daemon.identity
    assert_equal "api_key", identity.vault.read.fetch("authentication_kind")
    assert_equal "api_key", identity.runner_vault.read.fetch("authentication_kind")
    assert_equal "rho.imported-agent", identity.agent_identifier
    assert_equal "rho.imported-runner", identity.runner_registration_identifier
    assert_equal [], daemon.maintenance.run_once(daemon.lineage.credentials, verify: true)
    assert_empty oauth.requests
    daemon.stop

    restarted = connected_boot(device_flow: connection_device_flow(oauth))
    assert_equal :active, restarted.phase
    assert_equal keys.values, [restarted.lineage.credentials.member_credential,
      restarted.lineage.credentials.executor_credential, restarted.lineage.credentials.runner_credential]
    assert_empty oauth.requests
  end

  def test_revoked_member_key_keeps_other_planes_and_never_refreshes
    oauth = NexusDoubles::FakeOAuth.new
    api = NexusDoubles::SelectiveApi.new
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api)
    assert_equal 200, import(daemon).code.to_i
    api.accept(NexusDoubles::MEMBER_TOKEN, false)

    report = Rho::Authority.new(oauth: daemon.lineage.credentials, base_url: daemon.home.base_url,
      transport: api, expected_identity: daemon.identity, mode: "full").check
    assert_equal({ member: :unauthorized, executor_transport: :live, runner_transport: :live }, report.fetch(:planes))
    refute report[:lost]
    refute report[:runner_lost]
    assert_empty oauth.requests
  end

  def test_bootstrap_refuses_foreign_executor_and_allows_corrected_import
    api = NexusDoubles::FakeAgentApi.new
    foreign = true
    api.define_singleton_method(:executor) do
      super().tap { |document| document.fetch("executor")["agent_public_id"] = "other-agent" if foreign }
    end
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    response = import(daemon)
    assert_equal 422, response.code.to_i
    assert_match(/same Agent/, response.body)
    assert_nil Rho::StateFile.new(daemon.home.connection_pointer_path).read
    foreign = false
    assert_equal 200, import(daemon).code.to_i
  end

  def test_full_mode_refuses_a_runner_from_another_agent
    api = NexusDoubles::FakeAgentApi.new
    api.define_singleton_method(:runner_executor) do
      super().tap { |document| document.fetch("executor")["assignment_agent_public_id"] = "other-agent" }
    end
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    response = import(daemon)
    assert_equal 422, response.code.to_i
    assert_match(/private Runner/, response.body)
    assert_nil Rho::StateFile.new(daemon.home.connection_pointer_path).read
  end

  def test_install_failure_resumes_staged_static_keys_without_an_exchange
    oauth = NexusDoubles::FakeOAuth.new
    home.prepare
    connection = Rho::Connection.new(home: home, mode: "full", device_flow: connection_device_flow(oauth),
      api_transport: NexusDoubles::FakeAgentApi.new)
    connection.define_singleton_method(:install) { raise Rho::StateError, "interrupted install" }
    assert_raises(Rho::StateError) { connection.receive_api_keys(keys) }
    staged = Rho::StateFile.new(home.pending_connection_path).read
    assert_equal "api_key", staged.fetch("authentication_kind")
    refute staged.key?("refresh_token")
    refute staged.key?("expires_in")
    restored = connected_boot(device_flow: connection_device_flow(oauth))
    assert_equal :active, restored.phase
    assert_nil Rho::StateFile.new(home.pending_connection_path).read
    assert_empty oauth.requests
  end

  def test_disconnect_revokes_each_key_and_forgets_only_after_success
    oauth = NexusDoubles::FakeOAuth.new
    daemon = connected_boot(device_flow: connection_device_flow(oauth))
    assert_equal 200, import(daemon).code.to_i
    response = request(daemon, :post, "/disconnect", token: bearer(daemon), body: {})
    assert_equal 200, response.code.to_i, response.body
    assert_equal keys.values.sort, oauth.revocations.sort
    assert_nil Rho::StateFile.new(home.connection_pointer_path).read
  end

  def test_runner_disconnect_preserves_its_opaque_registration_for_reconnect
    daemon = connected_boot
    assert_equal 200, import(daemon).code.to_i
    response = request(daemon, :post, "/disconnect", token: bearer(daemon), body: { runner: true })
    assert_equal 200, response.code.to_i, response.body
    pointer = Rho::StateFile.new(home.connection_pointer_path).read
    assert_equal "agent", pointer.fetch("mode")
    assert_equal "rho.imported-runner", pointer.fetch("runner_registration_identifier")
    assert_equal "rho.imported-agent", pointer.fetch("agent_identifier")
  end

  def test_partial_revoke_keeps_the_agent_vault_and_pointer_for_retry
    oauth = NexusDoubles::FakeOAuth.new
    failing = true
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if failing && path == "/oauth/revoke" && params[:token] == NexusDoubles::TRANSPORT_TOKEN
        raise CybrosAgent::TransportError, "Nexus is unreachable"
      end
      super(path, params, timeout: timeout)
    end
    daemon = connected_boot(device_flow: connection_device_flow(oauth))
    assert_equal 200, import(daemon).code.to_i
    identity = daemon.identity
    before = identity.vault.read
    response = request(daemon, :post, "/disconnect", token: bearer(daemon), body: {})
    assert_equal 502, response.code.to_i
    assert_equal before, identity.vault.read
    refute_nil Rho::StateFile.new(home.connection_pointer_path).read

    failing = false
    response = request(daemon, :post, "/disconnect", token: bearer(daemon), body: {})
    assert_equal 200, response.code.to_i, response.body
    assert_nil identity.vault.read
    assert_nil Rho::StateFile.new(home.connection_pointer_path).read
  end

  def test_import_replacement_waits_for_running_tools
    daemon = connected_boot
    assert_equal 200, import(daemon).code.to_i
    about = daemon.lineage.credentials
    runner = Object.new
    runner.define_singleton_method(:snapshot) { Struct.new(:in_flight).new(1) }
    daemon.lineage.define_singleton_method(:runners) { [runner] }
    response = import(daemon)
    assert_equal 409, response.code.to_i
    assert_equal "work_in_flight", JSON.parse(response.body).dig("error", "code")
    assert_same about, daemon.lineage.credentials
  ensure
    daemon&.lineage&.singleton_class&.remove_method(:runners)
  end

  def test_unauthenticated_import_is_refused
    daemon = connected_boot
    assert_equal 401, request(daemon, :post, "/connection/api_keys", body: keys).code.to_i
    assert_nil Rho::StateFile.new(home.connection_pointer_path).read
  end
end
