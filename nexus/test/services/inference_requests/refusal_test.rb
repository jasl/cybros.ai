require "test_helper"
require "test_helpers/invocation_result_test_helper"

# A REFUSED ONE-SHOT FAILED, the way every other lane reports a refusal: the
# call completed and was billed, but the run produced no answer, so its
# status is `failed` with `error.code: model_refused`, the quality and the
# category beside it. Between the refusal's apply and the terminal event's
# record the aggregate reads `running` — the converger decides what the
# refusal comes to, and nothing may read, follow or tombstone a verdict the
# converger has not recorded.
class InferenceRequests::RefusalTest < ActiveJob::TestCase
  include InvocationResultTestHelper

  test "a refused one-shot reads running until recorded, then failed with the refusal's facts" do
    attempt = admitted_attempt
    inference_request = attempt.model_invocation.inference_request
    refused = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "id" => "msg_1", "content" => [], "stop_reason" => "refusal",
        "stop_details" => { "category" => "reasoning_extraction", "explanation" => "no" },
        "usage" => { "input_tokens" => 2, "output_tokens" => 0 },
      }))
    ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)

    apply_provider_result(attempt, refused, adapter_profile: "anthropic_messages")

    assert_equal "completed", attempt.model_invocation.reload.status
    assert_equal "running", inference_request.reload.status, "the converger has not decided yet"
    assert_not AgentAPI::InferenceRequestPresenter.full(inference_request).key?(:result), "no result before the decision"
    assert_equal :not_terminal, InferenceRequests::Tombstone.call(inference_request: inference_request).outcome

    InferenceRequests::ConvergeTerminalEvents.call(invocation_id: attempt.model_invocation_id)

    assert_equal "failed", inference_request.reload.status
    result = AgentAPI::InferenceRequestPresenter.full(inference_request).fetch(:result)
    assert_equal ["failed", "refused", "reasoning_extraction", { "code" => "model_refused" }],
      result.values_at(:status, :finish_quality, :refusal_category, :error)
    assert_not result.key?(:output_text)

    items = inference_request.inference_request_event_items.order(:sequence).to_a
    assert_equal({ "status" => "failed" }, items.find { |item| item.item_type == "run_status" }.payload)
    terminal = items.find { |item| item.item_type == "result" }.payload.fetch("result")
    assert_equal ["failed", "refused", "reasoning_extraction", { "code" => "model_refused" }],
      terminal.values_at("status", "finish_quality", "refusal_category", "error")

    assert_predicate InferenceRequests::Tombstone.call(inference_request: inference_request), :accepted?
  end

  test "a truncated one-shot still completes with its caveat" do
    attempt = admitted_attempt
    apply_via(attempt, sse_incomplete("as far as I got"))
    InferenceRequests::ConvergeTerminalEvents.call(invocation_id: attempt.model_invocation_id)

    result = AgentAPI::InferenceRequestPresenter.full(attempt.model_invocation.inference_request.reload).fetch(:result)
    assert_equal ["completed", "output_budget_exhausted", nil], result.values_at(:status, :finish_quality, :error)
    assert_not result.key?(:refusal_category)
  end
end
