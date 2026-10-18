require "test_helper"
require "test_helpers/invocation_result_test_helper"

class ModelInvocations::ExecutionDeadlineTest < ActiveJob::TestCase
  include InvocationResultTestHelper

  test "typed provider timeout retries within the first admitted deadline" do
    first = admitted_attempt
    invocation = first.model_invocation
    deadline = first.deadline_at
    apply_via(first, SimpleInference::TimeoutError.new("read timed out"))
    invocation.update!(next_admission_at: 1.second.ago)

    second = ModelInvocations::AdmitQueuedWork.call.admitted.find { |row| row.invocation.id == invocation.id }.attempt
    assert_equal 2, second.ordinal
    assert_equal deadline, second.deadline_at
  end

  test "a retry whose original execution deadline passed never allocates another attempt" do
    first = admitted_attempt
    invocation = first.model_invocation
    apply_via(first, SimpleInference::TimeoutError.new("read timed out"))
    first.update!(deadline_at: 1.second.ago)
    invocation.update!(next_admission_at: 1.second.ago)

    assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
    assert_equal %w[timed_out deadline_passed], invocation.reload.values_at(:status, :failure_reason_key)
    assert_not invocation.recovery_eligible?
    assert_equal 1, invocation.attempts.count
  end

  test "an automatic one-shot fallback inherits the original admitted deadline" do
    creator = users(:agent)
    creator.update!(fallback_models: ["dev/mock-unmetered"])
    attempt = admitted_attempt(creator: creator)
    first = attempt.model_invocation
    deadline = attempt.deadline_at
    3.times do |index|
      if index.positive?
        first.update!(next_admission_at: 1.second.ago)
        attempt = ModelInvocations::AdmitQueuedWork.call.admitted.find { |row| row.invocation.id == first.id }.attempt
      end
      apply_via(attempt, SimpleInference::TimeoutError.new("read timed out"))
    end
    InferenceRequests::ConvergeTerminalEvents.call
    replacement = first.inference_request.reload.model_invocation
    assert_equal "mock-unmetered", replacement.model_ref
    admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find { |row| row.invocation.id == replacement.id }
    assert_equal deadline, admitted.attempt.deadline_at
  end
end
