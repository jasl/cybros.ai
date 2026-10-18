require "test_helper"

# The after-commit wake: who is told there is work, and when.
class ModelInvocations::WakeTest < ActiveJob::TestCase
  # Non-streaming workloads have only the queue implementation. Discovery is
  # based on that platform capability, not acceptance-time Catalog wire facts.
  test "a non-text workload wakes only the queue host" do
    notifications = 0

    described.stub(:notify_runner_after_commit, -> { notifications += 1 }) do
      assert_equal 1, described.after_commit_batch(
        attempts: [build_attempt(workload: "image_generation")]
      )
    end

    assert_equal 1, enqueued_jobs.count { _1["job_class"] == "ModelInvocations::RunJob" }
    assert_equal 0, notifications
  end

  test "the enqueue carries only the durable attempt identity, with no delay" do
    attempt = build_attempt

    assert_enqueued_with(job: ModelInvocations::RunJob) do
      described.after_commit_batch(attempts: [attempt])
    end

    enqueued = enqueued_jobs.sole
    assert_equal [attempt.public_id], enqueued["arguments"] || enqueued[:args]
    assert_nil enqueued["scheduled_at"] || enqueued[:at], "nothing waits on a host that does not exist"
  end

  test "a batch enqueues every attempt and coalesces its runner notification" do
    attempts = 3.times.map { build_attempt }
    notifications = 0

    described.stub(:notify_runner_after_commit, -> { notifications += 1 }) do
      assert_enqueued_jobs 3, only: ModelInvocations::RunJob do
        assert_equal 3, described.after_commit_batch(attempts: attempts)
      end
    end

    assert_equal attempts.map(&:public_id).sort,
      enqueued_jobs.map { (_1["arguments"] || _1[:args]).sole }.sort
    assert_equal 1, notifications
  end

  # The failure is the adapter's (never a stub on `ActiveJob.perform_all_later`:
  # a prepended override makes Minitest's alias/restore recurse).
  test "a queue failure does not suppress the independent runner wake" do
    notifications = 0
    error = SolidQueue::Job::EnqueueError.new("queue unavailable")

    described.stub(:notify_runner_after_commit, -> { notifications += 1 }) do
      queue_adapter.stub(:enqueue, ->(*) { raise error }) do
        assert_raises(SolidQueue::Job::EnqueueError) do
          described.after_commit_batch(attempts: [build_attempt])
        end
      end
    end

    assert_equal 1, notifications
  end

  # Rails 8.2 defaults hold an enqueue until its transaction commits and drop it if the transaction
  # rolls back so a rolled-back domain change cannot dispatch a wake.
  test "an enqueue inside a rolled-back transaction never reaches the queue" do
    attempt = build_attempt

    assert_no_enqueued_jobs do
      ApplicationRecord.transaction do
        described.after_commit_batch(attempts: [attempt])
        raise ActiveRecord::Rollback
      end
    end
  end

  private

    def build_attempt(workload: "text_generation")
      ModelInvocationAttempt.new(
        public_id: SecureRandom.uuid_v7,
        model_invocation: ModelInvocation.new(workload: workload)
      )
    end

    def described = ModelInvocations::Wake
end
