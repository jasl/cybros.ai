require "test_helper"

class AgentLoops::DrainSweepJobTest < ActiveJob::TestCase
  test "a full retained window enqueues one continuation with its cursor" do
    result = Sweeps::Pass.new(counts: { scanned: 200, escalated: 0 }, cursor: 321, more: true)

    AgentLoops::DrainSweep.stub(:call, result) do
      assert_no_enqueued_jobs(only: AgentLoops::ConvergeTerminalStepsJob) do
        assert_enqueued_jobs 1, only: AgentLoops::DrainSweepJob do
          assert_enqueued_with(job: AgentLoops::DrainSweepJob, args: [321]) do
            AgentLoops::DrainSweepJob.perform_now
          end
        end
      end
    end
  end

  test "the final page forwards the cursor and wakes terminal convergence without continuing" do
    result = Sweeps::Pass.new(counts: { scanned: 1, escalated: 1 }, cursor: 322, more: false)
    call = ->(after_id:, **) do
      assert_equal 321, after_id
      result
    end

    AgentLoops::DrainSweep.stub(:call, call) do
      assert_no_enqueued_jobs(only: AgentLoops::DrainSweepJob) do
        assert_enqueued_jobs 1, only: AgentLoops::ConvergeTerminalStepsJob do
          AgentLoops::DrainSweepJob.perform_now(321)
        end
      end
    end
  end

  test "an empty recurring pass enqueues no work" do
    result = Sweeps::Pass.new(counts: { scanned: 0, escalated: 0 }, cursor: 0, more: false)

    AgentLoops::DrainSweep.stub(:call, result) do
      assert_no_enqueued_jobs { AgentLoops::DrainSweepJob.perform_now }
    end
  end
end
