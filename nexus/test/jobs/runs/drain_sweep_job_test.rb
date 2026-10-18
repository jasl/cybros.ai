require "test_helper"

class Runs::DrainSweepJobTest < ActiveJob::TestCase
  test "a full retained window enqueues one continuation with its cursor" do
    result = Sweeps::Pass.new(counts: { scanned: 200, escalated: 0 }, cursor: 321, more: true)

    Runs::DrainSweep.stub(:call, result) do
      assert_no_enqueued_jobs(only: Runs::ConvergeTerminalStepsJob) do
        assert_enqueued_jobs 1, only: Runs::DrainSweepJob do
          assert_enqueued_with(job: Runs::DrainSweepJob, args: [321]) do
            Runs::DrainSweepJob.perform_now
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

    Runs::DrainSweep.stub(:call, call) do
      assert_no_enqueued_jobs(only: Runs::DrainSweepJob) do
        assert_enqueued_jobs 1, only: Runs::ConvergeTerminalStepsJob do
          Runs::DrainSweepJob.perform_now(321)
        end
      end
    end
  end

  test "an empty recurring pass enqueues no work" do
    result = Sweeps::Pass.new(counts: { scanned: 0, escalated: 0 }, cursor: 0, more: false)

    Runs::DrainSweep.stub(:call, result) do
      assert_no_enqueued_jobs { Runs::DrainSweepJob.perform_now }
    end
  end
end
