require "test_helper"
require "tmpdir"

# Real processes throughout: the properties here — the group is the unit,
# stdin never closes, TERM then KILL, the latch, the sweep — are about the
# operating system, and a fake would prove only the fake.
class ProcessesRegistryTest < Minitest::Test
  FAST = 0.3

  def setup
    @dir = Dir.mktmpdir("rho-processes")
    @state = Rho::StateFile.new(File.join(@dir, "processes.json"))
    @registry = build
    @rows = []
  end

  def teardown
    @registry.close
    FileUtils.rm_rf(@dir)
  end

  # THE KERNEL'S WORD ON THE ROW, as the execution context carries it to
  # every call: which conversation a loop belongs to. Two loops of one
  # conversation, one loop of another, and a loop the kernel named no
  # conversation for (a standalone loop) — nil.
  CONVERSATIONS = { "loop-a" => "conv-1", "loop-b" => "conv-1", "loop-c" => "conv-2" }.freeze

  def build(live_cap: 8)
    Rho::Processes::Registry.new(log_dir: File.join(@dir, "log"), state_file: @state, live_cap: live_cap)
  end

  # The four verbs as a tool calls them: the loop and its conversation
  # travel together, the way the context hands them over.
  def start(command, loop: nil, **options)
    @registry.start(command:, workdir: @dir, env: Rho::Runner::ChildEnv.call,
      loop: loop, conversation: CONVERSATIONS[loop], **options)
  end

  def fetch(id, by) = @registry.fetch(id, by: by, conversation: CONVERSATIONS[by])
  def stop(id, by, **options) = @registry.stop(id, by: by, conversation: CONVERSATIONS[by], **options)
  def notices(loop) = @registry.take_notices(loop, conversation: CONVERSATIONS[loop])

  def wait_for(seconds = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      flunk "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  # THE WATCHER'S CHANNEL: every completed line of a row the
  # table holds reaches the pump under the row's HOST — the conversation
  # the kernel named, else the loop itself — and its exit follows; a row
  # the person started reaches it under no host at all.
  def test_a_rows_lines_and_exit_reach_the_pump_under_the_rows_host
    pump = Rho::Processes::Pump.new(post: ->(_frame) { true }, sleeper: ->(_) { nil })
    seen = []
    pump.define_singleton_method(:line) { |id, host, text| seen << [:line, id, host, text] }
    pump.define_singleton_method(:exited) { |id, host, status| seen << [:exit, id, host, status] }
    @registry.close
    @registry = Rho::Processes::Registry.new(log_dir: File.join(@dir, "log"), state_file: @state, progress: pump)

    owned = start("echo hi; echo there; exit 2", loop: "loop-a")
    # A short process can reach EOF before the registry installs its row;
    # drive the daemon's ordinary recovery as well as the pump callback.
    wait_for do
      @registry.sweep_dead!
      seen.count { |kind, id, *| kind == :exit && id == owned.id } == 1
    end
    assert_equal [[:line, owned.id, { "conversation_public_id" => "conv-1" }, "hi"],
                  [:line, owned.id, { "conversation_public_id" => "conv-1" }, "there"],
                  [:exit, owned.id, { "conversation_public_id" => "conv-1" }, 2]], seen

    seen.clear
    standalone = start("echo solo", loop: "loop-z")
    wait_for do
      @registry.sweep_dead!
      seen.any? { |kind, id, *| kind == :exit && id == standalone.id }
    end
    assert_equal({ "agent_loop_public_id" => "loop-z" }, seen.first[2], "a standalone loop is its own host")

    seen.clear
    person = start("echo mine", loop: "user")
    wait_for do
      @registry.sweep_dead!
      seen.any? { |kind, id, *| kind == :exit && id == person.id }
    end
    assert seen.all? { |_kind, _id, host, *| host.nil? }, "a person's process is no host's frame: #{seen.inspect}"
  end

  def test_a_started_process_is_running_with_its_output_captured_and_logged
    row = start("echo hello; echo listening on 3000; sleep 30", name: "web", wait_for: "LISTENING ON")
    wait_for { row.output.matched? }

    snapshot = row.snapshot
    assert_equal "running", snapshot.status
    assert_equal "p1", snapshot.id
    assert_equal "web", snapshot.name
    assert_equal "listening on 3000", snapshot.ready_line
    assert_equal "hello", row.output.first_line
    assert File.file?(snapshot.log_path)
    assert_equal File.join(@dir, "log", "p1.log"), snapshot.log_path
    assert @registry.any_live?
  end

  # A leader that backgrounds the real server and exits: the group is the
  # unit, and it is still running until the pipe closes.
  def test_the_group_is_the_unit_not_the_leader
    row = start("sleep 30 & echo started; exit 0")
    wait_for { row.leader_exited? }

    snapshot = row.snapshot
    assert_equal "running", snapshot.status
    assert snapshot.leader_exited
    assert snapshot.output_open

    stopped = stop("p1", "user", grace: FAST)
    assert_equal "exited", stopped.status
    refute stopped.output_open, "KILL to the group closes the pipe"
  end

  def test_stdin_is_held_open_not_closed
    row = start("if read line; then echo data; else echo eof; fi; echo after", wait_for: "after")
    sleep FAST

    refute row.output.matched?, "the child saw EOF on stdin: #{row.output.lines(5)}"
    assert_equal "running", row.snapshot.status
  end

  def test_term_first_then_kill_for_a_process_that_ignores_term
    row = start('trap "" TERM; echo armed; while :; do sleep 1; done', wait_for: "armed")
    wait_for { row.output.matched? }

    snapshot = stop("p1", "user", grace: FAST)
    assert_equal "exited", snapshot.status
    assert_equal "KILL", snapshot.signal
    assert_equal "user", snapshot.stopped_by
  end

  def test_a_polite_process_exits_on_term_and_is_reaped
    row = start("sleep 30")
    snapshot = stop("p1", "user")

    assert_equal "exited", snapshot.status
    assert_equal "TERM", snapshot.signal
    assert_raises(Errno::ESRCH) { Process.kill(0, -row.pgid) }
  end

  # THE OWNER IS THE CONVERSATION: the loop that called is kept for display, and every
  # loop of that conversation may read and stop what one of them started; a loop of
  # another conversation is refused by name, the person never is.
  def test_the_owner_is_the_conversation_of_the_loop_that_started_it
    row = start("sleep 30", loop: "loop-a")

    snapshot = row.snapshot
    assert_equal "conv-1", snapshot.owner
    assert_equal "loop-a", snapshot.loop
    assert_same row, fetch("p1", "loop-b"), "a sibling loop of the conversation reads it"
    assert_same row, fetch("p1", "user")
    error = assert_raises(Rho::Processes::NotOwner) { fetch("p1", "loop-c") }
    assert_equal "p1 belongs to conversation conv-1; only its loops, or the person (rho kill p1), may read it",
      error.message
    error = assert_raises(Rho::Processes::NotOwner) { stop("p1", "loop-c") }
    assert_equal "p1 belongs to conversation conv-1; only its loops, or the person (rho kill p1), may stop it",
      error.message
    assert_equal "exited", stop("p1", "loop-b").status
  end

  # A loop the kernel named no conversation for (a standalone loop is its
  # own host) owns by its own id, in every mode.
  def test_a_loop_with_no_conversation_owns_by_its_own_id
    start("sleep 30", loop: "loop-x")

    snapshot = @registry.snapshots.first
    assert_equal "loop-x", snapshot.owner
    assert_equal "loop-x", snapshot.loop
    error = assert_raises(Rho::Processes::NotOwner) { stop("p1", "loop-a") }
    assert_equal "p1 belongs to loop loop-x; only that loop, or the person (rho kill p1), may stop it", error.message
    assert_equal "exited", stop("p1", "loop-x").status
  end

  # THE DEAD CALL (item P, the primary path): a group that died leaves the
  # table; a read or a stop against its id answers the exit and says the
  # entry is gone; the next start is a NEW id — the old one never revives.
  def test_a_dead_group_leaves_the_table_and_a_call_against_it_names_the_exit_and_says_gone
    row = start("echo bye; exit 3", loop: "loop-a")
    wait_for { @registry.row("p1").nil? }

    refute row.live?
    assert_empty @registry.snapshots
    gone = assert_raises(Rho::Processes::Gone) { fetch("p1", "loop-c") }
    assert_equal "p1 exited with status 3, on its own; the entry is gone — start_process again gives a new id. " \
                 "Its log: #{row.output.path}", gone.message
    assert_equal "exited", gone.snapshot.status
    assert_equal 3, gone.snapshot.exit_status
    assert_raises(Rho::Processes::Gone) { stop("p1", "loop-b") }
    assert_equal "p2", start("sleep 30", loop: "loop-a").id
    assert_equal "p1", @registry.exit_of("p1").id
    lines = File.readlines(row.output.path, chomp: true, encoding: Encoding::UTF_8)
    assert_equal "bye", lines[0]
    assert_match(/\A\[rho\] p1: leader exited with status 3, on its own; the group ended at \d{4}-\d\d-\d\dT/, lines[1])
  end

  # An id the table never held is still "no process", with the live ids.
  def test_an_unknown_id_is_not_found_with_the_known_ids
    start("sleep 30", loop: "loop-a")

    error = assert_raises(Rho::Processes::NotFound) { fetch("p9", "loop-a") }
    refute_kind_of Rho::Processes::Gone, error
    assert_equal "no process p9; known: p1", error.message
  end

  # THE FALLBACK: the validity sweep removes what is dead and leaves what lives alone; the
  # exit memory behind the dead-call answer is bounded, oldest first.
  def test_the_sweep_removes_dead_groups_and_leaves_live_ones_alone
    dead = start("exit 0", loop: "loop-a")
    live = start("sleep 30", loop: "loop-a")
    wait_for { !dead.live? }

    @registry.sweep_dead!
    assert_nil @registry.row("p1")
    assert_same live, @registry.row("p2")
    assert_equal "running", live.snapshot.status
    assert_empty @registry.sweep_dead!, "a live group is never touched"
  end

  def test_the_exit_memory_is_bounded_oldest_first
    (Rho::Processes::Registry::EXITED_KEEP + 2).times do
      row = start("exit 0")
      # Establish retirement order, and drive the daemon's ordinary recovery
      # when the output pump finishes before the row is installed.
      wait_for do
        @registry.sweep_dead!
        @registry.row(row.id).nil?
      end
    end

    assert_nil @registry.exit_of("p1")
    assert_nil @registry.exit_of("p2")
    assert_equal "p3", @registry.exit_of("p3").id
    error = assert_raises(Rho::Processes::NotFound) { fetch("p1", "user") }
    assert_equal "no process p1; nothing has been started", error.message
  end

  # THE CONVERSATION ENDED HERE: its groups are killed — TERM, grace, KILL — and their
  # entries removed; another conversation's stand; the conversation that ended hears
  # nothing.
  def test_a_conversations_end_kills_its_groups_and_removes_their_entries
    ours = start('trap "" TERM; echo armed; while :; do sleep 1; done', loop: "loop-a", wait_for: "armed")
    polite = start("sleep 30", loop: "loop-b")
    theirs = start("sleep 30", loop: "loop-c")
    wait_for { ours.output.matched? }

    assert_equal %w[p1 p2], @registry.release("conv-1", grace: FAST)
    wait_for { @registry.row("p1").nil? && @registry.row("p2").nil? }
    assert_equal "KILL", ours.snapshot.signal
    assert_equal "TERM", polite.snapshot.signal
    assert_equal "conversation_ended", ours.snapshot.stopped_by
    assert_same theirs, @registry.row("p3")
    assert_equal "running", theirs.snapshot.status
    assert_empty notices("loop-a")
    assert_equal [], @registry.release("conv-1", grace: FAST), "nothing left to end"
    assert_match(/stopped when its conversation ended here/, @registry.exit_of("p2").then { |s| gone_sentence(s) })
    last = File.readlines(polite.output.path, chomp: true, encoding: Encoding::UTF_8).last
    assert_match(/\A\[rho\] p2: leader exited with signal TERM, stopped when its conversation ended here; the group ended at/, last)
  end

  # The notice is the CONVERSATION's: the loop that started it or any
  # later loop of the same conversation hears it, once.
  def test_the_owner_hears_once_about_a_process_it_did_not_stop
    row = start("sleep 30", loop: "loop-a")
    stop("p1", "user")
    wait_for { @registry.row("p1").nil? }

    refute row.live?
    notices = notices("loop-b")
    assert_equal 1, notices.size
    assert_match(/p1 .*exited with signal TERM, stopped by the person/, notices.first)
    assert_empty notices("loop-a")
  end

  def test_the_owner_hears_nothing_about_its_own_conversations_stop
    row = start("sleep 30", loop: "loop-a")
    stop("p1", "loop-b")
    wait_for { @registry.row("p1").nil? }

    refute row.live?
    assert_empty notices("loop-a")
    assert_equal "loop-b", row.snapshot.stopped_by, "the stopping loop is kept for display"
  end

  def test_a_crash_is_announced_as_on_its_own
    row = start("echo boom; exit 7", loop: "loop-a")
    wait_for { @registry.row("p1").nil? }

    refute row.live?
    assert_match(/exited with status 7, on its own/, notices("loop-a").first)
  end

  def test_the_cap_counts_live_processes_only
    @registry = build(live_cap: 2)
    dead = start("exit 0")
    wait_for do
      @registry.sweep_dead!
      @registry.row("p1").nil?
    end
    refute dead.live?
    start("sleep 30")
    start("sleep 30")

    error = assert_raises(Rho::Processes::Full) { start("sleep 30") }
    assert_includes error.message, "p2"
    assert_includes error.message, "p3"
    refute_includes error.message, "p1", "an exited row is not counted"
  end

  def test_closing_stops_everything_and_refuses_what_comes_after
    row = start("sleep 30")
    stopped = @registry.close

    assert_equal ["exited"], stopped.map(&:status)
    assert_equal "shutdown", row.snapshot.stopped_by
    assert_raises(Rho::Processes::Closed) { start("sleep 30") }
    refute File.exist?(@state.description), "nothing for the next boot to sweep"
  end

  def test_the_state_file_names_the_live_groups_and_forgets_the_dead
    row = start("sleep 30")
    recorded = @state.read.fetch("processes")

    assert_equal [{ "id" => "p1", "pid" => row.pid, "pgid" => row.pgid, "command" => "sleep 30" }],
      recorded.map { |r| r.slice("id", "pid", "pgid", "command") }
    stop("p1", "user")
    assert_empty @state.read.fetch("processes")
  end

  # The previous daemon died without stopping: what it recorded is still
  # there, in its recorded group, and the next boot ends it.
  def test_sweeps_a_previous_daemons_orphans_and_says_so_once
    orphan = Rho::Runner::OwnedProcess.spawn(
      "/bin/sh", "-c", "sleep 30", in: File::NULL, out: File::NULL, err: File::NULL
    )
    @state.write("processes" => [
      { "id" => "p9", "pid" => orphan.pid, "pgid" => orphan.group_pid, "command" => "sleep 30" },
      { "id" => "p8", "pid" => 1, "pgid" => 999_999, "command" => "not ours any more" },
    ])

    reaped = @registry.sweep_orphans
    assert_equal ["p9"], reaped.map { |r| r["id"] }
    wait_for { !orphan.poll.nil? }
    orphan.kill_and_reap
    assert_equal ["p9"], @registry.take_orphans.map { |r| r["id"] }
    assert_empty @registry.take_orphans
    refute File.exist?(@state.description)
    # A restart resurrects nothing: the orphan is reaped, never re-listed,
    # and the ids start over for a new table.
    assert_empty @registry.snapshots
    assert_nil @registry.exit_of("p9")
    assert_equal "p1", start("sleep 30").id
  end

  def test_the_child_does_not_inherit_bundlers_environment
    row = start("env; sleep 30", wait_for: "PYTHONUNBUFFERED")
    wait_for { row.output.matched? }

    text = row.output.lines(500)
    refute_match(/^BUNDLE_GEMFILE=/, text)
    assert_includes text, "PYTHONUNBUFFERED=1"
  end

  def test_stop_without_wait_answers_stopping_and_finishes_on_its_own
    row = start('trap "" TERM; echo armed; while :; do sleep 1; done', wait_for: "armed")
    wait_for { row.output.matched? }

    first = stop("p1", "user", grace: FAST, wait: false)
    assert_equal "stopping", first.status
    wait_for { !row.live? }
    assert_equal "KILL", row.snapshot.signal
  end

  private

    def gone_sentence(snapshot)
      assert_raises(Rho::Processes::Gone) { fetch(snapshot.id, "user") }.message
    end
end
