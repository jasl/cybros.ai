require "test_helper"

# A nil phase cursor is durable only for one continuation chain. The job must
# serialize it explicitly beside the still-live cursor; otherwise the next hop
# would silently restart the parked walk and recover the quadratic scan.
class DependencyBlockedReaperJobsTest < ActiveJob::TestCase
  test "family continuation carries both the live and parked cursor" do
    # The pair the family sweep hand-carries: the marker walk's, then the reap walk's.
    result = Sweeps::Pass.new(counts: { marked: 0, reaped: 0, scanned: 1 }, cursor: [42, nil], more: true)

    RefreshTokenFamily.stub(:converge, result) do
      assert_enqueued_with(
        job: RefreshTokenFamilies::ConvergeJob,
        args: [42, nil]
      ) do
        RefreshTokenFamilies::ConvergeJob.perform_now
      end
    end
  end

  test "executor continuation carries both the parked and live cursor" do
    # The pair the executor sweep hand-carries: the shutdown walk's, then the reap walk's.
    result = Sweeps::Pass.new(counts: { converged: 0, reaped: 0, scanned: 1 }, cursor: [nil, 84], more: true)

    TaskExecutor.stub(:converge, result) do
      assert_enqueued_with(
        job: TaskExecutors::ConvergeJob,
        args: [nil, 84]
      ) do
        TaskExecutors::ConvergeJob.perform_now
      end
    end
  end

  test "refresh-token continuation preserves its parked lapsed-family phase" do
    # The pair the token sweep hand-carries: the lapsed walk's, then the marker walk's.
    result = Sweeps::Pass.new(counts: { marked: 0, reaped: 0, scanned: 1 }, cursor: [false, 73], more: true)

    RefreshToken.stub(:converge, result) do
      assert_enqueued_with(
        job: RefreshTokens::ConvergeJob,
        args: [false, 73]
      ) do
        RefreshTokens::ConvergeJob.perform_now
      end
    end
  end
end
