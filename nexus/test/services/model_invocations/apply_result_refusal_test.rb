require "test_helper"
require "test_helpers/invocation_result_test_helper"
require "test_helpers/log_capture"

# A PROVIDER'S DECLINE, applied to the rows: the invocation completes with
# the typed quality (`refused | blocked`), the provider's category in its
# own column and its sentence as the detail, and NO answer body — the
# vendor's rule is that a declined answer's partial output is discarded.
# What the decline fails is the work the call was for, never the call.
class ModelInvocations::ApplyResultRefusalTest < ActiveJob::TestCase
  include InvocationResultTestHelper
  include LogCapture

  # A CLASSIFIER REFUSAL IS A TERMINAL COMPLETION WITH ITS CATEGORY: the
  # provider answers HTTP 200 with `stop_reason: "refusal"` and
  # `stop_details {type, category, explanation}`; the quality is `refused`,
  # the category has its own column and the explanation rides the detail
  # column alone, and the call is never a failure — the exchange happened
  # and was billed. What the refusal FAILS is the work the call was for.
  test "a classifier refusal completes REFUSED with its category and explanation apart" do
    attempt = admitted_attempt
    provider_result = anthropic_answer(
      "content" => [], "stop_reason" => "refusal",
      "stop_details" => { "type" => "refusal", "category" => "cyber",
                          "explanation" => "The request asked for an exploit." }
    )

    result = apply_provider_result(attempt, provider_result, adapter_profile: "anthropic_messages")

    assert_predicate result, :applied?
    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_equal SimpleInference::FinishQuality::REFUSED, invocation.finish_quality
    assert_equal "cyber", invocation.refusal_category
    assert_equal "The request asked for an exploit.", invocation.failure_detail,
      "the category has its column; the detail is the provider's sentence alone"
    assert_nil invocation.failure_reason_key, "a refusal is a quality, never a failure"
    assert_predicate invocation, :refused?
    assert_predicate invocation, :declined?
    assert_equal "succeeded", receipt_for(attempt).status, "the exchange happened and was billed"
  end

  # THE VENDOR'S RULE: partial output of a declined answer is incomplete and
  # discarded. A classifier that stops a stream after a thinking block, some
  # text and a complete tool call leaves none of them on the row — no answer
  # body, no calls a later turn would replay as unanswered, no reasoning.
  test "a refusal after streamed thinking, text and a tool call stores no body at all" do
    attempt = admitted_attempt
    events = [
      { "type" => "message_start", "message" => { "id" => "msg_p", "role" => "assistant", "content" => [],
                                                   "usage" => { "input_tokens" => 3, "output_tokens" => 0 } } },
      { "type" => "content_block_start", "index" => 0, "content_block" => { "type" => "thinking", "thinking" => "", "signature" => "" } },
      { "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "thinking_delta", "thinking" => "Weighing it." } },
      { "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "signature_delta", "signature" => "sig" } },
      { "type" => "content_block_stop", "index" => 0 },
      { "type" => "content_block_start", "index" => 1, "content_block" => { "type" => "text", "text" => "" } },
      { "type" => "content_block_delta", "index" => 1, "delta" => { "type" => "text_delta", "text" => "Here is how" } },
      { "type" => "content_block_stop", "index" => 1 },
      { "type" => "content_block_start", "index" => 2,
        "content_block" => { "type" => "tool_use", "id" => "toolu_1", "name" => "read_file", "input" => {} } },
      { "type" => "content_block_delta", "index" => 2, "delta" => { "type" => "input_json_delta", "partial_json" => "{\"path\":\"a\"}" } },
      { "type" => "content_block_stop", "index" => 2 },
      { "type" => "message_delta", "delta" => { "stop_reason" => "refusal",
                                                "stop_details" => { "type" => "refusal", "category" => "cyber", "explanation" => nil } },
        "usage" => { "output_tokens" => 9 } },
      { "type" => "message_stop" },
    ]
    stream = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(
        { sse: events.map { |event| "event: #{event.fetch("type")}\ndata: #{JSON.generate(event)}\n\n" },
          status: 200, headers: { "content-type" => "text/event-stream" } }
      )
    ).stream(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    stream.each { }
    assert_equal "Here is how", stream.final_result.output_text, "the gem reports the partial; discarding is ours"

    apply_provider_result(attempt, stream.final_result, adapter_profile: "anthropic_messages")

    invocation = attempt.model_invocation.reload
    assert_equal %w[completed refused cyber], invocation.values_at(:status, :finish_quality, :refusal_category)
    assert_nil invocation.failure_detail, "no explanation was sent, and none is invented"
    assert_empty invocation.content_bodies.where(role: %w[response tool_calls reasoning reasoning_trace]),
      "a declined answer leaves no body to clone, replay or present"
    assert_equal "succeeded", receipt_for(attempt).status
  end

  # A null category is a normal, permanent value of the vendor's: carried as
  # absence, never replaced with a word of ours.
  test "a refusal naming no category records none" do
    attempt = admitted_attempt

    apply_provider_result(attempt, anthropic_answer(
      "content" => [], "stop_reason" => "refusal", "stop_details" => { "category" => nil, "explanation" => nil }
    ), adapter_profile: "anthropic_messages")

    invocation = attempt.model_invocation.reload
    assert_equal SimpleInference::FinishQuality::REFUSED, invocation.finish_quality
    assert_nil invocation.refusal_category
    assert_nil invocation.failure_detail
  end

  # The Responses family's refusal is a message PART: the category is absent
  # because the wire names none, and the part's text is the explanation —
  # never the answer, even when text streamed ahead of it.
  test "a Responses refusal part is a REFUSED finish with its text as the detail" do
    attempt = admitted_attempt

    apply_via(attempt, sse_refused("I can't help with that.", text: "Sure, here"))

    invocation = attempt.model_invocation.reload
    assert_equal %w[completed refused], invocation.values_at(:status, :finish_quality)
    assert_nil invocation.refusal_category
    assert_equal "I can't help with that.", invocation.failure_detail
    assert_empty invocation.content_bodies.where(role: %w[response tool_calls reasoning reasoning_trace])
  end

  test "a chat content filter is a REFUSED finish" do
    attempt = admitted_attempt
    adapter = InvocationHarness::FakeAdapter.new(json_response(200, {
      "id" => "chat_f", "object" => "chat.completion",
      "choices" => [{ "index" => 0, "finish_reason" => "content_filter",
                      "message" => { "role" => "assistant", "content" => "" } }],
      "usage" => { "prompt_tokens" => 4, "completion_tokens" => 0, "total_tokens" => 4 },
    }))
    provider_result = SimpleInference::Protocols::OpenAICompatibleResponses.new(
      base_url: "http://example.com", api_key: "k", adapter: adapter
    ).create(model: "m", input: "hi")

    apply_provider_result(attempt, provider_result, adapter_profile: "openai_compatible_chat")

    invocation = attempt.model_invocation.reload
    assert_equal %w[completed refused], invocation.values_at(:status, :finish_quality)
    assert_nil invocation.refusal_category
  end

  # Google's finish word IS a category: a SAFETY stop refuses (another model
  # may answer), a SPII stop BLOCKS (the content itself is never re-sent).
  test "a Gemini candidate stop refuses or blocks by its word, and the word is the category" do
    { "SAFETY" => SimpleInference::FinishQuality::REFUSED,
      "SPII" => SimpleInference::FinishQuality::BLOCKED }.each do |reason, quality|
      attempt = admitted_attempt
      provider_result = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "candidates" => [{ "content" => { "parts" => [{ "text" => "partial" }] }, "finishReason" => reason }],
          "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 1, "totalTokenCount" => 4 },
        }))
      ).create(model: "gemini-3.7-flash", input: "Hello")

      apply_provider_result(attempt, provider_result, adapter_profile: "gemini_generate_content")

      invocation = attempt.model_invocation.reload
      assert_equal ["completed", quality, reason], invocation.values_at(:status, :finish_quality, :refusal_category)
      assert_predicate invocation, :declined?
      assert_equal quality == SimpleInference::FinishQuality::BLOCKED, invocation.blocked?
      assert_empty invocation.content_bodies.where(role: "response"), reason
    end
  end

  # A refusal is an HTTP 200 that error-rate monitoring never sees, so the
  # kernel names it — once, after the answer committed, and never for an
  # apply a cut discarded.
  test "an applied refusal logs one line after commit and a discarded one logs none" do
    attempt = admitted_attempt
    refusal = anthropic_answer(
      "content" => [], "stop_reason" => "refusal", "stop_details" => { "category" => "cyber", "explanation" => "no" }
    )

    lines = capture_log { apply_provider_result(attempt, refusal, adapter_profile: "anthropic_messages") }

    invocation = attempt.model_invocation
    assert_equal ["event=model_refused invocation=#{invocation.public_id} model=dev/mock-text quality=refused category=cyber"],
      lines.grep(/event=model_refused/).map(&:strip)

    uncategorized = admitted_attempt
    lines = capture_log { apply_via(uncategorized, sse_refused("I can't help with that.")) }
    assert_equal ["event=model_refused invocation=#{uncategorized.model_invocation.public_id} model=dev/mock-text quality=refused"],
      lines.grep(/event=model_refused/).map(&:strip), "a null category drops the field"

    late = admitted_attempt
    started = start(late)
    sent = nil
    fake_dispatch(sse_refused("I can't help with that.")) do
      sent = ModelInvocations::Dispatch.call(attempt: late, context: started.context, request: build(late).request)
    end
    ModelInvocation::Cancellation.call(scope: ModelInvocation.where(id: late.model_invocation_id), reason: "workspace_archived")
    lines = capture_log { ModelInvocations::ApplyResult.call(attempt: late, outcome: sent) }
    assert_empty lines.grep(/event=model_refused/), "a discarded refusal is not the one that stands"
  end

  # A BLOCKED PROMPT IS A FINISH, NOT A TRANSPORT FAILURE: Google answers
  # HTTP 200 with no candidate, and the gem types it as a declined finish
  # carrying the billed prompt work — terminal on the first attempt, since
  # replaying the same blocked prompt cannot change the provider decision.
  test "a Gemini prompt block is a terminal refused finish that keeps its billed usage" do
    attempt = admitted_attempt
    provider_result = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com",
      api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "promptFeedback" => { "blockReason" => "SAFETY" },
        "usageMetadata" => { "promptTokenCount" => 7, "totalTokenCount" => 7 },
      }))
    ).create(model: "gemini-3.7-flash", input: "Hello")

    result = apply_provider_result(attempt, provider_result, adapter_profile: "gemini_generate_content")

    assert_predicate result, :applied?
    assert_not_predicate result, :requeued?
    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    assert_equal SimpleInference::FinishQuality::REFUSED, invocation.finish_quality
    assert_equal "SAFETY", invocation.refusal_category, "the block reason is Google's category"
    assert_equal 1, invocation.attempts.count
    receipt = receipt_for(attempt)
    assert_equal 7, receipt.input_tokens
    assert_equal 7, receipt.total_tokens
  end

  # The provider's word is one `key=value` token on both lines a refusal
  # writes — the apply's `model_refused` and the switch's `model_fallback`
  # — so a parser pairs them by the same spelling.
  test "a category with whitespace is one token on both refusal lines" do
    attempt = admitted_attempt
    refusal = anthropic_answer(
      "content" => [], "stop_reason" => "refusal", "stop_details" => { "category" => " general harms " }
    )
    candidate = AgentLoops::ModelFallback::Candidate.new(provider_id: "dev", model_ref: "mock-unmetered",
      reasoning_effort: nil, reason: "model_refused", category: " general harms ")

    lines = capture_log do
      apply_provider_result(attempt, refusal, adapter_profile: "anthropic_messages")
      ApplicationRecord.transaction { AgentLoops::ModelFallback.log_switch("probe=1", "dev/mock-text", candidate) }
    end

    assert_match(/ category=general_harms\z/, lines.grep(/event=model_refused/).sole.strip)
    assert_match(/ category=general_harms\z/, lines.grep(/event=model_fallback/).sole.strip)
  end
end
