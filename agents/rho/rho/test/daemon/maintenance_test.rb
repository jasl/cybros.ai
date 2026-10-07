require "test_helper"

# THE ONE WORKER AND ITS EVENTS: what a
# renewal outcome does to the lineage it names, Ensure-Workspace on the
# adoption wake, the authority probe status reads coalesce into, and the
# stop that waits for the worker's masked writes before the home goes.
class MaintenanceTest < Minitest::Test
  include RhoTest::DaemonHarness

  # A ROTATION IS A PUSH THE SOCKET CANNOT HEAR. The handshake pinned the
  # bearer it presented, so a follower still holding one is authenticated by a
  # credential this daemon has already replaced — and nothing is wrong yet,
  # which is why it has to be told rather than left to find out.
  #
  # The rebind ends the SUBSCRIPTION and not the run: a rotated credential is
  # not a reason to stop following, and a caller that had to restart the pump
  # would need its position to do that without re-delivering.
  def test_a_rotation_rebinds_the_shared_client_on_its_reactor_without_ending_runs
    daemon = inference_request_ready(boot)
    about = daemon.lineage.credentials
    rebound = Queue.new
    stopped = 0
    realtime = Object.new
    realtime.define_singleton_method(:rebind) do
      rebound << [Thread.current, !Async::Task.current?.nil?]
      true
    end
    realtime.define_singleton_method(:close) { nil }
    runs = 2.times.map do |index|
      fake_run("os-#{index}").tap do |run|
        run.define_singleton_method(:realtime) { realtime }
        run.define_singleton_method(:stop) { stopped += 1 }
      end
    end
    runs.each { |run| daemon.lineage.install_follower(about, run) }
    caller_thread = Thread.current

    # THROUGH THE EVENT, not the helper: what is worth pinning is that a
    # rotation reaches the followers at all. A test that called the sweep
    # directly would stay green with the wiring removed.
    daemon.maintenance.renewal_event(:renewed, about)
    rebind_thread, inside_reactor = rebound.pop

    refute_same caller_thread, rebind_thread
    assert inside_reactor, "the Async client is only mutated on the control reactor"
    assert_nil rebound.pop(timeout: 0.05),
      "multiplexed runs schedule one rebind for their one shared client"
    assert_equal 0, stopped, "a rotation is not a reason to stop following"
    assert_equal runs, daemon.lineage.followers,
      "and the follower stays registered, so the next rotation reaches it too"
  end

  # The maintenance worker is started once and only `stop` ends it, so it outlives
  # every connection this process holds. A run still holding the credentials it
  # started with rotates a lineage the vault has moved past, is told
  # `ConnectionSuperseded` — correctly — and reports the connection that
  # replaced it terminally lost. `/status` then reads "expired" beside a
  # connection that works, and the same tick kills every later recovery.
  def test_renewal_follows_a_reconnect_rather_than_the_connection_it_started_with
    now = Time.now
    daemon = connected_boot(config: agent_mode, clock: -> { now }, renewal_interval: 0.02)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    # The steward revokes it and the human connects again. Same daemon, same
    # thread, a new lineage in the vault.
    daemon.maintenance.renewal_event(:lost, daemon.lineage.credentials)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    # Past the renewal lead, so the tick performs a real rotation rather than
    # answering `:not_due`. Waited for by its own evidence — the vault's
    # rotation counter — not by a fixed sleep, because the tick's cadence is
    # real wall-clock and a loaded box can starve it past any sleep chosen.
    # The counter moving is also the assertion that matters: a run still
    # holding the superseded credentials would swallow `ConnectionSuperseded`
    # every tick while this counter never moved, and the connection would
    # lapse a month later with the suite green.
    vault = daemon.identity.vault
    assert_equal 0, vault.read.fetch("rotation")
    now += 8 * 24 * 60 * 60
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.02 until vault.read.fetch("rotation").positive? ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_operator vault.read.fetch("rotation"), :>, 0,
      "the tick must have rotated the credentials the daemon actually holds"

    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "signed_in", body.dig("authority", "signed"),
      "renewal must not report the connection it just adopted as lost"
    assert_equal "active", body["state"]
  end

  # The other half, which the test above cannot reach because reading the
  # current credentials each tick already prevents it: an answer that was
  # already in flight when the reconnect landed. `rotate!` raises inside the
  # vault's lock and reports after releasing it, so the reconnect can take that
  # lock, install, and move `@credentials` before the report arrives. The
  # report is right about the lineage it names and must not be applied to the
  # live one.
  def test_a_late_answer_about_a_superseded_lineage_is_not_news
    daemon = connected_boot(config: agent_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    superseded = daemon.lineage.credentials

    daemon.maintenance.renewal_event(:lost, superseded)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    daemon.maintenance.renewal_event(:lost, superseded)

    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "active", body["state"], "a superseded lineage's answer is not news about this one"
    assert_equal "signed_in", body.dig("authority", "signed")
  end

  # A connection that can never rotate again is over, and the daemon has to say
  # so with the same word a client reads. `rho connect` matches on `state`, so
  # leaving it at "active" made the CLI print "Connected" as the revoked
  # identity while the line above it said the credentials had expired.
  def test_a_terminal_loss_leaves_the_daemon_disconnected
    daemon = connected_boot(config: agent_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    daemon.maintenance.renewal_event(:lost, daemon.lineage.credentials)

    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "disconnected", body["state"], "a connection that cannot rotate again is not active"
    assert_equal "expired", body.dig("authority", "signed")
    refute body.key?("connection"),
      "the dead ceremony's document must not sit beside a state that says otherwise"
    assert_equal "pending", body.dig("workspace", "state"),
      "the workspace answer was the dead lineage's and must not outlive it"
  end

  def test_a_fresh_agent_creates_its_dedicated_workspace_at_adoption
    # An ordinary shared Workspace exists, but Rho deliberately limits its
    # adoption scope to Workspaces dedicated to this Agent application.
    api = NexusDoubles::FakeAgentApi.new(
      workspaces: [{ public_id: "0199-workspace-shared", name: "Shared workspace", dedicated: false }]
    )
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = connect(daemon)

    body = await_workspace_state(daemon, "adopted", token: token)
    workspace = body["workspace"]
    assert_equal "Helper", workspace["name"], "the create names the profile display name"
    assert_equal "dedicated", workspace["kind"], "the default path says what it adopted"
    assert_equal({ "dedicated_to_current_agent" => true }, api.workspace_list_params.first,
      "the listing that scopes adoption carries the dedication filter on the wire")
    assert_equal 1, api.workspace_creates.length
    create = api.workspace_creates.first
    refute create[:body].fetch("workspace").key?("dedicated"),
      "Agent identity alone makes the Workspace dedicated"
    refute create[:body].fetch("workspace").key?("agent_identifier"),
      "no identifier ever crosses the wire"
    key = create[:headers].find { |name, _| name.to_s.downcase == "idempotency-key" }
    refute_nil key, "the create carries a client-minted idempotency key"
  end

  def test_an_existing_dedicated_workspace_is_adopted_without_creating
    api = NexusDoubles::FakeAgentApi.new(
      workspaces: [
        # Oldest of all, but shared rather than dedicated — Rho's explicit
        # product policy keeps it out of the adoption scope.
        { public_id: "0199-workspace-shared", name: "Shared workspace", dedicated: false },
        { public_id: "0199-workspace-old", name: "Oldest" },
        { public_id: "0199-workspace-new", name: "Newest" },
      ]
    )
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = connect(daemon)

    body = await_workspace_state(daemon, "adopted", token: token)
    assert_equal "0199-workspace-old", body["workspace"]["public_id"],
      "the first dedicated row of the ascending list is the oldest and wins"
    assert_empty api.workspace_creates
  end

  # THE ROOM KNOB: told a workspace, the daemon
  # FETCHES that row and adopts it — no dedication-scoped listing, no
  # create — and `/status` says it is a room. Access is the kernel's own
  # funnel: the fetch answers what this agent's steward may see.
  def test_under_the_room_knob_the_daemon_adopts_the_named_room_and_mints_nothing
    api = NexusDoubles::FakeAgentApi.new(
      workspaces: [
        { public_id: "0199-mine", name: "Helper" },
        { public_id: "0199-room", name: "Team", dedicated: false, access_mode: "account_wide" },
      ]
    )
    daemon = boot(device_flow: connection_device_flow, api_transport: api,
      config: Rho::Config.from_hash({ "workspace" => "0199-room" }))
    token = connect(daemon)

    body = await_workspace_state(daemon, "adopted", token: token)
    assert_equal({ "state" => "adopted", "public_id" => "0199-room", "name" => "Team", "kind" => "room" },
      body["workspace"])
    assert_equal ["0199-room"], api.workspace_fetches, "the room is read by its address"
    assert_empty api.workspace_list_params, "no dedication-scoped listing under the knob"
    assert_empty api.workspace_creates, "nothing is minted under the knob"
  end

  # Explicit own dedication is selectable; a foreign dedication is never a fallback.
  def test_an_explicit_own_dedicated_workspace_is_selected_and_an_invisible_one_is_refused
    api = NexusDoubles::FakeAgentApi.new(workspaces: [{ public_id: "0199-mine", name: "Helper" }])
    daemon = boot(device_flow: connection_device_flow, api_transport: api,
      config: Rho::Config.from_hash({ "workspace" => "0199-mine" }))
    token = connect(daemon)
    body = await_workspace_state(daemon, "adopted", token: token)
    assert_equal "0199-mine", body.dig("workspace", "public_id")
    assert_empty api.workspace_creates

    absent = NexusDoubles::FakeAgentApi.new
    other = boot(root: File.join(@root, "absent"), device_flow: connection_device_flow, api_transport: absent,
      config: Rho::Config.from_hash({ "workspace" => "0199-elsewhere" }))
    token = connect(other)
    body = await_workspace_state(other, "error", token: token)
    assert_equal "not_found", body["workspace"]["code"]
    assert_equal ["0199-elsewhere"], absent.workspace_fetches.uniq
    assert_empty absent.workspace_creates
  end

  def test_a_failed_ensure_reports_its_code_and_does_not_blind_retry
    api = NexusDoubles::FakeAgentApi.new(
      workspace_create: CybrosAgent::Response.new(
        status: 500, headers: {},
        body: { "error" => { "code" => "server_error", "message" => "boom" } }
      )
    )
    daemon = boot(device_flow: connection_device_flow, api_transport: api)
    token = connect(daemon)

    body = await_workspace_state(daemon, "error", token: token)
    assert_equal "server_error", body["workspace"]["code"]
    assert_equal 1, api.workspace_creates.length,
      "one cycle makes at most one create attempt"
  end

  # A dead member plane must not take a live delivery address down with it.
  # That independence is the property Round D was built to create, and this is
  # where a human sees it.
  def test_a_dead_member_plane_is_reported_without_disconnecting
    api = NexusDoubles::SelectiveApi.new
    daemon = boot(
      device_flow: connection_device_flow,
      api_transport: api,
      renewal_interval: 0.02
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    body = await_authority(daemon, "expired", token: token)

    assert_equal "active", body["state"], "a dead plane must never disconnect the daemon"
    assert_equal "unauthorized", body.dig("authority", "planes", "member")
    assert_equal "live", body.dig("authority", "planes", "executor_transport")
    assert_equal "expired", body.dig("authority", "signed"),
      "an Agent is fully signed in only while both required planes are live"
  end

  def test_every_plane_refused_reads_as_expired_credentials
    api = NexusDoubles::SelectiveApi.new
    daemon = boot(
      device_flow: connection_device_flow,
      api_transport: api,
      renewal_interval: 0.02
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    api.accept(NexusDoubles::TRANSPORT_TOKEN, false)
    body = await_authority(daemon, "expired", token: token)

    assert_equal "expired", body.dig("authority", "signed")
    assert_equal "active", body["state"], "rho stays up and says so, rather than pretending nothing happened"
  end

  # Authority probes yield between their two HTTP reads. A replacement can
  # adopt in that window, so the returned report is meaningful only for the
  # exact OAuth object captured before the first read. The final status
  # snapshot must pair the new identity/connection with `unknown`, never with
  # the old lineage's otherwise-valid report; the next request probes the new
  # lineage normally.
  def test_status_never_splices_an_old_authority_report_onto_a_replacement
    now = Time.now
    daemon = connected_boot(clock: -> { now })
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    # Settle the adoption-wake ensure and the edge's declaration before the
    # gated transport goes in, so the call ladder below is exactly probes,
    # one relist and the replacement's own declaration.
    await_workspace_state(daemon, "adopted", token: token)
    wait_for { daemon.wire.api_transport.configuration_declarations.any? }
    wait_for { !daemon.maintenance.running? }
    now += Rho::Daemon::Lineage::AUTHORITY_OBSERVATION_INTERVAL + 1

    old_probe = Queue.new
    allow_old_probe = Queue.new
    new_probe = Queue.new
    allow_new_probe = Queue.new
    side_sweep = Queue.new
    allow_side_sweep = Queue.new
    calls = []
    # A pre-existing dedicated row keeps the replacement's ensure to a
    # single list call — no create, no extra profile read.
    upstream = NexusDoubles::FakeAgentApi.new(
      executor_public_id: "0199-executor-new",
      workspaces: [{ public_id: "0199-workspace-replacement", name: "Replacement" }]
    )
    blocking_api = Object.new
    blocking_api.define_singleton_method(:call) do |path, method: :get, credential:, body: nil, params: nil, headers: {}, timeout:|
      # The same maintenance cycle discovers both workspace scopes for its
      # side sweep after ensure. Keep those reads outside the ensure count.
      if path == "/agent_api/v1/workspaces" && params&.[]("dedicated_to_current_agent") == false
        side_sweep << true
        allow_side_sweep.pop
      end
      calls << path
      case calls.length
      when 1
        old_probe << true
        allow_old_probe.pop
      when 3
        new_probe << true
        allow_new_probe.pop
      else nil
      end
      upstream.call(path, method: method, credential: credential, body: body, params: params, headers: headers, timeout: timeout)
    end
    daemon.wire.api_transport = blocking_api

    first = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "signed_in", first.dig("authority", "signed")
    old_probe.pop

    replacement_identity = Rho::Identity.agent(
      home: daemon.home,
      user_public_id: daemon.identity.user_public_id,
      executor_public_id: "0199-executor-new", mode: "full"
    ).prepare
    replacement_oauth = CybrosAgent::Credentials::OAuth.issue(
      credentials: CybrosAgent::DeviceFlow::Credentials.new(
        access_token: NexusDoubles::MEMBER_TOKEN,
        executor_access_token: NexusDoubles::TRANSPORT_TOKEN,
        refresh_token: "rt-cybros-api-v1-replacement.secret",
        token_type: "Bearer",
        expires_in: 1_209_600
      ),
      authority: connection_device_flow,
      store: replacement_identity.vault,
      clock: -> { Time.now }
    )
    replacement_identity.record(clock: -> { Time.now })
    replacement_oauth = Rho::Credentials.new(agent: replacement_oauth)
    replacement_connection = daemon.ceremony.build_connection
    replacement_connection.send(:instance_variable_set, :@identity, replacement_identity)
    replacement_connection.send(:instance_variable_set, :@oauth, replacement_oauth)
    replacement_connection.send(:instance_variable_set, :@phase, :active)
    assert_equal :claimed, daemon.lineage.claim_slot(replacement_connection)
    daemon.send(
      :adopt_connection,
      identity: replacement_identity,
      credentials: replacement_oauth
    )

    allow_old_probe << true
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 while daemon.maintenance.running? &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

    body = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "0199-executor-new", body.dig("identity", "executor_public_id")
    assert_equal "0199-executor-new",
      body.dig("connection", "identity", "executor_public_id")
    assert_equal "unknown", body.dig("authority", "signed")
    assert_equal "pending", body.dig("workspace", "state"),
      "replacement adoption resets the workspace answer before the new lineage re-ensures"
    new_probe.pop

    allow_new_probe << true
    body = await_workspace_state(daemon, "adopted", token: token)
    assert_equal "0199-workspace-replacement", body.dig("workspace", "public_id"),
      "the replacement lineage's own ensure cycle re-adopts"
    current = JSON.parse(request(daemon, :get, "/status", token: token).body)
    assert_equal "0199-executor-new", current.dig("identity", "executor_public_id")
    assert_equal "signed_in", current.dig("authority", "signed")
    assert side_sweep.pop(timeout: 5), "assert after the replacement's ensure and before its side sweep reads"
    # The adopted edge's announcement and declaration are not probes — the
    # named definitions' listing the edge reads first included (capabilities
    # III, named sub-agents) — and neither is the runner's inbox sweep on
    # the executor plane.
    declaration = %w[/agent_api/v1/executor/announcement /agent_api/v1/tools /agent_api/v1/profile/configuration
                     /agent_api/v1/profile/agents /agent_api/v1/executor/inbox /agent_api/v1/executors]
    probes = calls.count { |path| !path.start_with?("/agent_api/v1/workspaces") && !declaration.include?(path) }
    assert_equal 5, probes, "one probe per plane per lineage (three on the full one, two on the replacement), and nothing else"
    assert_equal 1, calls.count { |path| path == "/agent_api/v1/workspaces" },
      "the superseded lineage's ensure is discarded; only the replacement relists"
  ensure
    allow_old_probe&.push(true)
    allow_new_probe&.push(true)
    allow_side_sweep&.push(true)
  end

  # ADOPTION STARTS NOTHING. The one maintenance worker is boot-time and only
  # `stop` ends it, so two lineages adopted at once cannot race two workers,
  # and no orphan survives the drain to rewrite the announcement after its
  # delete.
  def test_adopting_from_two_threads_leaves_exactly_one_maintenance_thread_and_stop_ends_it
    before_boot = Thread.list
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    booted = Thread.list - before_boot
    refute_empty booted, "the worker and the reactor are up"
    worker_source = Rho::Daemon::Maintenance.instance_method(:work).source_location.first
    workers = -> {
      Thread.list.select do |thread|
        thread.backtrace_locations&.any? { |frame| frame.path == worker_source && frame.base_label == "work" }
      end
    }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.001 while workers.call.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    original_workers = workers.call
    assert_equal 1, original_workers.length, "boot starts exactly one maintenance worker"
    identity = daemon.identity
    credentials = daemon.lineage.credentials

    2.times.map { Thread.new { daemon.lineage.adopt(identity: identity, credentials: credentials) } }
      .each(&:join)

    # Runner placement may still be opening its checkpoint store and reading
    # Git pipes. Those short-lived threads do not own credential maintenance.
    assert_equal original_workers, workers.call, "adopting twice at once keeps the one maintenance worker"
    daemon.stop
    assert_empty workers.call, "stop ends the maintenance worker"
    assert(booted.none?(&:alive?), "no daemon thread outlives stop")
    refute File.exist?(daemon.home.announcement_path)
  end

  # `stop` now always joins the maintenance worker; its condition is what keeps that
  # from costing an idle daemon the whole drain deadline. A sleeping thread is
  # woken, sees `@stopping`, and exits at once — an implementation that joins
  # against a plain hourly sleep would sit here for the full deadline instead.
  def test_shutdown_does_not_wait_out_the_renewal_interval_on_an_idle_daemon
    daemon = connected_boot(renewal_interval: 3600)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    daemon.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, Rho::Daemon::Maintenance::RENEWAL_DRAIN_DEADLINE,
      "an idle maintenance worker must exit on its condition, not the deadline"
  end

  # `OAuth#rotate!` presents the refresh token and only then writes the
  # replacement, so a kill landing on that socket read leaves the spent token as
  # the only one on disk. The next boot presents it again, the kernel reads that
  # as replay, and the family is revoked — a connection destroyed by the orderly
  # shutdown that was supposed to protect it.
  def test_shutdown_waits_for_a_rotation_whose_token_is_already_spent
    now = Time.now
    rotating = Queue.new
    gate = Queue.new
    oauth = NexusDoubles::FakeOAuth.new
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" && params[:grant_type] == "refresh_token"
        rotating << true
        gate.pop
      end
      super(path, params, timeout: timeout)
    end

    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new,
      clock: -> { now }, renewal_interval: 0.02)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    vault = daemon.identity.vault
    assert_equal 0, vault.read.fetch("rotation")

    now += 8 * 24 * 60 * 60
    rotating.pop # the rotation is in flight and its token is already presented

    stopping = Thread.new { daemon.stop }
    sleep 0.15
    assert stopping.alive?, "shutdown must not abandon a rotation the kernel may already have redeemed"

    gate << true
    stopping.join(10)
    refute stopping.alive?, "and must not wait for it forever either"
    assert_equal 1, vault.read.fetch("rotation"), "the replacement must be on disk before the process goes"
  end

  # The SDK masks Thread#kill after a rotation answer exists until the
  # replacement token is durable. If that commit outlives the polite renewal
  # drain deadline, `kill` is only queued; it does not make the writer dead.
  # Stop must join after requesting the kill and keep the home claimed until
  # the masked store write completes.
  def test_shutdown_does_not_release_the_home_while_a_killed_renewal_is_still_committing
    now = Time.now
    daemon = boot(
      device_flow: connection_device_flow,
      api_transport: NexusDoubles::FakeAgentApi.new,
      clock: -> { now },
      renewal_interval: 0.02
    )
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    credentials = daemon.lineage.credentials.agent
    store = credentials.send(:instance_variable_get, :@store)
    committing = Queue.new
    allow_commit = Queue.new
    original = store.method(:write)
    store.define_singleton_method(:write) do |document|
      if document.fetch("rotation") > 0
        committing << true
        allow_commit.pop
      end
      original.call(document)
    end

    now += 8 * 24 * 60 * 60
    committing.pop
    @daemons.delete(daemon)
    stopping = Thread.new { daemon.stop }
    stopping.report_on_exception = false
    sleep(Rho::Daemon::Maintenance::RENEWAL_DRAIN_DEADLINE + 0.1)

    assert stopping.alive?,
      "a queued Thread#kill must not be mistaken for a terminated masked writer"
    assert_raises(Rho::AlreadyRunning) do
      Rho::Daemon.boot(home: Rho::Home.resolve(base_url: "https://nexus.example", root: @root))
    end

    allow_commit << true
    refute_nil stopping.join(10)
    replacement = boot(
      device_flow: connection_device_flow,
      api_transport: NexusDoubles::FakeAgentApi.new
    )
    assert_equal :active, replacement.phase
    assert_equal 1,
      replacement.lineage.credentials.rotation(:member), "the agent lineage's rotation was written down"
  ensure
    allow_commit&.push(true)
    stopping&.kill if stopping&.alive?
  end

  # Status only projects memory. A stale read wakes the one maintenance worker,
  # and shutdown drains that owner before releasing the home; it never waits on
  # the status handler itself or leaves a background writer behind.
  def test_shutdown_waits_for_background_authority_maintenance_before_releasing_the_home
    now = Time.now
    daemon = connected_boot(clock: -> { now })
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    # Finish the adoption wake before gating the stale read's own probe.
    await_workspace_state(daemon, "adopted", token: token)
    wait_for { !daemon.maintenance.running? }
    now += Rho::Daemon::Lineage::AUTHORITY_OBSERVATION_INTERVAL + 1

    reached_probe = Queue.new
    allow_probe = Queue.new
    calls = []
    # Count the worker's probe, not shared API paths: the executor plane's
    # announcements and declaration reads use those paths concurrently.
    daemon.maintenance.define_singleton_method(:authority_snapshot) do |about: nil|
      calls << about
      if calls.length == 1
        reached_probe << true
        allow_probe.pop
      end
      super(about: about)
    end

    probing = Thread.new { request(daemon, :get, "/status", token: token) }
    probing.report_on_exception = false
    reached_probe.pop
    refute_nil probing.join(1), "status must return without waiting for the Nexus probe"
    assert_equal "signed_in", JSON.parse(probing.value.body).dig("authority", "signed")
    10.times do
      body = JSON.parse(request(daemon, :get, "/status", token: token).body)
      assert_equal "signed_in", body.dig("authority", "signed")
    end
    assert_equal 1, calls.length,
      "a burst of stale status reads must coalesce into the maintenance cycle already running"

    @daemons.delete(daemon)
    stopping = Thread.new { daemon.stop }
    stopping.report_on_exception = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until daemon.phase == :draining ||
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert_equal :draining, daemon.phase

    assert_raises(Rho::AlreadyRunning) do
      Rho::Daemon.boot(home: Rho::Home.resolve(base_url: "https://nexus.example", root: @root))
    end
    allow_probe << true
    refute_nil probing.join(10)
    refute_nil stopping.join(10)
    assert_equal "200", get(
      boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new),
      "/healthz"
    ).code
  ensure
    allow_probe&.push(true)
    probing&.kill if probing&.alive?
    stopping&.kill if stopping&.alive?
  end
  # THE SIDE SWEEP RIDES THE CYCLE (rho's 24 h TTL, never the kernel's): a side row idle past the TTL under the adopted workspace is
  # deleted through the kernel's door by the maintenance worker, with no
  # verb typed — the wiring, not the sweep's own rule (runs_test has that).
  def test_the_maintenance_cycle_sweeps_an_idle_side
    now = Time.utc(2026, 9, 10, 12)
    api = NexusDoubles::FakeAgentApi.new(conversation_events: [])
    daemon = boot(device_flow: connection_device_flow, api_transport: api, clock: -> { now },
      renewal_interval: 0.02)
    token = connect(daemon)
    workspace = await_workspace_state(daemon, "adopted", token: token).dig("workspace", "public_id")
    stale = { "parent" => "c-1", "tools" => "write", "opened_at" => (now - 90_000).iso8601,
              "last_turn_at" => (now - Rho::Daemon::HostFollowers::SIDE_IDLE_TTL - 1).iso8601 }
    host_store(daemon)
      .remember(Rho::Host::Conversation.new(public_id: "c-1-side"), workspace: workspace, model: "m/x",
        notes: { "rho.side" => stale })

    wait_for(5) { api.conversation_deletes.include?("c-1-side") }

    assert_empty host_store(daemon).rows, "the row went with it"
  end
end
