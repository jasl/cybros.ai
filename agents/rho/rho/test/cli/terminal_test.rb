require "test_helper"
require "tempfile"

# `Rho::Cli::Terminal` as a library: the LINES the shipped verbs print
# from the documents the core answers — `report_turn` (`rho run`'s header,
# rho-dev's `do`), `report_said`, `report_stopped`, `report_status`, the
# disconnect lines — and the ceremony's wait-and-print (`Connect`)
# against a real daemon and against scripted ones that misbehave in every
# way the poll must survive. `core_test.rb` pins the documents; the
# shipped lines name no rho-dev verb (`shipped_hints_test`).
class CliTerminalTest < Minitest::Test
  include RhoTest::CliHarness

  IDS = { "conversation" => { "public_id" => "c-9" }, "turn" => { "public_id" => "t-9" },
          "loop" => { "public_id" => "al-9" } }.freeze

  # `rho do`, as the binary composes it: the core opens, the terminal prints.
  def do_turn(**arguments, &fold)
    terminal = cli
    terminal.report_turn(terminal.core.open_conversation(**arguments, &fold))
  end

  def say_to(public_id, text, **arguments)
    terminal = cli
    terminal.report_said(terminal.core.say(public_id, text, **arguments))
  end

  def stop(public_id, task_key = nil, **arguments)
    terminal = cli
    terminal.report_stopped(terminal.core.stop(public_id, task_key, **arguments))
  end

  def lines = @out.string.lines.map(&:chomp)

  def reset_out = (@out = StringIO.new)

  # ---- rho do ----

  # THE OUTPUT CONTRACT:
  # `conversation:`, `turn:`, `loop:` — the paid lanes parse `^loop:` —
  # then `compose:` with the tier and its source, then the one line an
  # extension's flags put on the body; no `status:` and no `tools:`.
  def test_report_turn_prints_the_three_ids_the_tier_and_the_acceptance_check
    announce(endpoint: recording_endpoint([], 201, IDS.merge(
      "compose" => { "on" => false, "source" => "flag" },
      "until" => { "command" => "make test", "attempts" => 3, "directory" => "/srv/app" }
    )))

    answer = do_turn(prompt: "fix it", model: "m/x", directory: "/srv/app", compose: false)

    assert_equal "al-9", answer.dig("loop", "public_id"), "the document is answered back"
    assert_equal ["conversation: c-9", "turn:         t-9", "loop:         al-9",
                  "compose:      off (flag)",
                  "until:        make test (3 checks, in /srv/app)"], lines
  end

  # THE CHECK ON A RUNNER ELSEWHERE: the line names the
  # runner the answer carries, and the directory only when one is known.
  def test_the_until_line_names_a_remote_runner_and_its_directory_when_known
    announce(endpoint: recording_endpoint([], 201, IDS.merge(
      "until" => { "command" => "make test", "attempts" => 3, "directory" => "/srv/app", "runner" => "R1" }
    )))
    do_turn(prompt: "fix it")
    assert_equal "until:        make test (3 checks, on runner R1 in /srv/app)", lines.last

    reset_out
    announce(endpoint: recording_endpoint([], 201, IDS.merge("until" => { "command" => "make test", "attempts" => 3, "runner" => "R1" })))
    do_turn(prompt: "fix it")
    assert_equal "until:        make test (3 checks, on runner R1)", lines.last
  end

  # The tier line reads the tier off the answer; a pending turn prints the
  # conversation and `pending`, nothing else of the ids.
  def test_report_turn_prints_the_daemons_tier_and_a_pending_turn
    announce(endpoint: recording_endpoint([], 201, IDS.merge("compose" => { "on" => true, "source" => "default" })))
    do_turn(prompt: "fix it")
    assert_equal ["conversation: c-9", "turn:         t-9", "loop:         al-9", "compose:      on (default)"], lines

    reset_out
    announce(endpoint: recording_endpoint([], 201, { "conversation" => { "public_id" => "c-9" }, "pending" => true }))
    answer = do_turn(prompt: "fix it")
    assert answer.fetch("pending")
    assert_match(/^conversation: c-9$/, @out.string)
    assert_match(/^pending:/, @out.string)
    refute_match(/^(loop|turn|status|tools):/, @out.string)
  end

  # A PENDING TURN BEHIND THE KERNEL'S BETWEEN-TURN SUMMARY: the answer carries the summary's ids under `compaction`,
  # and the line says what runs first and names that loop as what it is
  # — never as `loop:`, which a lane would follow into the summarizer —
  # with the hint after it as on any pending turn.
  def test_report_turn_names_the_compaction_summary_that_runs_first_on_a_pending_turn
    announce(endpoint: recording_endpoint([], 201, { "conversation" => { "public_id" => "c-9" }, "pending" => true,
      "compaction" => { "turn" => { "public_id" => "t-s" }, "loop" => { "public_id" => "al-s" } } }))
    terminal = cli
    answer = terminal.report_turn(terminal.core.open_conversation(prompt: "fix it"), pending_hint: "`rho watch` follows it")
    assert answer.fetch("pending")
    assert_equal ["conversation: c-9",
                  "pending:      the turn has not started yet; a compaction summary runs first (loop al-s); `rho watch` follows it"],
      lines
    refute_match(/^loop:/, @out.string, "the summary's loop is never the turn's")
  end

  # A refusal prints nothing: the sentence is the verb's failure.
  def test_a_refused_open_prints_nothing
    announce(endpoint: recording_endpoint([], 422, { "error" => { "code" => "input_blocked", "message" => "blocked" } }))
    assert_raises(Rho::Error) { do_turn(prompt: "fix it") }
    assert_equal "", @out.string
  end

  # The staged pictures, the answerer and the access default print as
  # lines when the answer carries them, and not otherwise.
  def test_report_turn_prints_the_attachments_the_answerer_and_the_access_line
    announce(endpoint: recording_endpoint([], 201, IDS.merge(
      "attachments" => [{ "filename" => "shot.png", "content_type" => "image/png", "byte_size" => 512 }],
      "answered_by" => { "public_id" => "peer-1", "handle" => "lark" }, "access" => "none"
    )))
    do_turn(prompt: "review it")
    assert_match(%r{^attached:\s+shot\.png \(image/png, 512 B\)$}, @out.string)
    assert_match(/^agent:\s+@lark \(peer-1\)$/, @out.string)
    assert_match(/^access:\s+none \(restricted\)$/, @out.string)

    reset_out
    announce(endpoint: recording_endpoint([], 201, IDS))
    do_turn(prompt: "review it")
    refute_match(/^(agent|access|attached):/, @out.string, "no fact, no line")
  end

  # THE SLOT is printed from the create response's `runner:` — the kernel's
  # word for a FOREIGN executor: none bound says what will fail and how to
  # pick one; offline says the calls wait and which verb moves them; not
  # yet seen says the calls wait; online prints nothing; a daemon that
  # says nothing prints nothing.
  def test_report_turn_prints_the_runner_slot_for_none_offline_and_not_yet_seen
    ids = IDS.merge("compose" => { "on" => true, "source" => "default" })
    announce(endpoint: recording_endpoint([], 201, ids.merge("runner" => nil)))
    do_turn(prompt: "fix it")
    assert_equal ["conversation: c-9", "turn:         t-9", "loop:         al-9", "compose:      on (default)",
                  "runner:       none — environment tools will fail; pick one with rho runners use ID"], lines

    reset_out
    seen = (Time.now - 190).utc.iso8601
    announce(endpoint: recording_endpoint([], 201, ids.merge("runner" => {
      "executor_public_id" => "0199-h", "display_name" => "Elsewhere", "presence" => "offline", "last_seen_at" => seen,
    })))
    do_turn(prompt: "fix it")
    assert_equal "runner:       0199-h offline (last seen 3m ago) — tool calls wait for it; rho handoff moves them", lines.last

    reset_out
    announce(endpoint: recording_endpoint([], 201, ids.merge("runner" => { "executor_public_id" => "0199-h", "presence" => "not_yet_seen" })))
    do_turn(prompt: "fix it")
    assert_equal "runner:       0199-h not yet seen — tool calls wait for it", lines.last

    reset_out
    announce(endpoint: recording_endpoint([], 201, ids.merge("runner" => { "executor_public_id" => "0199-h", "presence" => "online" })))
    do_turn(prompt: "fix it")
    refute_match(/^runner:/, @out.string, "online prints nothing")

    reset_out
    announce(endpoint: recording_endpoint([], 201, ids.merge("pending" => true, "runner" => nil).except("turn", "loop")))
    do_turn(prompt: "fix it")
    assert_match(/^runner:       none — environment tools will fail/, @out.string, "a pending turn still says where it will run")
  end

  # ---- rho say ----

  def test_report_said_prints_the_state_the_addressee_the_pictures_and_the_runner_slot
    announce(endpoint: recording_endpoint([], 200,
      "input" => { "public_id" => "in-1", "state" => "steering" }))
    input = say_to("al-9", "look at the tests")
    assert_equal "steering", input.fetch("state"), "the input row is answered back"
    assert_equal ["queued:    in-1 (steering)"], lines

    reset_out
    announce(endpoint: recording_endpoint([], 200,
      "input" => { "public_id" => "in-2", "state" => "pending", "deliver_at" => "2026-09-16T09:20:00Z" },
      "addressed_to" => { "public_id" => "peer-1", "handle" => "lark" },
      "attachments" => [{ "filename" => "diagram.png", "content_type" => "image/png", "byte_size" => 188_416 }],
      "runner" => nil))
    say_to("c-9", "and you?", mode: "queue", to: "@lark")
    assert_equal ["queued:    in-2 (pending, scheduled for 2026-09-16T09:20:00Z)",
                  "to:        @lark (peer-1)",
                  "attached:  diagram.png (image/png, 184 KiB)",
                  "runner:    none — environment tools will fail; pick one with rho runners use ID"], lines

    reset_out
    announce(endpoint: recording_endpoint([], 200,
      "input" => { "public_id" => "in-3", "state" => "steering" },
      "runner" => { "executor_public_id" => "0199-h", "presence" => "offline", "last_seen_at" => (Time.now - 61).utc.iso8601 }))
    say_to("c-1", "more")
    assert_equal ["queued:    in-3 (steering)",
                  "runner:    0199-h offline (last seen 1m ago) — tool calls wait for it; rho handoff moves them"], lines
  end

  # ---- rho stop ----

  def test_report_stopped_prints_the_host_its_status_and_the_kernel_route_for_a_child
    announce(endpoint: recording_endpoint([], 200,
      "stopped" => { "host_type" => "agent_loop", "public_id" => "al-9", "status" => "canceling" }))
    stopped = stop("al-9", force: false, host_type: "agent_loop")
    assert_equal "canceling", stopped.fetch("status")
    assert_equal ["stopped:   al-9 (agent_loop)", "status:    canceling"], lines

    reset_out
    announce(endpoint: recording_endpoint([], 200,
      "stopped" => { "host_type" => "conversation", "public_id" => "c-child", "status" => "canceling", "followed" => false }))
    stop("c-child")
    assert_equal ["stopped:   c-child (conversation)", "status:    canceling", "followed:  no — canceled through the kernel"], lines
    refute_includes @out.string, "rho attach", "no verb is named that cannot take a conversation id"

    reset_out
    announce(endpoint: recording_endpoint([], 200,
      "stopped" => { "host_type" => "task", "public_id" => "r3t1", "status" => "canceled", "loop" => "al-9" }))
    stop("c-1", "r3t1")
    assert_equal ["stopped:   r3t1 (task)", "status:    canceled"], lines
  end

  # ---- rho connect ----

  # The ceremony as a person runs it: the code on screen, then who they became.
  def test_connect_drives_a_running_daemon_and_reports_who_it_became
    boot

    cli.connect

    assert_match(/Open https:\/\/nexus\.example\S* and enter: BCDF-GHJK/, @out.string)
    assert_match(/Connected as 0199-user/, @out.string)
  end

  # The connect line per mode (crit-product S-2), and `rho status` in
  # runner mode.
  def test_connect_names_what_got_paired_per_mode
    boot
    cli.connect
    assert_match(/^Connected as 0199-user — agent 0199-executor, runner 0199-runner \(private to you\)\.$/, @out.string)
    @daemons.pop.stop
    FileUtils.rm_rf(@root)
    FileUtils.mkdir_p(@root)

    boot(config: Rho::Config.from_hash("mode" => "agent"), extensions: [Rho::Extensions::Ops])
    reset_out
    cli.connect
    assert_match(/^Connected as 0199-user — agent 0199-executor\.$/, @out.string)
    assert_match(/^runner:    none selected — `rho run … --runner ID` names one$/, @out.string)
    @daemons.pop.stop
    FileUtils.rm_rf(@root)
    FileUtils.mkdir_p(@root)

    boot(config: Rho::Config.from_hash("mode" => "agent"), extensions: [Rho::Extensions::Ops])
    File.write(home.settings_path, JSON.generate("mode" => "agent", "runner" => "0199-elsewhere"))
    reset_out
    cli.connect
    assert_match(/^runner:    0199-elsewhere$/, @out.string, "the selection as the settings file says now")
    @daemons.pop.stop
    FileUtils.rm_rf(@root)
    FileUtils.mkdir_p(@root)

    boot(config: Rho::Config.from_hash("mode" => "runner"))
    reset_out
    cli.connect
    assert_match(/^Connected runner 0199-runner \(rho-runner on \S+\)\.$/, @out.string)
    reset_out
    cli.report_status
    assert_equal "mode:      runner", lines[1]
    refute_match(/^profile:/, @out.string)
    refute_match(/^executor:/, @out.string)
    assert_match(/^runner:    0199-runner (serving|stopped)/, @out.string)
  end

  # A health document the core refuses ends connect before any code prints.
  def test_a_live_health_response_without_a_version_fails_closed
    announce(endpoint: scripted_endpoint(health: { "status" => "ok" }, start: pending_start))

    error = assert_raises(Rho::ConnectionError) { cli.connect }

    assert_match(/valid health document/, error.message)
    refute_match(/Connected/, @out.string)
  end

  # ---- the poll's exits, each against a scripted daemon ----

  # The daemon's boot window answers 503 connection_bootstrapping while it
  # inspects durable staging — a state it resolves by itself. A connect racing
  # that window waits through it rather than reporting a failure that would be
  # gone on the next try; only the error's own code is retried, so every other
  # refusal still raises immediately.
  def test_connect_waits_out_the_daemons_bootstrapping_window
    announce(endpoint: scripted_endpoint(start: nil, starts: [
      [503, { "error" => { "code" => "connection_bootstrapping", "message" => "The stored Agent connection is still being checked" } }],
      [200, { "phase" => "active", "identity" => { "user_public_id" => "0199-user" } }],
    ]))

    cli.connect

    assert_match(/Connected as 0199-user/, @out.string)
  end

  # A ceremony the daemon itself refused to start: the answer carries an error
  # envelope, and the terminal must raise it as the failure it is rather than
  # printing a blank code line and polling for a ceremony that never began.
  def test_a_start_the_daemon_refused_is_raised_not_polled
    announce(endpoint: scripted_endpoint(start: { "phase" => "error", "error" => "the kernel refused this identifier" }))

    assert_match(/the kernel refused this identifier/, connect_error.message)
  end

  # A daemon that restarts mid-poll mints a new bearer, so every later poll
  # answers 401 — and without this exit the terminal would sleep-loop on it
  # forever, printing nothing.
  def test_a_poll_answered_with_anything_but_200_ends_the_wait
    announce(endpoint: scripted_endpoint(start: pending_start,
      statuses: [[401, { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }]]))

    assert_match(/stopped answering \(HTTP 401\)/, connect_error.message)
  end

  # A ceremony that failed reports through the connection document, and the
  # human gets the failure's own words.
  def test_a_ceremony_that_failed_mid_poll_raises_its_own_message
    announce(endpoint: scripted_endpoint(start: pending_start, statuses: [[200, {
      "state" => "disconnected", "connection" => { "phase" => "error", "error" => "activation failed: the vault is unwritable" },
    }]]))

    assert_match(/activation failed: the vault is unwritable/, connect_error.message)
  end

  def test_a_restore_that_failed_while_the_old_transport_stays_active_is_not_reported_as_success
    announce(endpoint: scripted_endpoint(start: pending_start, statuses: [[200, {
      "state" => "active", "authority" => { "signed" => "expired" },
      "connection" => { "phase" => "error", "error" => "profile restore failed" },
      "identity" => { "user_public_id" => "0199-user" },
    }]]))

    assert_match(/profile restore failed/, connect_error.message)
    refute_match(/Connected as/, @out.string)
  end

  # The daemon may time out its courtesy wait and answer only `starting` or
  # `activating`. The code can arrive on the first status poll, and that is
  # when the terminal must print it — exactly once — rather than printing
  # blanks from the bare start document.
  def test_a_bare_start_phase_prints_the_code_when_status_first_supplies_it
    announce(endpoint: scripted_endpoint(start: { "phase" => "starting" }, statuses: [
      [200, { "state" => "disconnected", "connection" => pending_start }],
      [200, {
        "state" => "active", "authority" => { "signed" => "signed_in" },
        "connection" => { "phase" => "active", "identity" => { "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" } },
        "identity" => { "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" },
      }],
    ]))

    cli.connect

    assert_equal 1, @out.string.scan(/enter: BCDF-GHJK/).length
    refute_match(/Open  and enter:/, @out.string)
    assert_match(/Connected as 0199-user/, @out.string)
  end

  # Disconnected with nothing in flight is not "still connecting": there is no
  # ceremony left to wait for, and waiting anyway is the silent forever-loop.
  def test_disconnected_with_nothing_in_flight_ends_the_wait
    announce(endpoint: scripted_endpoint(start: pending_start, statuses: [[200, { "state" => "disconnected" }]]))

    assert_match(/no longer in flight/, connect_error.message)
  end

  # ---- rho disconnect ----

  def test_disconnect_prints_what_was_revoked_and_the_connection_that_ended
    oauth = NexusDoubles::FakeOAuth.new
    daemon = boot(oauth: oauth)
    cli.connect
    reset_out

    document = cli.disconnect

    assert_equal %w[runner agent], document["revoked"]
    assert_equal [NexusDoubles::RUNNER_REFRESH_TOKEN, "rt-cybros-api-v1-a.b"], oauth.revocations
    assert_equal :disconnected, daemon.phase
    assert_equal ["Revoked the runner credential (0199-runner).",
                  "Disconnected from https://nexus.example as 0199-user."], lines
    reset_out
    cli.report_status
    assert_match(/state:     credentials expired/, @out.string)
  end

  def test_disconnect_runner_prints_the_unclaimed_count_and_rewrites_the_pointers_mode
    oauth = NexusDoubles::FakeOAuth.new
    unclaimed = { "kind" => "tool_call", "agent_loop_public_id" => "al-1", "conversation_public_id" => nil,
                  "parent_public_id" => nil, "task_key" => "t1", "tool_name" => "ls",
                  "tool_input" => {}, "tool_call_id" => "call-t1", "started_at" => "2026-09-07T00:00:00Z",
                  "deadline_at" => nil, "claimed" => false,
                  "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-runner" } }
    api = NexusDoubles::FakeAgentApi.new(claim: :taken,
      runner_inbox_tasks: [unclaimed, unclaimed.merge("task_key" => "t2", "tool_call_id" => "call-t2")])
    daemon = boot(oauth: oauth, api: api)
    cli.connect
    reset_out

    document = cli.disconnect(runner: true)

    assert_equal ["runner"], document["revoked"]
    assert_equal [NexusDoubles::RUNNER_REFRESH_TOKEN], oauth.revocations
    pointer = Rho::StateFile.new(home.connection_pointer_path).read
    assert_equal "agent", pointer.fetch("mode")
    refute pointer.key?("runner_executor_public_id")
    assert_equal :active, daemon.phase
    refute daemon.lineage.credentials.runner?
    assert_nil daemon.identity.runner_executor_public_id
    assert_equal ["Revoked the runner credential (0199-runner).",
                  "2 tasks addressed to this runner are unclaimed and will time out; rho handoff moves them first."], lines
    reset_out
    cli.report_status
    assert_match(/^runner:    not registered$/, @out.string)
  end

  def test_disconnect_refuses_with_work_in_flight_and_a_runner_this_home_never_paired
    daemon = boot
    cli.connect
    about = daemon.lineage.credentials
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 while daemon.lineage.runner(:runner).nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    daemon.lineage.take_runner(about, slot: :runner)
    busy = Object.new
    busy.define_singleton_method(:snapshot) { Struct.new(:in_flight).new(1) }
    busy.define_singleton_method(:stop) { nil }
    assert daemon.lineage.reserve_runner(about, slot: :runner)
    assert daemon.lineage.install_runner(about, busy, nil, slot: :runner)

    error = assert_raises(Rho::Error) { cli.disconnect }
    assert_equal "1 tool call(s) are running; stop them or wait before disconnecting", error.message
    @daemons.pop.stop
    FileUtils.rm_rf(@root)
    FileUtils.mkdir_p(@root)

    boot(config: Rho::Config.from_hash("mode" => "agent"), extensions: [Rho::Extensions::Ops])
    cli.connect
    error = assert_raises(Rho::Error) { cli.disconnect(runner: true) }
    assert_equal "this home never paired a runner (mode agent)", error.message
  end

  # ---- rho status ----

  def test_report_status_describes_the_daemon_and_the_identity_it_holds
    daemon = boot
    cli.connect
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 while daemon.lineage.runner(:runner).nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    reset_out

    cli.report_status

    assert_equal "nexus:     https://nexus.example", lines[0]
    assert_equal "mode:      full", lines[1], "the mode is the second line (crit-product S-1)"
    assert_equal "instance:  #{daemon.home.instance_id}", lines[2], "the per-home instance part after the mode"
    assert_match(/daemon:    running at http:/, @out.string)
    assert_match(/state:     signed in/, @out.string)
    assert_match(/profile:   0199-user/, @out.string)
    assert_match(/^handle:    @helper$/, @out.string, "the agent's own handle, as the last probe read it")
    assert_match(/executor:  0199-executor/, @out.string)
    # The coding set (including attachment import/publication), the processes pair and the checkpoint store's two
    # hidden names: a default-layout home opens a store for its placed runner.
    assert_match(/^runner:    0199-runner serving 19 tools \((socket connected|no socket), swept \d+\)$/, @out.string)
    assert_match(/  runner_transport: live/, @out.string)
    assert_match(/^adaptations: default \(gem\)$/, @out.string,
      "the default model's adaptation row and its source, off the daemon")
  end

  # THE WORKSPACE KIND: a person must tell rho's own dedicated
  # workspace from a room the knob named, and a failed ensure prints its code.
  def test_report_status_prints_the_workspace_kind_beside_its_name
    announce(endpoint: routed_endpoint(
      "GET /status" => [
        [200, { "state" => "active", "authority" => { "signed" => "signed_in" },
                "workspace" => { "state" => "adopted", "public_id" => "0199-room", "name" => "Team", "kind" => "room" } }],
        [200, { "state" => "active", "authority" => { "signed" => "signed_in" },
                "workspace" => { "state" => "adopted", "public_id" => "0199-mine", "name" => "Helper", "kind" => "dedicated" } }],
        [200, { "state" => "active", "authority" => { "signed" => "signed_in" },
                "workspace" => { "state" => "error", "code" => "not_a_room" } }],
      ],
      "GET /asks" => [[503, { "error" => { "code" => "executor_plane_unavailable", "message" => "none" } }]] * 3
    ))

    cli.report_status
    assert_match(/^workspace: room Team \(0199-room\)$/, @out.string, @out.string)
    cli.report_status
    assert_match(/^workspace: dedicated Helper \(0199-mine\)$/, @out.string, @out.string)
    cli.report_status
    assert_match(/^workspace: error \(not_a_room\)$/, @out.string, @out.string)
  end

  # A DECLINED STEP ON THE SHIPPED SURFACE, as the pushed stream narrates
  # it: the task's item names the failure, its round a moment later adds
  # the category and who declined — the line prints again with them and
  # with the CAPABILITY that goes on (a product home has no rho-dev verb);
  # the round's item carries no `on_failure`, so the task item's is
  # remembered, and an absorbed member is offered nothing.
  def test_a_declined_stand_names_the_capability_on_the_shipped_surface
    seen = {}
    terminal = cli
    stand = { "task_key" => "r2", "kind" => "model_task", "status" => "failed", "error_key" => "model_refused",
              "on_failure" => "halt", "agent_loop_public_id" => "al-9" }
    round = { "task_key" => "r2", "status" => "failed", "model" => "dev/primary", "finish_quality" => "refused",
              "refusal_category" => "cyber", "agent_loop_public_id" => "al-9" }
    [stand, round, stand.merge("task_key" => "m1", "on_failure" => "absorb"), round.merge("task_key" => "m1")]
      .each { |item| terminal.report_tasks({ "tasks" => [item] }, seen) }

    assert_equal ["  failed         r2  (model_refused)",
                  "  failed         r2  (model_refused: cyber — declined by dev/primary; retry it on another " \
                  "model on the console, or start a new conversation)",
                  "  failed         m1  (model_refused)",
                  "  failed         m1  (model_refused: cyber — declined by dev/primary)"], lines
    refute_match(/rho retry/, @out.string, "the shipped surface names no rho-dev verb")
  end

  # THE PROFILE'S TWO MODELS, as the kernel answered the last declaration:
  # rho's own model and the fallback a declined step re-runs on — the read
  # that shows what the settings file stands for, since the file IS the
  # surface. Each says what its absence means; a daemon that has declared
  # nothing yet prints neither.
  def test_report_status_prints_the_declared_model_and_fallback
    declared = { "default_model" => "dev/primary", "fallback_model" => "dev/fallback" }
    announce(endpoint: routed_endpoint(
      "GET /status" => [
        [200, { "state" => "active", "authority" => { "signed" => "signed_in" }, "profile" => declared }],
        [200, { "state" => "active", "authority" => { "signed" => "signed_in" },
                "profile" => { "default_model" => nil, "fallback_model" => nil } }],
        [200, { "state" => "active", "authority" => { "signed" => "signed_in" } }],
      ],
      "GET /asks" => [[503, { "error" => { "code" => "executor_plane_unavailable", "message" => "none" } }]] * 3
    ))

    cli.report_status
    assert_match(/^model:     dev\/primary$/, @out.string, @out.string)
    assert_match(/^fallback:  dev\/fallback \(re-runs a step a provider declines or is overloaded for\)$/, @out.string, @out.string)
    reset_out
    cli.report_status
    assert_match(/^model:     none \(the initiator's model answers\)$/, @out.string, @out.string)
    assert_match(/^fallback:  none \(a declined or overloaded step fails\)$/, @out.string, @out.string)
    reset_out
    cli.report_status
    refute_match(/^(model|fallback):/, @out.string, "nothing declared yet, nothing claimed")
  end

  # THE DAEMON'S PENDING ASKS, LISTED: each question, then the
  # one line naming the console that answers them (a product home has no
  # `answer` verb; rho-dev's watch prints its own hint); a refused read
  # prints nothing; an empty inbox says so.
  def test_report_status_lists_the_pending_asks_and_says_nothing_when_the_read_is_refused
    announce(endpoint: routed_endpoint(
      "GET /status" => [[200, { "state" => "active", "authority" => { "signed" => "signed_in" } }]],
      "GET /asks" => [[200, { "asks" => [
        { "kind" => "ask", "agent_loop_public_id" => "al-9", "task_key" => "r1t0", "prompt" => "which database?" },
        { "kind" => "ask", "agent_loop_public_id" => "al-9", "task_key" => "r1t1", "prompt" => "x" * 100 },
      ] }], [503, { "error" => { "code" => "executor_plane_unavailable", "message" => "none" } }], [200, { "asks" => [] }]]
    ))

    cli.report_status
    assert_match(/^asks:      2 pending$/, @out.string)
    assert_match(/^  ask        al-9 r1t0  "which database\?"$/, @out.string)
    assert_match(/^  ask        al-9 r1t1  "#{"x" * 80}…"$/, @out.string)
    assert_match(/^console:   answer and decide them on the console: `rho console`$/, @out.string)
    refute_match(/rho answer/, @out.string, "the shipped status names no rho-dev verb")

    reset_out
    cli.report_status
    refute_match(/asks:/, @out.string, "a refused read prints nothing")
    cli.report_status
    assert_match(/^asks:      \(none\)$/, @out.string)
    assert_match(/^approvals: \(none\)$/, @out.string)
    refute_match(/^console:/, @out.string, "nothing to answer, nothing to point at")
  end

  # A daemon loaded without the Ops routes has no `/asks` and its webui
  # answers the unrouted GET with a page: `status` is a core verb and must
  # not die on an absent read.
  def test_report_status_survives_a_daemon_whose_asks_route_answers_a_page
    announce(endpoint: serve do |client, request|
      if request.start_with?("GET /healthz")
        answer(client, 200, "status" => "ok", "version" => Rho::VERSION, "control_version" => Rho::Daemon::ANNOUNCEMENT_VERSION)
      elsif request.start_with?("GET /status")
        answer(client, 200, "state" => "active", "authority" => { "signed" => "signed_in" })
      else
        body = "<!doctype html><title>rho</title>"
        client.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      end
    end)

    cli.report_status

    assert_match(/^state:     signed in$/, @out.string)
    refute_match(/asks:/, @out.string)
  end

  # THE HELD CALLS: under `approvals:` — tool, an argument
  # excerpt — after the `asks:` block, then the console line. The excerpt
  # is the command when the tool takes one, else the arguments as JSON;
  # bounded, one line; the verbs that decide it are rho-dev's, on its own
  # renderers, never here.
  def test_report_status_lists_the_held_calls_under_approvals_and_names_the_console
    long = "printf #{"x" * 100} > out.txt"
    announce(endpoint: routed_endpoint(
      "GET /status" => [[200, { "state" => "active", "authority" => { "signed" => "signed_in" } }]],
      "GET /asks" => [[200, { "asks" => [
        { "kind" => "approval", "agent_loop_public_id" => "al-9", "task_key" => "r1t0", "tool_name" => "bash",
          "tool_input" => { "command" => "git push --force origin main" } },
        { "kind" => "approval", "agent_loop_public_id" => "al-9", "task_key" => "r1t1", "tool_name" => "bash", "tool_input" => { "command" => long } },
        { "kind" => "approval", "agent_loop_public_id" => "al-9", "task_key" => "r1t2", "tool_name" => "start_process",
          "tool_input" => { "command" => "sh -c 'a\nb'" } },
        { "kind" => "approval", "agent_loop_public_id" => "al-9", "task_key" => "r1t3", "tool_name" => "write",
          "tool_input" => { "path" => "x.rb", "content" => "1" } },
        { "kind" => "ask", "agent_loop_public_id" => "al-9", "task_key" => "a1", "prompt" => "which database?" },
      ] }]]
    ))

    cli.report_status

    assert_includes lines, "asks:      1 pending"
    assert_includes lines, "approvals: 4 pending"
    assert_operator lines.index("asks:      1 pending"), :<, lines.index("approvals: 4 pending"), "asks first, then approvals"
    assert_includes lines, "  approval   al-9 r1t0  bash \"git push --force origin main\""
    assert_includes lines, "  approval   al-9 r1t1  bash \"#{long[0, 80]}…\""
    assert_includes lines, "  approval   al-9 r1t2  start_process \"sh -c 'a\\u000Ab'\""
    assert_includes lines, "  approval   al-9 r1t3  write \"{\"path\":\"x.rb\",\"content\":\"1\"}\""
    assert_includes lines, "  ask        al-9 a1  \"which database?\""
    assert_equal "console:   answer and decide them on the console: `rho console`", lines.last
    refute_match(/rho (approve|deny|answer)/, @out.string, "the shipped status names no rho-dev verb")
  end

  def test_report_status_escapes_workspace_name_terminal_controls_on_one_line
    announce(endpoint: scripted_endpoint(start: pending_start, statuses: [[200, {
      "state" => "active", "authority" => { "signed" => "signed_in" },
      "workspace" => { "state" => "adopted", "name" => "safe\nforged\e]52;c;YQ==\a", "public_id" => "0199-workspace" },
    }]]))

    cli.report_status

    assert_equal ["workspace: safe\\u000Aforged\\u001B]52;c;YQ==\\u0007 (0199-workspace)\n"], @out.string.lines.grep(/\Aworkspace:/)
    refute_includes @out.string, "\e"
  end

  # The other two frozen mirrors: a typed failure never reads as pending,
  # and an unsettled cycle says so.
  def test_report_status_mirrors_the_workspace_error_and_pending_states
    announce(endpoint: scripted_endpoint(start: pending_start, statuses: [
      [200, { "state" => "active", "authority" => { "signed" => "signed_in" }, "workspace" => { "state" => "error", "code" => "transport_error" } }],
      [200, { "state" => "active", "authority" => { "signed" => "signed_in" }, "workspace" => { "state" => "pending" } }],
    ]))

    cli.report_status
    cli.report_status

    assert_includes @out.string.lines, "workspace: error (transport_error)\n"
    assert_includes @out.string.lines, "workspace: pending\n"
  end

  # A daemon that restarted between the liveness probe and the read mints
  # a new bearer and answers 401 with a body that has no `state`. Reporting
  # that would print a blank `state:` line as if it were an answer.
  def test_a_restarted_daemon_is_refused_rather_than_reported_blank
    announce(endpoint: refusing_endpoint)

    error = assert_raises(Rho::ConnectionError) { cli.report_status }

    assert_match(/stopped answering \(HTTP 401\)/, error.message)
    assert_empty @out.string.lines.grep(/^state:/), "a refusal must not also print a state"
  end

  # THE STORED BRANCH prints the instance too: the id is the
  # home's, so a daemon need not be running to say which install this is.
  def test_offline_status_prints_the_instance_after_the_mode
    daemon = boot
    cli.connect
    daemon.stop
    reset_out

    cli.report_status

    assert_equal "mode:      full", lines[1]
    assert_equal "instance:  #{home.instance_id}", lines[2]
    assert_equal "daemon:    not running", lines[3]
    assert_match(/state:     connected \(no daemon running\)/, @out.string)
  end

  def test_offline_status_refuses_an_old_runner_pointer
    home.prepare
    Rho::StateFile.new(home.connection_pointer_path).write(
      "version" => Rho::Identity::SESSION_VERSION - 1, "branch" => "runner", "executor_public_id" => "0199-old-runner"
    )

    cli.report_status

    assert_equal "daemon:    not running", lines[3], "the header lines print before the verification"
    assert_match(/state:     unreadable/, @out.string)
    refute_match(/connected \(no daemon running\)/, @out.string)
  end

  private

    # Runs `connect` with a bound, because the failure mode these tests pin is
    # a poll that never exits: a deleted guard must read as a clean failure
    # here, not as a suite that hangs.
    def connect_error
      thread = Thread.new do
        cli.connect
        nil
      rescue Rho::ConnectionError => error
        error
      end
      finished = thread.join(10)
      thread.kill if finished.nil?
      refute_nil finished, "the poll must exit rather than loop"
      refute_nil thread.value, "connect must fail, not succeed"
      thread.value
    end
end
