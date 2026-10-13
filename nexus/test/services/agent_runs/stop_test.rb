require "test_helper"

# Stop immediately cancels queued and approval-held tasks with a recorded reason. Neither has begun
# an external effect, and leaving an approval parked would wait for a decision the stopped loop can
# no longer use.
class AgentRuns::StopTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    clear_enqueued_jobs
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def stop!(agent_run, force: true)
    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.new(
      agent_run: agent_run, acting_user: @human, force: force
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result
  end

  # A row held at the stage is neither started (the drain never waits on
  # it) nor, before this, selected by the unstarted cancel: a graceful stop
  # left it resting forever and a forced one wedged the loop in `canceling`.
  test "a row resting at the approval stage is canceled by the stop with the loop's reason, and its announcement clears" do
    agent_run = seed(tool("held", "read_file"), model("after"))
    start!(agent_run)
    held = node(agent_run, "held")
    # FORGED through `update_all`: an authored row never parks, so the rest state is written by hand
    # — with its clock, which every approval-held row must carry.
    AgentRunTask.where(id: held.id).update_all(status: "needs_approval", started_at: nil,
      await_started_at: Time.current, addressed_executor_id: nil, addressed_role: nil, effect_profile: nil)
    AgentRuns::EvaluateQuiescence.call(agent_run.reload)
    assert_equal AgentRuns::EvaluateQuiescence::APPROVAL_REASON, agent_run.reload.attention_reason,
      "a held row announces while the loop runs"

    stop!(agent_run, force: false)

    assert_nil agent_run.reload.attention_reason, "the stop clears the announcement with the row"
    assert_equal %w[canceled run_canceled], held.reload.values_at(:status, :error_key)
    assert_equal %w[canceled run_canceled], node(agent_run, "after").values_at(:status, :error_key),
      "the queued follower is canceled with the same reason"
    assert_equal "canceling", agent_run.reload.status
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "canceled", agent_run.reload.status, "nothing started, so the drain ends the loop at its next pass"
  end

  # The stage set is the pre-dispatch set: the one the starvation arm and
  # `waiting_on` already read, so the three agree on what has spent nothing.
  test "the unstarted cancel selects the pre-dispatch statuses" do
    assert_equal %w[queued needs_approval], AgentRunTask::PRE_DISPATCH_STATUSES
    agent_run = seed(model("first"), model("second"))
    start!(agent_run)
    assert_equal "queued", node(agent_run, "second").status

    stop!(agent_run)

    assert_equal %w[canceled run_canceled], node(agent_run, "second").values_at(:status, :error_key),
      "a queued row carries the reason the person's stop gave it"
  end

  # A pending loop's stop is the same cancel: every row is unstarted.
  test "a pending loop's stop cancels its rows with the reason and ends the loop" do
    agent_run = seed(model("only"))

    stop!(agent_run)

    assert_equal %w[canceled run_canceled], node(agent_run, "only").values_at(:status, :error_key)
    assert_equal "canceled", agent_run.reload.status
  end

  test "a synchronous scheduler wake applies the forced cut without recursively waking itself" do
    agent_run = seed(model("started"), model("queued"))
    start!(agent_run)
    invocation = node(agent_run, "started").selected_model_invocation
    stop!(agent_run, force: false)
    clear_enqueued_jobs
    clear_performed_jobs

    perform_enqueued_jobs(only: AgentRuns::ScheduleJob) do
      AgentRuns::Stop.mark_now(agent_run)
    end

    assert_performed_jobs 1, only: AgentRuns::ScheduleJob
    assert_equal "canceled", invocation.reload.status
    assert_equal "canceling", agent_run.reload.status,
      "the scheduler yields to invocation convergence instead of enqueuing itself"
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    assert_equal "canceled", agent_run.reload.status
  end

  test "authority loss and replacement permanently cut their owner while retaining graceful drain semantics" do
    %w[authority_lost replaced].each do |reason|
      agent_run = seed(model("started"), model("queued"))
      start!(agent_run)
      invocation = node(agent_run, "started").selected_model_invocation
      original_status = invocation.status

      agent_run.with_lock do
        AgentRuns::Stop.terminate(agent_run, failure_reason: reason, force: false)
      end

      assert_not agent_run.reload.stopped?, "the graceful state is durable without a forced-cut marker"
      assert AgentRuns::SourceWork.stopped?(agent_run.public_id, agent_run)
      assert_equal ["canceling", reason], agent_run.values_at(:status, :failure_reason)
      assert_equal original_status, invocation.reload.status, "graceful stop still lets an in-flight step drain"
      assert_equal "canceled", node(agent_run, "queued").status
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      assert_equal original_status, invocation.reload.status, "the queued stop wake must not escalate force:false"
      assert_equal "canceling", agent_run.reload.status
      stop!(agent_run)
      cut = agent_run.reload.stopped_at
      assert cut, "the explicit force upgrade writes the permanent marker"
      stop!(agent_run)
      assert_equal cut, agent_run.reload.stopped_at
    end
  end
end
