require "test_helper"
require "test_helpers/invocation_result_test_helper"
require "test_helpers/gemini_finish_test_helper"

class ModelInvocations::ApplyResultFinishErrorTest < ActiveJob::TestCase
  include InvocationResultTestHelper
  include GeminiFinishTestHelper

  test "every abnormal Gemini finish fails the work while retaining its completed exchange and billed usage" do
    ERROR_REASONS.each do |reason|
      [false, true].each do |empty|
        attempt = admitted_attempt
        applied = apply_provider_result(attempt, gemini_error_result(reason, empty: empty), adapter_profile: "gemini_generate_content")
        assert_predicate applied, :applied?
        assert_not_predicate applied, :requeued?
        invocation = attempt.model_invocation.reload
        assert_equal ["completed", "error", "provider_error"], invocation.values_at(:status, :finish_quality, :failure_reason_key)
        assert_equal "failed", invocation.work_status
        assert_not_predicate invocation, :declined?
        assert_nil invocation.refusal_category
        assert_includes invocation.failure_detail, reason
        assert_empty invocation.content_bodies.where(role: %w[response reasoning reasoning_trace tool_calls])
        assert_equal "completed", attempt.reload.status
        assert_equal 1, invocation.attempts.count
        receipt = receipt_for(attempt)
        assert_equal ["succeeded", 3, 9], receipt.values_at(:status, :input_tokens, :total_tokens)
        assert_equal({ "code" => "provider_error" }, ModelInvocations::PublicError.render(invocation, receipt))
      end
    end
  end

  test "a failed finish projects to one-shot reads and terminal events without invoking the declared fallback" do
    agent = users(:agent)
    agent.update!(fallback_model: "dev/mock-unmetered")
    attempt = admitted_attempt(creator: agent)
    apply_provider_result(attempt, gemini_error_result("OTHER"), adapter_profile: "gemini_generate_content")
    InferenceRequests::ConvergeTerminalEvents.call(invocation_id: attempt.model_invocation_id)

    inference_request = attempt.model_invocation.inference_request.reload
    assert_equal "failed", inference_request.status
    assert_equal 1, inference_request.model_invocations.count
    result = AgentAPI::InferenceRequestPresenter.full(inference_request).fetch(:result)
    assert_equal ["failed", "error", { "code" => "provider_error" }], result.values_at(:status, :finish_quality, :error)
    assert_not result.key?(:output_text)
    terminal = inference_request.inference_request_event_items.find_by!(item_type: "result").payload.fetch("result")
    assert_equal ["failed", "error", { "code" => "provider_error" }], terminal.values_at("status", "finish_quality", "error")
    assert_nil inference_request.inference_request_event_items.find_by(item_type: "provider_output_item_completed")
  end
end
