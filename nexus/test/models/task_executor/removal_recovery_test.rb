require "test_helper"

class TaskExecutor::RemovalRecoveryTest < ActiveJob::TestCase
  setup do
    @human = users(:owner)
    @workspace = workspaces(:shared)
  end

  test "revocation wakes cleanup only after its enclosing authority transaction commits" do
    executor = suite_runner
    clear_enqueued_jobs

    assert_no_enqueued_jobs(only: AgentLoops::Parks::TimeoutSweepJob) do
      TaskExecutor.transaction(requires_new: true) do
        executor.revoke
        assert_predicate executor, :revoked?
        raise ActiveRecord::Rollback
      end
    end
    assert_not executor.reload.revoked?

    assert_enqueued_with(job: AgentLoops::Parks::TimeoutSweepJob) do
      TaskExecutor.transaction do
        executor.revoke
        assert_no_enqueued_jobs(only: AgentLoops::Parks::TimeoutSweepJob)
      end
    end
    assert_predicate executor.reload, :revoked?
  end

  test "recurring recovery settles unclaimed work when runner revocation stops after its authority cut" do
    agent_loop = seed(tool("read", "read_file"))
    assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    task = agent_loop.agent_loop_nodes.find_by!(node_key: "read")
    assert_equal "dispatched", task.status
    assert_equal suite_runner.id, task.addressed_executor_id

    assert_predicate AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: agent_loop, acting_user: @human
    )), :accepted?
    clear_enqueued_jobs

    AgentLoops::Parks::TimeoutSweepJob.stub(:perform_later, -> { raise IOError, "revocation interrupted" }) do
      assert_raises(IOError) { suite_runner.revoke }
    end
    assert_predicate suite_runner.reload, :revoked?, "the address fence survives the interrupted cleanup"
    assert_equal "dispatched", task.reload.status

    # A paused loop's virtual deadline cannot rescue a lost removal pass.
    # Only ordinary recurring entrypoints may rediscover the obligation.
    perform_enqueued_jobs(only: [TaskExecutors::ConvergeJob, AgentLoops::ScheduleJob]) do
      2.times do
        TaskExecutors::ConvergeJob.perform_now
        AgentLoops::ScheduleSweepJob.perform_now
        AgentLoops::Parks::TimeoutSweepJob.perform_now
      end
    end

    assert_equal %w[failed executor_revoked], task.reload.values_at(:status, :error_key)
  end
end
