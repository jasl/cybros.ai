require "test_helper"
require_relative "../../test_helpers/agent_runs_execution_test_helper"

class AgentRuns::ExecutionLifecycleTest < ActiveJob::TestCase
  include AgentRunsExecutionTestHelper

  test "two-phase cancel: in-flight steps terminalize, the drain settles the loop" do
    agent_run = seed(model("running-step"), model("waiting-step"))
    start!(agent_run)
    running = node(agent_run, "running-step")
    invocation = ModelInvocation.find(running.selected_model_invocation_id)

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "canceling", agent_run.status
    assert_equal "canceled", node(agent_run, "waiting-step").status
    assert_equal "canceled", invocation.reload.status
    assert_equal "running", running.reload.status,
      "phase one never touches a running node — the converger applies its terminal"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", running.reload.status
    assert_equal "canceled", agent_run.reload.status
  end

  test "pause stops scheduling while in-flight work still applies; resume picks it up" do
    agent_run = seed(model("first"), model("second"))
    start!(agent_run)

    pause = AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate pause, :accepted?

    apply_via(step_attempt(agent_run), sse_success("landed while paused"))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "completed", node(agent_run, "first").status,
      "pause stops scheduling, never result application"
    assert_equal "queued", node(agent_run, "second").status

    resume = AgentRuns::Resume.call(AgentRuns::Resume::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate resume, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "running", node(agent_run, "second").status
  end

  test "the schedule sweep re-seeds a loop whose wake was lost" do
    agent_run = seed(model("orphan"))
    result = AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    clear_enqueued_jobs
    assert_equal "queued", node(agent_run, "orphan").status, "the wake was never run"

    AgentRuns::ScheduleSweepJob.perform_now
    assert_equal "running", node(agent_run, "orphan").status
  end

  test "the ask waits indefinitely — no sweep ends a hold (§9c)" do
    agent_run = seed(model("brittle"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    agent_run.reload
    assert_equal "needs_attention", agent_run.status

    # Days pass; nothing expires the ask — the exits are the adjudication verbs, stop, and
    # tombstone, never a clock.
    assert_not defined?(AgentRuns::AttentionSweepJob),
      "the attention sweep is deleted, not merely disabled"
    assert_equal "needs_attention", agent_run.reload.status
    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "brittle", acting_user: @human
    ))
    assert_predicate result, :accepted?, "the three-day-old ask is still answerable"
    assert_equal "running", agent_run.reload.status
  end

  test "the drain sweep escalates a canceling loop past the hard limit" do
    agent_run = seed(ask("gate", "timeout_ms" => 6.hours.in_milliseconds))
    start!(agent_run)
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    )), :accepted?
    assert_equal "canceling", agent_run.reload.status

    AgentRuns::DrainSweepJob.perform_now
    assert_equal "canceling", agent_run.reload.status,
      "a young drain re-evaluates and keeps waiting for its park"

    # Past the ceiling nothing legitimate can still be pending — whatever
    # remains is a bug's residue, and the sweep bounds what it costs.
    agent_run.update_columns(canceling_since: 25.hours.ago)
    AgentRuns::DrainSweepJob.perform_now
    agent_run.reload
    assert_equal "canceled", agent_run.status
    assert_equal "canceled", node(agent_run, "gate").status
  end

  test "a step that fails while the loop is canceling settles canceled, never requeued" do
    agent_run = seed(model("racy"))
    start!(agent_run)
    racy = node(agent_run, "racy")
    invocation = ModelInvocation.find(racy.selected_model_invocation_id)
    # The race: the step self-terminalizes (deadline sweep / attempt budget)
    # before cancel's phase one runs, so cancel's own terminalize no-ops.
    ModelInvocation.lock.find(invocation.id)
      .terminalize(status: "failed", reason_key: ModelInvocation::TRANSIENT_EXHAUSTED_KEY)

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    assert_equal "canceling", agent_run.reload.status

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    racy.reload
    assert_equal "canceled", racy.status,
      "the retry budget never resurrects work inside a dying loop"
    assert_equal "canceled", agent_run.reload.status
  end

  test "a graceful stop lets in-flight work finish and KEEPS its answer" do
    agent_run = seed(model("working", "prompt" => "almost done"), model("waiting"))
    start!(agent_run)
    working = node(agent_run, "working")
    invocation = ModelInvocation.find(working.selected_model_invocation_id)

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "canceling", agent_run.status
    assert_equal "canceled", node(agent_run, "waiting").status,
      "nothing NEW ever starts, graceful or not"
    assert_equal "queued", invocation.reload.status,
      "the in-flight step was NOT terminalized — graceful means finish"

    run_step!(agent_run, sse_success("the last answer"))
    working.reload
    assert_equal "completed", working.status
    assert_includes working.content_bodies.find_by!(role: "output").effective_text,
      "the last answer", "the drain waited and the answer survived"
    assert_equal "canceled", agent_run.reload.status
  end

  test "a graceful stop waits for a parked await, which can still resolve" do
    agent_run = seed(ask("gate", "timeout_ms" => 6.hours.in_milliseconds))
    token = AgentRunAppendReceipt.where(agent_run_id: agent_run.id).order(:id).first
      .response_body.dig("resolution_tokens", "gate")
    start!(agent_run)
    gate = node(agent_run, "gate")
    assert_equal "dispatched", gate.status

    AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    ))
    assert_equal "canceling", agent_run.reload.status
    assert_equal "dispatched", gate.reload.status, "the rendezvous is worth waiting for"

    resolved = AgentRuns::Parks::Settle.call(
      node: gate, claim_token: gate.resolution_token, content: "the external answer"
    )
    assert_predicate resolved, :applied?, "a canceling loop still settles its parks"
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", agent_run.reload.status
    assert_equal "completed", gate.reload.status
  end

  test "a graceful stop escalates: stopping again with force ends the wait" do
    agent_run = seed(model("slow"))
    start!(agent_run)
    invocation = ModelInvocation.find(node(agent_run, "slow").selected_model_invocation_id)

    AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: false
    ))
    assert_equal "queued", invocation.reload.status, "graceful leaves it running"

    AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_equal "canceled", invocation.reload.status, "force ends the wait NOW"

    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "canceled", agent_run.reload.status
  end

  test "canceling a pending loop settles it at once, and cancel converges idempotently" do
    agent_run = seed(model("unstarted"))

    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    agent_run.reload
    assert_equal "canceled", agent_run.status
    assert_equal "canceled", node(agent_run, "unstarted").status

    again = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_equal :already_terminal, again.outcome
  end

  test "a timed-out step holds like any halt failure and abandon resolves it" do
    agent_run = seed(model("slowpoke"))
    start!(agent_run)
    slowpoke = node(agent_run, "slowpoke")
    step_attempt(agent_run)
    # The deadline sweep's own write, applied by the converger like any
    # terminal.
    ModelInvocation.lock.find(slowpoke.selected_model_invocation_id)
      .terminalize(status: "timed_out", reason_key: "deadline_passed")
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)

    slowpoke.reload
    assert_equal "timed_out", slowpoke.status
    assert_equal "deadline_passed", slowpoke.error_key
    assert_equal "needs_attention", agent_run.reload.status

    abandoned = AgentRuns::Tasks::Abandon.call(AgentRuns::Tasks::Abandon::Command.new(
      agent_run: agent_run, task_key: "slowpoke", acting_user: @human
    ))
    assert_predicate abandoned, :accepted?
    clear_enqueued_jobs
    schedule!(agent_run)
    assert_equal "needs_attention", agent_run.reload.status
    assert_equal "deliverable_unresolved", agent_run.attention_reason,
      "the deliverable was abandoned, not answered — the kernel never synthesizes"
  end

  test "the schedule sweep drains a canceling loop whose wake was lost" do
    agent_run = seed(model("inflight"))
    start!(agent_run)
    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    ))
    assert_predicate result, :accepted?
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    assert_equal "canceling", agent_run.reload.status, "the wake never ran"

    AgentRuns::ScheduleSweepJob.perform_now
    assert_equal "canceled", agent_run.reload.status
  end

  test "stopping a held loop settles its waiting tasks with it" do
    agent_run = seed(model("brittle"), model("starved"))
    start!(agent_run)
    run_step!(agent_run, json_response(400, { "error" => "bad" }))
    agent_run.reload
    assert_equal "needs_attention", agent_run.status
    assert_equal "queued", node(agent_run, "starved").status

    # The clock no longer ends a hold — stop is the terminal exit, and it must not leave
    # live-looking work behind.
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    agent_run.reload
    assert_equal "canceled", agent_run.status
    assert_equal "canceled", node(agent_run, "starved").status,
      "a terminal loop never carries live-looking waiting tasks"
  end

  test "an authority cut stops the loop the way a cancel does" do
    agent_run = seed(model("head"), model("tail"))
    start!(agent_run)

    # The cut: archive cancels the in-flight step once; the loop row is
    # still running and its sweeps would otherwise keep minting.
    @workspace.reload.accept_archive
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)

    agent_run.reload
    assert_equal "canceled", agent_run.status,
      "the scheduler's authority recheck kills the loop instead of minting under cut authority"
    assert_equal "authority_lost", agent_run.failure_reason
    # The formula settled the dependent first: its source was canceled, so
    # it SKIPPED — either way, nothing waits inside the dead loop.
    assert_equal "skipped", node(agent_run, "tail").status
    assert_equal 1, ModelInvocation.where(agent_run_id: agent_run.id).count,
      "no invocation was ever minted after the cut"
  end
end
