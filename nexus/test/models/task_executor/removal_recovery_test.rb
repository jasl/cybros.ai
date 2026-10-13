require "test_helper"

class TaskExecutor::RemovalRecoveryTest < ActiveJob::TestCase
  setup do
    @human = users(:owner)
    @workspace = workspaces(:shared)
  end

  test "revocation wakes cleanup only after its enclosing authority transaction commits" do
    executor = suite_runner
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: AgentRuns::Parks::TimeoutSweepJob) do
      TaskExecutor.transaction(requires_new: true) do
        executor.revoke
        assert_predicate executor, :revoked?
        raise ActiveRecord::Rollback
      end
    end
    assert_not executor.reload.revoked?

    assert_enqueued_with(job: AgentRuns::Parks::TimeoutSweepJob) do
      TaskExecutor.transaction do
        executor.revoke
        assert_no_enqueued_jobs(only: AgentRuns::Parks::TimeoutSweepJob)
      end
    end
    assert_predicate executor.reload, :revoked?
  end

  test "recurring recovery settles unclaimed work when runner revocation stops after its authority cut" do
    agent_run = seed(tool("read", "read_file"))
    assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    task = agent_run.agent_run_tasks.find_by!(node_key: "read")
    assert_equal "dispatched", task.status
    assert_equal suite_runner.id, task.addressed_executor_id

    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(
      agent_run: agent_run, acting_user: @human
    )), :accepted?
    clear_enqueued_jobs

    AgentRuns::Parks::TimeoutSweepJob.stub(:perform_later, -> { raise IOError, "revocation interrupted" }) do
      assert_raises(IOError) { suite_runner.revoke }
    end
    assert_predicate suite_runner.reload, :revoked?, "the address fence survives the interrupted cleanup"
    assert_equal "dispatched", task.reload.status

    # A paused loop's virtual deadline cannot rescue a lost removal pass.
    # Only ordinary recurring entrypoints may rediscover the obligation.
    perform_enqueued_jobs(only: [TaskExecutors::ConvergeJob, AgentRuns::ScheduleJob]) do
      2.times do
        TaskExecutors::ConvergeJob.perform_now
        AgentRuns::ScheduleSweepJob.perform_now
        AgentRuns::Parks::TimeoutSweepJob.perform_now
      end
    end

    assert_equal %w[failed executor_revoked], task.reload.values_at(:status, :error_key)
  end
end
