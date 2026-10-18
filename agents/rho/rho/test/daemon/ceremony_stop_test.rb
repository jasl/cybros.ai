require "test_helper"

# THE CEREMONY HALF OF AN ORDERLY STOP:
# the home lock is held until every interrupt-masked writer the ceremony
# started — the poller's staging commit, a resume handler, a Consume
# winner — is done, and an unknown cancellation aborts the stop rather
# than guessing.
class CeremonyStopTest < Minitest::Test
  include RhoTest::DaemonHarness

  # The poller's stage write is interrupt-masked because losing a token bundle
  # after Consume would orphan it. Orderly shutdown must therefore wait for
  # that writer before releasing the lifetime home lock; otherwise the next
  # daemon can start while its predecessor is still publishing pending.json.
  def test_shutdown_keeps_the_home_claimed_until_the_poller_is_quiescent
    token_returning = Queue.new
    allow_token = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token"
        token_returning << true
        allow_token.pop
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(
      device_flow: connection_device_flow(oauth),
      api_transport: NexusDoubles::FakeAgentApi.new
    )
    request(daemon, :post, "/device/start", token: bearer(daemon))
    token_returning.pop

    staging = Queue.new
    allow_stage = Queue.new
    connection = daemon.connection
    original = connection.method(:stage)
    connection.define_singleton_method(:stage) do |credentials|
      staging << true
      allow_stage.pop
      original.call(credentials)
    end
    allow_token << true
    staging.pop

    @daemons.delete(daemon)
    stopping = Thread.new { daemon.stop }
    sleep 0.05
    assert stopping.alive?, "shutdown must wait for the interrupt-masked staging commit"
    assert_raises(Rho::AlreadyRunning) do
      Rho::Daemon.boot(home: Rho::Home.resolve(base_url: "https://nexus.example", root: @root))
    end

    allow_stage << true
    refute_nil stopping.join(10)
    replacement = boot
    assert_equal "200", get(replacement, "/healthz").code
  ensure
    allow_token&.push(true)
    allow_stage&.push(true)
    stopping&.kill if stopping&.alive?
  end

  # A failed activation leaves a durable staged bundle. Retrying it happens on
  # the control handler itself rather than a poller, and can therefore still be
  # inside two bootstrap reads or the final vault/session/pointer commit when a
  # signal asks the daemon to stop. The handler is a home writer every bit as
  # much as the poller: stop must seal the control gate, wait for it, and keep
  # the lifetime lock until it has adopted the staged identity.
  def test_shutdown_waits_for_a_staged_resume_handler_before_releasing_the_home
    api = HealableApi.new
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = bearer(daemon)
    start_and_fail(daemon, token: token)

    reached_bootstrap = Queue.new
    allow_bootstrap = Queue.new
    upstream = NexusDoubles::FakeAgentApi.new
    blocking_api = Object.new
    blocking_api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      unless instance_variable_defined?(:@bootstrap_released)
        @bootstrap_released = true
        reached_bootstrap << true
        allow_bootstrap.pop
      end
      upstream.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
    end
    daemon.wire.api_transport = blocking_api

    resuming = Thread.new { request(daemon, :post, "/device/start", token: token) }
    resuming.report_on_exception = false
    reached_bootstrap.pop
    @daemons.delete(daemon)
    stopping = Thread.new { daemon.stop }
    stopping.report_on_exception = false
    await_daemon_stopping(daemon)

    refused = request(daemon, :get, "/status", token: token)
    assert_equal 503, refused.code.to_i
    assert_equal "daemon_stopping", JSON.parse(refused.body).dig("error", "code"),
      "sealing the gate must reject rather than admit another potential home writer"
    assert_raises(Rho::AlreadyRunning) do
      Rho::Daemon.boot(home: Rho::Home.resolve(base_url: "https://nexus.example", root: @root))
    end

    allow_bootstrap << true
    refute_nil resuming.join(10)
    refute_nil stopping.join(10)
    replacement = boot(
      device_flow: connection_device_flow,
      api_transport: NexusDoubles::FakeAgentApi.new
    )
    assert_equal :active, replacement.phase
  ensure
    allow_bootstrap&.push(true)
    resuming&.kill if resuming&.alive?
    stopping&.kill if stopping&.alive?
  end

  # A token response delayed after Nexus committed Consume is exactly the
  # window local Thread#kill cannot classify. Orderly stop asks the same
  # row-lock winner as explicit cancel; `too_late` means it must wait for the
  # bundle to stage and adopt before releasing the home.
  def test_shutdown_waits_for_a_consume_winner_before_releasing_the_home
    consumed = Queue.new
    allow_response = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      response = super(path, params, timeout: timeout)
      if path == "/oauth/token" &&
          params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        consumed << true
        allow_response.pop
      end
      response
    end
    daemon = boot(
      device_flow: connection_device_flow(oauth),
      api_transport: NexusDoubles::FakeAgentApi.new
    )
    request(daemon, :post, "/device/start", token: bearer(daemon))
    consumed.pop

    @daemons.delete(daemon)
    stopping = Thread.new { daemon.stop }
    sleep 0.05

    assert stopping.alive?, "a Consume winner must reach durable local state before stop"
    assert_raises(Rho::AlreadyRunning) do
      Rho::Daemon.boot(home: Rho::Home.resolve(base_url: "https://nexus.example", root: @root))
    end
    allow_response << true
    refute_nil stopping.join(10)

    replacement = boot
    assert_equal "200", get(replacement, "/healthz").code
  ensure
    allow_response&.push(true)
    stopping&.kill if stopping&.alive?
  end

  # Unknown is not a third lock winner. A failed cancellation preflight aborts
  # the orderly stop while the daemon and lifetime lock remain live; a later
  # retry can obtain `canceled` and then shut down safely.
  def test_shutdown_unknown_keeps_the_daemon_and_home_live_for_retry
    polling = Queue.new
    allow_poll = Queue.new
    cancel_unknown = true
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" &&
          params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        polling << true
        allow_poll.pop
      end
      if path == "/oauth/device_authorization/cancellation" && cancel_unknown
        next Data.define(:status, :headers, :body).new(
          status: 503, headers: {}, body: nil
        )
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(
      device_flow: connection_device_flow(oauth),
      api_transport: NexusDoubles::FakeAgentApi.new
    )
    request(daemon, :post, "/device/start", token: bearer(daemon))
    polling.pop

    error = assert_raises(Rho::ConnectionError) { daemon.stop }

    assert_match(/safe connection shutdown outcome/, error.message)
    assert daemon.running?
    assert_equal "200", get(daemon, "/healthz").code
    assert_raises(Rho::AlreadyRunning) do
      Rho::Daemon.boot(home: Rho::Home.resolve(base_url: "https://nexus.example", root: @root))
    end

    cancel_unknown = false
    daemon.stop
    @daemons.delete(daemon)
    replacement = boot
    assert_equal "200", get(replacement, "/healthz").code
  ensure
    allow_poll&.push(true)
  end
end
