require "test_helper"

# THE CREATOR'S CANCEL, AND WHO FINDS OUT.
#
# The cut itself is one guarded set update in the kernel every authority path
# shares, and the read surface goes terminal the moment it commits. What a
# FOLLOWER waits for is the terminal replay item, and that is a converger's to
# write — so a cut that wakes nobody leaves rho, and every other stream
# consumer, following a run the caller already stopped until the next
# level-triggered sweep comes round.
class InferenceRequests::CancelTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
  end

  def test_a_cut_wakes_the_convergers_once_it_has_committed
    inference_request = running_inference_request

    assert_enqueued_with(job: ModelInvocations::ConvergePostCutJob) do
      assert_enqueued_with(job: InferenceRequests::ConvergeTerminalEventsJob) do
        InferenceRequests::Cancel.call(inference_request: inference_request)
      end
    end
  end

  # A FRAMEWORK GUARANTEE THIS DESIGN LEANS ON, pinned because it is load
  # bearing and invisible. `enqueue_after_transaction_commit` is true, so a
  # plain `perform_later` inside the cut's fence waits for that fence. Flip it
  # off and the wake becomes a wakeup waiting to be lost: Solid Queue writes to
  # its own database, so the job row would commit independently of the cut and
  # a worker could find the invocation still non-terminal and converge nothing.
  def test_the_wake_waits_for_the_commit
    inference_request = running_inference_request

    # SAMPLED FROM INSIDE, because the question is what a worker could see
    # before the cut is durable. Counting around the transaction would count
    # after the commit and prove nothing.
    inside = nil
    ActiveRecord::Base.transaction do
      InferenceRequests::Cancel.call(inference_request: inference_request)
      assert_equal "canceled", inference_request.model_invocation.reload.status,
        "the cut is visible in this transaction; only the wake is deferred"
      inside = converger_jobs
    end

    assert_equal 0, inside, "an enqueue inside the cut's transaction is a wakeup waiting to be lost"
    assert_equal 2, converger_jobs, "and it arrives once the cut is durable"
  end

  # A terminal run matches nothing, so there is nothing to converge and no
  # reason to spend a job saying so.
  def test_a_cut_that_stops_nothing_wakes_nobody
    inference_request = running_inference_request
    InferenceRequests::Cancel.call(inference_request: inference_request)

    assert_no_enqueued_jobs(only: [ModelInvocations::ConvergePostCutJob,
                                   InferenceRequests::ConvergeTerminalEventsJob]) do
      InferenceRequests::Cancel.call(inference_request: inference_request)
    end
  end

  private

    def converger_jobs
      enqueued_jobs.count do |job|
        [ModelInvocations::ConvergePostCutJob.name,
         InferenceRequests::ConvergeTerminalEventsJob.name].include?(job.fetch("job_class"))
      end
    end

    def running_inference_request
      record = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
      invocation = DevModelLane.create_invocation!(inference_request: record)
      ModelInvocation.where(id: invocation.id).update_all(status: "running")
      record
    end
end
