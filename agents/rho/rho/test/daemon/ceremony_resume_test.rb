require "test_helper"

# THE BOOT-TIME RESUME: a restart is
# invisible, a won ceremony that failed to file is finished rather than
# repeated, and both credential planes are re-read before the stored
# connection is adopted.
class CeremonyResumeTest < Minitest::Test
  include RhoTest::DaemonHarness

  # Slice 5's exit evidence: a restart is invisible. The daemon comes back
  # connected, as the same identity, with no second ceremony — the fake wire
  # would answer one, so the proof is that it is never asked.
  def test_a_restart_comes_back_connected_without_a_second_ceremony
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    @daemons.pop.stop

    oauth = NexusDoubles::FakeOAuth.new
    restarted = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)

    assert_equal "active", body["state"]
    assert_equal "0199-user", body.dig("identity", "user_public_id")
    assert_equal restarted.home.instance_id, body.dig("identity", "instance_id"),
      "the status names the install `rho status` prints: the home's own instance id"
    assert_match Rho::Home::INSTANCE_ID, body.dig("identity", "instance_id")
    assert_empty oauth.requests, "a restart that re-ran the ceremony is not a restart"
  end

  # The announcement is what a client reads before it has spoken to anything,
  # so a connected daemon must be identifiable from the file alone.
  def test_the_announcement_carries_the_connected_identity
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)

    document = announcement(daemon)
    assert_equal "active", document["state"]
    assert_equal "0199-user", document.dig("identity", "user_public_id")
  end

  # A stored connection pointing at a different Nexus must never be adopted —
  # the installation key is a digest, so a copied tree looks native.
  def test_a_stored_connection_from_another_nexus_leaves_the_daemon_disconnected
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    identity = daemon.identity
    @daemons.pop.stop
    session = identity.session
    session.write(session.read.merge("base_url" => "https://elsewhere.example"))

    restarted = boot
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)
    assert_equal "disconnected", body["state"]
    assert_match(/different Nexus/, body["error"])
  end

  # The rule staging exists to enforce, on the path `rho server` and the webui
  # actually use. A won ceremony that could not be filed must be finished, not
  # repeated: a later winning Consume re-pairs the same address, advances its
  # epoch, and fences the staged bundle this machine still needs to install.
  def test_a_won_ceremony_that_failed_to_file_is_finished_not_repeated
    oauth = NexusDoubles::FakeOAuth.new
    api = HealableApi.new
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api)
    token = bearer(daemon)
    start_and_fail(daemon, token: token)
    assert_equal 1, oauth.requests.count { |path, _| path == "/oauth/device_authorization" }

    api.heal
    healed = request(daemon, :post, "/device/start", token: token)
    assert_equal "200", healed.code

    body = await_state(daemon, "active", token: token)
    assert_equal "0199-user", body.dig("identity", "user_public_id")
    assert_equal 1, oauth.requests.count { |path, _| path == "/oauth/device_authorization" },
      "the ceremony was already won; running it again would fence its staged bundle"
  end

  # And across a restart, without waiting for a human to click anything: the
  # pointer is written last, so "no pointer but a staged bundle" is exactly
  # what a failed activation leaves behind.
  def test_a_restart_finishes_a_ceremony_that_was_won_before_the_crash
    daemon = boot(device_flow: connection_device_flow, api_transport: HealableApi.new)
    start_and_fail(daemon, token: bearer(daemon))
    @daemons.pop.stop

    oauth = NexusDoubles::FakeOAuth.new
    restarted = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new)
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)

    assert_equal "active", body["state"]
    assert_equal "0199-user", body.dig("identity", "user_public_id")
    assert_empty oauth.requests, "the won bundle was on disk; nothing needed asking again"
  end

  def test_a_restart_finishes_an_agent_only_restore_without_losing_its_runner
    oauth = NexusDoubles::FakeOAuth.new
    api = NexusDoubles::SelectiveApi.new
    fail_install = false
    api.define_singleton_method(:call) do |path, **options|
      if fail_install && options[:credential] != NexusDoubles::RUNNER_TOKEN
        CybrosAgent::Response.new(status: 500, headers: {}, body: nil)
      else
        super(path, **options)
      end
    end
    oauth.define_singleton_method(:post) do |path, params, timeout:|
      if path == "/oauth/token" && params[:grant_type] == CybrosAgent::DeviceFlow::Client::DEVICE_GRANT &&
          branches.last == :agent
        fail_install = true
      end
      super(path, params, timeout: timeout)
    end
    daemon = boot(device_flow: connection_device_flow(oauth), api_transport: api)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    original = daemon.identity
    api.accept(NexusDoubles::MEMBER_TOKEN, false)
    api.accept(NexusDoubles::TRANSPORT_TOKEN, false)

    body = start_and_fail(daemon, token: token)

    assert_equal "agent", body.dig("connection", "branch")
    assert_equal [:combined, :agent], oauth.branches
    assert_equal "agent", Rho::StateFile.new(daemon.home.pending_connection_path).read.fetch("branch")
    assert_equal original.pointer_document, Rho::StateFile.new(daemon.home.connection_pointer_path).read
    @daemons.pop.stop

    resumed_oauth = NexusDoubles::FakeOAuth.new
    restarted = boot(device_flow: connection_device_flow(resumed_oauth),
      api_transport: NexusDoubles::FakeAgentApi.new)

    assert_equal :active, restarted.phase
    assert_equal original.runner_executor_public_id, restarted.identity.runner_executor_public_id
    assert_equal NexusDoubles::RUNNER_TOKEN, restarted.lineage.credentials.runner_credential
    assert_equal restarted.identity.pointer_document, Rho::StateFile.new(restarted.home.connection_pointer_path).read
    assert_nil Rho::StateFile.new(restarted.home.pending_connection_path).read
    assert_empty resumed_oauth.requests, "the staged Agent grant must resume without re-pairing either address"
  end

  # Pointer/session equality proves only what was written last time. Every
  # boot re-reads both credential planes before it finishes reconnecting. A
  # pair of resource 401s does not prove terminal lineage loss, so the durable
  # connection remains active but its authority is honestly expired; the
  # future Task runtime separately requires a live transport before serving.
  def test_boot_bootstraps_both_planes_before_it_adopts_stored_credentials
    daemon = connected_boot
    request(daemon, :post, "/device/start", token: bearer(daemon))
    await_state(daemon, "active", token: bearer(daemon))
    @daemons.pop.stop

    refusing = NexusDoubles::SelectiveApi.new(
      accept: {
        NexusDoubles::MEMBER_TOKEN => false,
        NexusDoubles::TRANSPORT_TOKEN => false,
        NexusDoubles::RUNNER_TOKEN => false,
      }
    )
    restarted = boot(device_flow: connection_device_flow, api_transport: refusing)

    assert_equal :active, restarted.phase
    plane_probes = refusing.calls.count { |path, _| %w[/agent_api/v1/profile /agent_api/v1/executor].include?(path) }
    assert_equal 3, plane_probes, "every plane of the mode, the runner's on its own credential"
    assert_includes refusing.calls, ["/agent_api/v1/profile", NexusDoubles::MEMBER_TOKEN]
    assert_includes refusing.calls, ["/agent_api/v1/executor", NexusDoubles::TRANSPORT_TOKEN]
    assert_includes refusing.calls, ["/agent_api/v1/executor", NexusDoubles::RUNNER_TOKEN]
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)
    assert_equal "expired", body.dig("authority", "signed")
    refute_nil body.dig("authority", "measured_at")
    # Settle the adoption-wake ensure (refused planes make it an error), then
    # hold the whole transport to a baseline: a fresh observation must keep
    # status reads free — no probe, and no workspace relist either.
    await_workspace_state(restarted, "error", token: bearer(restarted))
    baseline = refusing.calls.length
    3.times { request(restarted, :get, "/status", token: bearer(restarted)) }
    assert_equal baseline, refusing.calls.length,
      "status must reuse the boot observation instead of probing Nexus again"
  end

  # THE SETTINGS/POINTER RULE: a home paired in one mode and
  # booted in another is refused with the switch sentence.
  def test_a_pointer_whose_mode_disagrees_with_settings_is_refused_with_the_switch_sentence
    daemon = connected_boot
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    @daemons.pop.stop

    restarted = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new,
      config: runner_mode)
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)
    assert_equal "disconnected", body["state"]
    assert_equal "this home was paired in mode full; settings say runner — `rho disconnect`, " \
                 "then `rho server --mode runner` and `rho connect`", body["error"]
  end

  # agent→full is recoverable: the stored mode is a subset, the runner plane
  # reads absent, and `rho connect` opens the runner-only shape.
  def test_a_pointer_paired_in_agent_mode_boots_under_full_mode_as_recoverable
    daemon = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new,
      extensions: [Rho::Extensions::Ops], config: agent_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    @daemons.pop.stop

    restarted = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new)
    token = bearer(restarted)
    body = JSON.parse(request(restarted, :get, "/status", token: token).body)
    assert_equal "active", body["state"]
    assert_equal "full", body["mode"]
    assert_equal "absent", body.dig("authority", "planes", "runner_transport")
    assert_equal "signed_in", body.dig("authority", "signed"), "the runner plane never moves the login word"
    started = JSON.parse(request(restarted, :post, "/device/start", token: token).body)
    assert_equal %w[runner pending_runner], started.values_at("branch", "phase")
  end

  # A runner-mode restart resumes the one lineage from `runner_credentials.json`.
  def test_a_runner_mode_restart_resumes_the_one_lineage
    daemon = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new,
      config: runner_mode)
    token = bearer(daemon)
    request(daemon, :post, "/device/start", token: token)
    await_state(daemon, "active", token: token)
    identity = daemon.identity
    assert File.exist?(identity.runner_vault.path)
    refute File.exist?(identity.vault.path)
    @daemons.pop.stop

    oauth = NexusDoubles::FakeOAuth.new
    restarted = boot(device_flow: connection_device_flow(oauth), api_transport: NexusDoubles::FakeAgentApi.new,
      config: runner_mode)
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)
    assert_equal "active", body["state"]
    assert_equal "runner", body["mode"]
    assert_equal ["runner_transport"], body.dig("authority", "planes").keys
    assert_equal "signed_in", body.dig("authority", "signed")
    assert_equal "0199-runner", body.dig("identity", "runner_executor_public_id")
    refute body.key?("workspace")
    assert_empty oauth.requests
  end

  # A failed ceremony must not wedge the surface for the process's life. The
  # connection object is spent, but the daemon is not.
  def test_a_failed_ceremony_does_not_wedge_the_control_surface
    daemon = boot(device_flow: connection_device_flow(NexusDoubles::FakeOAuth.new), api_transport: HealableApi.new)
    token = bearer(daemon)
    body = start_and_fail(daemon, token: token)
    assert_equal "error", body.dig("connection", "phase")

    retried = JSON.parse(request(daemon, :post, "/device/start", token: token).body)
    refute_equal "error", retried["phase"], "a spent connection must be rebuilt, not memoized"
  end

  # A daemon that recovers must stop reporting why it once could not.
  def test_a_boot_time_failure_is_not_reported_beside_a_working_connection
    daemon = boot(device_flow: connection_device_flow, api_transport: HealableApi.new)
    start_and_fail(daemon, token: bearer(daemon))
    @daemons.pop.stop

    restarted = boot(device_flow: connection_device_flow, api_transport: NexusDoubles::FakeAgentApi.new)
    body = JSON.parse(request(restarted, :get, "/status", token: bearer(restarted)).body)

    assert_equal "active", body["state"]
    refute body.key?("error"), "a connected daemon must not still be explaining an old failure"
  end
end
