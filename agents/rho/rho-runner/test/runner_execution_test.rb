require "support/runner_loop_fixtures"

class RunnerLoopTest < Minitest::Test
  include RunnerLoopFixtures


  # THE TICKET IS ALWAYS RETURNED. A claim that raises something the SDK
  # does not own — a malformed nudge, an HTTP client raising outright —
  # used to keep its ticket forever; enough of them and the runner was
  # full for the daemon's life.
  def test_a_claim_that_raises_returns_its_ticket_and_is_logged
    lane = Lane.new(rows: [row("t1")])
    def lane.record_claim(_key) = raise(ArgumentError, "run_public_id must be a String")
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    log = Kept.new
    runner = Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: log, pool: pool, sleeper: ->(_) { nil })

    3.times { runner.nudged(run_public_id: "loop-1", task_key: "t1") }

    assert_equal 3, log.warned.count { |event, _| event == "runner_task_failed" }, "every raise is logged"
    assert_equal "ArgumentError", log.warned.first.last[:error_class]
    refute_nil pool.reserve, "the ticket was not returned"
  ensure
    pool&.stop
  end

  # NUDGES FAN OUT. Called from many threads at once — what the daemon's
  # per-fiber dispatch does — native blocking handlers overlap up to the
  # worker count, a full startup backlog declines before claiming, and every
  # ticket comes back. Cooperative waits have separate live-stack coverage.
  def test_nudges_from_many_threads_overlap_and_return_every_ticket
    rows = (1..4).map { |i| row("t#{i}") }
    lane = Lane.new(rows: rows)
    pool = Rho::Runner::Pool.new(worker_threads: 2)
    slow = toolset { |args, _ctx| Fiber.blocking { sleep 0.2 }; Rho::Runner::Result.ok("echo: #{args["text"]}") }
    runner = Rho::Runner.new(executor: lane, toolsets: fixed(slow), log: Silent.new, pool: pool, sleeper: ->(_) { nil })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcomes = rows.map { |r| Thread.new { runner.nudged(run_public_id: "loop-1", task_key: r.task_key) } }.map(&:value)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.6, "four 0.2s tools on two workers did not overlap (#{elapsed.round(2)}s)"
    assert_equal 2, outcomes.count(:done), "two workers, two done at once: #{outcomes.inspect}"
    assert_equal 2, outcomes.count(:busy), "a full pool must decline, not queue a claimed task: #{outcomes.inspect}"
    pool.worker_count.times { refute_nil pool.reserve, "a ticket was not returned" }
  ensure
    pool&.stop
  end

  def test_a_rewritten_argument_is_what_the_tool_actually_receives
    lane = Lane.new(rows: [row("t1", input: { "text" => "original" })])
    rewrite = registration(:tool_call) do |_name, args|
      Rho::Runner::Extensions::Hooks::Rewrite.new(arguments: args.merge("text" => "rewritten"))
    end

    hooked(lane, rewrite).nudged(run_public_id: "loop-1", task_key: "t1")

    assert_equal "echo: rewritten", only(lane.commits)[:content]
  end

  def test_a_result_hook_rewrites_the_answer_on_its_way_to_the_kernel
    lane = Lane.new(rows: [row("t1")])
    shout = registration(:tool_result) do |_name, result|
      Rho::Runner::Result.ok(result.content.upcase)
    end

    hooked(lane, shout).nudged(run_public_id: "loop-1", task_key: "t1")

    assert_equal "ECHO: HI", only(lane.commits)[:content]
  end

  # THE GATE RUNS ON THE WORKER: the `tool_call` chain
  # and the schema check run INSIDE the pool block, so a hook that blocks
  # costs its call's park and never the reactor, and `ExecutionContext.
  # current` is bound where the hook runs — the loop id read off it is
  # the row's. A veto spends a ticket for the microseconds of the chain
  # and gives it back when its execution first yields or finishes; the handler
  # never runs; the `tool_result` chain is skipped — nothing ran.
  def test_a_veto_runs_on_a_worker_with_the_context_bound_and_returns_the_ticket
    lane = Lane.new(rows: [row("t1")])
    ran = []
    seen = []
    tools = toolset { |args, _ctx| ran << args; Rho::Runner::Result.ok("ran") }
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    reactor = Thread.current
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: Silent.new,
      pool: pool, sleeper: ->(_) { nil },
      hooks: Rho::Runner::Extensions::Hooks::Host.new([
        registration(:tool_call) do |_name, _args, tool|
          seen << [Rho::Runner::ExecutionContext.current&.run_public_id, tool.name, Thread.current.equal?(reactor)]
          Rho::Runner::Extensions::Hooks::Veto.new(extension: "rho.guard", reason: "no")
        end,
        registration(:tool_result) { |_name, _result, _tool| seen << :result; nil },
      ]))

    subject.nudged(run_public_id: "loop-1", task_key: "t1")

    assert_empty ran, "the handler must not have run"
    assert_equal [["loop-1", "echo", false]], seen,
      "the chain ran on a worker with the row's context bound, and the result chain did not run"
    assert_includes only(lane.commits)[:content], "blocked by rho.guard: no"
    refute_nil pool.reserve, "the veto's ticket came back"
  ensure
    pool&.stop
  end

  def test_a_full_pool_declines_rather_than_claiming
    lane = Lane.new(rows: [row("t1")])
    pool = Rho::Runner::Pool.new(worker_threads: 1)
    (pool.worker_count * Rho::Runner::Pool::BACKLOG_PER_WORKER).times { pool.reserve }
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: Silent.new,
      pool: pool, sleeper: ->(_) { nil })

    assert_equal :busy,
      subject.nudged(run_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    assert_empty lane.claims, "a claim held while queueing burns a deadline nothing extends"
    subject.stop
  end

  # The cancel names a loop and task key; its context is cancelled, and the handler notices
  # at its next checkpoint and the claim is answered `failed` interrupted,
  # so the kernel's cancel and the runner's answer meet. The meter says it
  # happened, beside `nudged` and `swept`.
  def test_cancel_reaches_the_in_flight_context_and_the_handler_answers_failed_interrupted
    lane = Lane.new(rows: [row("t1")])
    entered = Queue.new
    blocking = toolset do |_args, ctx|
      entered << true
      loop do
        ctx.raise_if_cancelled!
        sleep 0.01
      end
    end
    subject = runner(lane, blocking)
    worker = Thread.new { subject.nudged(run_public_id: "loop-1", task_key: "t1") }
    assert entered.pop(timeout: 2), "the handler never started"

    refute subject.cancel(run_public_id: "loop-1", task_key: "t-other"), "a key nobody holds cancels nothing"
    refute subject.cancel(run_public_id: "loop-other", task_key: "t1"), "a different loop cancels nothing"
    assert subject.cancel(run_public_id: "loop-1", task_key: "t1"), "the running context is found by loop and key"
    assert_equal :done, worker.value

    submitted = only(lane.commits)
    assert_equal "failed", submitted[:outcome]
    assert_includes submitted[:content], "interrupted"
    assert_equal 1, subject.snapshot.canceled
    assert_equal 0, subject.snapshot.in_flight
    subject.stop
  end

  def test_cancel_leaves_the_same_task_key_in_another_loop_running
    lane = Lane.new(rows: [row("t1"), row("t1").with(run_public_id: "loop-2")])
    entered = Queue.new
    release_other = Queue.new
    tools = toolset do |_args, ctx|
      entered << ctx.run_public_id
      loop do
        ctx.raise_if_cancelled!
        break if ctx.run_public_id == "loop-2" && !release_other.empty?

        sleep 0.005
      end
      Rho::Runner::Result.ok("other loop finished")
    end
    subject = runner(lane, tools)
    workers = %w[loop-1 loop-2].map do |run_id|
      Thread.new { subject.nudged(run_public_id: run_id, task_key: "t1") }
    end
    2.times { assert entered.pop(timeout: 2), "the handler never started" }

    assert subject.cancel(run_public_id: "loop-1", task_key: "t1")
    assert workers.first.join(2), "the canceled task did not settle"
    release_other << true
    assert workers.last.join(2), "the other task did not finish"

    assert_equal %w[completed failed], lane.commits.map { |commit| commit.fetch(:outcome) }.sort
    assert_equal "other loop finished", lane.commits.find { |commit| commit[:outcome] == "completed" }&.fetch(:content)
  ensure
    subject&.stop
  end

  # A STOP ANSWERS THE CLAIM IT HOLDS: the pool cancels every running
  # context with `:shutdown`, the handler notices at its next checkpoint,
  # and the claim is answered `failed` interrupted before `stop` returns —
  # never left claimed to its park deadline, where a restarted daemon
  # would meet `already_claimed`. That row is the runner draining, not the
  # kernel's cancel, so the `canceled` meter does not move.
  def test_a_stop_cancels_the_in_flight_handler_and_answers_its_claim_failed_interrupted
    lane = Lane.new(rows: [row("t1")])
    entered = Queue.new
    blocking = toolset do |_args, ctx|
      entered << true
      loop do
        ctx.raise_if_cancelled!
        sleep 0.01
      end
    end
    subject = runner(lane, blocking)
    worker = Thread.new { subject.nudged(run_public_id: "loop-1", task_key: "t1") }
    assert entered.pop(timeout: 2), "the handler never started"

    subject.stop
    submitted = only(lane.commits)
    assert_equal "failed", submitted[:outcome]
    assert_equal "The tool was interrupted: execution cancelled", submitted[:content]
    assert_equal 0, subject.snapshot.canceled, "a shutdown is not the kernel's cancel"
    assert worker.join(2), "the take never returned after the stop"
  end

  # A COMMIT REFUSED BY TRANSPORT IS RETRIED WHILE THE DEADLINE STANDS:
  # the token makes the retry safe — a second commit under the
  # same token after the settle is `idle` — and a result computed and never
  # delivered is the same as no result. Backoff doubles from a second and
  # the clock is the park's; past it the answer is dropped and said once.
  def task_run(lane, clock:, sleeper:, log: Silent.new)
    Rho::Runner::TaskRun.new(executor: lane, pool: Rho::Runner::Pool.new(worker_threads: 1),
      toolsets: fixed(toolset), log: log, clock: clock, sleeper: sleeper)
  end

  def test_a_transport_refused_commit_is_retried_until_the_deadline_then_dropped
    now = 0.0
    slept = []
    sleeper = ->(seconds) { slept << seconds; now += seconds }
    refusals = 2
    lane = Lane.new(rows: [row("t1")], deadline_at: (Time.now + 60).iso8601,
      on_commit: lambda { |_fields|
        refusals -= 1
        raise CybrosAgent::TransportError, "connection reset" if refusals >= 0
      })

    outcome = task_run(lane, clock: -> { now }, sleeper: sleeper)
      .call(run_public_id: "loop-1", task_key: "t1")

    assert_equal :done, outcome
    assert_equal "completed", only(lane.commits)[:outcome], "the third attempt landed"
    assert_equal [1.0, 2.0], slept, "a second, doubling"

    # AND DROPPED PAST THE DEADLINE, said once: nothing can extend a park.
    now = 0.0
    slept = []
    log = Kept.new
    lane = Lane.new(rows: [row("t2")], deadline_at: (Time.now + 10).iso8601,
      on_commit: ->(_fields) { raise CybrosAgent::TransportError, "connection reset" })

    task_run(lane, clock: -> { now }, sleeper: sleeper, log: log)
      .call(run_public_id: "loop-1", task_key: "t2")

    assert_equal [1.0, 2.0, 4.0], slept, "a wait that would cross the deadline is not taken"
    assert_empty lane.commits
    assert_equal 1, log.warned.count { |event, _| event == "runner_submit_refused" }, "said once"
  end

  # A TYPED REFUSAL IS NOT RETRIED: `stale_claim` past the deadline, a
  # payload the door refuses — the same request would meet the same answer.
  def test_a_refusal_typed_by_the_kernel_is_logged_once_and_never_retried
    slept = []
    log = Kept.new
    lane = Lane.new(rows: [row("t1")], deadline_at: (Time.now + 60).iso8601,
      on_commit: ->(_fields) { raise CybrosAgent::Api::Conflict.new("stale", code: "stale_claim") })

    task_run(lane, clock: -> { 0.0 }, sleeper: ->(seconds) { slept << seconds }, log: log)
      .call(run_public_id: "loop-1", task_key: "t1")

    assert_empty slept
    assert_equal [["runner_submit_refused", { task: "t1", code: "stale_claim" }]],
      log.warned.select { |event, _| event == "runner_submit_refused" }
  end

  # A 401 ON THE EXECUTOR PLANE IS TERMINAL FOR THE RUNNER HALF:
  # the credential stopped being usable — a re-pair, a revoke — and no
  # retry can change that. The runner stops, says why, and starts no
  # ceremony of its own (executor.md: a runner "must not automatically
  # begin another device flow").
  def test_an_unauthorized_inbox_read_stops_the_runner_and_runs_no_ceremony
    lane = Lane.new(rows: [row("t1")],
      on_list: -> { raise CybrosAgent::Api::Unauthorized.new("no", code: "unauthorized") })
    log = Kept.new
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: log,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil })

    subject.follow

    refute subject.snapshot.running, "lost authority reads as not running"
    assert_equal 1, lane.lists, "no retry: the next pass would meet the same answer"
    assert_empty lane.claims
    assert_equal ["runner_authority_lost"], log.warned.map(&:first)
    assert_nil subject.nudged(run_public_id: "loop-1", task_key: "t1"),
      "a nudge after the loss claims nothing"
    assert_empty lane.claims
    subject.stop
  end

  # Every other failure of the inbox is a condition to wait out: the next
  # pass is five seconds away and the work is still there.
  def test_an_unreachable_inbox_is_waited_out_rather_than_stopped
    lane = Lane.new(rows: [row("t1")],
      on_list: -> { raise CybrosAgent::TransportError, "connection refused" })
    log = Kept.new
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: log,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil })

    subject.send(:sweep)

    assert subject.snapshot.running
    assert_equal ["runner_sweep_failed"], log.warned.map(&:first)
    subject.stop
  end

  # THE CLAMP IS THE POOL'S RULE, NOT THE HANDLER'S COURTESY. A handler that never checks its context — a plugin that never
  # asks, an echo that sleeps — used to park to the kernel's deadline,
  # where the sweep would write `uncertain` for a runner that was alive
  # the whole time. The pool waits on the context's own clock, cancels,
  # gives the grace, and replaces only an unresponsive native host; the answer is
  # DATA the model reads (`completed`, `is_error`), never `failed`, and
  # the runner is whole afterwards: nothing in flight, the next job runs.
  # WHAT A RUNNING TOOL SAYS WHILE IT RUNS (executor.md "Progress"): the
  # context carries the claim's token, a handler hands in tails on its
  # worker, and the pool's wait posts them under the claim at the kernel's
  # cadence — the newest tail, once per interval, never from the handler.
  def test_a_handlers_progress_tails_are_posted_under_its_claim_at_the_cadence
    lane = Lane.new(rows: [row("t1")], deadline_at: (Time.now + 60).iso8601)
    tokens = []
    tools = toolset do |_args, context|
      tokens << context.claim_token
      context.report_progress("step 1\n")
      context.report_progress("step 1\nstep 2\n")
      # Past one interval, so the pool's wait wakes and posts; a handler
      # that answers inside the interval posts nothing — its answer follows.
      sleep 0.35
      Rho::Runner::Result.ok("done")
    end
    subject = runner(lane, tools)
    subject.nudged(run_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_equal ["tok-t1"], tokens, "the context carries the claim's own proof"
    assert_equal 1, lane.frames.length, "one frame per interval: the newest tail, the earlier one superseded"
    assert_equal({ "run_public_id" => "loop-1", "task_key" => "t1", "claim_token" => "tok-t1",
                   "text_tail" => "step 1\nstep 2\n" }, lane.frames.first)
    assert_equal "done", lane.commits.first.fetch(:content), "the answer follows the frames untouched"
  end

  # ONE REFUSAL ENDS THE POSTING — the claim ended under the tool, say —
  # logged once; the work goes on and the answer still commits.
  def test_a_refused_progress_frame_is_logged_once_and_the_posting_stops
    log = Kept.new
    attempts = []
    lane = Lane.new(rows: [row("t1")], on_progress: lambda { |frame|
      attempts << frame
      raise CybrosAgent::Api::Conflict.new("no", code: "not_claimant")
    })
    tools = toolset do |_args, context|
      context.report_progress("a")
      sleep 0.35
      context.report_progress("b")
      sleep 0.35
      Rho::Runner::Result.ok("done")
    end
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(tools), log: log,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil })
    subject.nudged(run_public_id: "loop-1", task_key: "t1", tool_name: "echo")
    subject.stop

    assert_equal ["a"], attempts.map { |frame| frame.fetch("text_tail") },
      "the refusal ends the asking; the second tail is never posted"
    assert_equal [["runner_progress_refused", { task: "t1", code: "not_claimant" }]],
      log.warned.select { |event, _| event == "runner_progress_refused" }
    assert_equal "done", lane.commits.first.fetch(:content)
  end

  # A SELF-CLAMPED tool (bash's shape): one the extension never carries,
  # so the pool's clamp is what answers for it.
  def test_the_pool_clamps_a_handler_that_never_checks_its_context_and_answers_timed_out
    lane = Lane.new(rows: [row("t1", timeout_ms: 800), row("t2", input: { "text" => "again" })],
      deadline_at: -> { (Time.now + 0.8).iso8601(3) })
    stubborn = toolset(internal_clamp: true) do |args, _ctx|
      sleep 3 if args["text"] == "hi"
      Rho::Runner::Result.ok("echo: #{args["text"]}")
    end
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    log = Kept.new
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(stubborn), log: log, pool: pool, sleeper: ->(_) { nil })

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome], "a timeout is data the model reads, not the task's policy"
    assert_equal true, submitted[:is_error]
    assert_match(/\AThe tool timed out: its granted execution deadline passed/,
      submitted[:content])
    assert_includes submitted[:content], "Check its effect before calling it again"
    assert_operator elapsed, :<, 2.0, "the clamp did not bound a handler that ignores its context (#{elapsed.round(2)}s)"
    assert_equal 0, pool.in_flight, "the caller's deadline ended its control wait"
    assert_empty log.warned.select { |event, _| event == "runner_tool_failed" }, "not a failure: the tool ran too long"

    # The sleeping handler still owns its stack, while the same responsive
    # execution thread can serve the next job.
    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t2")
    assert_equal "echo: again", lane.commits.last[:content]
  ensure
    pool&.stop
  end

  # Timeout delivery cannot claim that a non-cooperative tool's effects stopped.
  def test_the_timeout_reports_cancellation_without_claiming_effects_were_undone
    lane = Lane.new(rows: [row("t1", timeout_ms: 2_000)], deadline_at: -> { (Time.now + 2.0).iso8601(3) })
    stubborn = toolset(internal_clamp: true) do |_args, _ctx|
      sleep 3
      Rho::Runner::Result.ok("late")
    end
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    log = Kept.new
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(stubborn), log: log, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")

    assert_equal "The tool timed out: its granted execution deadline passed before it returned a result. " \
      "Cancellation was requested; external effects may be incomplete. Check its effect before calling it again.",
      only(lane.commits)[:content]
    timed_out = log.warned.select { |event, _| event == "runner_tool_timed_out" }
    assert_equal 1, timed_out.length
    assert timed_out.first.last.key?(:elapsed_seconds), "the log keeps the measured time"
  ensure
    pool&.stop
  end

  # Delivery text is stable across clock origins and claim latency; elapsed
  # timings belong to diagnostics, not claims about external effects.
  def test_timeout_text_does_not_depend_on_claim_latency_or_the_runners_clock
    sentences = [[1.0, 1_000.0], [1.9, -42.0]].map do |away, offset|
      lane = Lane.new(rows: [row("t1", timeout_ms: 1_000)], deadline_at: (Time.now + away).iso8601(3))
      timed_out_content(lane, polite_toolset, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) + offset })
    end

    assert_equal sentences.first, sentences.last
    refute_match(/\d/, sentences.first)
  end

  def test_an_extended_task_reports_the_same_effect_uncertainty_when_it_times_out
    asks = 0
    lane = Lane.new(rows: [row("t1", timeout_ms: 1_000)], deadline_at: (Time.now + 1).iso8601(3),
      on_extend: lambda { |_fields|
        asks += 1
        raise CybrosAgent::Api::Conflict.new("no", code: "extension_too_long") if asks > 1
      })
    log = Kept.new

    extended = timed_out_content(lane, polite_toolset(timeout_ms: 1_600), log: log)
    unextended = timed_out_content(
      Lane.new(rows: [row("t1", timeout_ms: 1_000)], deadline_at: (Time.now + 1).iso8601(3)), polite_toolset
    )

    assert_equal 1, log.told.count { |event, _| event == "runner_task_extended" }, "the kernel moved the deadline once"
    assert_equal unextended, extended, "renewal does not prove that timed-out effects stopped"
  end

  # A handler that returns only through its own checkpoint: nothing it leaves behind outlives
  # the case.
  def polite_toolset(timeout_ms: nil)
    toolset(internal_clamp: timeout_ms.nil?, timeout_ms: timeout_ms) do |_args, ctx|
      loop do
        ctx.raise_if_cancelled!
        sleep 0.01
      end
    end
  end

  def timed_out_content(lane, tools, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, log: Silent.new)
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 1.0)
    run = Rho::Runner::TaskRun.new(executor: lane, pool: pool, toolsets: fixed(tools), log: log, clock: clock,
      sleeper: ->(_) { nil })

    assert_equal :done, run.call(run_public_id: "loop-1", task_key: "t1")
    submitted = only(lane.commits)
    assert_equal true, submitted[:is_error], "the clamp answered"
    submitted.fetch(:content)
  ensure
    pool&.stop
  end

  # A COOPERATIVE HANDLER under the same clamp returns through its own
  # checkpoint inside the grace — the worker is kept, and the answer is
  # the same timed-out result: the DEADLINE reason is what makes it data,
  # where a cancel (below) and a shutdown stay `failed` interrupted.
  def test_a_cooperative_handler_under_the_clamp_answers_timed_out_through_its_own_checkpoint
    lane = Lane.new(rows: [row("t1", timeout_ms: 800)], deadline_at: -> { (Time.now + 0.8).iso8601(3) })
    polite = toolset(internal_clamp: true) do |_args, ctx|
      loop do
        ctx.raise_if_cancelled!
        sleep 0.01
      end
    end
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 1.0)
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(polite), log: Silent.new, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome]
    assert_equal true, submitted[:is_error]
    assert_match(/\AThe tool timed out: its granted execution deadline passed/,
      submitted[:content])
    assert_equal 0, pool.in_flight
  ensure
    pool&.stop
  end

  # THE ASK FOR MORE TIME, TIMED ON A FAKE CLOCK (executor.md "Extend"):
  # once at half the park, again at each half of the park asked for, the
  # one deadline moved only forward by the kernel's answer — and one
  # refusal ends the asking for good.
  def test_the_extension_asks_at_half_the_park_and_again_at_each_half_until_refused
    now = 0.0
    clock = -> { now }
    answers = [[95.0, "later-1", 60.0], [175.0, "later-2", 60.0], nil]
    asked = []
    extension = Rho::Runner::DeadlineExtension.new(park_seconds: 60.0, deadline_at: "first", clock: clock) do
      asked << now
      answers.shift
    end
    context = Rho::Runner::ExecutionContext.new(deadline: 45.0, clock: clock, extension: extension)

    assert_equal 30.0, extension.due_at, "half the park"
    assert_equal 30.0, context.wait_slice, "the ask comes before the clamp"
    now = 29.0
    context.renew!
    assert_empty asked, "not due yet"
    assert_equal 45.0, context.deadline

    now = 30.0
    context.renew!
    assert_equal [30.0], asked, "asked at half the park"
    assert_equal 95.0, context.deadline, "the one deadline moved by the answer"
    assert_equal "later-1", extension.deadline_at
    assert_equal 60.0, extension.due_at, "re-armed at half the park, from the answer"
    assert_equal 30.0, context.wait_slice

    now = 60.0
    context.renew!
    assert_equal 175.0, context.deadline
    assert_equal 90.0, extension.due_at

    now = 90.0
    context.renew!
    assert_equal 3, asked.length
    assert_predicate extension, :stopped?, "a refusal ends the asking"
    assert_nil extension.wait
    assert_equal 175.0, context.deadline, "a refusal moves nothing"
    assert_equal 85.0, context.wait_slice, "only the clamp remains"
    now = 120.0
    context.renew!
    assert_equal 3, asked.length, "never asked again"

    refute context.extend_deadline(100.0), "never backwards"
    context.cancel(:canceled)
    refute context.extend_deadline(500.0), "never over a cancellation"
    assert_equal 175.0, context.deadline
  end

  def test_a_context_without_an_extension_waits_on_its_clamp_alone_and_one_without_a_clock_waits_forever
    clock = -> { 10.0 }
    assert_equal 35.0, Rho::Runner::ExecutionContext.new(deadline: 45.0, clock: clock).wait_slice
    assert_nil Rho::Runner::ExecutionContext.new(clock: clock).wait_slice
    unclocked = Rho::Runner::ExecutionContext.new(clock: clock)
    unclocked.renew!
    assert_nil unclocked.deadline
  end

  # A silent handler survives successive renewals on the real Runner clock.
  # Progress frames are not the liveness signal: the control wait renews at
  # half each granted park, bounded by the tool's announced window.
  def test_a_silent_handler_without_an_internal_clamp_survives_two_renewals
    lane = Lane.new(rows: [row("t1")], deadline_at: -> { (Time.now + 2.0).iso8601(3) })
    slow = toolset(timeout_ms: 1_500) { |_args, _ctx| sleep 2.2; Rho::Runner::Result.ok("made it") }
    log = Kept.new
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(slow), log: log, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome]
    assert_equal "made it", submitted[:content], "the clamp at 1.5 s did not answer for it"
    refute submitted[:is_error]
    assert_operator lane.extends.length, :>=, 2, "the silent handler crossed two renewal points"
    assert_empty lane.frames, "no progress frame was needed to keep the handler alive"
    first = lane.extends.first
    assert_equal "tok-t1", first[:claim_token]
    assert_equal 1_500, first[:timeout_ms], "the ask is bounded by the tool's own announced park"
    assert_includes log.told.map(&:first), "runner_task_extended"
  ensure
    pool&.stop
  end

  # A TOOL THAT CLAMPS ITSELF NEVER ASKS: bash's own timeout is its bound,
  # so the same slow handler under `internal_clamp` meets the runner's
  # clamp and answers "timed out" as data, and the kernel hears nothing.
  def test_a_tool_with_an_internal_clamp_never_extends
    lane = Lane.new(rows: [row("t1", timeout_ms: 2_000)], deadline_at: -> { (Time.now + 2.0).iso8601(3) })
    slow = toolset(internal_clamp: true) { |_args, _ctx| sleep 1.7; Rho::Runner::Result.ok("made it") }
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(slow), log: Silent.new, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal true, submitted[:is_error]
    assert_match(/\AThe tool timed out: its granted execution deadline passed/,
      submitted[:content])
    assert_empty lane.extends, "a self-clamped tool is never extended"
  ensure
    pool&.stop
  end

  # A REFUSED ASK ENDS THE ASKING, said once, and the handler runs to the
  # deadline the kernel would not move.
  def test_a_refused_extension_is_logged_once_and_the_clamp_stands
    lane = Lane.new(rows: [row("t1", timeout_ms: 2_000)], deadline_at: -> { (Time.now + 2.0).iso8601(3) },
      on_extend: ->(_fields) { raise CybrosAgent::Api::Conflict.new("no", code: "extension_too_long") })
    slow = toolset { |_args, _ctx| sleep 1.7; Rho::Runner::Result.ok("made it") }
    log = Kept.new
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(slow), log: log, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")

    assert_equal 1, lane.extends.length, "asked once, refused, never again"
    assert_equal [["runner_extension_refused", { task: "t1", code: "extension_too_long" }]],
      log.warned.select { |event, _| event == "runner_extension_refused" }
    assert_equal true, only(lane.commits)[:is_error], "the clamp answered"
  ensure
    pool&.stop
  end

  # THE ASK IS THE ROW'S OWN PARK: a handler whose tool announced none asks for the budget the
  # row states — never the park it measured against its own clock, rounded up to whole seconds.
  def test_the_ask_for_more_time_is_the_rows_park_never_the_measured_one
    lane = Lane.new(rows: [row("t1", timeout_ms: 2_000)], deadline_at: -> { (Time.now + 2.5).iso8601(3) })
    slow = toolset { |_args, _ctx| sleep 1.5; Rho::Runner::Result.ok("made it") }
    pool = Rho::Runner::Pool.new(worker_threads: 1, grace_seconds: 0.05)
    subject = Rho::Runner.new(executor: lane, toolsets: fixed(slow), log: Silent.new, pool: pool, sleeper: ->(_) { nil })

    assert_equal :done, subject.nudged(run_public_id: "loop-1", task_key: "t1")

    assert_equal "made it", only(lane.commits)[:content]
    refute_empty lane.extends, "the kernel was asked at half the park"
    assert_equal 2_000, lane.extends.first.fetch(:timeout_ms), "the row's park, exactly"
  ensure
    pool&.stop
  end

  # HEADROOM IS A QUARTER OF A SHORT PARK. A fixed fifteen seconds made
  # every park under fifteen seconds clamp at once — a 30 s announced park
  # left its handler 15 s, a 10 s park nothing at all.
  def test_headroom_is_a_quarter_of_a_short_park_and_fifteen_seconds_of_a_long_one
    run = task_run(Lane.new, clock: -> { 0.0 }, sleeper: ->(_) { nil })
    short = Claimed.new(task: row("t1"), claim_token: "tok", deadline_at: (Time.now + 8).iso8601(3))
    long = Claimed.new(task: row("t1"), claim_token: "tok", deadline_at: (Time.now + 120).iso8601(3))

    assert_in_delta 6.0, run.send(:handler_deadline, short), 0.1, "8 s park: 2 s of headroom"
    assert_in_delta 105.0, run.send(:handler_deadline, long), 0.1, "120 s park: the fifteen-second cap"
    assert_nil run.send(:handler_deadline, Claimed.new(task: row("t1"), claim_token: "tok", deadline_at: nil))
  end

  # ARGUMENTS ARE VALIDATED AGAINST THE DECLARED inputSchema BEFORE THE
  # HANDLER RUNS, and a mismatch is DATA: `completed` with
  # `is_error` and a sentence that names the field, so the model corrects
  # itself — where a handler raising on a bad argument took the round's
  # failure policy and told it nothing.
  def typed_toolset(&handler)
    body = handler || ->(args, _ctx) { Rho::Runner::Result.ok("read #{args["path"]}") }
    Rho::Runner::Toolset.new(
      "echo" => Rho::Runner::Toolset::Tool.new(
        name: "echo", description: "echo",
        parameters: { "type" => "object", "properties" => { "path" => { "type" => "string" } },
                      "required" => ["path"] },
        handler: body
      )
    )
  end

  def test_malformed_arguments_commit_a_readable_error_before_the_handler_runs
    lane = Lane.new(rows: [row("t1", input: { "path" => 3 })])
    ran = []
    tools = typed_toolset { |args, _ctx| ran << args; Rho::Runner::Result.ok("ran") }

    runner(lane, tools).nudged(run_public_id: "loop-1", task_key: "t1")

    submitted = only(lane.commits)
    assert_equal "completed", submitted[:outcome], "a refusal the model can act on, not a dead task"
    assert_equal true, submitted[:is_error]
    assert submitted[:content].start_with?("invalid_tool_arguments:"), submitted[:content]
    assert_includes submitted[:content], "/path"
    assert_empty ran, "the handler must not have run"
  end

  # A HOOK'S REWRITE IS WHAT IS VALIDATED — the arguments the tool
  # RECEIVES, not the ones the row carried: a hook that repairs a call
  # lets it through, and one that breaks it is refused the same way.
  def test_a_hooks_rewrite_is_what_is_validated
    repaired = Lane.new(rows: [row("t1", input: {})])
    repair = registration(:tool_call) do |_name, _args|
      Rho::Runner::Extensions::Hooks::Rewrite.new(arguments: { "path" => "README" })
    end
    Rho::Runner.new(executor: repaired, toolsets: fixed(typed_toolset), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil },
      hooks: Rho::Runner::Extensions::Hooks::Host.new([repair]))
      .nudged(run_public_id: "loop-1", task_key: "t1")
    assert_equal "read README", only(repaired.commits)[:content], "the row was invalid; the rewrite is not"

    broken = Lane.new(rows: [row("t2", input: { "path" => "README" })])
    breaker = registration(:tool_call) do |_name, _args|
      Rho::Runner::Extensions::Hooks::Rewrite.new(arguments: { "path" => 3 })
    end
    Rho::Runner.new(executor: broken, toolsets: fixed(typed_toolset), log: Silent.new,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil },
      hooks: Rho::Runner::Extensions::Hooks::Host.new([breaker]))
      .nudged(run_public_id: "loop-1", task_key: "t2")
    assert submitted = only(broken.commits)
    assert_equal true, submitted[:is_error], "the row was valid; the rewrite is not"
    assert submitted[:content].start_with?("invalid_tool_arguments:"), submitted[:content]
  end

  # THE CLAIM IS LOGGED, WITH ITS DEADLINE. Nothing marked a claim in any
  # log before — `claimed` moved only after the answer — so an operator
  # reading a daemon log could not see what a runner was holding, and a
  # journey that kills a runner mid-claim had nothing to wait on.
  def test_the_claim_is_logged_with_its_deadline
    at = (Time.now + 60).iso8601
    lane = Lane.new(rows: [row("t1")], deadline_at: at)
    log = Kept.new
    Rho::Runner.new(executor: lane, toolsets: fixed(toolset), log: log,
      pool: Rho::Runner::Pool.new(worker_threads: 1), sleeper: ->(_) { nil })
      .nudged(run_public_id: "loop-1", task_key: "t1")

    assert_includes log.told, ["runner_task_claimed", { task: "t1", tool: "echo", deadline_at: at }]
  end

  # THE PORT SITS BEHIND RHO'S RULES: the
  # seam is INSIDE the handler, after the `tool_call` chain — a vetoed
  # `read` never asks the editor for anything, and an admitted one reads
  # through the port the context resolved for the row's anchor, placed
  # with the placement on the worker.
  def test_the_port_is_asked_only_after_the_call_chain_admitted_the_call
    Dir.mktmpdir("rho-runner-port") do |dir|
      tmp = File.realpath(dir)
      zero_root = File.join(tmp, "zero")
      bound_root = File.join(tmp, "bound")
      FileUtils.mkdir_p([zero_root, bound_root])
      File.write(File.join(bound_root, "a.txt"), "disk\n")
      port = RunnerTest::PortDouble.new(buffers: { File.join(bound_root, "a.txt") => "buffer\n" })
      zero = Rho::Runner::ToolEnv.new(root: zero_root, artifacts_dir: File.join(tmp, "work", "artifacts", "z"))
      registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
      binding = Rho::Runner::Environment::Binding.new(root: bound_root, directories: [], anchor: "conv-1")
      toolsets = Rho::Runner::Toolsets.new(registry: registry, zero: zero, work_dir: File.join(tmp, "work"),
        resolver: ->(_conversation, _parent) { binding }, ports: ->(anchor) { anchor == "conv-1" ? port : nil })
      guard = registration(:tool_call) do |_name, arguments, _tool|
        if arguments["path"] == "denied.txt"
          Rho::Runner::Extensions::Hooks::Veto.new(extension: "rho.guard", reason: "not here")
        else
          arguments
        end
      end
      lane = Lane.new(rows: [
        row("t1", tool: "read", input: { "path" => "denied.txt" }, conversation: "conv-1"),
        row("t2", tool: "read", input: { "path" => "a.txt" }, conversation: "conv-1"),
      ])
      pool = Rho::Runner::Pool.new(worker_threads: 1)
      subject = Rho::Runner.new(executor: lane, toolsets: toolsets, log: Silent.new, pool: pool,
        sleeper: ->(_) { nil }, hooks: Rho::Runner::Extensions::Hooks::Host.new([guard]))
      subject.nudged(run_public_id: "loop-1", task_key: "t1")
      assert_empty port.calls, "a vetoed call asked the port nothing"

      subject.nudged(run_public_id: "loop-1", task_key: "t2")
      subject.stop
      by_key = lane.commits.to_h { |fields| [fields.fetch(:claim_token), fields] }
      assert by_key.fetch("tok-t1").fetch(:is_error)
      assert_includes by_key.fetch("tok-t1").fetch(:content), "blocked by rho.guard"
      assert_equal "buffer", by_key.fetch("tok-t2").fetch(:content), "the admitted read saw the editor's buffer"
      assert_equal [[:read, File.join(bound_root, "a.txt"), { line: 1, limit: 2001 }]], port.calls
    ensure
      pool&.stop
    end
  end
end
