require "test_helper"

# ONE TEST PER INVARIANT of the one lock:
# every verb is one critical section, `about` is compared by identity, and
# nothing a verb hands back has been stopped or closed — the caller does
# that outside the monitor.
class LineageTest < Minitest::Test
  Lineage = Rho::Daemon::Lineage
  Workspace = Lineage::Workspace

  IDENTITY = Data.define(:user_public_id, :executor_public_id, :runner_executor_public_id).new(
    user_public_id: "user-1", executor_public_id: "executor-1", runner_executor_public_id: nil
  )
  LIVE = { planes: { member: :live, executor_transport: :live }, lost: false }.freeze

  def setup
    @now = Time.utc(2026, 9, 5, 12)
    @minted = []
    @lineage = Lineage.new(
      clock: -> { @now },
      realtime_factory: lambda do |credential|
        @minted << credential
        Struct.new(:credential).new(credential)
      end
    )
  end

  def about(token = "member-token")
    credential = Object.new
    credential.define_singleton_method(:member_credential) { token }
    credential.define_singleton_method(:runner) { nil }
    credential
  end

  def adopted(credential = about, report: nil)
    @lineage.adopt(identity: IDENTITY, credentials: credential, authority_report: report)
    credential
  end

  def fake_run(public_id, realtime: nil)
    follower = Object.new
    follower.define_singleton_method(:public_id) { public_id }
    follower.define_singleton_method(:realtime) { realtime }
    follower
  end

  def connection(phase:, oauth: nil)
    connection = Object.new
    connection.define_singleton_method(:phase) { phase }
    connection.define_singleton_method(:oauth) { oauth }
    connection.define_singleton_method(:to_h) { { "phase" => phase.to_s } }
    connection.define_singleton_method(:publish_pending) { |notify:| phase = :pending; self }
    connection
  end

  # ---- adopt ----

  def test_adopt_moves_every_fact_of_the_lineage_together
    credential = about
    adoption = @lineage.adopt(identity: IDENTITY, credentials: credential, authority_report: LIVE)

    assert adoption.changed
    assert_equal :stopped, adoption.from
    assert_equal :active, @lineage.phase
    assert_same credential, @lineage.credentials
    assert_same IDENTITY, @lineage.identity
    assert_equal Workspace.pending, @lineage.workspace
    assert_equal "signed_in", @lineage.status_document.dig(:authority, :signed)
    refute @lineage.status_document.key?(:error)
    assert_equal [false, credential, true], @lineage.maintenance_wait(0),
      "adoption wakes maintenance with the dirty bit set"
  end

  def test_adopting_the_same_object_again_only_refreshes_the_observation
    credential = adopted
    @lineage.install_follower(credential, fake_run("os-1"))
    before = @lineage.announcement_facts.generation

    adoption = @lineage.adopt(identity: IDENTITY, credentials: credential, authority_report: LIVE)

    refute adoption.changed
    assert_equal :active, adoption.from
    assert_equal 1, @lineage.followers.size, "a rotation keeps the followers"
    assert_equal "signed_in", @lineage.status_document.dig(:authority, :signed)
    assert_equal before, @lineage.announcement_facts.generation
  end

  def test_adopting_a_different_object_hands_back_the_old_lineages_runs_client_and_runner_unstopped
    old = adopted
    stopped = []
    runner = Object.new
    runner.define_singleton_method(:stop) { stopped << :runner }
    old_run = fake_run("os-1")
    @lineage.install_follower(old, old_run)
    client = @lineage.realtime_for(old)
    @lineage.reserve_runner(old)
    @lineage.install_runner(old, runner, :env)

    adoption = @lineage.adopt(identity: IDENTITY, credentials: about)

    assert_equal [old_run], adoption.retired.followers
    assert_same client, adoption.retired.realtime
    assert_equal [runner], adoption.retired.runners
    assert_equal [client], adoption.retired.clients
    assert_empty stopped, "the caller stops what it is handed, outside the monitor"
    assert_empty @lineage.followers
    assert_nil @lineage.realtime
    assert_nil @lineage.runner
  end

  def test_adopt_never_starts_a_thread
    before = Thread.list.size
    2.times.map { Thread.new { adopted } }.each(&:join)
    assert_equal before, Thread.list.size
  end

  def test_adopt_lost_holds_the_identity_and_records_the_loss_about_the_stored_credentials
    credential = about
    adoption = @lineage.adopt_lost(identity: IDENTITY, credentials: credential, report: Lineage::LOST_REPORT)

    assert adoption.changed
    assert_equal :disconnected, @lineage.phase
    assert_nil @lineage.credentials
    document = @lineage.status_document
    assert_equal "expired", document.dig(:authority, :signed)
    assert_equal "user-1", document.dig(:identity, :user_public_id)
  end

  # ---- lose ----

  def test_lose_is_a_no_op_for_a_stale_about_or_while_stopping_when_asked
    credential = adopted

    assert_nil @lineage.lose(about: about), "another object's loss is not this lineage's"
    @lineage.begin_stop
    assert_nil @lineage.lose(about: credential, unless_stopping: true)
    refute_nil @lineage.lose(about: credential), "stop does not veto a terminal loss it was not asked to"
  end

  def test_lose_ends_the_lineage_and_hands_back_everything_holding_its_credential
    credential = adopted(report: LIVE)
    @lineage.install_follower(credential, fake_run("os-1"))
    client = @lineage.realtime_for(credential)
    before = @lineage.announcement_facts.generation

    adoption = @lineage.lose(about: credential)

    assert_equal :active, adoption.from
    assert_equal :disconnected, @lineage.phase
    assert_nil @lineage.credentials
    assert_equal Workspace.pending, @lineage.workspace
    assert_equal 1, adoption.retired.followers.size
    assert_same client, adoption.retired.realtime
    assert_empty @lineage.followers
    assert_operator @lineage.announcement_facts.generation, :>, before
    assert_equal "expired", @lineage.status_document.dig(:authority, :signed)
    assert_equal @now.utc.iso8601, @lineage.status_document.dig(:authority, :measured_at)
  end

  def test_lose_keeps_a_foreign_slot_and_drops_only_the_dead_lineages_own
    credential = adopted
    pending = connection(phase: :pending)
    assert_equal :claimed, @lineage.claim_slot(pending)
    @lineage.lose(about: credential)
    assert_same pending, @lineage.connection, "a ceremony in flight belongs to nobody yet"

    replacement = adopted
    dead = connection(phase: :active, oauth: replacement)
    @lineage.release_slot(pending)
    assert_equal :claimed, @lineage.claim_slot(dead)
    @lineage.lose(about: replacement)
    assert_nil @lineage.connection, "the adopted connection whose OAuth object died goes with it"
  end

  # ---- writes gated on currency ----

  def test_commit_workspace_and_observe_write_only_for_the_current_lineage
    credential = adopted
    adopted_workspace = Workspace.adopted(public_id: "ws-1", name: "W")

    refute @lineage.commit_workspace(about, adopted_workspace)
    refute @lineage.observe(about, LIVE)
    assert @lineage.commit_workspace(credential, adopted_workspace)
    assert @lineage.observe(credential, LIVE)
    assert_equal adopted_workspace, @lineage.workspace
    assert_equal "signed_in", @lineage.status_document.dig(:authority, :signed)

    @lineage.begin_stop
    refute @lineage.commit_workspace(credential, Workspace.error(code: "x"))
    refute @lineage.observe(credential, LIVE)
    assert_equal adopted_workspace, @lineage.workspace
  end

  def test_member_plane_snapshot_pairs_the_workspace_with_the_lineage_that_adopted_it
    first = adopted
    @lineage.commit_workspace(first, Workspace.adopted(public_id: "ws-1", name: "W"))
    second = adopted

    workspace, credential = @lineage.member_plane_snapshot

    assert_same second, credential
    assert_equal Workspace.pending, workspace, "B never answers with A's workspace"
  end

  def test_record_not_durable_and_a_connection_error_show_in_status
    credential = adopted
    refute @lineage.record_not_durable(about, unless_stopping: false)
    assert @lineage.record_not_durable(credential, unless_stopping: false)
    assert_equal Lineage::NOT_DURABLE, @lineage.status_document[:error]

    @lineage.begin_stop
    refute @lineage.record_not_durable(credential, unless_stopping: true)
    @lineage.record_connection_error("boom")
    assert_equal "boom", @lineage.status_document[:error]
  end

  # ---- admission and shutdown ----

  def test_admit_refuses_once_stopping_and_release_lets_quiesce_return
    assert @lineage.admit
    @lineage.begin_stop
    refute @lineage.admit
    assert @lineage.stopping?

    quiescing = Thread.new { @lineage.quiesce(deadline: 5) }
    sleep 0.02
    assert quiescing.alive?, "one admitted handler keeps stop waiting"
    @lineage.release
    refute_nil quiescing.join(2)

    @lineage.abort_stop
    assert @lineage.admit
  end

  def test_quiesce_raises_at_its_deadline_with_a_handler_still_admitted
    @lineage.admit
    @lineage.begin_stop
    assert_raises(Rho::ConnectionError) { @lineage.quiesce(deadline: 0.05) }
  ensure
    @lineage.release
  end

  # ---- followers ----

  def test_install_run_is_idempotent_per_public_id
    credential = adopted
    first = fake_run("os-1")
    assert_equal [first, true], @lineage.install_follower(credential, first)
    assert_equal [first, false], @lineage.install_follower(credential, fake_run("os-1"))
    assert_equal [first], @lineage.followers
    assert_same first, @lineage.follower("os-1")
  end

  def test_install_run_after_lose_returns_the_run_without_registering_it
    credential = adopted
    @lineage.lose(about: credential)
    fresh = fake_run("os-1")

    assert_equal [fresh, false], @lineage.install_follower(credential, fresh)
    assert_empty @lineage.followers
    assert_equal [fresh, false], @lineage.install_follower(nil, fresh), "no lineage is not a lineage"
    assert_empty @lineage.followers
  end

  def test_realtime_for_mints_one_client_per_lineage_and_none_for_a_stale_about
    credential = adopted
    assert_nil @lineage.realtime_for(about)
    assert_empty @minted

    client = @lineage.realtime_for(credential)
    assert_same client, @lineage.realtime_for(credential)
    assert_same client, @lineage.realtime
    assert_equal 1, @minted.size
    assert_equal "member-token", @minted.first.call, "the lambda reaches the member credential outside the lock"

    @lineage.lose(about: credential)
    assert_nil @lineage.realtime_for(credential)
  end

  # THE EXECUTOR SOCKET is the member socket's twin on the
  # transport credential: one per lineage, none for a stale `about`, handed
  # back with the rest on every edge so the caller closes it — the lineage
  # owns its life, never the stream fiber.
  def test_executor_realtime_for_mints_one_client_per_lineage_and_retires_it_with_the_rest
    credential = about
    credential.define_singleton_method(:runner) { credential }
    credential.define_singleton_method(:runner_credential) { "runner-token" }
    adopted(credential)
    assert_nil @lineage.executor_realtime_for(about)

    client = @lineage.executor_realtime_for(credential)
    assert_same client, @lineage.executor_realtime_for(credential)
    assert_same client, @lineage.executor_realtime
    assert_equal 1, @minted.size
    assert_equal "runner-token", @minted.first.call, "the runner slot's socket reaches the runner credential"
    member = @lineage.realtime_for(credential)
    refute_same member, client, "two sockets: one bearer each"

    retired = @lineage.retire_runs
    assert_equal [client], retired.executor_realtimes
    assert_equal [member, client], retired.clients
    assert_nil @lineage.executor_realtime
    assert_raises(CybrosAgent::Error) { @minted.first.call }
  end

  # TWO SLOTS ON ONE ABOUT: the runner address's run and the agent address's, each with
  # its own socket on its own credential, both retired together with the lineage.
  def test_two_slots_hold_two_runners_and_two_sockets_on_one_about
    credential = about
    credential.define_singleton_method(:runner) { credential }
    credential.define_singleton_method(:executor_credential) { "transport-token" }
    credential.define_singleton_method(:runner_credential) { "runner-token" }
    adopted(credential)

    assert @lineage.reserve_runner(credential, slot: :runner)
    assert @lineage.reserve_runner(credential, slot: :agent_runner), "the other slot is free"
    assert @lineage.install_runner(credential, :serving, :env, slot: :runner)
    assert @lineage.install_runner(credential, :own, :env2, slot: :agent_runner)
    assert_equal :serving, @lineage.runner
    assert_equal :own, @lineage.runner(:agent_runner)
    assert_equal [:serving, :own], @lineage.runners
    assert_equal :env2, @lineage.tool_env(:agent_runner)
    refute @lineage.reserve_runner(credential, slot: :runner), "each slot holds one"

    runner_socket = @lineage.executor_realtime_for(credential, slot: :runner)
    agent_socket = @lineage.executor_realtime_for(credential, slot: :agent_runner)
    refute_same runner_socket, agent_socket
    assert_equal %w[runner-token transport-token], @minted.map(&:call).sort, "each socket on its own credential"
    assert_same runner_socket, @lineage.executor_realtime
    assert_same agent_socket, @lineage.executor_realtime(:agent_runner)

    assert_equal [:own, :env2], @lineage.take_runner(credential, slot: :agent_runner)
    assert_equal [:serving], @lineage.runners

    retired = @lineage.retire_runs
    assert_equal [:serving], retired.runners
    assert_equal [runner_socket, agent_socket], retired.executor_realtimes
    assert_empty @lineage.runners
    assert_nil @lineage.executor_realtime(:agent_runner)
  end

  def test_a_preserved_runner_reader_is_fenced_when_its_own_oauth_is_replaced
    oauth = Data.define(:executor_credential).new(executor_credential: "runner-token")
    old = Rho::Credentials.new(agent: about, runner: oauth)
    adopted(old)
    @lineage.reserve_runner(old)
    @lineage.install_runner(old, :serving, :env)
    socket = @lineage.executor_realtime_for(old)
    reader = @minted.last

    restored = Rho::Credentials.new(agent: about("new-agent"), runner: oauth)
    adoption = @lineage.adopt(identity: IDENTITY, credentials: restored)
    assert_empty adoption.retired.runners
    assert_same socket, @lineage.executor_realtime_for(restored)
    assert_equal "runner-token", reader.call
    refute @lineage.reserve_runner(restored), "the preserved slot belongs to the new holder"

    replacement = Rho::Credentials.new(agent: about, runner: oauth.with(executor_credential: "new-runner"))
    adoption = @lineage.adopt(identity: IDENTITY, credentials: replacement)
    assert_equal [:serving], adoption.retired.runners
    assert_equal [socket], adoption.retired.executor_realtimes
    assert_raises(CybrosAgent::Error) { reader.call }
  end

  # `adopt_runner` attaches the runner half under the monitor and moves the
  # identity with it; `lose_runner` drops that half, retires the :runner
  # slot and its socket ALONE, and the lineage still holds its about.
  def test_adopt_runner_and_lose_runner_move_the_runner_half_without_moving_the_lineage
    credential = Rho::Credentials.new(agent: about)
    adopted(credential)
    identity = Data.define(:user_public_id, :executor_public_id, :runner_executor_public_id)
      .new(user_public_id: "user-1", executor_public_id: "executor-1", runner_executor_public_id: "runner-1")
    runner_oauth = Object.new
    runner_oauth.define_singleton_method(:executor_credential) { "runner-token" }
    before = @lineage.announcement_facts.generation

    refute @lineage.adopt_runner(about, identity: identity, runner: runner_oauth), "a stale about adopts nothing"
    assert @lineage.adopt_runner(credential, identity: identity, runner: runner_oauth)
    assert_same runner_oauth, credential.runner
    assert_same identity, @lineage.identity
    assert_same credential, @lineage.credentials, "the lineage did not move"
    assert_operator @lineage.announcement_facts.generation, :>, before

    @lineage.reserve_runner(credential, slot: :runner)
    @lineage.install_runner(credential, :serving, :env, slot: :runner)
    @lineage.reserve_runner(credential, slot: :agent_runner)
    @lineage.install_runner(credential, :own, :env, slot: :agent_runner)
    socket = @lineage.executor_realtime_for(credential, slot: :runner)
    other = @lineage.executor_realtime_for(credential, slot: :agent_runner)

    assert_nil @lineage.lose_runner(about), "another object's loss is not this lineage's"
    retired = @lineage.lose_runner(credential)
    assert_equal [:serving], retired.runners
    assert_equal [socket], retired.executor_realtimes
    assert_empty retired.followers
    refute credential.runner?
    assert @lineage.holds?(credential)
    assert_equal :active, @lineage.phase
    assert_equal [:own], @lineage.runners, "the agent's own run stands"
    assert_same other, @lineage.executor_realtime(:agent_runner)
    assert_nil @lineage.lose_runner(credential), "nothing left to lose"
    assert @lineage.reserve_runner(credential, slot: :runner), "the slot is free for the next grant"
  end

  # A reservation given back without a runner — the executor plane had no
  # credential — so a later edge may place one; a held runner is not released.
  def test_release_runner_gives_back_only_an_unfilled_reservation
    credential = adopted
    assert @lineage.reserve_runner(credential)

    assert @lineage.release_runner(credential)
    refute @lineage.install_runner(credential, Object.new, :env), "no reservation stands to install on"
    assert @lineage.reserve_runner(credential), "free again"

    assert @lineage.install_runner(credential, Object.new, :env)
    refute @lineage.release_runner(credential), "a placed runner is taken, never released"
    refute_nil @lineage.runner
  end

  def test_the_realtime_credential_refuses_after_its_lineage_is_retired
    credential = adopted
    @lineage.realtime_for(credential)
    lambda = @minted.first

    @lineage.retire_runs

    assert_raises(CybrosAgent::Error) { lambda.call }
  end

  def test_a_blocked_member_credential_does_not_block_adopt_or_lose
    credential = about
    refreshing = Queue.new
    release = Queue.new
    credential.define_singleton_method(:member_credential) do
      refreshing << true
      release.pop
      "member-token"
    end
    adopted(credential)
    @lineage.realtime_for(credential)
    reading = Thread.new { @minted.first.call }
    refreshing.pop

    moved = Queue.new
    moving = Thread.new do
      @lineage.lose(about: credential)
      adopted
      moved << true
    end

    assert moved.pop(timeout: 2), "a rotation on the wire must not hold the lineage"
  ensure
    release&.push(true)
    reading&.join
    moving&.join
  end

  def test_retire_runs_empties_the_registry_before_anything_is_stopped
    credential = adopted
    shared = Object.new
    @lineage.install_follower(credential, fake_run("os-1", realtime: shared))
    @lineage.install_follower(credential, fake_run("al-1"))
    client = @lineage.realtime_for(credential)

    retired = @lineage.retire_runs

    assert_equal %w[os-1 al-1], retired.followers.map(&:public_id)
    assert_same client, retired.realtime
    assert_equal [shared, client], retired.clients
    assert_empty @lineage.followers
    assert_nil @lineage.realtime
    assert_equal [], @lineage.rebind_runs
  end

  def test_rebind_runs_answers_the_distinct_clients_the_runs_hold
    credential = adopted
    shared = Object.new
    @lineage.install_follower(credential, fake_run("os-1", realtime: shared))
    @lineage.install_follower(credential, fake_run("os-2", realtime: shared))
    @lineage.install_follower(credential, fake_run("al-1"))

    assert_equal [shared], @lineage.rebind_runs
  end

  # ---- the runner ----

  def test_at_most_one_runner_per_credential_object
    credential = adopted
    refute @lineage.reserve_runner(about), "a stale about reserves nothing"
    assert @lineage.reserve_runner(credential)
    assert @lineage.reserve_runner(credential), "a second builder may race; the install decides"
    assert @lineage.install_runner(credential, :first, :env)
    refute @lineage.install_runner(credential, :second, :env), "the loser stops what it built"
    refute @lineage.reserve_runner(credential), "an installed runner refuses another"
    assert_equal :first, @lineage.runner
    assert_equal :env, @lineage.tool_env
  end

  def test_install_runner_for_an_unreserved_about_is_refused
    credential = adopted
    refute @lineage.install_runner(credential, :runner, :env)
    assert_nil @lineage.runner

    @lineage.reserve_runner(credential)
    @lineage.begin_stop
    refute @lineage.install_runner(credential, :runner, :env), "nothing is installed while stopping"
  end

  def test_take_runner_removes_the_pair_only_for_its_about_and_lose_releases_a_reservation
    credential = adopted
    @lineage.reserve_runner(credential)
    @lineage.install_runner(credential, :runner, :env)

    assert_nil @lineage.take_runner(about)
    assert_equal [:runner, :env], @lineage.take_runner(credential)
    assert_nil @lineage.runner
    assert @lineage.reserve_runner(credential), "taking it frees the slot for a rebuild"

    @lineage.lose(about: credential)
    replacement = adopted
    assert @lineage.reserve_runner(replacement), "the dead lineage's reservation went with it"
  end

  # ---- the ceremony slot ----

  def test_claim_slot_answers_each_outcome_from_one_section
    @lineage.begin_stop
    assert_equal :stopping, @lineage.claim_slot(connection(phase: :idle))
    @lineage.abort_stop

    credential = adopted
    assert_equal :already_connected, @lineage.claim_slot(connection(phase: :idle), expected: about)
    assert_equal :claimed, @lineage.claim_slot(connection(phase: :idle), expected: credential)

    pending = connection(phase: :pending)
    assert_equal :claimed, @lineage.claim_slot(pending)
    joined = @lineage.claim_slot(connection(phase: :idle))
    assert_same pending, joined.connection

    @lineage.release_slot(pending)
    @lineage.lose(about: credential)
    assert_equal :stale, @lineage.claim_slot(connection(phase: :idle), expected: credential)
    assert_equal :claimed, @lineage.claim_slot(connection(phase: :idle), expected: nil),
      "after a loss, expecting no credential is the recovery's honest expectation"
  end

  def test_a_connection_active_under_another_credential_is_joinable_until_adopted
    adopted
    unadopted = connection(phase: :active, oauth: about)
    assert_equal :claimed, @lineage.claim_slot(unadopted)
    assert_same unadopted, @lineage.joinable

    assert_same unadopted, @lineage.claim_slot(connection(phase: :idle)).connection
    adopted(unadopted.oauth)
    assert_nil @lineage.joinable, "once adopted, its OAuth object is the lineage's own"
  end

  def test_publish_pending_makes_pending_and_its_poller_visible_together
    pending = connection(phase: :starting)
    @lineage.claim_slot(pending)
    ran = Queue.new

    document = @lineage.publish_pending(pending) { ran << Thread.current }

    assert_equal({ "phase" => "pending" }, document)
    poller = @lineage.slot_snapshot.poller
    refute_nil poller
    assert_same poller, ran.pop(timeout: 2)
    poller.join
    @lineage.release_poller(poller)
    assert_nil @lineage.slot_snapshot.poller
  end

  def test_release_slot_and_release_poller_drop_only_the_same_object
    first = connection(phase: :pending)
    @lineage.claim_slot(first)
    refute @lineage.release_slot(connection(phase: :pending))
    assert_same first, @lineage.connection

    @lineage.record_connection_error("stale")
    assert @lineage.release_slot(first, canceled: true)
    assert_nil @lineage.connection
    assert @lineage.slot_snapshot.last_cancel_succeeded
    refute @lineage.status_document.key?(:error), "a canceled ceremony's error must not haunt the status"

    thread = Thread.new { sleep 0.01 }
    @lineage.publish_pending(connection(phase: :starting)) { nil }
    @lineage.release_poller(thread)
    refute_nil @lineage.slot_snapshot.poller, "another thread's release is not this poller's"
  ensure
    thread&.join
    @lineage.slot_snapshot.poller&.join
  end

  # ---- maintenance ----

  def test_maintenance_stops_only_on_its_own_latch
    credential = adopted
    assert_equal [false, credential, true], @lineage.maintenance_wait(0)
    assert @lineage.maintenance_running?
    @lineage.maintenance_done
    refute @lineage.maintenance_running?

    @lineage.begin_stop
    assert_equal [false, nil, false], @lineage.maintenance_wait(0), "stopping only skips the work"
    @lineage.stop_maintenance
    assert_equal [true, nil, false], @lineage.maintenance_wait(60), "the latch wakes and ends the run"
  end

  def test_request_probe_coalesces_and_respects_a_fresh_observation
    @lineage.request_probe
    assert_equal [false, nil, false], @lineage.maintenance_wait(0), "no credentials, nothing to probe"
    @lineage.maintenance_done

    credential = adopted
    @lineage.maintenance_wait(0)
    @lineage.maintenance_done
    @lineage.observe(credential, LIVE)
    @lineage.request_probe
    assert_equal [false, credential, false], @lineage.maintenance_wait(0), "a fresh observation is not re-asked"
    @lineage.maintenance_done

    @now += Lineage::AUTHORITY_OBSERVATION_INTERVAL + 1
    refute @lineage.observation_fresh?(credential)
    @lineage.request_probe
    @lineage.request_probe
    assert_equal [false, credential, true], @lineage.maintenance_wait(0), "two stale reads are one request"
  end

  def test_mark_verified_answers_the_credentials_once_per_window
    assert_nil @lineage.mark_verified(@now)
    credential = adopted
    assert_same credential, @lineage.mark_verified(@now)
    assert_nil @lineage.mark_verified(@now + Lineage::VERIFY_WINDOW - 1)
    assert_same credential, @lineage.mark_verified(@now + Lineage::VERIFY_WINDOW)
  end

  # ---- phase and the announcement ----

  def test_transition_returns_the_phase_left_and_never_publishes
    assert_equal :stopped, @lineage.transition(:disconnected)
    assert_equal :disconnected, @lineage.transition(:draining)
    assert_equal :draining, @lineage.phase
  end

  def test_announcement_facts_are_one_snapshot_with_a_monotonic_generation
    generations = [@lineage.announcement_facts.generation]
    @lineage.transition(:disconnected)
    generations << @lineage.announcement_facts.generation
    credential = adopted
    generations << @lineage.announcement_facts.generation
    pending = connection(phase: :pending)
    @lineage.claim_slot(pending)
    facts = @lineage.announcement_facts
    generations << facts.generation
    @lineage.lose(about: credential)
    generations << @lineage.announcement_facts.generation

    assert_equal generations.sort, generations
    assert_equal generations.uniq, generations, "every edge bumps"
    assert_equal "active", facts.state
    assert_equal({ "phase" => "pending" }, facts.connection_document)
    assert_same IDENTITY, facts.identity
  end

  def test_bootstrap_is_a_latch_the_ceremony_flips
    assert @lineage.bootstrapping?
    @lineage.finish_bootstrap
    refute @lineage.bootstrapping?
    @lineage.begin_bootstrap
    assert @lineage.slot_snapshot.bootstrapping
  end

  def test_status_is_honest_before_any_lineage
    document = @lineage.status_document
    assert_equal "stopped", document[:state]
    assert_equal({ state: "pending" }, document[:workspace])
    refute document.key?(:authority)
    refute document.key?(:identity)
  end
end
