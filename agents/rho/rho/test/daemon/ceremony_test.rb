require "test_helper"

# THE DEVICE FLOW BEHIND `/device/start`:
# a human connecting, a second caller joining the one ceremony, and the
# refusals — a terminal loss delivered by hand, an intact connection, an
# authority nobody can read. Cancel, the orderly stop and the boot-time
# resume have their own files beside this one.
class CeremonyTest < Minitest::Test
  include RhoTest::DaemonHarness

  # A steward revoking the connection from the console is the state a human
  # reaches by their own deliberate action, and reconnecting is the only way
  # back — so /device/start must let it through and must hand back a real
  # ceremony. Driven through the actual surface: the earlier version of this
  # test fabricated `:active` by calling adopt_connection with three nils, a
  # state no production path can reach, and passed on the 502 that fabrication
  # produced rather than on any recovery.
  def test_a_terminally_lost_authority_lets_the_only_recovery_path_run
    daemon = connected_boot(config: agent_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    refused = request(daemon, :post, "/device/start", token: token)
    assert_equal 409, refused.code.to_i, "an intact connection still refuses a second ceremony"

    daemon.maintenance.renewal_event(:lost, daemon.lineage.credentials)

    recovery = request(daemon, :post, "/device/start", token: token)
    assert_equal 200, recovery.code.to_i, "a lost authority must not block reconnecting"
    body = JSON.parse(recovery.body)
    assert_equal "pending", body["phase"]
    refute_nil body["user_code"], "the recovery must be a real ceremony, not the dead one's document"
  end

  # A replacement deliberately leaves the old pointer in place until its new
  # bundle is fully installed. Staging is therefore the latest commit intent,
  # not a fallback used only when no pointer exists.
  def test_a_restart_prefers_a_won_replacement_over_the_old_pointer
    healthy = NexusDoubles::FakeAgentApi.new
    failing = false
    api = Object.new
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      if failing
        CybrosAgent::Response.new(status: 500, headers: {}, body: nil)
      else
        healthy.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
      end
    end
    daemon = boot(device_flow: connection_device_flow, api_transport: api, config: agent_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old_pointer = Rho::StateFile.new(daemon.home.connection_pointer_path).read

    daemon.maintenance.renewal_event(:lost, daemon.lineage.credentials)
    failing = true
    start_and_fail(daemon, token: token)
    assert_equal old_pointer,
      Rho::StateFile.new(daemon.home.connection_pointer_path).read,
      "the failed replacement has not committed its pointer yet"
    @daemons.pop.stop

    oauth = NexusDoubles::FakeOAuth.new
    restarted = boot(
      device_flow: connection_device_flow(oauth),
      api_transport: NexusDoubles::FakeAgentApi.new(executor_public_id: "0199-executor-new"), config: agent_mode
    )

    assert_equal :active, restarted.phase
    assert_equal "0199-executor-new", restarted.identity.executor_public_id
    assert_empty oauth.requests, "the staged replacement must not run another browser ceremony"
  end

  def test_old_lineage_loss_does_not_forget_a_replacement_already_in_flight
    api = NexusDoubles::SelectiveApi.new
    oauth = NexusDoubles::FakeOAuth.new
    device_tokens = 0
    polling = Queue.new
    gate = Queue.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" &&
          params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        device_tokens += 1
        if device_tokens == 2
          polling << true
          gate.pop
        end
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(
      device_flow: connection_device_flow(oauth), api_transport: api
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old_credentials = daemon.lineage.credentials

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    first = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    polling.pop
    daemon.maintenance.renewal_event(:lost, old_credentials)
    second = JSON.parse(request(daemon, :post, "/device/start", token: token).body)

    assert_equal first["user_code"], second["user_code"]
    assert_equal 2,
      oauth.requests.count { |path, _params| path == "/oauth/device_authorization" },
      "terminal news about the old lineage must not re-arm a second replacement"
  ensure
    gate&.push(true)
  end

  # Two clicks may both finish probing the old active lineage before either
  # claims the replacement slot. If the first replacement then adopts, the
  # second probe is stale: it must not overwrite the newly adopted Connection
  # and mint a third ceremony.
  def test_a_stale_recovery_probe_cannot_replace_the_connection_that_just_won
    api = NexusDoubles::SelectiveApi.new
    oauth = NexusDoubles::FakeOAuth.new
    accept_on_device_grant(oauth, api, [NexusDoubles::MEMBER_TOKEN], grant: 2)
    daemon = boot(
      device_flow: connection_device_flow(oauth),
      api_transport: api
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old_credentials = daemon.lineage.credentials
    api.accept(NexusDoubles::MEMBER_TOKEN, false)

    checked = Queue.new
    gates = Queue.new
    original = daemon.ceremony.method(:required_authority_state)
    daemon.ceremony.define_singleton_method(:required_authority_state) do
      original.call.tap do
        checked << true
        gates.pop
      end
    end
    callers = 2.times.map do
      Thread.new { daemon.ceremony.start }
    end
    2.times { checked.pop }

    gates << true
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 while daemon.lineage.credentials.equal?(old_credentials) &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    refute_same old_credentials, daemon.lineage.credentials

    gates << true
    callers.each { |caller| refute_nil caller.join(10) }

    assert_equal [200, 409], callers.map { |caller| Array(caller.value).first }.sort
    assert_equal 2,
      oauth.requests.count { |path, _params| path == "/oauth/device_authorization" },
      "the stale old-lineage decision must not mint a ceremony after replacement adoption"
  ensure
    2.times { gates&.push(true) }
  end

  # The product flow end to end: ask for a code, the human confirms it, the
  # daemon files the credentials and says who it is.
  def test_a_human_connects_the_daemon_and_it_reports_who_it_became
    now = Time.utc(2026, 7, 27, 12)
    # A pre-existing dedicated Workspace keeps ensure to a single list call,
    # so the plane-probe economy this test pins stays observable.
    api = NexusDoubles::FakeAgentApi.new(
      workspaces: [{ public_id: "0199-workspace-1", name: "Helper" }]
    )
    daemon = boot(
      device_flow: connection_device_flow,
      api_transport: api,
      clock: -> { now }
    )
    token = bearer(daemon)

    started = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "pending", started["phase"]
    assert_equal "full", started["mode"]
    assert_equal "combined", started["branch"], "ONE grant for the two addresses"
    assert_equal "BCDF-GHJK", started["user_code"]
    assert_equal "https://nexus.example/oauth/device", started["verification_uri"]

    body = await_state(daemon, "active", token: token)
    assert_equal "0199-user", body.dig("identity", "user_public_id")
    assert_equal "0199-executor", body.dig("identity", "executor_public_id")
    # Two vocabularies on purpose: the precise per-plane words the code needs,
    # and the ordinary login word a person already understands.
    assert_equal "signed_in", body.dig("authority", "signed")
    assert_equal "live", body.dig("authority", "planes", "member")
    assert_equal "live", body.dig("authority", "planes", "executor_transport")
    assert_equal now.iso8601, body.dig("authority", "measured_at")
    # Neither the workspace lane nor the adopted edge's announcement and
    # declaration (the announcement write, the catalog read, the configuration write and the guideline's slot write beside it) nor the runner's inbox sweep is a plane probe.
    declaration = %w[/agent_api/v1/executor/announcement /agent_api/v1/tools /agent_api/v1/profile/configuration
                     /agent_api/v1/profile/prompt_documents/system_prompt /agent_api/v1/executor/inbox]
    plane_probes = api.requests.count do |path, _|
      !path.start_with?("/agent_api/v1/workspaces") && !declaration.include?(path)
    end
    assert_equal 3, plane_probes,
      "the three bootstrap reads (the runner's on its own credential) are the observation status reuses"

    await_workspace_state(daemon, "adopted", token: token)
    # The adopted edge declares the profile's configuration; let that land
    # so the baseline below is the daemon at rest.
    wait_for { api.configuration_declarations.any? }
    baseline = api.requests.length
    3.times { request(daemon, :get, "/status", token: token) }
    assert_equal baseline, api.requests.length,
      "fresh local status reads must not multiply Nexus requests"
  end

  # A probe spends nothing, so something else must reach the one endpoint that
  # can tell a revoked lineage from any other 401 — and it must reach it while
  # a human is standing there, having just revoked their own connection.
  #
  # The transport accepts through the ceremony, then refuses everything; the
  # OAuth double answers a rotation with invalid_grant, which is what Nexus
  # does once the family is gone. The daemon must learn that from the first
  # refusal, not from the 14-day expiry, and must not ask again on every poll.
  def test_a_refusal_reaches_the_one_endpoint_that_can_diagnose_it
    revoked = false
    rotations = 0
    api = Object.new
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      next NexusDoubles::FakeAgentApi.new.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout) unless revoked

      CybrosAgent::Response.new(
        status: 401, headers: {},
        body: { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }
      )
    end
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" && params[:grant_type] == "refresh_token"
        rotations += 1
        next Data.define(:status, :headers, :body).new(
          status: 400, headers: {}, body: { "error" => "invalid_grant" }
        )
      end
      super(path, params, timeout: timeout)
    end

    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    revoked = true

    # The read path stays a read: it reports the refusal and spends nothing,
    # however many times it is polled.
    4.times { request(daemon, :get, "/status", token: token) }
    assert_equal 0, rotations, "a poll must never be able to spend a single-use token"

    # The action path is where a human asks to reconnect, and where spending
    # one rotation to answer them honestly is proportionate.
    recovery = request(daemon, :post, "/device/start", token: token)
    assert_equal 2, rotations, "one consultation per lineage (agent, runner), from the human's own action"
    assert_equal 200, recovery.code.to_i, "the diagnosis must unblock the only way back"
    refute_nil JSON.parse(recovery.body)["user_code"]

    assert_equal "expired", JSON.parse(request(daemon, :get, "/status", token: token).body)
      .dig("authority", "signed")
  end

  # A poller speaks for the ceremony it was started for, never for whatever
  # `@connection` holds when it finishes: a terminal loss drops that ivar
  # mid-`await`, and a poller reading it through a default adopts `nil, nil` —
  # a daemon at `active` holding no identity and no credentials, which is
  # unrecoverable in-process because `verify_authority` has nothing to consult
  # and every later `/device/start` therefore answers 409 forever.
  def test_a_ceremony_finishing_beside_a_terminal_loss_is_adopted_whole
    upstream = NexusDoubles::FakeAgentApi.new
    resolving = Queue.new
    gate = Queue.new
    api = Object.new
    held = false
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      # The ceremony's identity read waits; the status probe's later reads on
      # the same path must not, or polling deadlocks the reactor.
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
    resolving.pop # the poller is inside `await`, resolving this ceremony's identity

    daemon.lineage.lose
    gate << true

    body = await_state(daemon, "active", token: token)
    refute_nil body["identity"], "a daemon claiming `active` must hold the connection it claims"
    assert_equal "signed_in", body.dig("authority", "signed")
  end

  # A 200 from `/device/start` is a document the caller acts on: a `user_code`
  # to show, an `identity` to report, or an `error` to raise. The in-flight
  # phases carry none of those, and the poller thread makes them reachable with
  # no concurrency at all — a second `rho connect` a moment after the first.
  # What the human saw was `Open  and enter: `.
  #
  # Held on a gate, not a sleep: a fixed hold raced the wait's own deadline on
  # a loaded box. The gate keeps the ceremony inside `activating` until the
  # second caller is in flight, and everything after the release is fake-API
  # fast — no wall-clock left to lose.
  def test_a_caller_arriving_mid_ceremony_is_answered_with_something_it_can_act_on
    upstream = NexusDoubles::FakeAgentApi.new
    resolving = Queue.new
    gate = Queue.new
    api = Object.new
    held = false
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      # One-shot: the gate holds the ceremony's identity read; the ensure
      # cycle's later profile read must pass, or maintenance deadlocks.
      if path == "/agent_api/v1/profile" && !held
        held = true
        resolving << true
        gate.pop
      end
      upstream.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
    end

    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = bearer(daemon)
    assert_equal "pending", JSON.parse(request(daemon, :post, "/device/start", token: token).body)["phase"]
    resolving.pop # the poller is inside `activating`; the document is bare

    second = Thread.new { JSON.parse(request(daemon, :post, "/device/start", token: token).body) }
    sleep 0.05 # let the second caller reach the daemon while the ceremony is held
    gate << true

    refute_nil second.join(15), "the second caller must be answered"
    assert_actionable second.value
  end

  # The same rule under the shape the conversation round multiplies: two
  # clients on one daemon at the same instant. Idempotency already holds — one
  # ceremony, one code — but the caller that loses the race must still be told
  # what it is. Gated for the same reason as the test above.
  def test_two_simultaneous_callers_are_both_answered_with_the_one_ceremony
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
    callers = 2.times.map do
      Thread.new { JSON.parse(request(daemon, :post, "/device/start", token: token).body) }
    end
    starting.pop # one caller opened the ceremony and is held inside it
    sleep 0.05   # let the other reach the daemon and find the bare `:starting`
    gate << true

    # Not "both carry the same code": the loser waits for the ceremony, and a
    # ceremony that finished while it waited answers with the identity instead.
    # Both are actionable; only a bare `{phase}` is not.
    callers.each do |caller|
      refute_nil caller.join(15), "every caller must be answered"
      assert_actionable caller.value
    end
    assert_equal 1, oauth.requests.count { |path, _params| path == "/oauth/device_authorization" },
      "a second caller must never mint a second device code"
  end

  # The earlier simultaneous test joins after the first caller has already
  # published `starting`. This one freezes the local staging read that used to
  # happen while the shared Connection was still `idle`: both handlers could
  # enter it, both conclude there was nothing to resume, and both mint a code.
  def test_the_idle_resume_or_start_decision_has_one_owner
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(
      device_flow: connection_device_flow(oauth),
      api_transport: NexusDoubles::FakeAgentApi.new
    )
    original = daemon.ceremony.method(:build_connection)
    reading = Queue.new
    gate = Queue.new
    daemon.ceremony.define_singleton_method(:build_connection) do |**options|
      original.call(**options).tap do |connection|
        staging = connection.instance_variable_get(:@staging)
        read = staging.method(:read)
        staging.define_singleton_method(:read) do
          reading << true
          gate.pop
          read.call
        end
      end
    end
    token = bearer(daemon)

    first = Thread.new { JSON.parse(request(daemon, :post, "/device/start", token: token).body) }
    reading.pop
    second = Thread.new { JSON.parse(request(daemon, :post, "/device/start", token: token).body) }
    sleep 0.05

    assert_equal 0, reading.length,
      "the second caller must join before it repeats the owner's staging decision"
    gate << true
    [first, second].each { |caller| refute_nil caller.join(15) }
    assert_equal 1, oauth.requests.count { |path, _| path == "/oauth/device_authorization" }
  ensure
    2.times { gate&.push(true) }
  end

  def assert_actionable(body)
    refute_nil body
    assert %w[user_code identity error].any? { |key| body.key?(key) },
      "a 200 the caller cannot act on: #{body.inspect}"
  end

  # THE ACCEPT RIDES THE GRANT: the double takes `credentials` again on the
  # ceremony's own thread, inside the `grant`-th device grant that mints
  # them — before that ceremony's bootstrap reads — so no `accept(true)`
  # from the test thread can lose the race to the consume (the fake mints
  # the same token strings, so a probe and a consume are told apart only
  # by WHEN). The refusals set before stand for every probe until then.
  def accept_on_device_grant(oauth, api, credentials, grant:)
    device_tokens = 0
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" && params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        device_tokens += 1
        credentials.each { |credential| api.accept(credential, true) } if device_tokens == grant
      end
      super(path, params, timeout: timeout)
    end
  end

  # ---- the three request shapes of one Connection, per cell ----

  # A boot whose registry serves no runner tool is agent mode: branch A
  # alone, and the planes are the agent's two.
  def test_an_agent_mode_boot_sends_branch_a_alone_and_reports_the_agents_planes
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new,
      extensions: [Rho::Extensions::Ops], config: agent_mode)
    token = bearer(daemon)

    started = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal %w[agent agent], started.values_at("branch", "mode")
    body = await_state(daemon, "active", token: token)
    request = oauth.requests.find { |path, _| path == "/oauth/device_authorization" }.last
    refute request.key?(:runner_identifier)
    assert_equal %w[executor_transport member], body.dig("authority", "planes").keys.sort
    assert_nil body.dig("identity", "runner_executor_public_id")
    assert_equal "agent", body["mode"]
  end

  # THE PIN: the agent planes lost beside a live runner plane
  # — a Profile removed and restored — sends branch A ALONE and keeps the
  # runner OAuth by object identity; the runner plane reads live after.
  def test_a_restore_never_fences_a_live_runner_plane
    api = NexusDoubles::SelectiveApi.new
    oauth = NexusDoubles::FakeOAuth.new
    accept_on_device_grant(oauth, api, [NexusDoubles::MEMBER_TOKEN, NexusDoubles::TRANSPORT_TOKEN], grant: 2)
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old = daemon.lineage.credentials
    runner = old.runner
    assert_equal "0199-runner", daemon.identity.runner_executor_public_id

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    api.accept(NexusDoubles::TRANSPORT_TOKEN, false)
    restoring = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal "agent", restoring["branch"], "branch A alone: a combined re-consume would re-pair the live runner"
    assert_equal "pending", restoring["phase"]

    body = await_connection_phase(daemon, "active", token: token)
    # The connection activates before its poller adopts the replacement.
    wait_for { !daemon.lineage.credentials.equal?(old) }
    restored = daemon.lineage.credentials
    refute_same old, restored
    assert_same runner, restored.runner, "the live runner OAuth, kept — never re-consumed"
    assert_equal "0199-runner", body.dig("identity", "runner_executor_public_id")
    assert_equal 2, oauth.requests.count { |path, _| path == "/oauth/device_authorization" }
    refute oauth.requests.last(3).any? { |path, params| path == "/oauth/device_authorization" && params[:runner_identifier] }
    wait_for { JSON.parse(request(daemon, :get, "/status", token: token).body).dig("authority", "planes", "runner_transport") == "live" }
  end

  # The agent planes live and the runner plane gone under full mode: branch
  # B for the in-process identifier, spelled `pending_runner`, the agent
  # half untouched — and the runner attached without moving the lineage.
  def test_a_lost_runner_plane_under_full_mode_opens_the_runner_only_shape
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    about = daemon.lineage.credentials
    agent = about.agent
    executor = daemon.identity.executor_public_id

    assert daemon.maintenance.renewal_event(:lost, about, lineage: :runner)
    refute about.runner?
    wait_for { JSON.parse(request(daemon, :get, "/status", token: token).body).dig("authority", "planes", "runner_transport") == "absent" }

    adding = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    assert_equal %w[runner pending_runner], adding.values_at("branch", "phase")
    refute_nil adding["user_code"]
    # The connection publishes active before its poller attaches the runner.
    wait_for { about.runner? }
    body = await_connection_phase(daemon, "active", token: token)
    request = oauth.requests.select { |path, _| path == "/oauth/device_authorization" }.last.last
    assert_equal ["rho.#{daemon.home.instance_id}", "runner"], request.values_at(:runner_identifier, :executor_kind)
    refute request.key?(:agent_identifier)
    assert_same about, daemon.lineage.credentials, "the lineage did not move"
    assert_same agent, about.agent, "the agent half untouched"
    assert about.runner?
    assert_equal executor, body.dig("identity", "executor_public_id")
    assert_equal "0199-runner", body.dig("identity", "runner_executor_public_id")
    wait_for { daemon.lineage.runner(:runner) }
    assert_equal "full", Rho::StateFile.new(daemon.home.connection_pointer_path).read.fetch("mode")
  end

  def test_both_planes_lost_opens_the_combined_shape_again
    api = NexusDoubles::SelectiveApi.new
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    api.accept(NexusDoubles::TRANSPORT_TOKEN, false)
    api.accept(NexusDoubles::RUNNER_TOKEN, false)
    again = JSON.parse(request(daemon, :post, "/device/start", token: token).body)

    assert_equal %w[combined pending], again.values_at("branch", "phase")
    request = oauth.requests.select { |path, _| path == "/oauth/device_authorization" }.last.last
    assert request.key?(:agent_identifier) && request.key?(:runner_identifier)
  end

  # FULL MODE WITH AN EMPTY RUNNER REGISTRY REFUSES TO BOOT (S-6): one page
  # per mode, no serving-nothing row.
  def test_a_full_boot_with_an_empty_runner_registry_refuses_to_boot
    error = assert_raises(Rho::ConfigurationError) { boot(extensions: [Rho::Extensions::Ops]) }
    assert_equal "mode full serves tools on this machine and none loaded — set mode: agent, or restore the extensions",
      error.message
  end

  # Idempotent by contract: a human double-clicking Connect must not mint a
  # second device code. If both ceremonies later won, the later Consume would
  # re-pair the same address, advance its epoch, and fence the other bundle.
  def test_starting_twice_does_not_mint_a_second_code
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(daemon)

    first = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    request(daemon, :post, "/device/start", token: token)

    assert_equal "BCDF-GHJK", first["user_code"], "the first answer carries the code the human needs"
    # The property is that no second authorization was minted. Asserting that
    # the second reply repeats the code would be asserting a race: by then the
    # ceremony may legitimately have completed, and a completed connection has
    # no code to show.
    assert_equal 1, oauth.requests.count { |path, _| path == "/oauth/device_authorization" }
  end

  def test_an_already_connected_daemon_refuses_to_start_another_ceremony
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    response = request(daemon, :post, "/device/start", token: token)
    assert_equal "409", response.code
    assert_equal "already_connected", JSON.parse(response.body).dig("error", "code")
  end

  # A member-plane refusal can leave an independent executor plane usable.
  # Recovery must preserve that plane until a replacement wins or is canceled.
  def test_member_authority_loss_can_start_and_cancel_a_ceremony_without_dropping_transport
    api = NexusDoubles::SelectiveApi.new
    oauth = NexusDoubles::FakeOAuth.new
    device_tokens = 0
    gate = Queue.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" &&
          params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        device_tokens += 1
        gate.pop if device_tokens == 2
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(
      device_flow: connection_device_flow(oauth), api_transport: api
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old_credentials = daemon.lineage.credentials

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    restoring = request(daemon, :post, "/device/start", token: token)

    assert_equal 200, restoring.code.to_i
    assert_equal "pending", JSON.parse(restoring.body)["phase"]
    assert_same old_credentials, daemon.lineage.credentials
    assert_equal NexusDoubles::TRANSPORT_TOKEN, old_credentials.executor_credential

    canceled = request(daemon, :post, "/device/cancel", token: token)
    assert_equal 200, canceled.code.to_i
    assert_equal 200, request(daemon, :post, "/device/cancel", token: token).code.to_i,
      "safe cancellation stays idempotent while the old transport remains active"
    assert_same old_credentials, daemon.lineage.credentials
    assert_equal :active, daemon.phase
  ensure
    gate&.push(true)
  end

  def test_member_authority_recovery_swaps_lineage_only_after_the_new_connection_is_active
    api = NexusDoubles::SelectiveApi.new
    oauth = NexusDoubles::FakeOAuth.new
    device_tokens = 0
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" &&
          params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT
        device_tokens += 1
        # The replacement is accepted before its bootstrap reads.
        api.accept(NexusDoubles::MEMBER_TOKEN, true) if device_tokens == 2
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(
      device_flow: connection_device_flow(oauth), api_transport: api
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    old_credentials = daemon.lineage.credentials

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    restoring = request(daemon, :post, "/device/start", token: token)
    assert_equal 200, restoring.code.to_i

    # The connection becomes active before the daemon adopts its replacement.
    wait_for { !daemon.lineage.credentials.equal?(old_credentials) }
    body = await_connection_phase(daemon, "active", token: token)
    new_credentials = daemon.lineage.credentials
    refute_same old_credentials, new_credentials
    assert_equal "0199-user", body.dig("identity", "user_public_id")
    assert_equal "signed_in", body.dig("authority", "signed")
    assert_equal 2, device_tokens
  end

  def test_unknown_authority_does_not_start_a_replacement_ceremony
    reachable = true
    upstream = NexusDoubles::FakeAgentApi.new
    api = Object.new
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      if reachable
        upstream.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
      else
        CybrosAgent::Response.new(
          status: 503, headers: {},
          body: { "error" => { "code" => "unavailable", "message" => "Unavailable" } }
        )
      end
    end
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(
      device_flow: connection_device_flow(oauth), api_transport: api
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    authorizations = lambda do
      oauth.requests.count { |path, _params| path == "/oauth/device_authorization" }
    end
    assert_equal 1, authorizations.call

    reachable = false
    response = request(daemon, :post, "/device/start", token: token)

    assert_equal 503, response.code.to_i
    assert_equal "authority_unknown", JSON.parse(response.body).dig("error", "code")
    assert_equal 1, authorizations.call,
      "uncertain reachability must not create or re-pair an Agent connection"
    assert_equal :active, daemon.phase
  end

  def test_one_unauthorized_plane_does_not_override_unknown_on_the_other_plane
    degraded = false
    upstream = NexusDoubles::FakeAgentApi.new
    api = Object.new
    api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      unless degraded
        next upstream.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
      end

      if path == "/agent_api/v1/profile"
        CybrosAgent::Response.new(
          status: 401, headers: {},
          body: { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }
        )
      else
        CybrosAgent::Response.new(
          status: 503, headers: {},
          body: { "error" => { "code" => "unavailable", "message" => "Unavailable" } }
        )
      end
    end
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(
      device_flow: connection_device_flow(oauth), api_transport: api
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    degraded = true

    response = request(daemon, :post, "/device/start", token: token)

    assert_equal 503, response.code.to_i
    assert_equal "authority_unknown", JSON.parse(response.body).dig("error", "code")
    assert_equal 1,
      oauth.requests.count { |path, _params| path == "/oauth/device_authorization" },
      "unknown required authority must not be turned into a replacement ceremony"
  end
end
