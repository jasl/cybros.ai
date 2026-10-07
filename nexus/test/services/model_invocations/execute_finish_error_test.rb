require "test_helper"

class ModelInvocations::ExecuteFinishErrorTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "gemini", api_key: "test-only-key")
    ModelProviders::EnableLane.call(account: @account, provider_id: "gemini", expected_lock_version: nil)
  end

  test "the native Gemini stream withdraws emitted text and buffered tails before recording its billed error finish" do
    attempt = admitted_attempt(model: "gemini/gemini-3.8-flash")
    frames = [
      { "candidates" => [{ "content" => { "parts" => [{ "text" => "unfinished answer" }] } }] },
      { "candidates" => [{ "content" => { "parts" => [{ "text" => " tail" }] } }] },
      { "candidates" => [{ "finishReason" => "OTHER" }],
        "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 4, "totalTokenCount" => 7 } },
    ]
    sink = InferenceRequestEvents::StreamSink.new(attempt: attempt, flush_interval_ms: 100, clock: -> { 0.0 })
    fake_dispatch({ status: 200, headers: { "content-type" => "text/event-stream" },
                    sse: frames.map { |frame| "data: #{JSON.generate(frame)}\n\n" } }) do |adapter|
      ModelInvocations::ExecuteAttempt.call(attempt: attempt, host: "solid_queue", stream_sink: sink)
      assert_equal 1, adapter.requests.length
    end

    invocation = attempt.model_invocation.reload
    assert_equal ["completed", "error", "failed", "provider_error"],
      [invocation.status, invocation.finish_quality, invocation.work_status, invocation.failure_reason_key]
    assert_empty invocation.content_bodies.where(role: %w[response reasoning reasoning_trace tool_calls])
    items = invocation.inference_request.inference_request_event_items.order(:sequence)
    assert_equal %w[text_delta rollback], items.pluck(:item_type)
    assert_equal "unfinished answer", items.first.payload.fetch("text")
    assert_equal "failed", items.last.payload.fetch("reason")
    receipt = UsageRecord.find_by!(model_invocation_public_id: invocation.public_id)
    assert_equal ["succeeded", 3, 4, 7], receipt.values_at(:status, :input_tokens, :output_tokens, :total_tokens)
    assert_equal "USD", receipt.cost_unit
    assert_equal BigDecimal("0.00001725"), receipt.cost_amount,
      "discarding an errored generation does not discard its reported, priced usage"
  end
end
