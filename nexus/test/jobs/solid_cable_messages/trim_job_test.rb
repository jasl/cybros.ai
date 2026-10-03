require "test_helper"

# The cable's own reclamation, which is level-triggered and bounded like every
# other reaper here — and which the gem's single-batch job is not.
#
# The numbers are the point. A streaming turn broadcasts about ten times a
# second, so a producer can write a full batch in under a minute; a trim that
# takes one batch per scheduled run and stops loses that race forever. These
# assertions are about CONTINUATION, not about deletion, because deletion was
# never the missing half.
class SolidCableMessages::TrimJobTest < ActiveJob::TestCase
  setup do
    SolidCable::Message.delete_all
  end

  teardown do
    SolidCable::Message.delete_all
  end

  test "an idle pass deletes nothing and schedules no continuation" do
    seed(3, created_at: Time.current)

    assert_no_enqueued_jobs(only: SolidCableMessages::TrimJob) do
      SolidCableMessages::TrimJob.perform_now
    end
    assert_equal 3, SolidCable::Message.count,
      "a message inside the retention window is not the trimmer's to take"
  end

  test "a backlog larger than one batch is drained across continuations" do
    SolidCable.stub(:trim_batch_size, 2) do
      seed(5, created_at: 2.days.ago)

      assert_enqueued_with(job: SolidCableMessages::TrimJob, args: [2]) do
        SolidCableMessages::TrimJob.perform_now
      end
      assert_equal 3, SolidCable::Message.count, "exactly one batch per pass"

      perform_enqueued_jobs while enqueued_jobs.any?
      assert_equal 0, SolidCable::Message.count,
        "the continuations keep taking batches until nothing is trimmable"
    end
  end

  # THE BOUND IS WHAT KEEPS A DRAIN FROM STARVING THE QUEUE IT RUNS ON. A
  # backlog bigger than one scheduled run's worth waits for the next minute
  # rather than monopolizing a worker.
  test "the last pass stops even with a backlog still standing" do
    SolidCable.stub(:trim_batch_size, 1) do
      seed(3, created_at: 2.days.ago)

      assert_no_enqueued_jobs(only: SolidCableMessages::TrimJob) do
        SolidCableMessages::TrimJob.perform_now(SolidCableMessages::TrimJob::MAX_PASSES)
      end
      assert_equal 2, SolidCable::Message.count, "it still took its own batch"
    end
  end

  private

    def seed(count, created_at:)
      SolidCable::Message.insert_all(
        Array.new(count) do |index|
          { channel: "c#{index}", payload: "p", channel_hash: index, created_at: created_at }
        end
      )
    end
end
