require "test_helper"

class MemberConnectionTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_disconnect_waits_for_the_member_worker_to_retire_on_its_reactor
    events = Queue.new
    release = Queue.new
    extension = connection_extension do |connection|
      events << [connection, Thread.current, !Async::Task.current?.nil?]
      release.pop if connection.nil?
    end
    daemon = connected_boot(config: agent_mode, extensions: [extension])
    connect(daemon)
    adopted = events.pop(timeout: 2)
    assert_equal "0199-user", adopted.fetch(0).user_public_id
    refute_same Thread.current, adopted.fetch(1)
    assert adopted.fetch(2)

    response = Queue.new
    caller = Thread.new { response << request(daemon, :post, "/disconnect", token: bearer(daemon)) }
    retired = events.pop(timeout: 2)
    assert_nil retired.fetch(0)
    assert_same adopted.fetch(1), retired.fetch(1)
    assert retired.fetch(2)
    assert_nil response.pop(timeout: 0), "disconnect cannot return while the old worker is retiring"

    release << true
    assert_equal 200, response.pop(timeout: 2).code.to_i
    assert caller.join(2)
  ensure
    release&.push(true)
    caller&.join(2)
  end

  def test_same_profile_reconnect_delivers_a_fresh_connection
    events = Queue.new
    daemon = connected_boot(config: agent_mode, extensions: [connection_extension { |connection| events << (connection || :lost) }])
    connect(daemon)
    first = events.pop(timeout: 2)
    assert_equal 200, request(daemon, :post, "/disconnect", token: bearer(daemon)).code.to_i
    assert_equal :lost, events.pop(timeout: 2)

    connect(daemon)
    second = events.pop(timeout: 2)
    assert_equal first.user_public_id, second.user_public_id
    refute_same first.client, second.client
  end

  def test_same_credentials_readoption_does_not_restart_the_member_worker
    events = Queue.new
    daemon = connected_boot(config: agent_mode, extensions: [connection_extension { |connection| events << connection }])
    connect(daemon)
    refute_nil events.pop(timeout: 2)
    about = daemon.lineage.credentials

    daemon.send(:adopt_connection, identity: daemon.identity, credentials: about)

    assert_same about, daemon.lineage.credentials
    assert_nil events.pop(timeout: 0)
  end

  def test_unauthorized_plane_replacement_retires_before_publishing_new_credentials
    events, release = Queue.new, Queue.new
    daemon = nil
    extension = connection_extension do |connection|
      events << [connection || :lost, daemon.lineage.credentials, daemon.identity.user_public_id]
      release.pop if connection.nil?
    end
    api = NexusDoubles::SelectiveApi.new
    replacement = NexusDoubles::FakeAgentApi.new(user_public_id: "0199-other", executor_public_id: "0199-other-executor")
    replacing = false
    api.define_singleton_method(:call) do |path, **arguments|
      response = super(path, **arguments)
      replacing && response.status == 200 ? replacement.call(path, **arguments) : response
    end
    oauth = NexusDoubles::FakeOAuth.new
    grants = 0
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" && params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        grants += 1
        if grants == 2
          replacing = true
          api.accept(NexusDoubles::MEMBER_TOKEN, true)
        end
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api,
      config: agent_mode, extensions: [extension])
    connect(daemon)
    original = events.pop(timeout: 2).fetch(1)
    api.accept(NexusDoubles::MEMBER_TOKEN, false)

    response = request(daemon, :post, "/device/start", token: bearer(daemon))
    assert_equal 200, response.code.to_i
    retiring = events.pop(timeout: 2)
    assert_equal :lost, retiring.fetch(0)
    assert_same original, retiring.fetch(1)
    assert_equal "0199-user", retiring.fetch(2)
    assert_same original, daemon.lineage.credentials, "old worker cleanup precedes the credential switch"
    refute daemon.lineage.snapshot.observation.report.fetch(:lost)

    release << true
    adopted = events.pop(timeout: 2)
    assert_equal "0199-other", adopted.fetch(0).user_public_id
    refute_same original, adopted.fetch(1)
    assert_equal "0199-other", adopted.fetch(2)
  ensure
    release&.push(true)
  end

  def test_a_replacement_profile_does_not_retarget_the_previous_member_client
    events = Queue.new
    daemon = connected_boot(config: agent_mode, extensions: [connection_extension { |connection| events << (connection || :lost) }])
    connect(daemon)
    first = events.pop(timeout: 2)
    assert_equal 200, request(daemon, :post, "/disconnect", token: bearer(daemon)).code.to_i
    assert_equal :lost, events.pop(timeout: 2)
    daemon.wire.api_transport = NexusDoubles::FakeAgentApi.new(user_public_id: "0199-other", executor_public_id: "0199-other-executor")

    connect(daemon)
    second = events.pop(timeout: 2)
    assert_equal "0199-other", second.user_public_id
    assert_equal "0199-other", second.client.profile.fetch.member.public_id
    assert_equal "0199-user", first.client.profile.fetch.member.public_id
  end

  def test_agent_loss_retires_the_member_worker_while_the_independent_runner_stands
    events = Queue.new
    daemon = connected_boot(extensions: [Rho::Runner::Extensions::Coding,
      connection_extension { |connection| events << (connection || :lost) }])
    connect(daemon)
    refute_nil events.pop(timeout: 2)
    about = daemon.lineage.credentials

    daemon.maintenance.renewal_event(:lost, about)

    assert_equal :lost, events.pop(timeout: 2)
    assert_same about, daemon.lineage.credentials
    assert about.runner?
  end

  def test_runner_disconnect_does_not_restart_the_member_worker
    events = Queue.new
    daemon = connected_boot(extensions: [Rho::Runner::Extensions::Coding,
      connection_extension { |connection| events << (connection || :lost) }])
    connect(daemon)
    refute_nil events.pop(timeout: 2)

    response = request(daemon, :post, "/disconnect", token: bearer(daemon), body: { runner: true })

    assert_equal 200, response.code.to_i
    assert_nil events.pop(timeout: 0)
    assert daemon.lineage.credentials.agent?
  end

  def test_boot_resume_delivers_the_connection_before_background_startup
    first = connected_boot(config: agent_mode)
    connect(first)
    @daemons.pop.stop
    events = Queue.new
    extension = connection_extension { |connection| events << connection.user_public_id }
    original = extension.method(:register)
    extension.define_singleton_method(:register) do |api|
      original.call(api)
      api.on(:startup) { events << :startup }
    end

    daemon = connected_boot(config: agent_mode, extensions: [extension])

    assert_equal :active, daemon.phase
    assert_equal "0199-user", events.pop(timeout: 2)
    assert_equal :startup, events.pop(timeout: 2)
  end

  private

    def connect(daemon)
      assert_equal 200, request(daemon, :post, "/device/start", token: bearer(daemon)).code.to_i
      await_state(daemon, "active", token: bearer(daemon))
    end

    def connection_extension(&handler)
      Module.new do
        const_set(:NAME, "rho.member_lifetime")
        define_singleton_method(:register) { |api| api.on(:member_connection, &handler) }
      end
    end
end
