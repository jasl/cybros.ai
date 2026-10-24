require "test_helper"
require "cybros_agent/test_support/fake_realtime"

class ProfileRemovalTest < Minitest::Test
  include RhoTest::DaemonHarness

  class Api < NexusDoubles::FakeAgentApi
    def initialize
      super
      @refused = []
    end

    def accept(credential, allowed)
      allowed ? @refused.delete(credential) : @refused.push(credential)
    end

    def call(path, credential:, **options)
      if @refused.include?(credential)
        return CybrosAgent::Response.new(status: 401, headers: {},
          body: { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } })
      end
      super
    end
  end

  class OAuth < NexusDoubles::FakeOAuth
    attr_accessor :agent_removed, :hold_connection, :on_connect
    attr_reader :polling, :release

    def initialize
      super
      @agent_removed = false
      @hold_connection = false
      @polling = Queue.new
      @release = Queue.new
    end

    def post(path, params, timeout:)
      if path == "/oauth/token" && params[:grant_type] == "refresh_token" && @agent_removed
        @requests << [path, params]
        return respond(400, { "error" => "invalid_grant" })
      end
      if path == "/oauth/token" && params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT && @hold_connection
        @polling.push(true)
        @release.pop
      end
      @on_connect&.call if path == "/oauth/token" && params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
      super
    end
  end

  def test_application_refresh_loss_retires_both_roles_and_member_work
    daemon, oauth, api = connected
    about = daemon.lineage.credentials
    daemon.lineage.install_follower(about, fake_run("old-agent-work"))
    remove_agent(oauth, api)

    assert_equal :lost, daemon.maintenance.run_once(about, verify: true)

    assert_nil daemon.lineage.credentials
    assert_nil daemon.lineage.runner
    assert_empty daemon.lineage.followers
    assert_equal :disconnected, daemon.phase
  end

  def test_canceling_then_completing_reconnect_replaces_the_application_owner
    daemon, oauth, api = connected
    token = bearer(daemon)
    about = daemon.lineage.credentials
    remove_agent(oauth, api)
    daemon.maintenance.run_once(about, verify: true)
    oauth.hold_connection = true

    restoring = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restoring["branch"]
    assert oauth.polling.pop(timeout: 5), "the restore never polled its device code"
    assert_equal "200", request(daemon, :post, "/device/cancel", token: token).code
    assert_nil daemon.lineage.credentials
    assert_nil daemon.lineage.runner
    assert_equal :disconnected, daemon.phase

    oauth.hold_connection = false
    oauth.on_connect = lambda do
      oauth.agent_removed = false
      api.accept(NexusDoubles::MEMBER_TOKEN, true)
      api.accept(NexusDoubles::TRANSPORT_TOKEN, true)
    end
    restarted = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restarted["branch"]
    wait_for { daemon.lineage.credentials && daemon.lineage.runner }
    refute_same about, daemon.lineage.credentials
    assert_equal daemon.identity.executor_public_id, daemon.identity.runner_executor_public_id
    assert_equal [:agent, :agent, :agent], oauth.branches
  ensure
    oauth&.release&.push(true)
  end

  def test_restart_with_a_terminal_refresh_cannot_resume_local_tools
    assert_connection_lost(after: 15 * 24 * 60 * 60)
  end

  def test_restart_with_refused_access_tokens_cannot_resume_local_tools
    assert_connection_lost(after: 0)
  end

  def test_explicit_disconnect_retires_the_connection_and_reconnects_both_roles
    daemon, oauth, = connected
    token = bearer(daemon)
    response = request(daemon, :post, "/disconnect", token: token)

    assert_equal "200", response.code
    assert_equal ["agent"], JSON.parse(response.body).fetch("revoked")
    assert_equal :disconnected, daemon.phase
    assert_nil daemon.lineage.credentials
    assert_nil daemon.lineage.runner
    assert_nil Rho::StateFile.new(daemon.home.connection_pointer_path).read
    restarting = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restarting["branch"]
    wait_for { daemon.lineage.runner }
    assert_equal [:agent, :agent], oauth.branches
  end

  def test_application_loss_closes_its_single_executor_socket
    sockets = []
    daemon, oauth, api = connected(realtime_factory: lambda do |_credential|
      sockets << CybrosAgent::TestSupport::FakeRealtime.new
      sockets.last
    end)
    about = daemon.lineage.credentials
    wait_for { daemon.lineage.executor_realtime&.connected? }
    socket = daemon.lineage.executor_realtime
    remove_agent(oauth, api)

    daemon.maintenance.run_once(about, verify: true)

    wait_for { socket.closed? }
    assert_nil daemon.lineage.executor_realtime
    assert_nil daemon.lineage.runner
    assert_equal 1, sockets.length
  end

  private

    def assert_connection_lost(after:)
      now = Time.now
      daemon, oauth, api = connected(clock: -> { now })
      remove_agent(oauth, api)
      daemon.stop
      now += after

      restarted = boot(device_flow: connection_device_flow(oauth), api_transport: api, clock: -> { now })

      if after.zero?
        assert_equal :active, restarted.phase
        assert_equal "expired", restarted.lineage.status_document.dig(:authority, :signed)
        assert_equal :lost, restarted.maintenance.run_once(restarted.lineage.credentials, verify: true)
      end
      assert_equal :disconnected, restarted.phase
      assert_nil restarted.lineage.credentials
      assert_nil restarted.lineage.runner
      assert_equal [:agent], oauth.branches, "restart cannot authorize another connection"
    end

    def connected(**options)
      oauth = OAuth.new
      api = Api.new
      daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api, **options)
      token = bearer(daemon)
      request(daemon, :post, "/device/start", token: token)
      await_state(daemon, "active", token: token)
      wait_for { daemon.lineage.runner }
      [daemon, oauth, api]
    end

    def remove_agent(oauth, api)
      oauth.agent_removed = true
      api.accept(NexusDoubles::MEMBER_TOKEN, false)
      api.accept(NexusDoubles::TRANSPORT_TOKEN, false)
    end
end
