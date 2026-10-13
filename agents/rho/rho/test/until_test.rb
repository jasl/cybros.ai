require "test_helper"

# The gate decides from the TRACE and acts with ONE append; these pin
# the predicate, the three envelopes, and the bounds — against fakes of
# the two things it talks to. THE CHECK IS A BASH TOOL STEP ON THE BOUND
# RUNNER: the gate never runs a command; it reads the settled
# row's detail once and records the verdict off its exit status.
class UntilTest < Minitest::Test
  RunTask = CybrosAgent::Api::RunTask

  # THE ONE FOLD: `--until`/`--attempts` into the body's
  # `until` block — the same method for the shipped `run` and rho-dev's
  # `do`; no command, no block; the default attempts filled in.
  def test_fold_puts_the_check_on_the_body_once
    assert_equal({ "prompt" => "p", "until" => { "command" => "make test", "attempts" => 2 } },
      Rho::Until.fold({ "prompt" => "p" }, until: "make test", attempts: 2))
    assert_equal({ "prompt" => "p", "until" => { "command" => "make test", "attempts" => Rho::Until::DEFAULT_ATTEMPTS } },
      Rho::Until.fold({ "prompt" => "p" }, until: "make test", attempts: nil))
    body = { "prompt" => "p" }
    assert_same body, Rho::Until.fold(body, until: nil, attempts: 3), "no command: the body as it came"
  end
  RunTaskDetail = CybrosAgent::Api::RunTaskDetail
  Run = CybrosAgent::Api::Run

  # The run context the gate is handed: the trace it reads, the ONE
  # detail read per attempt, and the door it appends through.
  class FakeContext
    attr_reader :appends, :detail_reads

    def initialize(trace, detail: nil)
      @trace = trace
      @detail = detail
      @appends = []
      @detail_reads = []
    end

    def fetch = @trace

    def task(key)
      @detail_reads << key
      @detail
    end

    def append(**fields)
      @appends << fields
      :receipt
    end
  end

  def setup
    @dir = "/srv/app"
    @seed = { "model" => { "model" => "m/x" }, "tools" => [{ "t" => 1 }], "instructions" => "be good" }
    @policy = Rho::Until::Policy.new(command: "ruby check.rb", attempts: 3, directory: @dir, runner: nil, seed: @seed)
  end

  def task(key, kind, status, error: nil)
    RunTask.new(key: key, kind: kind, lifetime: "conversation", wake: "auto", status: status, on_failure: nil, failure_resolution: nil,
      tool_name: nil, result: nil, error: error, visibility: nil,
      created_at: nil, started_at: nil, completed_at: nil)
  end

  # The deliverable is the hold once it is placed; the gate never reads
  # it — the settled check row is its evidence.
  def trace(tasks, status: "running", attention: nil, deliverable: "hold-1")
    Run.new(public_id: "run-1", status: status, failure_reason: nil,
      deliverable_task_key: deliverable, tasks: tasks, task_progress: nil, attention: attention,
      started_at: nil, paused_at: nil, completed_at: nil, created_at: nil, updated_at: nil)
  end

  def settled_trace(attempt: 1)
    trace([
      task(Rho::Until.work_key(attempt), "model_task", "completed"),
      task("r1t0", "tool_task", "completed"),
      task("r1", "model_task", "completed"),
      task(Rho::Until.check_key(attempt), "tool_task", "completed"),
      task(Rho::Until.hold_key(attempt), "await_task", "dispatched"),
    ])
  end

  # A SETTLED ROW as the single-task read renders it: `exit_status` rides
  # the structured content on every exit, and is absent on a timeout or a
  # refusal to start.
  def detail(status: "completed", exit_status: nil, output: "boom\nexit", error: nil, attempt: 1)
    RunTaskDetail.new(
      task: task(Rho::Until.check_key(attempt), "tool_task", status, error: error),
      output: output, content: nil,
      structured_content: (exit_status.nil? ? nil : { "exit_status" => exit_status }),
      prompt: nil, tool_input: nil
    )
  end

  def gate(**options)
    Rho::Until::Gate.new(policy: @policy, timeout_seconds: 5, **options)
  end

  # ---- the predicate ----

  def test_ready_when_the_check_settled_and_the_hold_is_parked
    assert_equal 1, gate.ready?(settled_trace)
  end

  def test_not_ready_while_the_check_itself_is_live
    running = trace(settled_trace.tasks.map { |t| t.key == "check-1" ? task("check-1", "tool_task", "dispatched") : t })
    assert_nil gate.ready?(running), "a live check row is `not yet`"
    unplaced = trace(settled_trace.tasks.reject { |t| t.key == "check-1" })
    assert_nil gate.ready?(unplaced), "a hold with no settled check beside it is not a verdict"
  end

  def test_not_ready_while_a_round_or_a_tool_call_is_live
    live = trace([
      task("work", "model_task", "completed"), task("r1t0", "tool_task", "dispatched"),
      task("r1", "model_task", "waiting"), task("check-1", "tool_task", "completed"),
      task("hold-1", "await_task", "dispatched"),
    ])
    assert_nil gate.ready?(live)
  end

  def test_a_pending_child_report_delays_the_verdict_and_followup_work
    completion = task("r1t0-delegation-1", "delegation_task", "running").with(lifetime: "turn")
    context = FakeContext.new(trace(settled_trace.tasks + [completion]), detail: detail(exit_status: 0))
    g = gate

    assert_nil g.ready?(context.fetch)
    g.reconsider(context)
    assert_empty context.detail_reads
    assert_empty context.appends
    assert_equal 1, g.ready?(trace(settled_trace.tasks + [completion.with(status: "completed")]))
  end

  def test_not_ready_while_the_run_is_asking_or_not_running
    asking = trace(settled_trace.tasks, attention: :something)
    assert_nil gate.ready?(asking)
    paused = trace(settled_trace.tasks, status: "paused")
    assert_nil gate.ready?(paused)
  end

  def test_not_ready_until_the_hold_is_parked
    waiting = trace(settled_trace.tasks.map { |t| t.key == "hold-1" ? task("hold-1", "await_task", "waiting") : t })
    assert_nil gate.ready?(waiting)
  end

  def test_not_ready_once_the_next_attempt_or_the_closing_round_is_planted
    planted = trace(settled_trace.tasks + [task("work-2", "model_task", "waiting")])
    assert_nil gate.ready?(planted)
    closing = trace(settled_trace.tasks + [task("summary", "model_task", "running")])
    assert_nil gate.ready?(closing)
  end

  def test_the_attempt_is_read_off_the_hold
    assert_equal 2, gate.ready?(settled_trace(attempt: 2))
  end

  # ---- the three envelopes ----

  def test_a_failing_check_plants_the_next_attempt_and_its_gate_and_moves_the_deliverable
    context = FakeContext.new(settled_trace, detail: detail(exit_status: 1))
    g = gate

    g.reconsider(context)

    assert_equal %w[check-1], context.detail_reads, "one detail read: the verdict is on the row"
    append = context.appends.fetch(0)
    assert_equal [{ "task" => "hold-1", "content" => "check 1/3: exit 1" }], append[:resolve]
    refute append.key?(:deliverable), "the envelope's end is the answer; nothing names one"
    assert_equal Rho::Until.idempotency_key("run-1", 1), append[:idempotency_key]
    refute append.key?(:expected_revision), "the trace carries no counter to fence on"
    work, check, hold = append[:steps]
    assert_instance_of CybrosAgent::Steps::Model, work
    assert_equal "work-2", work.key
    assert_equal @seed["model"], work.model
    assert_equal @seed["tools"], work.tools
    assert_equal @seed["instructions"], work.instructions
    assert_includes work.prompt, "exited with status 1 (check 1 of 3)"
    assert_includes work.prompt, "result of `check-1`"
    assert_equal %w[check-1 hold-1], work.results,
      "the round names the check and its verdict: nothing reaches it by position across appends"
    refute_includes work.prompt, "boom", "the model reads the check's output as the named result, never a copy"
    refute_includes work.prompt, "full output:"
    assert_equal Rho::Until.check_steps(2, command: "ruby check.rb", directory: @dir, timeout_seconds: 5), [check, hold],
      "the next check is placed after its attempt, by position, with its hold behind it"
    assert_instance_of CybrosAgent::Steps::Tool, check
    assert_equal ["bash", { "command" => "ruby check.rb", "workdir" => @dir, "timeout" => 5 }, "check-2",
                  Rho::Until::CHECK_PARK_MS, "absorb"],
      [check.name, check.input, check.key, check.timeout_ms, check.on_failure]
    assert_instance_of CybrosAgent::Steps::Ask, hold
    assert_equal "hold-2", hold.key
    refute g.done?
    assert_equal ["exit 1"], g.checks.map(&:verdict)
  end

  def test_a_passing_check_plants_the_summary_and_is_done
    context = FakeContext.new(settled_trace, detail: detail(exit_status: 0, output: "fine"))
    g = gate

    g.reconsider(context)

    append = context.appends.fetch(0)
    assert_equal [{ "task" => "hold-1", "content" => "check 1/3: passed" }], append[:resolve]
    assert_equal ["summary"], append[:steps].map(&:key)
    assert_includes append[:steps].first.prompt, "passed"
    assert_equal %w[check-1 hold-1], append[:steps].first.results
    assert g.done?
    assert_equal ["passed"], g.checks.map(&:verdict)
  end

  def test_the_last_allowed_failure_plants_the_report_and_is_done
    context = FakeContext.new(settled_trace(attempt: 3), detail: detail(exit_status: 2, attempt: 3))
    g = gate

    g.reconsider(context)

    append = context.appends.fetch(0)
    assert_equal ["report"], append[:steps].map(&:key)
    assert_includes append[:steps].first.prompt, "last allowed run"
    assert_includes append[:steps].first.prompt, "Do not continue working"
    assert_includes append[:steps].first.prompt, "result of `check-3`"
    assert_equal %w[check-3 hold-3], append[:steps].first.results, "the last attempt's check, by name"
    assert g.done?
  end

  # A timeout is `completed` with no exit status and bash's own sentence
  # in the output — the runner's contract, read as such.
  def test_a_timeout_is_a_failure_that_says_so
    context = FakeContext.new(settled_trace,
      detail: detail(output: "partial\n\nCommand timed out after 5 seconds"))
    g = gate
    g.reconsider(context)

    assert_includes context.appends.fetch(0)[:steps].first.prompt, "did not finish in time"
    assert_equal [{ "task" => "hold-1", "content" => "check 1/3: timed out" }], context.appends.fetch(0)[:resolve]
    assert_equal ["timed out"], g.checks.map(&:verdict)
  end

  def test_nothing_happens_when_the_trace_is_not_settled
    context = FakeContext.new(trace([task("work", "model_task", "running")]), detail: detail(exit_status: 0))

    gate.reconsider(context)

    assert_empty context.detail_reads, "no row is read until the trace says one settled"
    assert_empty context.appends
  end

  def test_the_key_is_deterministic_and_fits_the_receipts_column
    key = Rho::Until.idempotency_key("01a063fb-5002-7af6-858a-93e449628a97", 2)
    assert_equal key, Rho::Until.idempotency_key("01a063fb-5002-7af6-858a-93e449628a97", 2)
    assert_equal 36, key.bytesize
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, key)
    refute_equal key, Rho::Until.idempotency_key("01a063fb-5002-7af6-858a-93e449628a97", 3)
    refute_equal key, Rho::Until.idempotency_key("01a063fb-5002-7af6-858a-93e449628a97", 2, "release")
  end

  def test_a_stale_revision_is_left_for_the_next_nudge
    stale = Class.new(FakeContext) do
      def append(**) = raise CybrosAgent::Api::Conflict.new("stale_revision", code: "stale_revision")
    end.new(settled_trace, detail: detail(exit_status: 1))
    g = gate
    g.reconsider(stale)

    refute g.done?, "a conflict means the trace moved; look again on the next nudge"
  end

  # The verdict is on the row; the recording is retried, and a kernel that
  # keeps refusing gets the run back with the reason rather than a run
  # parked behind its hold for twelve hours.
  def test_a_refused_append_is_retried_then_the_run_is_given_back_with_the_reason
    refusing = Class.new(FakeContext) do
      attr_reader :tries

      def append(**fields)
        @tries = (@tries || 0) + 1
        raise CybrosAgent::Api::InvalidRequest.new("Invalid parameter: x", code: "invalid_request") if @tries <= 4

        super
      end
    end.new(settled_trace, detail: detail(exit_status: 1))
    naps = []
    g = gate(sleeper: ->(s) { naps << s })

    g.reconsider(refusing)

    assert_equal %w[check-1], refusing.detail_reads, "the row is read once; only the append is retried"
    assert_equal [2.0, 4.0, 6.0], naps
    assert g.done?
    release = refusing.appends.fetch(0)
    assert_equal ["report"], release[:steps].map(&:key)
    assert_includes release[:steps].first.prompt, "verdict could not be recorded"
    assert_includes release[:steps].first.prompt, "Invalid parameter"
    assert_equal [{ "task" => "hold-1", "content" => "check 1/3: the acceptance check's verdict could not be recorded " \
                                                    "(InvalidRequest: Invalid parameter: x)" }], release[:resolve]
    assert_equal Rho::Until.idempotency_key("run-1", 1, "release"), release[:idempotency_key]
  end

  # A check the RUNNER could not run — no executor announces bash, the
  # park expired, the claim died — is a failed row (absorbed, so the hold
  # still parks): the run is given back with the kernel's detail.
  def test_a_check_that_could_not_run_gives_the_run_back_too
    context = FakeContext.new(settled_trace, detail: detail(status: "failed", output: nil,
      error: { "key" => "tool_not_served", "detail" => "no executor announces bash for this principal" }))
    g = gate

    g.reconsider(context)

    release = context.appends.fetch(0)
    assert_equal ["report"], release[:steps].map(&:key)
    assert_includes release[:steps].first.prompt, "could not be run: no executor announces bash"
    assert_equal %w[check-1 hold-1], release[:steps].first.results, "the failed row is read by name, its error with it"
    assert_equal [{ "task" => "hold-1",
                    "content" => "check 1/3: the acceptance check could not be run: no executor announces bash for this principal" }],
      release[:resolve]
    assert g.done?
    assert_empty g.checks, "nothing ran, so nothing is a check"
  end

  # Bash refusing to START — the directory gone where the runner is — is
  # `completed` with no exit status and bash's sentence: the run is given
  # back with that line, which is what a wrong `--dir` on a remote runner
  # now reads as.
  def test_bash_refusing_to_start_gives_the_run_back_with_its_sentence
    context = FakeContext.new(settled_trace,
      detail: detail(output: "Working directory does not exist: /x\nCannot execute bash commands."))

    gate.reconsider(context)

    release = context.appends.fetch(0)
    assert_equal ["report"], release[:steps].map(&:key)
    assert_equal [{ "task" => "hold-1",
                    "content" => "check 1/3: the acceptance check could not be run: Working directory does not exist: /x" }],
      release[:resolve]
  end

  def test_worth_a_look_is_the_cheap_filter_over_the_followers_table
    g = gate
    row = ->(key, kind, status) { Rho::HostFollower::Task.new(task_key: key, kind: kind, status: status, error_key: nil, failure_resolution: nil) }
    parked = [row.call("hold-1", "await_task", "dispatched"), row.call("check-1", "tool_task", "completed"),
              row.call("r1", "model_task", "completed")]
    assert g.worth_a_look?(parked)
    checking = [row.call("hold-1", "await_task", "waiting"), row.call("check-1", "tool_task", "dispatched"),
                row.call("r1", "model_task", "completed")]
    refute g.worth_a_look?(checking), "a live check row is not yet a verdict"
    busy = parked + [row.call("r2", "model_task", "running")]
    refute g.worth_a_look?(busy)
    child = row.call("r1t0-delegation-1", "delegation_task", "running")
    refute g.worth_a_look?(parked + [child]), "a pending child report is still work"
    assert g.worth_a_look?(parked + [child.with(status: "completed")])
    refute g.worth_a_look?([])
  end

  # Nothing runs in this process: a cancel ends the policy, and a check in
  # flight is the kernel's to cancel through `rho stop` like any tool call.
  def test_cancel_ends_the_policy_and_reads_nothing
    g = gate
    g.cancel!

    assert g.done?
    context = FakeContext.new(settled_trace, detail: detail(exit_status: 0))
    g.reconsider(context)
    assert_empty context.detail_reads
    assert_empty context.appends
  end

  # ---- the verdict, off the row ----

  def test_the_verdict_is_the_exit_status_on_a_completed_row
    passed = Rho::Until.verdict_of(detail(exit_status: 0))
    assert passed.passed?
    assert passed.runnable?
    failed = Rho::Until.verdict_of(detail(exit_status: 3))
    refute failed.passed?
    assert_equal 3, failed.exit_status
    timed = Rho::Until.verdict_of(detail(output: "Command timed out after 5 seconds"))
    assert timed.timed_out
    assert timed.runnable?
    refute timed.passed?
    unserved = Rho::Until.verdict_of(detail(status: "failed", error: { "key" => "tool_not_served" }))
    refute unserved.runnable?
    assert_equal "tool_not_served", unserved.reason
    expired = Rho::Until.verdict_of(detail(status: "timed_out", error: nil))
    assert_equal "timed_out", expired.reason, "a park nobody claimed is the row's own status"
  end

  # ---- the seed's half ----

  # THE FIRST ROUND IS THE KERNEL'S `r1`: the first
  # check is placed after it, and every later one after the round this
  # gate planted under its own name — by position, never by an edge. The
  # check is a TOOL step and the hold an ask behind it.
  def test_the_check_is_a_tool_step_and_the_hold_an_ask_placed_by_position
    assert_equal "r1", Rho::Until.work_key(1)
    assert_equal "work-2", Rho::Until.work_key(2)
    wire = [
      { "tool" => { "name" => "bash", "route" => { "kind" => "runner" },
                    "input" => { "command" => "t", "workdir" => "/d", "timeout" => 5 },
                    "key" => "check-1", "timeout_ms" => Rho::Until::CHECK_PARK_MS, "on_failure" => "absorb" } },
      { "ask" => { "key" => "hold-1", "prompt" => "verdict of acceptance check 1",
                   "timeout_ms" => Rho::Until::HOLD_TIMEOUT_MS } },
    ]
    assert_equal wire, Rho::Until.check_steps(1, command: "t", directory: "/d", timeout_seconds: 5).map(&:to_h)
    assert_equal %w[check-4 hold-4], Rho::Until.check_steps(4, command: "t", directory: "/d", timeout_seconds: 5).map(&:key)
    assert_equal 4, Rho::Until.attempt_of("hold-4")
    assert_equal 4, Rho::Until.attempt_of("check-4")
  end

  # No directory known (a remote runner announced no root): bash runs in
  # the runner's root, so the step names no `workdir`.
  def test_an_unknown_directory_leaves_workdir_to_the_runner
    check, = Rho::Until.check_steps(1, command: "t", directory: nil, timeout_seconds: 5)
    assert_equal({ "command" => "t", "timeout" => 5 }, check.input)
  end

  # BOUND TO ONE RUN: the follower asks a gate which run it belongs to,
  # and the snapshot shows it — and the runner the check runs on.
  def test_the_gate_names_the_run_it_is_bound_to_and_the_runner
    g = Rho::Until::Gate.new(policy: @policy, run_public_id: "al-7", timeout_seconds: 5)
    assert_equal "al-7", g.run_public_id
    assert_equal "al-7", g.to_h.fetch("run_public_id")
    refute gate.to_h.key?("run_public_id"), "an unbound gate says nothing about one"
    refute gate.to_h.key?("runner"), "an own-runner gate names none"
    remote = Rho::Until::Gate.new(policy: @policy.with(runner: "R1"), timeout_seconds: 5)
    assert_equal "R1", remote.to_h.fetch("runner")
  end

  def test_the_policy_round_trips_through_the_store_with_its_nils
    remote = Rho::Until::Policy.new(command: "t", attempts: 2, directory: nil, runner: "R1", seed: {})
    assert_equal remote, Rho::Until::Policy.from_h(remote.to_h)
    assert_equal({ "command" => "t", "attempts" => 2, "directory" => nil, "runner" => "R1", "seed" => {} }, remote.to_h)
    assert_equal @policy, Rho::Until::Policy.from_h(@policy.to_h)
    assert_equal @policy, Rho::Until::Policy.from_h(@policy.to_h.except("runner")),
      "a row written before the runner member is read as own"
  end

  def test_the_paragraph_names_the_command_the_directory_and_the_count
    text = Rho::Until.paragraph(command: "make test", attempts: 4, directory: "/srv/app")
    assert_includes text, "`make test`, run in /srv/app"
    assert_includes text, "you have 4 checks"
    assert_includes text, "do not edit, skip or weaken"
    remote = Rho::Until.paragraph(command: "make test", attempts: 4, directory: nil)
    assert_includes remote, "`make test`, run in the runner's root"
  end
end
