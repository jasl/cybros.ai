require_relative "support/anthropic_protocol_helpers"

class TestAnthropicRefusal < Minitest::Test
  include AnthropicProtocolHelpers

  # F10c + F8 (unary): `input_transformations` and `stop_details` ride the
  # provider response the Result carries; finish_detail reads the typed
  # stop_details.type ahead of the bare stop_reason.
  def test_unary_refusal_carries_stop_details_and_input_transformations_in_the_provider_response
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            id: "msg_ref",
            content: [],
            stop_reason: "refusal",
            stop_details: { type: "refusal", category: "cyber", explanation: "classifier" },
            input_transformations: [{ path: "messages.3.content.0", reason: "prefix_binding_mismatch" }],
            usage: { input_tokens: 5, output_tokens: 0 }
          ),
        }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    result = protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096)

    assert_equal "refusal", result.finish_reason
    assert_equal "refusal", result.finish_detail
    body = result.provider_response.body
    assert_equal({ "type" => "refusal", "category" => "cyber", "explanation" => "classifier" }, body.fetch("stop_details"))
    assert_equal [{ "path" => "messages.3.content.0", "reason" => "prefix_binding_mismatch" }], body.fetch("input_transformations")
    assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "anthropic_messages", detail: result.finish_detail)
  end

  # THE REFUSAL IS A TYPED FACT: the category and the sentence ride
  # Result#refusal, each nullable — the vendor's null category is a normal,
  # permanent value, carried as nil and never replaced with a word of ours.
  def test_unary_refusal_with_null_details_is_a_typed_refusal
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            id: "msg_null", content: [], stop_reason: "refusal",
            stop_details: { category: nil, explanation: nil },
            usage: { input_tokens: 5, output_tokens: 0 }
          ),
        }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    result = protocol.create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)

    assert_equal SimpleInference::Responses::Refusal.new(category: nil, explanation: nil), result.refusal
    assert_equal "refusal", result.finish_detail
    assert_equal "", result.output_text
  end

  def test_unary_refusal_carries_its_category_and_explanation
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            id: "msg_cyber", content: [], stop_reason: "refusal",
            stop_details: { type: "refusal", category: "cyber", explanation: "The request asked for an exploit." },
            usage: { input_tokens: 5, output_tokens: 0 }
          ),
        }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    result = protocol.create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)

    assert_equal "cyber", result.refusal.category
    assert_equal "The request asked for an exploit.", result.refusal.explanation
  end

  # A classifier can stop a stream after text went out: the gem reports the
  # partial beside the refusal (discarding it is the consumer's act).
  def test_streamed_refusal_after_text_carries_the_category_beside_the_partial
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"message_start","message":{"id":"msg_p","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}\n\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Here is how"}}\n\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null}},"usage":{"output_tokens":4}}\n\n)
          sse << %(data: {"type":"message_stop"}\n\n)
          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    result = protocol.stream(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096).final_result

    assert_equal SimpleInference::Responses::Refusal.new(category: "cyber", explanation: nil), result.refusal
    assert_equal "refusal", result.finish_detail
    assert_equal "Here is how", result.output_text
  end

  def test_a_clean_finish_carries_no_refusal
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            id: "msg_ok", content: [{ type: "text", text: "hi" }], stop_reason: "end_turn",
            usage: { input_tokens: 5, output_tokens: 1 }
          ),
        }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    assert_nil protocol.create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096).refusal
  end
end
