require "test_helper"

class Deployments::MaintenanceTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  test "an already started provider finishes while maintenance holds later work" do
    attempt = admitted_attempt
    dispatch = ModelInvocations::Dispatch.method(:call)
    begin_maintenance = ->(**arguments, &block) do
      status = Deployments::Maintenance.prepare
      assert status.fetch(:active)
      assert_not status.fetch(:drained)
      assert_equal 1, status.fetch(:model_attempts)
      dispatch.call(**arguments, &block)
    end

    fake_dispatch(sse_success("finished before restart")) do |adapter|
      ModelInvocations::Dispatch.stub(:call, begin_maintenance) do
        ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "model_runner")
      end
      assert_equal 1, adapter.requests.length
    end

    assert_equal "completed", attempt.reload.status
    assert_equal "settled", attempt.settlement_state
    assert Deployments::Maintenance.status.fetch(:drained)
    assert Deployments::Maintenance.active?
  end

  test "claimed effects commit once while new claims and scheduling stay closed" do
    run = seed(tool("first", "read_file"), tool("second", "read_file"))
    start_run(run)
    claim = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: run, task_key: "first", executor: suite_runner
    ))
    assert_predicate claim, :accepted?
    status = Deployments::Maintenance.prepare
    assert_equal 1, status.fetch(:claimed_tools)
    assert_not status.fetch(:drained)
    assert status.fetch(:active_work)

    command = Executors::Commit::Command.new(
      agent_run: run, task_key: "first", executor: suite_runner, claim_token: claim.value.claim_token,
      content: "retained result", outcome: "completed", result_type: nil,
      is_error: false, title: nil, metadata: nil
    )
    assert_predicate Executors::Commit.call(command), :applied?
    assert_equal :idle, Executors::Commit.call(command).outcome
    AgentRuns::ScheduleReady.call(agent_run_id: run.id)
    assert_equal "queued", run.agent_run_tasks.find_by!(node_key: "second").status
    assert Deployments::Maintenance.status.fetch(:drained)

    assert_enqueued_with(job: AgentRuns::ScheduleSweepJob) { Deployments::Maintenance.resume }
    AgentRuns::ScheduleReady.call(agent_run_id: run.id)
    assert_equal "dispatched", run.agent_run_tasks.find_by!(node_key: "second").status
  end

  test "queued model work waits without an attempt then uses ordinary admission after resume" do
    run = seed(model("next"))
    start_run(run)
    invocation = run.agent_run_tasks.find_by!(node_key: "next").selected_model_invocation
    assert_equal "queued", invocation.status
    Deployments::Maintenance.prepare

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
    assert_empty invocation.attempts
    assert Deployments::Maintenance.status.fetch(:drained)
    assert Deployments::Maintenance.status.fetch(:active_work)

    Deployments::Maintenance.resume
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted
    assert_equal [invocation.id], admitted.map { |item| item.invocation.id }
  end

  test "a dispatched kernel task drains while its continuation stays queued" do
    declaration = Nexus::ToolRegistry::LIVE.fetch("nexus.memory.ls").function_definition
    run = seed(model("first", "tools" => [declaration]))
    start_run(run)
    invocation = run.agent_run_tasks.find_by!(node_key: "first").selected_model_invocation
    attempt = ModelInvocations::AdmitQueuedWork.call.admitted.find do |item|
      item.invocation.id == invocation.id
    end.attempt
    apply_via(attempt, sse_success("read memory", tool_calls: [
      { id: "memory", name: "memory_ls", arguments: "{}" },
    ]))
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: run.id)
    first = run.agent_run_tasks.find_by!(tool_call_id: "memory")
    assert_equal "running", first.status
    assert_equal 1, Deployments::Maintenance.prepare.fetch(:kernel_tools)

    Nexus::ToolRegistry.job_for(first.tool_name).perform_now(first.id)
    assert_equal "completed", first.reload.status
    AgentRuns::ScheduleReady.call(agent_run_id: run.id)
    continuation = run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name, status: "queued").sole
    assert Deployments::Maintenance.status.fetch(:drained)

    Deployments::Maintenance.resume
    AgentRuns::ScheduleReady.call(agent_run_id: run.id)
    assert_equal "running", continuation.reload.status
  end

  test "a host retaining the old prepared deadline observes maintenance repayment before refusal" do
    attempt = admitted_attempt
    at = Time.current.change(usec: 0)
    attempt.update!(deadline_at: at + 1.minute)
    stale = ModelInvocationAttempt.find(attempt.id)
    DatabaseClock.stub(:now, at) { Deployments::Maintenance.prepare }

    DatabaseClock.stub(:now, at + 2.hours) do
      Deployments::Maintenance.resume
      invocation = stale.model_invocation
      result = ModelInvocations::ProviderStart.call(attempt: stale, host: "solid_queue",
        base_url: ModelCatalog.provider_base_url(invocation.provider_id),
        profile: DevModelLane.profile_for_invocation(invocation))
      assert_predicate result, :started?
    end
    assert_equal "running", attempt.reload.status
    assert_equal at + 2.hours + 1.minute, attempt.deadline_at
  end

  test "terminal attempts awaiting late accounting do not block the execution drain" do
    attempt = admitted_attempt
    start(attempt)
    attempt.update!(status: "canceled")
    attempt.model_invocation.update!(status: "canceled")

    status = Deployments::Maintenance.prepare

    assert_equal "pending", attempt.reload.settlement_state
    assert_equal 0, status.fetch(:model_attempts)
    assert status.fetch(:drained)
    assert_not status.fetch(:active_work)
  end

  test "prepare and resume retry retain one frozen interval" do
    attempt = admitted_attempt
    original_deadline = attempt.deadline_at
    at = Time.current.change(usec: 0)
    first = DatabaseClock.stub(:now, at) { Deployments::Maintenance.prepare }
    repeated = DatabaseClock.stub(:now, at + 1.hour) { Deployments::Maintenance.prepare }
    assert_equal first.fetch(:started_at), repeated.fetch(:started_at)

    DatabaseClock.stub(:now, at + 2.hours) { Deployments::Maintenance.resume }
    assert_in_delta original_deadline + 2.hours, attempt.reload.deadline_at, 0.001
    deadline = attempt.deadline_at
    DatabaseClock.stub(:now, at + 3.hours) { Deployments::Maintenance.resume }
    assert_equal deadline, attempt.reload.deadline_at
    assert_not Deployments::Maintenance.active?
  end

  private

    def start_run(run)
      assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: run, acting_user: @human
      )), :accepted?
      AgentRuns::ScheduleReady.call(agent_run_id: run.id)
      clear_enqueued_jobs
    end
end
