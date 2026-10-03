$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "support/screen/definition"
require "support/screen/stamp"
require "support/screen/watch"

# THE WATCH'S REGISTERED STOPS, OFFLINE: the rules over one snapshot (a storm reads only past its
# event floor, LOST pools a model's arm over the count floor, the stall clock ticks per call, a hand
# stop owes a relaunch only when it names a fault and a record), and the watch over a real home —
# one blind line per record, the stop's STOPPED file and process-group kills, a job registered
# after the stop stopped too, a record it cannot take, the tree it was stamped on moving under it.
# Pure Ruby over a tmpdir; the only processes are `sleep` children in their own groups.
class ScreenWatchRulesHarnessTest < Minitest::Test
  S = E2E::Screen
  R = S::WatchRules
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  PARAMS = S::Definition.load(FAKE).watch_params

  # ---- the rules over one snapshot

  def test_a_clean_snapshot_meets_no_stop
    assert_nil R.stop_reason(state, PARAMS)
  end

  def test_the_storm_waits_for_its_event_floor_then_reads_the_share
    assert_nil R.stop_reason(state(jobs: [job(calls: 2, bad_calls: 2)]), PARAMS), "two bad calls are not yet a storm"
    assert_match(/\ASTORM 1 with m: 3 of 3 calls/, R.stop_reason(state(jobs: [job(calls: 3, bad_calls: 3)]), PARAMS))
    assert_nil R.stop_reason(state(jobs: [job(calls: 60, bad_calls: 5)]), PARAMS), "five bad calls below ten per cent"
  end

  def test_the_spend_and_wall_stops
    assert_match(/\ASPEND \$25\.00 ≥ \$25\.00/, R.stop_reason(state(spend_usd: 25.0), PARAMS))
    assert_match(/\AWALL 75\.0 min/, R.stop_reason(state(elapsed_seconds: 4500), PARAMS))
  end

  def test_the_stall_flags_then_stops_the_whole_screen_on_a_quiet_call
    flagged = state(jobs: [job(quiet_seconds: 601)])
    assert_nil R.stop_reason(flagged, PARAMS)
    assert_equal [1], R.flags(flagged, PARAMS).keys
    assert_match(/\ASTALL-STOP 1 with m: no call for 25\.0 min/, R.stop_reason(state(jobs: [job(quiet_seconds: 1500)]), PARAMS))
    assert_nil R.stop_reason(state(jobs: [job(quiet_seconds: 9999, exit_status: 0)]), PARAMS), "an ended job is not stalled"
  end

  def test_a_job_ahead_of_its_records_is_blind
    assert_nil R.stop_reason(state(jobs: [job(progress: 4, draws: 2)]), PARAMS)
    assert_match(/\ABLIND 1 with m: 5 progress lines, 2 records/, R.stop_reason(state(jobs: [job(progress: 5, draws: 2)]), PARAMS))
  end

  # LOST: more than five per cent AND at least three, pooled over a model's arm across instruments.
  def test_lost_pools_a_models_arm_over_instruments_above_its_count_floor
    one_of_sixteen = [job(planned: 16, lost: 1)]
    assert_nil R.stop_reason(state(jobs: one_of_sixteen), PARAMS), "6 % of the plan but one draw"
    pooled = [job(index: 1, planned: 20, lost: 2), job(index: 2, planned: 20, lost: 1)]
    assert_match(/\ALOST m with: 3 of 40 planned draws lost/, R.stop_reason(state(jobs: pooled), PARAMS))
    thin = [job(index: 1, planned: 40, lost: 2), job(index: 2, planned: 40, lost: 1)]
    assert_nil R.stop_reason(state(jobs: thin), PARAMS), "3 of 80 is under five per cent"
    other_arm = [job(index: 1, planned: 20, lost: 2), job(index: 2, arm: "without", planned: 20, lost: 1)]
    assert_nil R.stop_reason(state(jobs: other_arm), PARAMS), "an arm is its own pool"
  end

  def test_a_harness_fault_record_or_an_unstopped_non_zero_exit_stops_the_screen
    assert_match(/\AHARNESS-FAULT 1 with m: 1 records/, R.stop_reason(state(jobs: [job(faults: 1)]), PARAMS))
    assert_match(/\AHARNESS-FAULT 1 with m: exit=1/, R.stop_reason(state(jobs: [job(exit_status: 1)]), PARAMS))
    assert_nil R.stop_reason(state(jobs: [job(exit_status: 143, stopped: true)]), PARAMS), "a job the watch stopped"
  end

  # A HAND STOP owes the relaunch only when it names a harness-fault class and a record.
  def test_a_hand_stop_owes_a_relaunch_only_when_it_names_a_fault_and_a_record
    bare = R.stop_reason(state(stop_request: "looks wrong\n"), PARAMS)
    assert bare.start_with?("MANUAL looks wrong"), bare
    refute R.relaunch_owed?(bare)
    named = R.stop_reason(state(stop_request: "NoMethodError in 3:O1#2"), PARAMS)
    assert_equal "MANUAL-FAULT NoMethodError in 3:O1#2", named
    assert R.relaunch_owed?(named)
    refute R.relaunch_owed?(R.stop_reason(state(stop_request: "NoMethodError somewhere"), PARAMS)), "a class with no record"
    assert R.relaunch_owed?(R.stop_reason(state(stop_request: "KeyError in 3:O1#2"), PARAMS)), "any class but the gem's call failure"
    refute R.relaunch_owed?(R.stop_reason(state(stop_request: "SimpleInference::TimeoutError in 3:O1#2"), PARAMS)),
      "a failed call is the provider's, not the harness's"
    refute R.relaunch_owed?(R.stop_reason(state(stop_request: "Stop 3:O1#2, it looks wrong"), PARAMS)), "a word is not an error class"
    refute R.relaunch_owed?(R.stop_reason(state(stop_request: "It Failed at 3:O1#2"), PARAMS)), "nor is a word ending in one"
    ["E2E::BenchRecords::WriteFailed at 3:O2#1", "Errno::ENOENT at 3:O2#1", "SimpleInference::ValidationError at 3:O2#1"].each do |request|
      assert_equal "MANUAL-FAULT #{request}", R.stop_reason(state(stop_request: request), PARAMS), "the harness's own spellings name a fault"
    end
    assert R.relaunch_owed?("STORM 1 with m: 3 of 3")
  end

  def test_a_moved_tree_and_a_watch_fault
    moved = state(trees: [R::TreeState.new(tag: "without", root: "/wo", stamped: "h s b", now: "h s2 b")])
    assert_match(/\ATREE-MOVED without tree \/wo/, R.stop_reason(moved, PARAMS))
    assert_match(/\AWATCH-FAULT 3/, R.stop_reason(state(take_errors: 3), PARAMS))
  end

  # The order is the registered one: a hand stop reads first, a stall last.
  def test_the_first_stop_in_the_registered_order_is_the_reason
    everything = state(stop_request: "x", spend_usd: 99, jobs: [job(quiet_seconds: 9999, faults: 1)])
    assert R.stop_reason(everything, PARAMS).start_with?("MANUAL")
    assert R.stop_reason(state(spend_usd: 99, jobs: [job(faults: 1)]), PARAMS).start_with?("SPEND")
  end

  def test_the_parameters_are_named_and_numeric
    assert_raises(ArgumentError) { R::Params.from(PARAMS.to_h.merge(spend_stop: 1)) }
    assert_raises(ArgumentError) { R::Params.from(PARAMS.to_h.except(:wall_stop_seconds)) }
    assert_raises(ArgumentError) { R::Params.from(PARAMS.to_h.merge(wall_stop_seconds: "soon")) }
    assert_equal 600.0, S::Definition.load(FAKE).watch_params(fake: true).wall_stop_seconds, "a fake run's clocks"
  end

  # ---- the watch over a home

  def test_one_blind_line_per_record_and_no_outcome_in_the_stream
    with_home do |home, jobs|
      started(home, jobs.first)
      record(home, jobs.first, "first_time_right" => true, "door_kind" => "compose_steps", "pass" => true,
        "usage" => { "input_tokens" => 900, "output_tokens" => 40, "cache_read_tokens" => 800 }, "seconds" => 2.5)
      out = StringIO.new
      watch(home, out: out).poll
      lines = out.string.lines.grep(/ RECORD /)
      assert_equal 1, lines.size
      assert_match(/ RECORD base 1 fake\/responses O1 #1 \S+ 2\.5s tokens\(900 40 800 0\) \$0\.0100 retries 0 -$/, lines.first)
      refute_match(/compose_steps|first_time_right|pass/, out.string)
    end
  end

  def test_the_spend_stop_counts_the_smoke_and_stops_every_running_group
    with_home(smoke_usd: 24.995) do |home, jobs|
      child = sleeper(home, jobs.first)
      started(home, jobs.first)
      record(home, jobs.first)
      watcher = watch(home)
      watcher.poll
      assert_match(/\ASPEND \$25\.0\d ≥ \$25\.00/, watcher.stop)
      assert_equal(-Signal.list.fetch("TERM"), reap(child))
      assert_includes File.read(File.join(home, "logs", "STOPPED")), "SPEND"
      assert_includes File.read(File.join(home, "logs", "stops.tsv")), "\tTERM\t"
    end
  end

  def test_a_job_registered_after_the_stop_is_stopped_once_its_group_exists
    with_home do |home, jobs|
      File.write(File.join(home, "logs", "STOP.request"), "owner asked\n")
      watcher = watch(home)
      watcher.poll
      assert watcher.stop.start_with?("MANUAL owner asked")
      started(home, jobs[1])
      watcher.poll
      child = sleeper(home, jobs[1])
      watcher.poll
      assert_equal(-Signal.list.fetch("TERM"), reap(child), "a TERM that found no pgid is sent once the pgid exists")
    end
  end

  # The stall clock is the CALL stream: a call line resets it where no record has come yet.
  def test_a_call_resets_the_stall_clock
    with_home do |home, jobs|
      now = [Time.now.to_f]
      started(home, jobs.first, at: now.first)
      watcher = watch(home, clock: -> { now.first })
      now[0] += 1000
      File.write(File.join(home, jobs.first.dir, "calls.jsonl"), "#{JSON.generate("model" => "m", "recorded_at" => Time.at(now.first).utc.iso8601(3))}\n")
      now[0] += 1000
      watcher.poll
      assert_nil watcher.stop, "1000 s since the last call is under the 1500 s stop"
      now[0] += 600
      watcher.poll
      assert_match(/\ASTALL-STOP/, watcher.stop)
    end
  end

  # A RATE LIMIT IS WAITED OUT: a call the transport asked again and that then answered is a draw like
  # any other, and the wall stop bounds the time its pauses took; a call that ended unreached, its
  # attempts spent, is the storm's event.
  def test_a_call_answered_after_its_retries_is_no_storm_event_and_an_unreached_one_is
    with_home do |home, jobs|
      started(home, jobs.first)
      limited = { "error" => "SimpleInference::HTTPError: HTTP 429", "pause_seconds" => 10 }
      3.times { call(home, jobs.first, "retries" => [limited]) }
      watcher = watch(home)
      watcher.poll
      assert_nil watcher.stop, "three calls answered after a rate limit"
      3.times { call(home, jobs.first, "retries" => [limited, limited], "error_class" => "SimpleInference::HTTPError") }
      watcher.poll
      assert_match(/\ASTORM 1 base \S+: 3 of 6 calls unreached \(50\.0 %\)\z/, watcher.stop)
    end
  end

  def test_a_record_the_watch_cannot_take_is_an_alarm_and_three_stop_the_screen
    with_home do |home, jobs|
      started(home, jobs.first)
      out = StringIO.new
      watcher = watch(home, out: out, pricer: ->(_record) { "many" })
      record(home, jobs.first)
      watcher.poll
      assert_nil watcher.stop
      assert_includes out.string, "ALARM TAKE-ERROR 1"
      2.times { |i| record(home, jobs.first, "sample" => i + 2) }
      watcher.poll
      assert_match(/\AWATCH-FAULT 3/, watcher.stop)
    end
  end

  def test_the_stamped_tree_moving_stops_the_screen_and_a_stamp_naming_none_checks_none
    with_home(trees: { "without" => ["/wo", "h s b"] }) do |home, _jobs|
      states = { "/wo" => "h s b" }
      watcher = watch(home, tree_probe: ->(root) { states.fetch(root) })
      watcher.poll
      assert_nil watcher.stop
      states["/wo"] = "h s2 b"
      watcher.poll
      assert_match(/\ATREE-MOVED without/, watcher.stop)
    end
    with_home do |home, _jobs|
      watch(home, tree_probe: ->(_root) { flunk "the stamp names no tree" }).poll
    end
  end

  def test_the_observer_prints_and_never_stops
    with_home do |home, _jobs|
      File.write(File.join(home, "logs", "STOP.request"), "owner asked\n")
      watcher = watch(home, observe: true)
      watcher.poll
      assert_nil watcher.stop
      refute File.exist?(File.join(home, "logs", "STOPPED"))
    end
  end

  def test_the_watch_ends_once_the_launch_is_done_and_every_started_job_exited
    with_home do |home, jobs|
      started(home, jobs.first)
      File.write(File.join(home, "logs", "#{jobs.first.index}.log"), "draw m O1 #1\nexit=0\n")
      record(home, jobs.first)
      File.write(File.join(home, "logs", "launched.done"), "1\n")
      out = StringIO.new
      assert_equal 0, watch(home, out: out).run(sleep: ->(_seconds) { flunk "one poll sees the end" })
      assert_match(/ALL-DONE draws 1\/\d+ · spend \$0\.01 · stop none/, out.string)
    end
  end

  # THE LAUNCH'S COUNT BINDS THE END: within one poll the launch may reap a job, start the last one
  # and write `launched.done` after the watch read `jobs.tsv` — every job the watch knows has
  # exited, but one it has not yet seen is running, so the watch is not done until it has seen as
  # many as the launch started.
  def test_the_watch_is_not_done_while_the_launch_started_a_job_it_has_not_seen
    with_home do |home, jobs|
      started(home, jobs.first)
      File.write(File.join(home, "logs", "#{jobs.first.index}.log"), "exit=0\n")
      File.write(File.join(home, "logs", "launched.done"), "2\n")
      watcher = watch(home)
      watcher.poll
      refute watcher.finished?, "the launch started two; the watch has seen one"
      started(home, jobs[1])
      File.write(File.join(home, "logs", "#{jobs[1].index}.log"), "exit=0\n")
      watcher.poll
      assert watcher.finished?
    end
  end

  # A LAUNCH THAT DIED leaves no `exit=N`: once the watch has stopped the screen, a job whose group
  # is gone has ended, so the watch always terminates. Before a stop the watch waits for the
  # launch's `exit=N`, whose status the harness-fault stop reads.
  def test_after_a_stop_a_job_whose_group_is_gone_has_ended
    with_home do |home, jobs|
      child = sleeper(home, jobs.first)
      started(home, jobs.first)
      File.write(File.join(home, "logs", "launched.done"), "1\n")
      watcher = watch(home)
      watcher.poll
      Process.kill("KILL", -child)
      reap(child)
      watcher.poll
      refute watcher.finished?, "no stop yet: a group gone without its exit line is the launch's to reap"
      File.write(File.join(home, "logs", "STOP.request"), "owner asked\n")
      watcher.poll
      assert watcher.stop.start_with?("MANUAL owner asked")
      assert watcher.finished?, "stopped, and the group is gone"
    end
  end

  # THE FIRST STOP WINS: a stop the launch recorded (its own fault) is not overwritten by the stop
  # the watch reads off the exits that fault caused.
  def test_the_watch_keeps_a_stop_the_launch_recorded_first
    with_home do |home, jobs|
      File.write(File.join(home, "logs", "STOPPED"), "2026-09-28T10:00:00Z LAUNCH-FAULT RuntimeError: boom\n")
      started(home, jobs.first)
      File.write(File.join(home, "logs", "#{jobs.first.index}.log"), "exit=143\n")
      watcher = watch(home)
      watcher.poll
      assert_match(/\AHARNESS-FAULT 1 /, watcher.stop)
      assert_equal "2026-09-28T10:00:00Z LAUNCH-FAULT RuntimeError: boom\n", File.read(File.join(home, "logs", "STOPPED"))
    end
  end

  def test_a_tree_state_moves_with_an_edit_and_not_without_one
    Dir.mktmpdir("watch-tree") do |root|
      builder = File.join(root, "nexus/lib/nexus/compose/builder.js")
      FileUtils.mkdir_p(File.dirname(builder))
      File.write(builder, "// v1\n")
      git(root, "init", "-q")
      git(root, "add", ".")
      git(root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "one")
      first = S::Watch.tree_state(root)
      assert_equal first, S::Watch.tree_state(root)
      File.write(builder, "// v2\n")
      refute_equal first, S::Watch.tree_state(root)
      assert_equal "unreadable", S::Watch.tree_state(File.join(root, "absent"))
    end
  end

  private

    def state(**fields)
      R::State.new(spend_usd: 0.0, elapsed_seconds: 60, jobs: [job], stop_request: nil, trees: [], take_errors: 0).with(**fields)
    end

    def job(**fields)
      R::JobState.new(index: 1, arm: "with", model: "m", planned: 16, calls: 1, bad_calls: 0, draws: 1, lost: 0, faults: 0,
        progress: 1, quiet_seconds: 5, exit_status: nil, stopped: false).with(**fields)
    end

    # A stamped home over the fake definition's jobs; `trees` tag => [root, stamped state].
    def with_home(smoke_usd: 0, trees: {})
      definition = S::Definition.load(FAKE)
      Dir.mktmpdir("screen-watch") do |home|
        FileUtils.mkdir_p(File.join(home, "logs"))
        definition.jobs.each { |job| FileUtils.mkdir_p(job.path(home)) }
        S::Stamp.write(home, [["launched_at", Time.now.utc.iso8601], ["smoke_spend_usd", smoke_usd.to_s],
                              *PARAMS.lines.map { |line| line.split("=", 2) },
                              *trees.flat_map { |tag, (root, stamped)| [["tree.#{tag}.root", root], ["tree.#{tag}.state", stamped]] },
                              *definition.jobs.map { |job| ["job.#{job.index}", job.stamp_line] }])
        yield home, definition.jobs
      end
    end

    def watch(home, out: StringIO.new, pricer: ->(_record) { 0.01 }, **options)
      S::Watch.new(home, pricer: pricer, out: out, **options)
    end

    def started(home, job, at: Time.now.to_f)
      File.write(File.join(home, "logs", "jobs.tsv"), "#{job.index}\t#{at}\n", mode: "a")
    end

    def record(home, job, fields = {})
      line = { "arm" => job.arm, "process" => job.index.to_s, "model" => job.model, "objective" => "O1", "sample" => 1,
               "recorded_at" => Time.now.utc.iso8601(3) }.merge(fields)
      File.write(File.join(home, job.dir, "records.jsonl"), "#{JSON.generate(line)}\n", mode: "a")
    end

    def call(home, job, fields = {})
      line = { "model" => job.model, "recorded_at" => Time.now.utc.iso8601(3) }.merge(fields)
      File.write(File.join(home, job.dir, "calls.jsonl"), "#{JSON.generate(line)}\n", mode: "a")
    end

    def sleeper(home, job)
      pid = Process.spawn("sleep", "30", pgroup: true)
      File.write(File.join(home, job.dir, "pgid"), pid.to_s)
      pid
    end

    def reap(pid)
      Process.wait(pid)
      $?.termsig ? -$?.termsig : $?.exitstatus
    end

    def git(root, *args)
      _out, status = Open3.capture2e("git", "-C", root, *args)
      assert status.success?, "git #{args.join(" ")}"
    end
end
