require "test_helper"
require_relative "../../test_helpers/runs_execution_test_helper"

class Runs::ExecutionLifecycleTest < ActiveJob::TestCase
  include RunsExecutionTestHelper

  test "two-phase cancel: in-flight steps terminalize, the drain settles the loop" do
    run = seed(model("running-step"), model("waiting-step"))
    start!(run)
    running = node(run, "running-step")
    invocation = ModelInvocation.find(running.selected_model_invocation_id)

    result = Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    run.reload
    assert_equal "canceling", run.status
    assert_equal "canceled", node(run, "waiting-step").status
    assert_equal "canceled", invocation.reload.status
    assert_equal "running", running.reload.status,
      "phase one never touches a running node — the converger applies its terminal"

    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
    assert_equal "canceled", running.reload.status
    assert_equal "canceled", run.reload.status
  end

  test "pause stops scheduling while in-flight work still applies; resume picks it up" do
    run = seed(model("first"), model("second"))
    start!(run)

    pause = Runs::Pause.call(Runs::Pause::Command.graceful(
      run: run, acting_user: @human
    ))
    assert_predicate pause, :accepted?

    apply_via(step_attempt(run), sse_success("landed while paused"))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
    assert_equal "completed", node(run, "first").status,
      "pause stops scheduling, never result application"
    assert_equal "queued", node(run, "second").status

    resume = Runs::Resume.call(Runs::Resume::Command.new(
      run: run, acting_user: @human
    ))
    assert_predicate resume, :accepted?
    clear_enqueued_jobs
    schedule!(run)
    assert_equal "running", node(run, "second").status
  end

  test "the schedule sweep re-seeds a loop whose wake was lost" do
    run = seed(model("orphan"))
    result = Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    assert_equal "queued", node(run, "orphan").status, "the wake was never run"

    Runs::ScheduleSweepJob.perform_now
    assert_equal "running", node(run, "orphan").status
  end

  test "the ask waits indefinitely — no sweep ends a hold (§9c)" do
    run = seed(model("brittle"))
    start!(run)
    run_step!(run, json_response(400, { "error" => "bad" }))
    run.reload
    assert_equal "needs_attention", run.status

    # Days pass; nothing expires the ask — the exits are the adjudication verbs, stop, and
    # tombstone, never a clock.
    assert_not defined?(Runs::AttentionSweepJob),
      "the attention sweep is deleted, not merely disabled"
    assert_equal "needs_attention", run.reload.status
    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "brittle", acting_user: @human
    ))
    assert_predicate result, :accepted?, "the three-day-old ask is still answerable"
    assert_equal "running", run.reload.status
  end

  test "the drain sweep escalates a canceling loop past the hard limit" do
    run = seed(ask("gate", "timeout_ms" => 6.hours.in_milliseconds))
    start!(run)
    assert_predicate Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    )), :accepted?
    assert_equal "canceling", run.reload.status

    Runs::DrainSweepJob.perform_now
    assert_equal "canceling", run.reload.status,
      "a young drain re-evaluates and keeps waiting for its park"

    # Past the ceiling nothing legitimate can still be pending — whatever
    # remains is a bug's residue, and the sweep bounds what it costs.
    run.update_columns(canceling_since: 25.hours.ago)
    Runs::DrainSweepJob.perform_now
    run.reload
    assert_equal "canceled", run.status
    assert_equal "canceled", node(run, "gate").status
  end

  test "a step that fails while the loop is canceling settles canceled, never requeued" do
    run = seed(model("racy"))
    start!(run)
    racy = node(run, "racy")
    invocation = ModelInvocation.find(racy.selected_model_invocation_id)
    # The race: the step self-terminalizes (deadline sweep / attempt budget)
    # before cancel's phase one runs, so cancel's own terminalize no-ops.
    ModelInvocation.lock.find(invocation.id)
      .terminalize(status: "failed", reason_key: ModelInvocation::TRANSIENT_EXHAUSTED_KEY)

    result = Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    assert_equal "canceling", run.reload.status

    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
    racy.reload
    assert_equal "canceled", racy.status,
      "the retry budget never resurrects work inside a dying loop"
    assert_equal "canceled", run.reload.status
  end

  test "a graceful stop lets in-flight work finish and KEEPS its answer" do
    run = seed(model("working", "prompt" => "almost done"), model("waiting"))
    start!(run)
    working = node(run, "working")
    invocation = ModelInvocation.find(working.selected_model_invocation_id)

    result = Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    ))
    assert_predicate result, :accepted?
    run.reload
    assert_equal "canceling", run.status
    assert_equal "canceled", node(run, "waiting").status,
      "nothing NEW ever starts, graceful or not"
    assert_equal "queued", invocation.reload.status,
      "the in-flight step was NOT terminalized — graceful means finish"

    run_step!(run, sse_success("the last answer"))
    working.reload
    assert_equal "completed", working.status
    assert_includes working.content_bodies.find_by!(role: "output").effective_text,
      "the last answer", "the drain waited and the answer survived"
    assert_equal "canceled", run.reload.status
  end

  test "a graceful stop waits for a parked await, which can still resolve" do
    run = seed(ask("gate", "timeout_ms" => 6.hours.in_milliseconds))
    token = RunAppendReceipt.where(run_id: run.id).order(:id).first
      .response_body.dig("resolution_tokens", "gate")
    start!(run)
    gate = node(run, "gate")
    assert_equal "dispatched", gate.status

    Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    ))
    assert_equal "canceling", run.reload.status
    assert_equal "dispatched", gate.reload.status, "the rendezvous is worth waiting for"

    resolved = Runs::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: "the external answer"
    )
    assert_predicate resolved, :applied?, "a canceling loop still settles its parks"
    clear_enqueued_jobs
    schedule!(run)
    assert_equal "canceled", run.reload.status
    assert_equal "completed", gate.reload.status
  end

  test "a graceful stop escalates: stopping again with force ends the wait" do
    run = seed(model("slow"))
    start!(run)
    invocation = ModelInvocation.find(node(run, "slow").selected_model_invocation_id)

    Runs::Stop.call(Runs::Stop::Command.new(
      run: run, acting_user: @human, force: false
    ))
    assert_equal "queued", invocation.reload.status, "graceful leaves it running"

    Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    ))
    assert_equal "canceled", invocation.reload.status, "force ends the wait NOW"

    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
    assert_equal "canceled", run.reload.status
  end

  test "canceling a pending loop settles it at once, and cancel converges idempotently" do
    run = seed(model("unstarted"))

    result = Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    run.reload
    assert_equal "canceled", run.status
    assert_equal "canceled", node(run, "unstarted").status

    again = Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    ))
    assert_equal :already_terminal, again.outcome
  end

  test "a timed-out step holds like any halt failure and abandon resolves it" do
    run = seed(model("slowpoke"))
    start!(run)
    slowpoke = node(run, "slowpoke")
    step_attempt(run)
    # The deadline sweep's own write, applied by the converger like any
    # terminal.
    ModelInvocation.lock.find(slowpoke.selected_model_invocation_id)
      .terminalize(status: "timed_out", reason_key: "deadline_passed")
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)

    slowpoke.reload
    assert_equal "timed_out", slowpoke.status
    assert_equal "deadline_passed", slowpoke.error_key
    assert_equal "needs_attention", run.reload.status

    abandoned = Runs::Tasks::Abandon.call(Runs::Tasks::Abandon::Command.new(
      run: run, task_key: "slowpoke", acting_user: @human
    ))
    assert_predicate abandoned, :accepted?
    clear_enqueued_jobs
    schedule!(run)
    assert_equal "needs_attention", run.reload.status
    assert_equal "deliverable_unresolved", run.attention_reason,
      "the deliverable was abandoned, not answered — the kernel never synthesizes"
  end

  test "the schedule sweep drains a canceling loop whose wake was lost" do
    run = seed(model("inflight"))
    start!(run)
    result = Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    assert_equal "canceling", run.reload.status, "the wake never ran"

    Runs::ScheduleSweepJob.perform_now
    assert_equal "canceled", run.reload.status
  end

  test "stopping a held loop settles its waiting tasks with it" do
    run = seed(model("brittle"), model("starved"))
    start!(run)
    run_step!(run, json_response(400, { "error" => "bad" }))
    run.reload
    assert_equal "needs_attention", run.status
    assert_equal "queued", node(run, "starved").status

    # The clock no longer ends a hold — stop is the terminal exit, and it must not leave
    # live-looking work behind.
    assert_predicate Runs::Stop.call(Runs::Stop::Command.forced(
      run: run, acting_user: @human
    )), :accepted?
    Runs::EvaluateQuiescence.call(run.reload)
    run.reload
    assert_equal "canceled", run.status
    assert_equal "canceled", node(run, "starved").status,
      "a terminal loop never carries live-looking waiting tasks"
  end

  test "an authority cut stops the loop the way a cancel does" do
    run = seed(model("head"), model("tail"))
    start!(run)

    # The cut: archive cancels the in-flight step once; the loop row is
    # still running and its sweeps would otherwise keep minting.
    @workspace.reload.accept_archive
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)

    run.reload
    assert_equal "canceled", run.status,
      "the scheduler's authority recheck kills the loop instead of minting under cut authority"
    assert_equal "authority_lost", run.failure_reason
    # The formula settled the dependent first: its source was canceled, so
    # it SKIPPED — either way, nothing waits inside the dead loop.
    assert_equal "skipped", node(run, "tail").status
    assert_equal 1, ModelInvocation.where(run_id: run.id).count,
      "no invocation was ever minted after the cut"
  end
end
