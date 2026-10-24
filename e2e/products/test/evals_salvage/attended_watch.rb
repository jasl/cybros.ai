class EvalsSalvageTest
  module AttendedWatch
    # ── turn 1's watch, attended ────────────────────────────────────
    # THE WATCH ANSWERS TOO: `until`, `say_second_turn` and `handoff` block turn 1 on `rho watch`, and
    # an ask never ends a watch (the kernel leaves an asking turn running), so before the attendant a
    # turn-1 ask idled to the watch's timeout: a lane error for the second-turn drivers, doubled
    # patience and lost checks for `until`. The attendant beside the watch reads the daemon's row and
    # draws the ask on the run's one answer; the watch runs on through the answer.
    UntilTask = Data.define(:instruction, :flags, :deadline_seconds)

    UNTIL_OPENED = "until:   sh check.sh (5 checks, in /tmp/project)\nconversation: c-1\nrun: loop-1\n".freeze
    # The daemon's own rows for loop-1 (`followed`), asking and not.
    DAEMON_ASKING = { "public_id" => "loop-1", "complete" => false, "attention" => { "reason" => "awaiting_human" } }.freeze
    DAEMON_WORKING = { "public_id" => "loop-1", "complete" => false }.freeze
    CLOSING_LINES = "status:    completed\nbackground: r1t0 running — its result reaches the next turn\n".freeze

    # The binary whose `watch` blocks WHILE THE ATTENDANT WORKS: `control` serves the daemon's rows,
    # one per read, the last repeated; `answer` records the verb — refused unless `answer_ok` — and
    # releases the watch with `after_answer`, its closing lines, when the script names them; `stop`
    # releases it with `on_stop`, what the watch had printed. A watch nothing releases gives up after
    # five seconds with the verb's own sentence, so a broken attendant fails its pin, never hangs.
    class WatchingDaemon < DaemonDouble
      attr_reader :control_reads

      def initialize(rows:, after_answer: nil, on_stop: "watched: stopped", answer_ok: true, opened_by: nil)
        super()
        @rows = rows.dup
        @after_answer = after_answer
        @on_stop = on_stop
        @answer_ok = answer_ok
        @opened_by = opened_by
        @control_reads = 0
      end

      def control(_verb, _path, body: nil)
        @control_reads += 1
        { "followers" => [@rows.size > 1 ? @rows.shift : @rows.first] }
      end

      def cli(*arguments)
        case arguments.first
        when "do" then @opened_by ? opened(arguments) : super
        when "watch" then watch(arguments)
        when "answer" then answer(arguments)
        when "stop" then (@verbs << arguments) && (@released << @on_stop) && ["stopped: c-1\n", Status.new(ok: true)]
        else super
        end
      end

      private

      def opened(arguments)
        @verbs << arguments
        [@opened_by, Status.new(ok: true)]
      end

      def watch(arguments)
        @verbs << arguments
        released = @released.pop(timeout: 5)
        released ? [released, Status.new(ok: true)] : ["rho watch: timed out watching loop-1\n", Status.new(ok: false)]
      end

      def answer(arguments)
        @verbs << arguments
        return ["no such task", Status.new(ok: false)] unless @answer_ok

        @released << @after_answer if @after_answer
        ["", Status.new(ok: true)]
      end
    end

    # The binary whose `watch` returns what it printed, with its exit, after `takes` seconds.
    class ReturningWatchDaemon < DaemonDouble
      def initialize(printed, ok:, takes: 0, opened_by: nil)
        super()
        @printed = printed
        @ok = ok
        @takes = takes
        @opened_by = opened_by
      end

      def cli(*arguments)
        if arguments.first == "watch"
          @verbs << arguments
          Kernel.sleep(@takes)
          [@printed, Status.new(ok: @ok)]
        elsif arguments.first == "do" && @opened_by
          @verbs << arguments
          [@opened_by, Status.new(ok: true)]
        else
          super
        end
      end
    end

    def verbs_named(name) = @daemon.verbs.select { |verb| verb.first == name }

    def answered_pairs(outcome) = outcome[:run].facts.fetch("harness_answered", []).map { |row| row.values_at("loop", "key") }

    def attended_second_turn(deadline_seconds: 900, **scripts)
      loops_scripted!(scripts)
      define_singleton_method(:await_mail) { |_conversation, deadline:, origin: "task_result"| { "type" => "input_accepted" } }
      define_singleton_method(:await_next_turn) { |_conversation, after:, deadline:| "loop-2" }
      task = SecondTurnTask.new(instruction: "start the suite", flags: {}, deadline_seconds: deadline_seconds, turns: [])
      outcome = nil
      capture_io { outcome = caught { drive_say_second_turn(task, "/tmp/project", nil) } }
      outcome
    end

    def attended_ladder(deadline_seconds: 900, **scripts)
      loops_scripted!(scripts)
      task = UntilTask.new(instruction: "write note.txt", flags: { "until" => "sh check.sh" }, deadline_seconds: deadline_seconds)
      outcome = nil
      capture_io { outcome = caught { drive_until(task, "/tmp/project", nil) } }
      outcome
    end

    def test_a_turn_one_ask_is_answered_beside_the_watch_and_the_same_watch_runs_on
      @daemon = WatchingDaemon.new(rows: [DAEMON_ASKING, DAEMON_WORKING], after_answer: CLOSING_LINES)
      outcome = attended_second_turn("loop-1" => [asking("loop-1", "r2t0-ask-1"), asking("loop-1", "r2t0-ask-1"), settled("loop-1")])

      assert_nil outcome[:error]
      assert_nil outcome[:stopped], "an answered ask is not a stop"
      assert_equal [["watch", "loop-1", "--timeout", "900"]], verbs_named("watch"), "ONE watch, its timeout the task's deadline"
      assert_equal [["answer", "loop-1", "r2t0-ask-1", bench_answer]], verbs_named("answer"),
        "answered once, though the kernel row still read the ask on the first poll after the watch"
      assert_empty verbs_named("stop"), "the run was never stopped"
      assert_equal true, outcome[:run].facts["reply_final_with_background"], "the same watch printed the turn's end"
      assert_equal [%w[loop-1 r2t0-ask-1]], answered_pairs(outcome)
    end

    def test_a_second_ask_while_the_watch_blocks_stops_the_run_once_as_needs_person
      @daemon = WatchingDaemon.new(rows: [DAEMON_ASKING])
      outcome = attended_second_turn("loop-1" => [asking("loop-1", "r2t0-ask-1"), asking("loop-1", "r2t0-ask-2")])

      assert_nil outcome[:error]
      assert_equal "needs_person", outcome[:stopped]
      assert_equal 1, verbs_named("watch").size
      assert_equal [["answer", "loop-1", "r2t0-ask-1", bench_answer]], verbs_named("answer"), "the run's one answer"
      assert_equal [["stop", "c-1"]], verbs_named("stop"), "ONE stop, made where needs_person was raised; it ended the watch"
      assert_empty verbs_named("result"), "a stopped run has no reply to print"
      assert_equal({ "asked_key" => "r2t0-ask-2", "asked_loop" => "loop-1" }, outcome[:run].facts.slice("asked_key", "asked_loop"))
      assert_equal [%w[loop-1 r2t0-ask-1]], answered_pairs(outcome)
    end

    def test_an_answer_refused_while_the_watch_blocks_is_a_lane_bug_that_ends_the_watch
      @daemon = WatchingDaemon.new(rows: [DAEMON_ASKING], answer_ok: false)
      outcome = attended_second_turn("loop-1" => [asking("loop-1", "r2t0-ask-1")])

      assert_nil outcome[:stopped], "the model did not stop the run"
      assert_equal "RuntimeError: the harness could not answer r2t0-ask-1: no such task", outcome[:error]
      assert_equal [["stop", "c-1"]], verbs_named("stop"), "the attendant's stop ended the watch at once"
      refute outcome[:run].facts.key?("harness_answered"), "the refused answer was never given"
      record = record_of(outcome, facts: { "rounds_settled" => 1 })
      assert_equal E2E::Evals::Scorecard::LANE_BUG, E2E::Evals::Scorecard.classify(record)
    end

    def test_the_ladders_watch_answers_an_ask_and_its_checks_cover_the_whole_ladder
      @daemon = WatchingDaemon.new(rows: [DAEMON_ASKING, DAEMON_WORKING], opened_by: UNTIL_OPENED,
        after_answer: "check 1/5: failed — exit 1\ncheck 2/5: passed\nstatus:    completed\n")
      outcome = attended_ladder("loop-1" => [asking("loop-1", "r2t0-ask-1"), settled("loop-1")])

      assert_nil outcome[:error]
      assert_nil outcome[:stopped]
      assert_equal [["watch", "loop-1", "--timeout", "900"]], verbs_named("watch")
      assert_equal [["answer", "loop-1", "r2t0-ask-1", bench_answer]], verbs_named("answer")
      assert_equal ["check 1/5: failed — exit 1", "check 2/5: passed"], outcome[:run].facts["checks"],
        "the checks the watch printed after the answer"
    end

    # THE WATCH'S FACTS OUTLIVE A STOP: every stop ends the watch before a wrapper raises, so what it
    # printed is stashed inside the innermost block — five wall cost stops read `checks: null` before.
    def test_a_second_ask_mid_ladder_keeps_the_checks_printed_so_far
      @daemon = WatchingDaemon.new(rows: [DAEMON_ASKING], opened_by: UNTIL_OPENED,
        on_stop: "check 1/5: failed — exit 1\n  ASKING     awaiting_human — r3t0-ask-2\nstatus:    stopped\n")
      outcome = attended_ladder("loop-1" => [asking("loop-1", "r2t0-ask-1"), asking("loop-1", "r3t0-ask-2")])

      assert_equal "needs_person", outcome[:stopped]
      assert_equal ["check 1/5: failed — exit 1"], outcome[:run].facts["checks"]
      assert_equal ["check 1/5: failed — exit 1"], outcome[:trace].fact(:checks), "the salvaged trace reads the same facts"
      assert_equal 1, verbs_named("stop").size
    end

    # A WATCH THAT GAVE UP IS THE RUN'S DEADLINE and the wait after it gets no fresh patience: the
    # kernel is never polled again (before, `until` answered a fresh deadline and the second-turn
    # drivers flunked on the watch's status).
    def test_a_watch_that_gives_up_is_the_deadline_and_nothing_waits_after_it
      printed = "check 1/5: failed — exit 1\n  ASKING     awaiting_human — r2t0-ask-1\nrho watch: timed out watching loop-1\n"
      define_singleton_method(:loop_row) { |_loop_id| raise "the wait after a watch that gave up polled the loop" }
      outcomes = {
        drive_say_second_turn: SecondTurnTask.new(instruction: "start the suite", flags: {}, deadline_seconds: 900, turns: []),
        drive_until: UntilTask.new(instruction: "write note.txt", flags: { "until" => "sh check.sh" }, deadline_seconds: 900),
      }.to_h do |drive, task|
        @daemon = ReturningWatchDaemon.new(printed, ok: false, opened_by: UNTIL_OPENED)
        outcome = nil
        capture_io { outcome = caught { send(drive, task, "/tmp/project", nil) } }
        assert_equal "deadline", outcome[:stopped], drive
        assert_equal "the loop never settled in 900 s (0 harness answer(s))", outcome[:note], drive
        assert_equal [["watch", "loop-1", "--timeout", "900"]], verbs_named("watch"), drive
        assert_equal [["stop", "c-1"]], verbs_named("stop"), "#{drive}: caught's stop for the deadline, once"
        [drive, outcome]
      end

      assert_equal false, outcomes.fetch(:drive_say_second_turn)[:run].facts["reply_final_with_background"]
      assert_equal ["check 1/5: failed — exit 1"], outcomes.fetch(:drive_until)[:run].facts["checks"],
        "the checks the watch printed before it gave up ride the stopped record"
    end

    # RHO'S SENTENCE IS NOT ALWAYS THE LAST LINE: the watch's stderr is merged into its stdout, and the
    # rows stdout still held are flushed at exit, after the sentence — or the sentence ends a line of
    # model text the watch left open. Either way the watch gave up: the run's deadline, never a lane
    # error.
    def test_a_watch_that_gave_up_is_the_deadline_wherever_its_sentence_lands
      {
        "a buffered row after it" => "bravo answered first\nrho watch: timed out watching loop-1\n  RUNNING    r2t0-tool-1 — bash\n",
        "glued to model text" => "The race settled on bravrho watch: timed out watching loop-1\n",
      }.each do |why, printed|
        @daemon = ReturningWatchDaemon.new(printed, ok: false)
        outcome = attended_second_turn("loop-1" => [settled("loop-1")])

        assert_nil outcome[:error], why
        assert_equal "deadline", outcome[:stopped], why
        assert_equal "the loop never settled in 900 s (0 harness answer(s))", outcome[:note], why
      end
    end

    # THE WATCH FAILED SOME OTHER WAY: the lane's error, rho's own sentence first on the record —
    # found where it landed, a buffered row after it or not.
    def test_a_watch_that_fails_otherwise_is_a_lane_error_naming_rhos_sentence
      ["rho watch: no daemon is running for this home\n",
       "rho watch: no daemon is running for this home\n  RUNNING    r2t0-tool-1 — bash\n"].each do |printed|
        @daemon = ReturningWatchDaemon.new(printed, ok: false)
        outcome = attended_second_turn("loop-1" => [settled("loop-1")])

        assert_nil outcome[:stopped]
        assert_match(/\AMinitest::Assertion: rho watch failed \(.+\): rho watch: no daemon is running for this home\z/, outcome[:error])
      end
    end

    # READ BEFORE JUDGING: the watch's own clock starts after the CLI boots, so a turn that settled
    # inside the watch's timeout can leave nothing of the shared deadline; the settle reads the row
    # once and a settled turn is no deadline.
    def test_a_turn_that_settled_as_the_deadline_ran_out_is_settled_not_stopped
      @daemon = ReturningWatchDaemon.new("status:    completed\n", ok: true, takes: 0.3)
      outcome = attended_second_turn("loop-1" => [settled("loop-1")], deadline_seconds: 0.2)

      assert_nil outcome[:error]
      assert_nil outcome[:stopped], "the row was read before the deadline judged it"
      assert_equal false, outcome[:run].facts["task_started"]
      assert_equal 0, @polls, "one read, no fresh patience waited on"
    end

    # ONE DEADLINE FOR THE WATCH AND THE SETTLE: a watch that returned with a background branch
    # still running loop one leaves the settle what is left — here nothing — never a fresh 900 s.
    def test_the_settle_after_the_watch_has_only_what_is_left_of_the_deadline
      @daemon = ReturningWatchDaemon.new(CLOSING_LINES, ok: true, takes: 0.3)
      running = { "public_id" => "loop-1", "status" => "running", "tasks" => TASK_STARTED_ROW.fetch("tasks") }
      outcome = attended_second_turn("loop-1" => [running], deadline_seconds: 0.2)

      assert_equal "deadline", outcome[:stopped]
      assert_match(/\Athe loop never settled in 0\.2 s \(0 harness answer\(s\)\)\z/, outcome[:note])
      assert_equal 0, @polls, "no patience was waited on after the watch"
      assert_equal true, outcome[:run].facts["reply_final_with_background"], "the watch's line rides the stopped record"
      assert_equal [["stop", "c-1"]], verbs_named("stop"), "the deadline stops nothing where it is raised: caught's stop"
    end

    def test_the_attendant_reads_the_kernel_only_when_the_daemons_row_asks
      @daemon = WatchingDaemon.new(rows: [DAEMON_WORKING])
      open_turn("copy the files", "/tmp/project", model: "m")
      kernel_reads = 0
      define_singleton_method(:loop_row) { |_loop_id| (kernel_reads += 1) && raise("the kernel was read") }
      answer = attending_asks("loop-1") do
        sleep 0.15
        "the watch's answer"
      end

      assert_equal "the watch's answer", answer
      assert_predicate @daemon.control_reads, :positive?, "the daemon's row was polled while the verb blocked"
      assert_equal 0, kernel_reads, "no member-plane read while the daemon's row asks nothing"
    end

    # The turn-1 ask spends the run's answer; the woken loop's ask then stops the run.
    def test_a_turn_one_ask_answered_mid_watch_spends_the_runs_answer_and_the_woken_turns_ask_stops_it
      @daemon = WatchingDaemon.new(rows: [DAEMON_ASKING, DAEMON_WORKING], after_answer: CLOSING_LINES)
      outcome = attended_second_turn("loop-1" => [asking("loop-1", "r3t0-ask-1"), TASK_STARTED_ROW],
        "loop-2" => [asking("loop-2", "r3t0-ask-1")])

      assert_equal "needs_person", outcome[:stopped]
      assert_equal [["answer", "loop-1", "r3t0-ask-1", bench_answer]], verbs_named("answer"), "turn 1's watch spent the answer"
      assert_equal({ "asked_loop" => "loop-2", "asked_key" => "r3t0-ask-1" }, outcome[:run].facts.slice("asked_loop", "asked_key"))
      assert_equal({ "reply_final_with_background" => true, "receipt_woke_a_turn" => true },
        outcome[:run].facts.slice("reply_final_with_background", "receipt_woke_a_turn"))
      assert_equal 1, verbs_named("stop").size
    end

    def test_a_cost_stop_ends_an_attended_watch_once
      @cost_stop_usd = 8.0
      @spent = "8.25"
      @daemon = WatchingDaemon.new(rows: [DAEMON_WORKING])
      outcome = attended_second_turn("loop-1" => [settled("loop-1")])

      assert_equal "cost_stop", outcome[:stopped]
      assert_equal [["stop", "c-1"]], verbs_named("stop"), "the spend watch's stop, once"
      assert_empty verbs_named("answer")
    end

    # The attendant's failure is the run's error even when the stop that should end the watch fails
    # too: the thread never dies with nothing to raise.
    def test_an_attendant_whose_stop_fails_too_still_answers_the_failure
      open_turn("copy the files", "/tmp/project", model: "m")
      define_singleton_method(:followed) { |_loop_id| raise "the control socket answered nothing" }
      define_singleton_method(:stop_conversation!) { |_conversation| raise IOError, "the stop could not spawn" }

      failure = attend_asks_beside("loop-1")

      assert_kind_of RuntimeError, failure
      assert_equal "the control socket answered nothing (and the stop failed: IOError: the stop could not spawn)", failure.message
    end
  end

  include AttendedWatch
end
