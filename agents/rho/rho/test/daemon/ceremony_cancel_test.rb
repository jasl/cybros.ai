require "test_helper"

# CANCEL, AND THE WINDOWS IT MUST REFUSE:
# Nexus's row lock decides whether a poll is safe to kill, and every
# in-flight phase before or after `pending` is a refusal rather than a
# ceremony destroyed on a guess.
class CeremonyCancelTest < Minitest::Test
  include RhoTest::DaemonHarness

  # A human who forgot a ceremony can stop it: Nexus atomically marks the
  # authorization canceled before the poll dies, the local connection is
  # forgotten, and the next click mints a genuinely new ceremony rather than
  # being answered with the abandoned one's code.
  def test_canceling_a_pending_ceremony_forgets_it_and_frees_the_next
    gate = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      gate.pop if path == "/oauth/token" # the ceremony holds at :pending
      super(path, params, timeout: timeout)
    end
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(daemon)
    first = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "pending", first["phase"]

    assert_equal 200, request(daemon, :post, "/device/cancel", token: token).code.to_i

    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    refute body.key?("connection"), "a canceled ceremony must be gone from status"
    assert_equal "disconnected", body["state"]

    gate << true # free the killed poller's corpse if the kill raced the pop
    second = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "pending", second["phase"]
    refute_nil second["user_code"]
    assert_equal 2, oauth.requests.count { |path, _params| path == "/oauth/device_authorization" },
      "cancel must free the daemon to mint a genuinely new ceremony"
    assert_equal 1,
      oauth.requests.count { |path, _params| path == "/oauth/device_authorization/cancellation" },
      "rho must obtain Nexus's safe-to-kill verdict before forgetting the poll"
  end

  # Consume and cancel take the same Nexus row lock. If Consume wins, the old
  # executor epoch may already be fenced even while the token response is
  # still on the wire; local phase observation cannot decide that race. A
  # `too_late` verdict keeps the poller alive and the daemon adopts its bundle.
  def test_cancel_returns_too_late_and_adopts_when_consume_won
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
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    consumed.pop

    canceled = request(daemon, :post, "/device/cancel", token: token)

    assert_equal 409, canceled.code.to_i
    assert_equal "too_late", JSON.parse(canceled.body).dig("error", "code")
    assert daemon.lineage.slot_snapshot.poller&.alive?,
      "a poll whose Consume won must not be killed"
    allow_response << true
    body = await_state(daemon, "active", token: token)
    assert_equal "0199-user", body.dig("identity", "user_public_id")
    assert_equal 1, oauth.requests.count { |path, _| path == "/oauth/device_authorization" }
  ensure
    allow_response&.push(true)
  end

  # A failed/unknown cancellation request says nothing about which Nexus lock
  # winner exists. It is never safe-to-kill: return a local 503 and leave the
  # same ceremony visible and running so a retry can obtain a real verdict.
  def test_cancel_unknown_keeps_the_same_ceremony_in_flight
    polling = Queue.new
    allow_poll = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" &&
          params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        polling << true
        allow_poll.pop
      end
      if path == "/oauth/device_authorization/cancellation"
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
    token = bearer(daemon)
    started = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    polling.pop

    canceled = request(daemon, :post, "/device/cancel", token: token)

    assert_equal 503, canceled.code.to_i
    assert_equal "cancel_unknown", JSON.parse(canceled.body).dig("error", "code")
    status = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal started["user_code"], status.dig("connection", "user_code")
    assert daemon.lineage.slot_snapshot.poller&.alive?
    allow_poll << true
    await_state(daemon, "active", token: token)
  ensure
    allow_poll&.push(true)
  end

  # Start owes the same refusal for the same reason: a ceremony begun before
  # reconnect finishes inspecting durable staging could race the resume of a
  # consumed connection this daemon does not yet know it holds.
  def test_start_refuses_while_the_stored_connection_is_bootstrapping
    daemon = connected_boot
    token = bearer(daemon)
    daemon.lineage.begin_bootstrap

    refused = request(daemon, :post, "/device/start", token: token)

    assert_equal 503, refused.code.to_i
    assert_equal "connection_bootstrapping", JSON.parse(refused.body).dig("error", "code")
  ensure
    daemon&.lineage&.finish_bootstrap
  end

  # The listener exists before reconnect has finished inspecting durable
  # staging. An empty in-memory slot during that boot window is not proof that
  # there is no consumed connection to recover, so cancel must not report the
  # safe-to-kill success used for a genuinely idle daemon.
  def test_cancel_refuses_while_the_stored_connection_is_bootstrapping
    daemon = connected_boot
    token = bearer(daemon)
    daemon.lineage.begin_bootstrap

    refused = request(daemon, :post, "/device/cancel", token: token)

    assert_equal 503, refused.code.to_i
    assert_equal "connection_bootstrapping", JSON.parse(refused.body).dig("error", "code")
  ensure
    daemon&.lineage&.finish_bootstrap
  end

  # Durable staging is the Consume winner made local. If memory lost its
  # Connection owner, cancel cannot turn that uncertainty into an idle 200:
  # the next boot or start will still resume and activate this exact bundle.
  def test_cancel_does_not_claim_an_orphaned_staged_connection_is_idle
    daemon = connected_boot
    token = bearer(daemon)
    staging = Rho::StateFile.new(daemon.home.pending_connection_path)
    staging.write(
      "version" => Rho::Connection::STAGING_VERSION,
      "base_url" => daemon.home.base_url,
      "refresh_token" => "rt-staged"
    )

    refused = request(daemon, :post, "/device/cancel", token: token)

    assert_equal 503, refused.code.to_i
    assert_equal "cancel_unknown", JSON.parse(refused.body).dig("error", "code")
    refute_nil staging.read, "an uncertain cancel must leave the consumed bundle recoverable"
  end

  # A replacement may have consumed and staged its new lineage before a
  # transient bootstrap failure leaves the Connection in `error`. Terminal
  # news about the old adopted lineage must not erase that replacement's
  # in-memory owner; its cancellation outcome is already `consumed`.
  def test_old_lineage_loss_preserves_a_consumed_replacement_that_failed_activation
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old_credentials = daemon.lineage.credentials

    replacement = daemon.ceremony.build_connection
    replacement.send(:instance_variable_set, :@phase, :error)
    replacement.send(:instance_variable_set, :@won, true)
    assert_equal :claimed, daemon.lineage.claim_slot(replacement)

    daemon.lineage.lose(about: old_credentials)

    assert_same replacement, daemon.connection,
      "terminal news about the old lineage must not orphan a consumed replacement"
    refused = request(daemon, :post, "/device/cancel", token: token)
    assert_equal 409, refused.code.to_i
    assert_equal "too_late", JSON.parse(refused.body).dig("error", "code")
  end

  # Before `pending` there is nothing to cancel: no code minted, no poll
  # running, and the start fiber holds its connection in a local — so a 200
  # here would cancel nothing while forgetting `@connection` re-arms the
  # double ceremony idempotency exists to prevent. Both halves pinned: the
  # refusal, and that the window's second start does not mint a second code.
  def test_cancel_refuses_while_the_ceremony_is_still_starting
    starting = Queue.new
    gate = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/device_authorization"
        starting << true
        gate.pop
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(daemon)
    first = Thread.new { JSON.parse(request(daemon, :post, "/device/start", token: token).body) }
    starting.pop # the start fiber is inside the device-authorization call

    refused = request(daemon, :post, "/device/cancel", token: token)
    assert_equal 409, refused.code.to_i
    assert_equal "starting", JSON.parse(refused.body).dig("error", "code")

    second = Thread.new { JSON.parse(request(daemon, :post, "/device/start", token: token).body) }
    sleep 0.05
    gate << true
    refute_nil first.join(15)
    refute_nil second.join(15)

    assert_equal "BCDF-GHJK", first.value["user_code"], "the refused cancel must not have touched the ceremony"
    assert_equal 1, oauth.requests.count { |path, _params| path == "/oauth/device_authorization" },
      "one ceremony, however many clicks and refused cancels land in the window"
  end

  # The connection reaches `:active` on the poller thread before the daemon
  # adopts it, and in that window the daemon still reads `:disconnected` — so
  # a guard on the daemon's phase alone would let cancel destroy a connection
  # whose vault and pointer are already on disk. The guard reads the
  # connection's phase; the frozen window must answer 409.
  def test_cancel_refuses_a_connection_installed_but_not_yet_adopted
    gate = Queue.new
    reached = Queue.new
    token_held = Queue.new
    hold_token = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      # Hold the poller at the token poll so the window instrument below is
      # armed before the ceremony can rush past :active.
      if path == "/oauth/token"
        token_held << true
        hold_token.pop
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    token_held.pop
    connection = daemon.connection
    original = connection.instance_variable_get(:@on_phase)
    connection.instance_variable_set(:@on_phase, lambda do |phase|
      # Freeze the poller at exactly connection-:active, daemon-:disconnected:
      # the phase is written before this callback runs, and `await` has not
      # returned to the daemon yet.
      if phase == :active
        reached << true
        gate.pop
      end
      original&.call(phase)
    end)
    hold_token << true
    reached.pop

    refused = request(daemon, :post, "/device/cancel", token: token)
    assert_equal 409, refused.code.to_i
    assert_equal "already_connected", JSON.parse(refused.body).dig("error", "code")

    gate << true
    body = await_state(daemon, "active", token: token)
    refute_nil body["identity"], "the connection cancel refused to destroy must be adopted whole"
  end

  # Past `pending` the code is spent and the bundle may already be staged, so
  # cancel refuses — and the ceremony it refused to destroy completes.
  def test_cancel_refuses_while_the_ceremony_is_completing
    upstream = NexusDoubles::FakeAgentApi.new
    resolving = Queue.new
    gate = Queue.new
    held = false
    api = Object.new
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      if path == "/agent_api/v1/profile" && !held
        held = true
        resolving << true
        gate.pop
      end
      upstream.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
    end

    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    resolving.pop # the poller is inside `activating`

    refused = request(daemon, :post, "/device/cancel", token: token)
    assert_equal 409, refused.code.to_i
    assert_equal "activating", JSON.parse(refused.body).dig("error", "code")

    gate << true
    body = await_state(daemon, "active", token: token)
    refute_nil body["identity"], "the ceremony cancel refused to destroy must still complete"
  end

  # "There is no ceremony now" is cancel's success condition, so asking twice
  # is not an error — and a connected daemon is not a ceremony, so cancel must
  # refuse rather than become a disconnect verb nobody designed.
  def test_cancel_is_idempotent_when_idle_and_refuses_when_connected
    daemon = connected_boot
    token = bearer(daemon)

    assert_equal 200, request(daemon, :post, "/device/cancel", token: token).code.to_i,
      "nothing in flight is exactly what cancel promises"

    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    refused = request(daemon, :post, "/device/cancel", token: token)
    assert_equal 409, refused.code.to_i
    assert_equal "already_connected", JSON.parse(refused.body).dig("error", "code")
  end

  # A cancel in `pending_runner` leaves the daemon active with no runner:
  # the agent connection stands, nothing was paired.
  def test_cancel_in_pending_runner_leaves_the_daemon_active_with_no_runner
    daemon = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new,
      extensions: [Rho::Extensions::Ops], config: agent_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    @daemons.pop.stop

    oauth = NexusDoubles::FakeOAuth.new
    gate = Queue.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      # The fake wins every poll at once; hold the runner grant's poll so the
      # cancel lands in `pending_runner`.
      if path == "/oauth/token" && params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        gate.pop
      end
      super(path, params, timeout: timeout)
    end
    full = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(full)
    started = JSON.parse(request(full, :post, "/device/start", token: token).body)
    assert_equal "pending_runner", started["phase"]

    canceled = request(full, :post, "/device/cancel", token: token)
    assert_equal 200, canceled.code.to_i, canceled.body
    assert_equal({ "canceled" => true }, JSON.parse(canceled.body))
    body = JSON.parse(request(full, :get, "/status", token: token).body)
    assert_equal "active", body["state"]
    assert_nil body.dig("identity", "runner_executor_public_id")
    refute body.key?("connection")
    assert_nil JSON.parse(request(full, :get, "/runner", token: token).body).fetch("runner")
  ensure
    gate&.push(true)
  end

  # A ceremony that already failed is a corpse, and forgetting it is what
  # cancel is for: the error clears with it rather than haunting `status`.
  def test_cancel_forgets_a_failed_ceremony_and_its_error
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      raise CybrosAgent::DeviceFlow::ServerError, "boom" if path == "/oauth/device_authorization"

      super(path, params, timeout: timeout)
    end
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(daemon)
    assert_equal 502, request(daemon, :post, "/device/start", token: token).code.to_i

    assert_equal 200, request(daemon, :post, "/device/cancel", token: token).code.to_i

    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    refute body.key?("connection"), "the failed ceremony must be forgotten"
    refute body.key?("error"), "and its error must not haunt the status"
  end
end
