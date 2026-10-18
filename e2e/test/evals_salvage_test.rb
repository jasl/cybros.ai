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
      { "key" => "r2t0-ask-1", "kind" => "await_task", "status" => "running", "addressed_to" => { "role" => "agent_application" } },
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
