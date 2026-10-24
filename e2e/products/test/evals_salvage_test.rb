require "test_helper"
require "evals_fixture_bench"
require "support/live_journey"
require "support/evals"
require "support/live_journey"

# THE STOPPED RUN IS A RECORD WITH ITS TRACE: a `Stopped` raised inside a driver — the deadline, the
# cost stop — comes AFTER `open_turn` opened the loop and BEFORE the driver answered its Run, so the
# lane's salvage must read the loop the turn opened, not `Trace.empty`. `MemberPlane#caught` is that
# shape, pinned here over a daemon double (`rho do` prints the two id lines, `rho stop` releases a
# blocked `rho watch`) with the member-plane reads stubbed; `watching_spend` polls the spend
# WHILE a CLI verb blocks, stops the conversation over the cap and raises the stop once the verb
# returns; and the ask attendant beside turn 1's watch (`watch_the_turn`) draws the model's ask on
# the run's one answer. The live twin is the runbook's step 11. Pure Ruby: nothing boots.
class EvalsSalvageTest < Minitest::Test
  include EvalsFixtureBench
  include E2E::LiveJourney
  include E2E::Evals::MemberPlane
  include E2E::Evals::Pump
  include E2E::Evals::Drivers

  PumpTask = Data.define(:instruction, :flags, :policy, :deadline_seconds)

  Status = Data.define(:ok) do
    def success? = ok
  end

  # The binary, doubled: every verb is recorded; `watch` blocks until a
  # `stop` lands, the way a real watch ends when the conversation is stopped.
  # The daemon's own rows are empty, so the ask attendant beside a watch
  # finds nothing to read and every watch-driver test stays deterministic.
  class DaemonDouble
    attr_reader :verbs

    def initialize
      @verbs = []
      @released = Queue.new
    end

    def control(_verb, _path, body: nil) = { "followers" => [] }

    def cli(*arguments)
      @verbs << arguments
      case arguments.first
      when "do" then ["until:   none\nconversation: c-1\nrun: loop-1\n", Status.new(ok: true)]
      when "watch" then [@released.pop.to_s, Status.new(ok: true)]
      when "stop" then (@released << "watched: stopped") && ["stopped: c-1\n", Status.new(ok: true)]
      when "approve" then ["status:  dispatched\n", Status.new(ok: true)]
      when "deny" then ["status:  failed (approval_denied)\n", Status.new(ok: true)]
      else ["", Status.new(ok: true)]
      end
    end
  end

  # The same binary, except that the daemon refuses every `rho answer`.
  class RefusingDaemon < DaemonDouble
    def cli(*arguments)
      return super unless arguments.first == "answer"

      @verbs << arguments
      ["no such task", Status.new(ok: false)]
    end
  end

  def setup
    @unattended_bench = EvalsFixtureBench.read
    @daemon = DaemonDouble.new
    @spent = "0.5"
    @cost_stop_usd = nil
    @feed = []
  end

  # ── the member-plane reads, stubbed ──────────────────────────────────
  # `@feed` is the conversation's feed items the trace keeps.
  def read_trace(loop_id, _conversation, extra_loops: [], facts: {})
    loops = [loop_id, *extra_loops].map { |id| { "id" => id, "status" => "running" } }
    E2E::Evals::Trace.draw(E2E::Evals::Trace::EMPTY_GRAPH, [], @feed, loops: loops, facts: facts)
  end

  def phases(_loop_id) = { "spend" => { "cost_amount" => @spent, "cost_unit" => "USD" } }

  def stopped(why) = E2E::Stopped.new(why, "the run was #{why}: stopped")

  # ── caught ───────────────────────────────────────────────────────────
  def test_a_stop_after_the_turn_opened_salvages_the_opened_loop
    outcome = caught do
      open_turn("copy the files", "/tmp/project", model: "m")
      raise stopped("cost_stop")
    end
    assert_equal "cost_stop", outcome[:stopped]
    assert_nil outcome[:error]
    assert_equal "the run was cost_stop: stopped", outcome[:note]
    assert_equal [{ "id" => "loop-1", "status" => "running" }], outcome[:trace].loops, "the opened loop's trace, not Trace.empty"
    assert_equal "loop-1", outcome[:run].loop
    assert_equal "c-1", outcome[:run].conversation
    refute_includes @daemon.verbs.map(&:first), "stop", "a cost stop already stopped the conversation: no second stop"
  end

  # The model's ask stops its run where `needs_person` is raised, as the cost stop does — a watch
  # blocked beside the ask ends only on that stop — so `caught` sends none of its own.
  def test_a_needs_person_stop_already_stopped_its_run_so_caught_stops_nothing
    outcome = caught do
      open_turn("copy the files", "/tmp/project", model: "m")
      raise stopped("needs_person")
    end
    assert_equal "needs_person", outcome[:stopped]
    assert_equal [{ "id" => "loop-1", "status" => "running" }], outcome[:trace].loops, "the opened loop's trace, not Trace.empty"
    refute_includes @daemon.verbs.map(&:first), "stop", "the raise site stopped the run: no second stop"
  end

  def test_a_deadline_stop_stops_the_conversation_then_salvages
    outcome = caught do
      open_turn("copy the files", "/tmp/project", model: "m")
      raise stopped("deadline")
    end
    assert_equal "deadline", outcome[:stopped]
    assert_includes @daemon.verbs, ["stop", "c-1"], "the deadline's loop is stopped so it cannot spend into the next run"
    assert_equal [{ "id" => "loop-1", "status" => "running" }], outcome[:trace].loops
  end

  def test_a_raise_before_any_turn_opened_leaves_an_empty_trace
    outcome = caught { raise "the fixture could not be written" }
    assert_equal E2E::Evals::Trace.empty, outcome[:trace]
    assert_equal "RuntimeError: the fixture could not be written", outcome[:error]
    assert_nil outcome[:stopped]
    assert_nil outcome[:run]
  end

  def test_a_driver_that_answers_its_run_reads_that_runs_trace
    outcome = caught do
      _conversation, loop_id = open_turn("copy the files", "/tmp/project", model: "m")
      E2E::Evals::Drivers::Run.new(loop: loop_id, conversation: "c-1", extra_loops: ["loop-2"], facts: { "reply" => "DONE" })
    end
    assert_nil outcome[:stopped]
    assert_nil outcome[:error]
    assert_equal %w[loop-1 loop-2], outcome[:trace].loops.map { |row| row["id"] }
    assert_equal "DONE", outcome[:trace].fact(:reply)
  end

  def test_a_second_caught_forgets_the_previous_runs_turn
    caught { open_turn("first", "/tmp/project", model: "m") && raise(stopped("deadline")) }
    outcome = caught { raise "nothing opened this time" }
    assert_nil outcome[:run]
    assert_equal E2E::Evals::Trace.empty, outcome[:trace]
  end

  # THE PERSON'S INTERRUPT IS A RECORD: a Ctrl-C after the turn opened stops the loop, salvages its
  # trace (the spend visible) and rides the outcome as `interrupt` for the lane to re-raise once the
  # record is on disk — before, `Interrupt` (no StandardError) left no record and no artifact
  # (exit-long glm #2, glm-flash #2).
  def test_an_interrupt_after_the_turn_opened_stops_the_loop_and_salvages_its_trace
    outcome = caught do
      open_turn("copy the files", "/tmp/project", model: "m")
      raise Interrupt
    end
    assert_equal "interrupted", outcome[:stopped]
    assert_kind_of Interrupt, outcome[:interrupt]
    assert_nil outcome[:error]
    assert_equal "the run was interrupted by the person", outcome[:note]
    assert_includes @daemon.verbs, ["stop", "c-1"], "the interrupted loop is stopped so it cannot spend on"
    assert_equal [{ "id" => "loop-1", "status" => "running" }], outcome[:trace].loops, "the opened loop's trace, not Trace.empty"
    assert_equal "loop-1", outcome[:run].loop
    before_any_turn = caught { raise Interrupt }
    assert_nil before_any_turn[:run]
    assert_equal E2E::Evals::Trace.empty, before_any_turn[:trace]
    assert_kind_of Interrupt, before_any_turn[:interrupt]
  end

  # A TERM IS A STOP BY HAND TOO: the launcher stops a unit by TERMing its process group, and Ruby
  # raises that as a `SignalException`, no `Interrupt` — the in-flight run left no record and its
  # spend was in none (a manual stop's loop-until-dry kimi-k3 #3). It stops the loop, salvages the
  # trace and rides the outcome for the lane to re-raise once the record is on disk, the signal on
  # the note. Escaping `caught`, it would end this whole suite, so the escape is a failure here.
  def test_a_term_after_the_turn_opened_stops_the_loop_and_salvages_its_trace
    outcome = begin
      caught do
        open_turn("copy the files", "/tmp/project", model: "m")
        raise SignalException, "TERM"
      end
    rescue SignalException => escaped
      flunk "the TERM escaped the run's salvage: #{escaped.message}"
    end
    assert_equal "interrupted", outcome[:stopped]
    assert_equal Signal.list.fetch("TERM"), outcome[:interrupt].signo, "the lane re-raises the signal it caught"
    assert_nil outcome[:error]
    assert_equal "the run was stopped by SIGTERM", outcome[:note]
    assert_includes @daemon.verbs, ["stop", "c-1"], "the stopped loop is stopped so it cannot spend on"
    assert_equal [{ "id" => "loop-1", "status" => "running" }], outcome[:trace].loops, "the opened loop's trace, not Trace.empty"
  end

  # THE PUMP'S PARKS ARE DECIDED UNDER THE SPEND WATCH: the park loop returns only on a complete
  # row, so the exit family had no cost stop at all (exit-long glm #1: $18.71 against $8, no
  # `stopped`). Here the spend crosses the patience after the first park: the watcher stops the
  # conversation, the daemon's row reads complete, the park loop returns and the stop is raised —
  # one record, `stopped: cost_stop`.
  def test_the_pump_decides_its_parks_under_the_spend_watch_so_the_cost_stop_fires_mid_parks
    @cost_stop_usd = 8.0
    task = PumpTask.new(instruction: "port the codec", flags: { "approval" => "ask" }, policy: "approve_all", deadline_seconds: 60)
    define_singleton_method(:sleep) { |_seconds| nil }
    define_singleton_method(:task_detail) { |_loop_id, key| { "key" => key, "tool_name" => "bash", "tool_input" => { "command" => "ruby test.rb" } } }
    define_singleton_method(:followed) do |_loop_id|
      next { "complete" => true } if @daemon.verbs.any? { |verb| verb.first == "stop" }

      { "complete" => false, "attention" => { "reason" => "approval_required", "blocked_task_keys" => ["r1t0"] } }
    end
    define_singleton_method(:phases) do |_loop_id|
      { "spend" => { "cost_amount" => (@daemon.verbs.any? { |verb| verb.first == "approve" } ? "8.25" : "0.5") } }
    end
    outcome = nil
    capture_io { outcome = caught { drive_pump(task, "/tmp/project", nil) } }
    assert_equal "cost_stop", outcome[:stopped]
    assert_match(/spent 8.25 over the task's 8.0/, outcome[:note])
    assert_includes @daemon.verbs, ["approve", "loop-1", "r1t0"], "the first park was decided before the stop"
    assert_equal 1, @daemon.verbs.count { |verb| verb.first == "stop" }, "the watcher's stop, once"
    assert_includes @daemon.verbs.first, "--approval", "the pump opened the turn under ask"
    assert_equal "loop-1", outcome[:run].loop, "the opened loop is the record's"
    assert_equal 1, outcome[:run].facts["parks"], "the park decided before the stop rides the stopped record (LB-W1-1)"
    assert_equal [{ "key" => "r1t0", "tool" => "bash", "argument" => "ruby test.rb", "verb" => "approve" }], outcome[:run].facts["park_list"]
  end

  # A STOPPED PUMP RUN KEEPS ITS PARK FACTS: kimi exit-long #2 decided 63 parks and its record read
  # `parks: nil` — the park loop kept them in a local and the stop raised past `drive_pump`'s merge.
  # The deadline path here: the loop raises from INSIDE the park loop after two parks were decided;
  # the salvaged Run carries `parks: 2`, the list, and the denial the policy made — and the stop is
  # still the record's.
  def test_a_pump_stopped_after_two_parks_keeps_both_on_the_salvaged_run
    task = PumpTask.new(instruction: "port the codec", flags: { "approval" => "ask" }, policy: "exit_long", deadline_seconds: 0)
    define_singleton_method(:sleep) { |_seconds| nil }
    inputs = { "r1t0" => { "command" => "ruby test.rb" }, "r2t0" => { "command" => "cat spec/vectors/vec-01.txt" } }
    define_singleton_method(:task_detail) { |_loop_id, key| { "key" => key, "tool_name" => "bash", "tool_input" => inputs.fetch(key) } }
    define_singleton_method(:followed) do |_loop_id|
      { "complete" => false, "attention" => { "reason" => "approval_required", "blocked_task_keys" => %w[r1t0 r2t0] } }
    end
    define_singleton_method(:loop_row) { |_loop_id| { "public_id" => "loop-1", "status" => "running", "tasks" => [] } }
    define_singleton_method(:summarize) { |row| row["status"] }
    outcome = nil
    capture_io { outcome = caught { drive_pump(task, "/tmp/project", nil) } }
    assert_equal "deadline", outcome[:stopped]
    assert_match(/never completed under the pump; 2 parks/, outcome[:note])
    assert_equal 2, outcome[:run].facts["parks"]
    assert_equal 1, outcome[:run].facts["denied"]
    assert_equal({ "bash" => 2 }, outcome[:run].facts["parked_tools"])
    assert_equal %w[approve deny], outcome[:run].facts["park_list"].map { |park| park["verb"] }
    assert_equal 2, outcome[:trace].fact(:parks), "the salvaged trace reads the same facts"
    assert_includes @daemon.verbs, ["deny", "loop-1", "r2t0", E2E::ExitLongPump::REASON]
    assert_includes @daemon.verbs, ["stop", "c-1"], "the deadline's loop is stopped"
    refute outcome[:run].facts.key?("reply"), "a stopped run has no reply to print"
  end

  # THE PUMP'S PARK LOOP ATTENDS THE MODEL'S OWN ASK: the loop spends the model's whole turn, so
  # an `awaiting_human` hold is read there off the kernel's row and drawn on the run's one answer —
  # the first ask gets the bench's sentence and the parks go on; the next stops the run as
  # `needs_person`, the parks decided before it on the record.
  def daemon_asking(key) = { "complete" => false, "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => [key] } }

  def daemon_parked(key) = { "complete" => false, "attention" => { "reason" => "approval_required", "blocked_task_keys" => [key] } }

  # Each read answers the next row, its last row repeated.
  def pump_over(daemon_rows, kernel_rows)
    daemon = daemon_rows.dup
    kernel = kernel_rows.dup
    define_singleton_method(:sleep) { |_seconds| nil }
    define_singleton_method(:followed) { |_loop_id| daemon.size > 1 ? daemon.shift : daemon.first }
    define_singleton_method(:loop_row) { |_loop_id| kernel.size > 1 ? kernel.shift : kernel.first }
    define_singleton_method(:task_detail) do |_loop_id, key|
      if key.include?("-ask-")
        { "key" => key, "kind" => "await_task", "status" => "running", "prompt" => ASK }
      else
        { "key" => key, "tool_name" => "bash", "tool_input" => { "command" => "ruby test.rb" } }
      end
    end
    define_singleton_method(:result_of) { |_loop_id| "ported" }
    define_singleton_method(:summarize) { |row| row["status"] }
    task = PumpTask.new(instruction: "port the codec", flags: { "approval" => "ask" }, policy: "approve_all", deadline_seconds: 60)
    outcome = nil
    capture_io { outcome = caught { drive_pump(task, "/tmp/project", nil) } }
    outcome
  end

  def test_the_pump_answers_the_models_first_ask_once_and_decides_its_parks_on
    outcome = pump_over([daemon_asking("r2t0-ask-1"), daemon_asking("r2t0-ask-1"), daemon_parked("r3t0"), { "complete" => true }],
      [asking("loop-1", "r2t0-ask-1"), asking("loop-1", "r2t0-ask-1"), settled("loop-1")])

    assert_nil outcome[:error], "a model's ask under the pump is no lane error"
    assert_nil outcome[:stopped], "an answered ask is not a stop"
    assert_equal [["answer", "loop-1", "r2t0-ask-1", bench_answer]], @daemon.verbs.select { |verb| verb.first == "answer" },
      "answered once, though the daemon's row still read the ask after the answer"
    assert_includes @daemon.verbs, ["approve", "loop-1", "r3t0"], "the parks go on after the answer"
    assert_equal 1, outcome[:run].facts["parks"]
    assert_equal [["loop-1", "r2t0-ask-1"]], outcome[:run].facts.fetch("harness_answered").map { |row| row.values_at("loop", "key") }
    assert_equal "ported", outcome[:run].facts["reply"]
  end

  def test_a_second_ask_under_the_pump_stops_the_run_as_needs_person_with_its_parks
    outcome = pump_over([daemon_parked("r1t0"), daemon_asking("r2t0-ask-1"), daemon_asking("r2t0-ask-2")],
      [asking("loop-1", "r2t0-ask-1"), asking("loop-1", "r2t0-ask-2")])

    assert_nil outcome[:error]
    assert_equal "needs_person", outcome[:stopped]
    assert_equal [["answer", "loop-1", "r2t0-ask-1", bench_answer]], @daemon.verbs.select { |verb| verb.first == "answer" },
      "the run's one answer went to the first ask"
    assert_equal "r2t0-ask-2", outcome[:run].facts["asked_key"]
    assert_equal 1, outcome[:run].facts["parks"], "the park decided before the stop rides the stopped record"
    assert_equal [{ "key" => "r1t0", "tool" => "bash", "argument" => "ruby test.rb", "verb" => "approve" }],
      outcome[:run].facts["park_list"]
    assert_includes @daemon.verbs, ["stop", "c-1"], "the asking loop is stopped at once"
    refute outcome[:run].facts.key?("reply"), "a stopped run has no reply to print"
  end

  # ── the second turn's driver, stopped mid-way ───────────────────────
  SecondTurnTask = Data.define(:instruction, :flags, :deadline_seconds, :turns)

  # The watch saw the reply go final with the suite in the background.
  class BackgroundDaemon < DaemonDouble
    def cli(*arguments)
      return super unless arguments.first == "watch"

      @verbs << arguments
      ["background: r2t0 task — running\n", Status.new(ok: true)]
    end
  end

  # WHAT THE DRIVER SAW BEFORE A STOP IS ON THE RECORD: the v10 bench's task-mail glm-5.3 #2 went
  # final with the suite in the background and its receipt woke a turn, which then asked a person
  # and sat to the deadline — and the salvaged record read "no `background:` line", because the
  # driver's facts lived only in a local it never returned.
  def test_a_second_turn_stopped_in_the_woken_turn_keeps_what_the_driver_saw
    @daemon = BackgroundDaemon.new
    task = SecondTurnTask.new(instruction: "start the suite", flags: {}, deadline_seconds: 0,
      turns: ["Which test failed?"])
    define_singleton_method(:await_loop_completion_unattended) do |loop_id, deadline:, since: nil|
      raise stopped("deadline") if loop_id == "loop-2"

      { "public_id" => loop_id, "status" => "completed", "tasks" => [{ "key" => "r2t0", "tool_name" => "delegate_task" }] }
    end
    define_singleton_method(:result_of) { |_loop_id| "3" }
    define_singleton_method(:task_detail) { |_loop_id, key| { "key" => key, "tool_input" => { "prompt" => "run the suite" } } }
    define_singleton_method(:await_mail) { |_conversation, deadline:, origin: "task_result"| { "type" => "input_accepted" } }
    define_singleton_method(:await_next_turn) { |_conversation, after:, deadline:| "loop-2" }
    outcome = nil
    capture_io { outcome = caught { drive_say_second_turn(task, "/tmp/project", nil) } }
    assert_equal "deadline", outcome[:stopped]
    assert_equal({ "reply_final_with_background" => true, "reply" => "3", "turn_1_called" => { "delegate_task" => 1 },
                   "task_started" => true, "mailed" => true, "wake_passive" => false, "receipt_woke_a_turn" => true },
      outcome[:run].facts)
    assert outcome[:trace].fact(:reply_final_with_background), "the salvaged trace reads the same facts"
  end

  # ── the plain driver's unscripted ask ───────────────────────────
  PlainTask = Data.define(:instruction, :flags, :deadline_seconds)

  ASKING_ROW = {
    "public_id" => "loop-1", "status" => "running", "attention" => { "reason" => "awaiting_human" }, "tasks" => [
      { "key" => "r1", "kind" => "model_task", "status" => "completed" },
      { "key" => "r2t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "ask" },
      { "key" => "r2t0-ask-1", "kind" => "await_task", "status" => "running", "addressed_to" => { "role" => "agent" } },
    ],
  }.freeze
  # The same loop a second time, asking again under a fresh key: one ask
  # the harness answers, the next one stops the run.
  SECOND_ASKING_ROW = ASKING_ROW.merge("tasks" => ASKING_ROW.fetch("tasks").map do |task|
    task["key"] == "r2t0-ask-1" ? task.merge("key" => "r2t0-ask-2") : task
  end).freeze
  SETTLED_ROW = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
    { "key" => "r1", "kind" => "model_task", "status" => "completed" },
  ] }.freeze
  ASK = "Should I force-push the rewritten history to origin? It cannot be undone.".freeze

  # THE UNSCRIPTED ASK, AND THE ONE ANSWER THE HARNESS GIVES IT (bench version 10, the owner's
  # ruling of 2026-09-23). A plain run scripts no person, so a model that calls its own `ask` parks
  # the loop `awaiting_human` and nobody will ever answer — seven scoring runs idled that way to the
  # deadline (≈ 88 min of box time). The harness first learned to stop at once as `needs_person`;
  # but the ACP door has no answer to script either (harbor's runner answers nothing, so the model
  # simply runs on there), so the two forms were not comparable trial for trial — five trials of the
  # 2026-09-18 plain floor cell stopped on an ask and the verification PASSED three of them. The
  # harness now answers the BENCH's own sentence once and stops at the NEXT ask, and both the
  # question and the answer ride the record so no reader mistakes the harness for a person.
  def plain_run_over(rows)
    task = PlainTask.new(instruction: "sanitize the repo", flags: {}, deadline_seconds: 600)
    @slept = []
    # A driver that waits an interval out on the park is the old one: the
    # stub raises past the first, so the pin fails instead of spinning.
    define_singleton_method(:sleep) { |seconds| (@slept << seconds).size > 1 && raise("a poll interval was waited out on the park") }
    @reads = 0
    scripted = rows.dup
    define_singleton_method(:loop_row) do |_loop_id|
      @reads += 1
      scripted.shift || rows.last
    end
    define_singleton_method(:task_detail) { |_loop_id, key| { "key" => key, "kind" => "await_task", "status" => "running", "prompt" => ASK } }
    outcome = nil
    capture_io { outcome = caught { drive_plain(task, "/tmp/project", nil) } }
    outcome
  end

  def bench_answer = EvalsFixtureBench.read.unattended_answer_text

  def test_the_harness_answers_the_first_ask_with_the_benchs_sentence_and_the_run_goes_on
    outcome = plain_run_over([ASKING_ROW, SETTLED_ROW])

    assert_nil outcome[:stopped], "an answered ask is not a stop"
    assert_equal 3, @reads, "the park is read, answered, the loop polled again, then read once for its tasks"
    assert_empty @slept
    assert_includes @daemon.verbs, ["answer", "loop-1", "r2t0-ask-1", bench_answer],
      "the sentence is the BENCH's, so a changed word is a changed digest"
    refute_includes @daemon.verbs.map(&:first), "stop", "the run was never stopped"
    answered = outcome[:run].facts.fetch("harness_answered")
    assert_equal ["r2t0-ask-1"], answered.map { |row| row.fetch("key") }
    assert_equal ASK, answered.first.fetch("prompt")
    assert_equal bench_answer, answered.first.fetch("answer"),
      "the record says what the harness said, so no reader takes it for a person"
  end

  def test_a_second_ask_stops_the_run_as_needs_person_with_the_first_answer_still_on_the_record
    outcome = plain_run_over([ASKING_ROW, SECOND_ASKING_ROW])

    assert_equal "needs_person", outcome[:stopped]
    assert_equal 2, @reads, "one answer, then the second park stops the run"
    assert_empty @slept
    assert_equal 1, @daemon.verbs.count { |verb| verb.first == "answer" }, "the bench allows one answer, not one per ask"
    assert_includes @daemon.verbs, ["stop", "c-1"], "the asking loop is stopped at once, where the stop is raised"
    assert_equal 1, @daemon.verbs.count { |verb| verb.first == "stop" }, "the raise site's stop; `caught` sends none"
    refute_includes @daemon.verbs.map(&:first), "result", "a stopped run has no reply to print"
    assert_equal "r2t0-ask-2", outcome[:run].facts["asked_key"], "the ask's task key rides the record's facts"
    assert_equal ASK, outcome[:run].facts["asked_prompt"], "the ask's prompt text rides the record's facts"
    assert_equal "r2t0-ask-2", outcome[:trace].fact(:asked_key), "the salvaged trace reads the same facts"
    assert_equal ["r2t0-ask-1"], outcome[:run].facts.fetch("harness_answered").map { |row| row.fetch("key") },
      "the answer the harness did give is still on the record beside the stop"
    assert_match(/the model asked a person \(r2t0-ask-2\): "Should I force-push/, outcome[:note])
  end

  # The lane's record over the outcome, as far as the scorecard reads it (`build_record`'s facts):
  # a terminal-bench task the verification passed, the trace's structure facts beside the run's own.
  def record_of(outcome, facts: {})
    trace = outcome.fetch(:trace)
    E2E::Evals::Drawing.record(task: "sanitize-git-repo", family: "terminal-bench", reached: nil, succeeded: nil, task_pass: true,
      stopped: outcome[:stopped], error: outcome[:error], facts: trace.structure_facts.merge(trace.facts).merge(facts))
  end

  # THE ANSWERED RUN READS GREEN ON THE SCORECARD: the kernel narrates the ask it parked on as
  # `attention_required{awaiting_human}` and the item stays on the feed after the answer, so the
  # trace of a run the harness answered carries it, with the run's own `harness_answered` beside it.
  def test_a_run_the_harness_answered_and_that_then_finished_is_green_on_the_scorecard
    @feed = [{ "type" => "attention_required", "payload" => { "reason" => "awaiting_human" } }]
    outcome = plain_run_over([ASKING_ROW, SETTLED_ROW])

    record = record_of(outcome)
    assert_equal({ "awaiting_human" => 1 }, record.dig("facts", "attention_reasons"), "the trace kept the kernel's item")
    assert_nil E2E::Evals::Scorecard.classify(record), "the harness's own answer is never a kernel finding"
  end

  # A REFUSED ANSWER IS THE HARNESS'S OWN FAILURE: the model asked once and the harness's verb
  # failed, so the run is a lane error, never the model's `needs_person`, and the record claims no
  # answer that never reached the model. The rounds the model settled before its ask do not make
  # the harness's failure the model's conduct.
  def test_an_answer_the_daemon_refuses_is_a_lane_bug_and_records_no_answer
    @daemon = RefusingDaemon.new
    outcome = plain_run_over([ASKING_ROW, SETTLED_ROW])

    assert_nil outcome[:stopped], "the model did not stop the run"
    assert_equal "RuntimeError: the harness could not answer r2t0-ask-1: no such task", outcome[:error]
    assert_equal 1, @daemon.verbs.count { |verb| verb.first == "answer" }, "never retried"
    refute outcome[:run].facts.key?("harness_answered"), "the refused answer was never given"
    refute outcome[:run].facts.key?("asked_key"), "the ask did not end the run"
    record = record_of(outcome, facts: { "rounds_settled" => 1 })
    assert_equal E2E::Evals::Scorecard::LANE_BUG, E2E::Evals::Scorecard.classify(record)
  end

  # The deadline path is unchanged: a loop running and asking nobody — or
  # resting on an approval park, which is not an ask (rho's `react` denies
  # those and runs on) — waits its deadline out and is stopped as before.
  def test_the_plain_driver_keeps_the_deadline_for_a_loop_that_asks_nobody
    task = PlainTask.new(instruction: "sanitize the repo", flags: {}, deadline_seconds: 0)
    define_singleton_method(:sleep) { |_seconds| nil }
    rows = [{ "public_id" => "loop-1", "status" => "running", "attention" => nil, "tasks" => [] },
            { "public_id" => "loop-1", "status" => "running", "attention" => { "reason" => "approval_required" }, "tasks" => [] }]
    # One definition over the row in hand (a second define_singleton_method
    # of the same name is a Ruby redefinition warning in the suite's output).
    define_singleton_method(:loop_row) { |_loop_id| @row }
    rows.each do |row|
      @daemon = DaemonDouble.new
      @row = row
      outcome = nil
      capture_io { outcome = caught { drive_plain(task, "/tmp/project", nil) } }
      assert_equal "deadline", outcome[:stopped], "attention #{row["attention"].inspect} is no ask"
      assert_match(/the loop never settled in 0 s/, outcome[:note])
      assert_includes @daemon.verbs, ["stop", "c-1"]
      refute outcome[:run].facts.key?("asked_key")
    end
  end

  def test_the_plain_driver_answers_its_run_when_the_loop_settles
    task = PlainTask.new(instruction: "sanitize the repo", flags: {}, deadline_seconds: 600)
    define_singleton_method(:loop_row) { |_loop_id| { "public_id" => "loop-1", "status" => "completed", "attention" => nil, "tasks" => [] } }
    outcome = nil
    capture_io { outcome = caught { drive_plain(task, "/tmp/project", nil) } }
    assert_nil outcome[:stopped]
    assert_nil outcome[:error]
    assert_equal "loop-1", outcome[:run].loop
    assert_includes @daemon.verbs, ["result", "loop-1"], "the reply is printed through the binary"
    refute_includes @daemon.verbs.map(&:first), "stop"
  end

  # ── every wait of a run shares the one answer ───────────────────
  # The drivers that wait on more than one loop — the woken turn, the
  # person's turn 2, the receipt-woken loops — answer the run's first ask
  # wherever it lands and stop at the next; an ask no wait attends would
  # idle the run to its deadline.
  def asking(loop_id, key)
    ASKING_ROW.merge("public_id" => loop_id, "tasks" => ASKING_ROW.fetch("tasks").map do |task|
      task["kind"] == "await_task" ? task.merge("key" => key) : task
    end)
  end

  def settled(loop_id) = SETTLED_ROW.merge("public_id" => loop_id)

  TASK_STARTED_ROW = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
    { "key" => "r1", "kind" => "model_task", "status" => "completed" },
    { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "delegate_task" },
  ] }.freeze

  # Each loop's rows, one per read, its last row repeated; a wait that
  # spins past twenty polls is a wait that never answered.
  def loops_scripted!(scripts)
    rows = scripts.transform_values(&:dup)
    @polls = 0
    define_singleton_method(:sleep) { |_seconds| (@polls += 1) > 20 && raise("a wait spun on an unanswered ask") }
    define_singleton_method(:loop_row) { |loop_id| rows.fetch(loop_id).then { |left| left.size > 1 ? left.shift : left.first } }
    define_singleton_method(:task_detail) { |_loop_id, key| { "key" => key, "kind" => "await_task", "status" => "running", "prompt" => ASK } }
    define_singleton_method(:result_of) { |_loop_id| "3" }
  end

  def second_turn_over(scripts)
    @daemon = BackgroundDaemon.new
    loops_scripted!(scripts)
    define_singleton_method(:await_mail) { |_conversation, deadline:, origin: "task_result"| { "type" => "input_accepted" } }
    define_singleton_method(:await_next_turn) { |_conversation, after:, deadline:| "loop-2" }
    task = SecondTurnTask.new(instruction: "start the suite", flags: {}, deadline_seconds: 600, turns: [])
    outcome = nil
    capture_io { outcome = caught { drive_say_second_turn(task, "/tmp/project", nil) } }
    outcome
  end

  def test_the_woken_turns_ask_gets_the_unattended_answer_and_rides_the_record
    outcome = second_turn_over("loop-1" => [TASK_STARTED_ROW], "loop-2" => [asking("loop-2", "r2t0-ask-1"), settled("loop-2")])

    assert_nil outcome[:stopped], "an answered ask is not a stop"
    assert_nil outcome[:error]
    assert_includes @daemon.verbs, ["answer", "loop-2", "r2t0-ask-1", bench_answer]
    assert_equal [["loop-2", "r2t0-ask-1"]], outcome[:trace].fact(:harness_answered).map { |row| row.values_at("loop", "key") },
      "the driver builds its Run from what it saw; the answer the wait gave rides the settled record too"
    assert_equal %w[loop-2], outcome[:run].extra_loops
  end

  def test_a_second_ask_across_the_runs_waits_stops_it_as_needs_person
    outcome = second_turn_over("loop-1" => [asking("loop-1", "r2t0-ask-1"), TASK_STARTED_ROW],
      "loop-2" => [asking("loop-2", "r3t0-ask-1")])

    assert_equal "needs_person", outcome[:stopped]
    assert_equal [["answer", "loop-1", "r2t0-ask-1", bench_answer]], @daemon.verbs.select { |verb| verb.first == "answer" },
      "turn 1's wait spent the run's one answer"
    assert_equal "r3t0-ask-1", outcome[:run].facts["asked_key"]
    assert_equal "loop-2", outcome[:run].facts["asked_loop"]
    assert_equal [["loop-1", "r2t0-ask-1"]], outcome[:run].facts.fetch("harness_answered").map { |row| row.values_at("loop", "key") }
    assert_includes @daemon.verbs, ["stop", "c-1"], "the asking loop is stopped at once"
  end

  # ── a receipt the model asked not to be woken by ────────────────
  # THE PASSIVE WAKE IS THE MODEL'S CHOICE, NEVER THE LANE'S FAULT: the v11 bench's
  # task-detached-receipt kimi-k3 #2 handed the suite to `task` with `wake: "passive"`; the kernel
  # mailed the receipt as history and started no reply, as the tool text says it will, and the
  # driver waited 300 s for a woken turn, raised, and the record read as a lane bug. The call's own
  # wake is read off its input: when every detached call asked passive, no woken turn is awaited,
  # `receipt_woke_a_turn` is false and `wake_passive` says why; the person's turn 2, when the task
  # has one, is said after turn 1.
  SPAWNED_ROW = { "public_id" => "loop-1", "status" => "completed", "tasks" => [
    { "key" => "r1", "kind" => "model_task", "status" => "completed" },
    { "key" => "r1t0", "kind" => "tool_task", "status" => "completed", "tool_name" => "spawn" },
  ] }.freeze

  def passive_calls!(row)
    @daemon = BackgroundDaemon.new
    loops_scripted!("loop-1" => [row])
    define_singleton_method(:task_detail) { |_loop_id, key| { "key" => key, "tool_input" => { "wake" => "passive" } } }
    define_singleton_method(:await_mail) { |_conversation, deadline:, origin: "task_result"| { "type" => "input_accepted" } }
    define_singleton_method(:await_next_turn) { |_conversation, after:, deadline:| raise "awaited a turn a passive receipt never wakes" }
    @said_after = nil
    define_singleton_method(:say_turn_two!) do |_task, _conversation, after:, origin: "task_result"|
      @said_after = after
      ["loop-3", { "turn_2_loop" => "loop-3" }]
    end
  end

  def test_a_passive_task_call_awaits_no_woken_turn
    passive_calls!(TASK_STARTED_ROW)
    task = SecondTurnTask.new(instruction: "start the suite", flags: {}, deadline_seconds: 600, turns: [])
    outcome = nil
    capture_io { outcome = caught { drive_say_second_turn(task, "/tmp/project", nil) } }

    assert_nil outcome[:error]
    assert_nil outcome[:stopped]
    assert_equal({ "mailed" => true, "wake_passive" => true, "receipt_woke_a_turn" => false },
      outcome[:run].facts.slice("mailed", "wake_passive", "receipt_woke_a_turn"))
    assert_empty outcome[:run].extra_loops
  end

  def test_a_passive_task_call_says_the_persons_turn_after_turn_one
    passive_calls!(TASK_STARTED_ROW)
    task = SecondTurnTask.new(instruction: "start the suite", flags: {}, deadline_seconds: 600, turns: ["Which test failed?"])
    outcome = nil
    capture_io { outcome = caught { drive_say_second_turn(task, "/tmp/project", nil) } }

    assert_nil outcome[:error]
    assert_equal %w[loop-1], @said_after
    assert_equal %w[loop-3], outcome[:run].extra_loops
    assert_equal({ "receipt_woke_a_turn" => false, "turn_2_loop" => "loop-3" },
      outcome[:run].facts.slice("receipt_woke_a_turn", "turn_2_loop"))
  end

  def test_a_passive_spawn_awaits_no_woken_turn
    passive_calls!(SPAWNED_ROW)
    task = SecondTurnTask.new(instruction: "spawn a child for the suite", flags: {}, deadline_seconds: 600, turns: [])
    outcome = nil
    capture_io { outcome = caught { drive_spawn_reply(task, "/tmp/project", nil) } }

    assert_nil outcome[:error]
    assert_equal({ "child_replied" => true, "wake_passive" => true, "reply_woke_a_turn" => false },
      outcome[:run].facts.slice("child_replied", "wake_passive", "reply_woke_a_turn"))
    assert_empty outcome[:run].extra_loops
  end

  # The workflow family's door: the receipts woke a loop that asks while
  # the conversation is read for quiet.
  def test_settle_receipts_answers_a_receipt_woken_loops_ask_once_and_the_record_keeps_it
    loops_scripted!("loop-1" => [settled("loop-1")],
      "loop-2" => [asking("loop-2", "r3t0-ask-1"), asking("loop-2", "r3t0-ask-1"), settled("loop-2")])
    define_singleton_method(:loops_on_feed) { |_conversation| %w[loop-1 loop-2] }
    task = PlainTask.new(instruction: "run the pipeline", flags: {}, deadline_seconds: 600)
    outcome = nil
    capture_io { outcome = caught { drive_settle_receipts(task, "/tmp/project", nil) } }

    assert_nil outcome[:stopped]
    assert_nil outcome[:error]
    assert_equal [["answer", "loop-2", "r3t0-ask-1", bench_answer]], @daemon.verbs.select { |verb| verb.first == "answer" }
    assert_equal %w[loop-2], outcome[:trace].fact(:woken_loops)
    assert_equal [["loop-2", "r3t0-ask-1"]], outcome[:trace].fact(:harness_answered).map { |row| row.values_at("loop", "key") }
  end

  # THE STEP A DRIVER OWES AFTER ITS RUN, by the driver's name: the brake's
  # loop rests `needs_attention`, alive, and is stopped once the run is
  # recorded; every other driver owes nothing, and a run that never opened
  # has nothing to stop.
  def test_only_the_brake_owes_a_step_after_its_run
    run = E2E::Evals::Drivers::Run.one("loop-1", "c-1")
    after_drive("plain", run)
    after_drive("brake", nil)
    assert_empty @daemon.verbs

    after_drive("brake", run)
    assert_equal [["stop", "c-1"]], @daemon.verbs
  end

  # The pollers beside a blocked verb — the spend watch and the ask attendant — poll fast here.
  def watching_spend(loop_id, every: 0.02, &block) = super(loop_id, every: every, &block)

  def attending_asks(loop_id, every: 0.02, &block) = super(loop_id, every: every, &block)

  # ── watching_spend ───────────────────────────────────────────────────
  def test_the_spend_is_watched_while_a_cli_verb_blocks_and_the_stop_is_raised_after_it_returns
    @cost_stop_usd = 8.0
    @spent = "8.25"
    open_turn("copy the files", "/tmp/project", model: "m")
    watched = nil
    error = assert_raises(E2E::Stopped) do
      watching_spend("loop-1", every: 0.02) { watched, = @daemon.cli("watch", "loop-1", "--timeout", "600") }
    end
    assert_equal "cost_stop", error.why
    assert_match(/spent 8.25 over the task's 8.0/, error.message)
    assert_equal "watched: stopped", watched, "the watch returned once the stop landed, before the raise"
    assert_equal 1, @daemon.verbs.count { |verb| verb.first == "stop" }, "one stop, however many polls"
  end

  def test_a_watch_under_the_cap_answers_the_verbs_own_value_and_stops_nothing
    @cost_stop_usd = 8.0
    @spent = "0.5"
    open_turn("copy the files", "/tmp/project", model: "m")
    answer = watching_spend("loop-1", every: 0.02) do
      sleep 0.1
      "the ladder line"
    end
    assert_equal "the ladder line", answer
    refute_includes @daemon.verbs.map(&:first), "stop"
  end

  def test_a_poll_that_cannot_read_the_spend_keeps_watching
    @cost_stop_usd = 8.0
    @spent = "8.25"
    open_turn("copy the files", "/tmp/project", model: "m")
    reads = 0
    define_singleton_method(:phases) do |_loop_id|
      reads += 1
      raise Errno::ECONNRESET, "the route blinked" if reads == 1

      { "spend" => { "cost_amount" => @spent } }
    end
    assert_raises(E2E::Stopped) do
      watching_spend("loop-1", every: 0.02) { @daemon.cli("watch", "loop-1", "--timeout", "600") }
    end
    assert_operator reads, :>=, 2
  end
end

require_relative "evals_salvage/attended_watch"
