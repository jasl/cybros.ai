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
    attr_accessor :agent_removed, :runner_removed, :hold_connection, :on_connect
    attr_reader :polling, :release

    def initialize
      super
      @agent_removed = false
      @runner_removed = false
      @hold_connection = false
      @polling = Queue.new
      @release = Queue.new
    end

    def post(path, params, timeout:)
      removed = params[:refresh_token] == NexusDoubles::RUNNER_REFRESH_TOKEN ? @runner_removed : @agent_removed
      if path == "/oauth/token" && params[:grant_type] == "refresh_token" && removed
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

  def test_agent_refresh_loss_retires_only_its_own_work_and_keeps_the_runner_renewable
    daemon, oauth, api = connected
    about = daemon.lineage.credentials
    runner = daemon.lineage.runner
    runner_oauth = about.runner
    run = fake_run("old-agent-work")
    daemon.lineage.install_run(about, run)
    remove_agent(oauth, api)

    assert_equal [:lost, :renewed], daemon.maintenance.run_once(about, verify: true)

    assert_same about, daemon.lineage.credentials
    assert_same runner_oauth, daemon.lineage.credentials.runner
    assert_same runner, daemon.lineage.runner
    assert_nil daemon.lineage.runner(:agent_runner)
    assert_empty daemon.lineage.runs
    assert_equal :active, daemon.phase
    assert_equal "expired", daemon.lineage.status_document.dig(:authority, :signed)
    assert_equal NexusDoubles::RUNNER_TOKEN, about.runner_credential
    assert_operator runner_oauth.rotation, :>, 0
  end

  def test_terminal_loss_of_both_refresh_lineages_disconnects_the_whole_daemon
    daemon, oauth, api = connected
    about = daemon.lineage.credentials
    remove_agent(oauth, api)
    oauth.runner_removed = true
    api.accept(NexusDoubles::RUNNER_TOKEN, false)

    assert_equal [:lost, :lost], daemon.maintenance.run_once(about, verify: true)

    assert_equal :disconnected, daemon.phase
    assert_nil daemon.lineage.credentials
    assert_empty daemon.lineage.runners
    restarting = JSON.parse(request(daemon, :post, "/device/start", token: bearer(daemon)).body)
    assert_equal "combined", restarting["branch"]
  end

  def test_canceling_then_completing_agent_only_reconnect_keeps_the_runner_lineage
    daemon, oauth, api = connected
    token = bearer(daemon)
    about = daemon.lineage.credentials
    runner = daemon.lineage.runner
    runner_oauth = about.runner
    remove_agent(oauth, api)
    oauth.hold_connection = true

    restoring = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restoring["branch"], restoring.inspect
    assert oauth.polling.pop(timeout: 5), "the restore never polled its device code"
    assert_equal "200", request(daemon, :post, "/device/cancel", token: token).code
    assert_same runner_oauth, daemon.lineage.credentials.runner
    assert_same runner, daemon.lineage.runner
    assert_equal :active, daemon.phase

    oauth.hold_connection = false
    oauth.on_connect = lambda do
      oauth.agent_removed = false
      api.accept(NexusDoubles::MEMBER_TOKEN, true)
      api.accept(NexusDoubles::TRANSPORT_TOKEN, true)
    end
    restarted = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restarted["branch"], restarted.inspect
    wait_for { !daemon.lineage.credentials.equal?(about) }
    assert_same runner_oauth, daemon.lineage.credentials.runner
    assert_equal "0199-runner", daemon.identity.runner_executor_public_id
    assert_equal [:combined, :agent, :agent], oauth.branches
  ensure
    oauth&.release&.push(true)
  end

  def test_restart_with_a_terminal_agent_refresh_resumes_the_independent_runner
    assert_runner_resumes(after: 15 * 24 * 60 * 60)
  end

  def test_restart_with_refused_agent_access_tokens_resumes_the_independent_runner
    assert_runner_resumes(after: 0)
  end

  def test_explicit_full_disconnect_retires_both_lineages_and_reconnects_both
    daemon, oauth, = connected
    token = bearer(daemon)

    response = request(daemon, :post, "/disconnect", token: token)

    assert_equal "200", response.code
    assert_equal ["runner", "agent"], JSON.parse(response.body).fetch("revoked")
    assert_equal :disconnected, daemon.phase
    assert_nil daemon.lineage.credentials
    assert_empty daemon.lineage.runners
    assert_nil Rho::StateFile.new(daemon.home.connection_pointer_path).read
    restarting = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "combined", restarting["branch"]
    wait_for { daemon.lineage.runner && daemon.lineage.runner(:agent_runner) }
    assert_equal [:combined, :combined], oauth.branches
  end

  def test_agent_only_reconnect_preserves_the_runners_in_flight_tool_and_socket
    readers = {}
    daemon, oauth, api = connected(realtime_factory: lambda do |credential|
      readers[credential.call.to_s] = credential
      CybrosAgent::TestSupport::FakeRealtime.new
    end)
    token = bearer(daemon)
    about = daemon.lineage.credentials
    runner = daemon.lineage.runner
    wait_for { daemon.lineage.executor_realtime&.connected? }
    socket = daemon.lineage.executor_realtime
    reader = readers.fetch(NexusDoubles::RUNNER_TOKEN)
    release = File.join(@root, "release-independent-runner")
    api.stock_inbox({ "kind" => "tool_call", "agent_loop_public_id" => "other-agent-loop",
      "conversation_public_id" => nil, "parent_public_id" => nil, "task_key" => "t1",
      "tool_name" => "bash", "tool_input" => { "command" => "while [ ! -e #{release} ]; do sleep 0.01; done; echo finished" },
      "tool_call_id" => "call-t1", "started_at" => "2026-09-07T00:00:00Z", "deadline_at" => nil, "claimed" => false,
      "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-runner" } }, address: :runner)
    daemon.context.spawn { runner.nudged(agent_loop_public_id: "other-agent-loop", task_key: "t1", tool_name: "bash") }
    wait_for { runner.snapshot.in_flight == 1 }
    remove_agent(oauth, api)
    daemon.maintenance.run_once(about, verify: true)
    oauth.on_connect = lambda do
      oauth.agent_removed = false
      api.accept(NexusDoubles::MEMBER_TOKEN, true)
      api.accept(NexusDoubles::TRANSPORT_TOKEN, true)
    end

    restoring = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restoring["branch"]
    wait_for { !daemon.lineage.credentials.equal?(about) }

    assert_same runner, daemon.lineage.runner
    assert_same socket, daemon.lineage.executor_realtime
    refute socket.closed?
    assert_equal NexusDoubles::RUNNER_TOKEN, reader.call.to_s, "a later handshake still uses the preserved Runner"
    File.write(release, "go")
    wait_for { api.commits.any? }
    assert_equal "completed", api.commits.first.last.fetch("outcome")
    assert_includes api.commits.first.last.fetch("content"), "finished"
  ensure
    File.write(release, "go") if release
  end

  private

    def assert_runner_resumes(after:)
      now = Time.now
      daemon, oauth, api = connected(clock: -> { now })
      runner_id = daemon.identity.runner_executor_public_id
      remove_agent(oauth, api)
      daemon.stop
      now += after

      restarted = boot(device_flow: connection_device_flow(oauth), api_transport: api, clock: -> { now })

      assert_equal :active, restarted.phase
      assert_equal runner_id, restarted.identity.runner_executor_public_id
      wait_for { restarted.lineage.runner }
      assert_equal NexusDoubles::RUNNER_TOKEN, restarted.lineage.credentials.runner_credential
      assert_equal "expired", restarted.lineage.status_document.dig(:authority, :signed)
      assert_equal [:combined], oauth.branches, "restart cannot pair another machine"
    end

    def connected(**options)
      oauth = OAuth.new
      api = Api.new
      daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api, **options)
      token = bearer(daemon)
      request(daemon, :post, "/device/start", token: token)
      await_state(daemon, "active", token: token)
      wait_for { daemon.lineage.runner && daemon.lineage.runner(:agent_runner) }
      [daemon, oauth, api]
    end

    def remove_agent(oauth, api)
      oauth.agent_removed = true
      api.accept(NexusDoubles::MEMBER_TOKEN, false)
      api.accept(NexusDoubles::TRANSPORT_TOKEN, false)
    end
end
