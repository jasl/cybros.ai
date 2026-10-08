require "json"
require "test_helper"
require_relative "anthropic_protocol_helpers"

class TestAnthropicStreaming < Minitest::Test
  include AnthropicProtocolHelpers

  def test_stream_uses_native_messages_sse_and_yields_text_deltas
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(_env)
          raise "stream should use call_stream"
        end

        def call_stream(env)
          @last_request = env

          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-opus-4-1","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"calculator","input":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"expression\\":\\"2 + 2\\"}"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":1}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":3}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)

          yield sse

          {
            status: 200,
            headers: { "content-type" => "text/event-stream" },
            body: nil,
          }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "claude-opus-4-1", max_output_tokens: 4096, input: "Hello").to_a

    assert_equal true, JSON.parse(adapter.last_request.fetch(:body)).fetch("stream")
    text_deltas = events.grep(SimpleInference::Responses::Events::TextDelta).map(&:delta)
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }

    assert_equal ["Hel", "lo"], text_deltas
    refute_nil completed
    assert_equal "Hello", completed.result.output_text
    assert_equal "calculator", completed.result.tool_calls.fetch(0).fetch("name")
    assert_equal 3, completed.result.usage.fetch("output_tokens")
  end

  # A stream cut by max_tokens mid-call leaves input JSON that never
  # closes. The call must carry that text, not `{}`: the kernel's parse
  # guard refuses it as data the model reads, where `{}` would run the
  # tool with no arguments (D4, 2026-09-05).
  def test_stream_keeps_a_truncated_tool_input_as_the_call_arguments
    partial = %({"expression":"2 + )
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          raise "stream should use call_stream"
        end

        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-opus-4-1","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"calculator","input":{}}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"expression\\":\\"2 + "}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":3}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "claude-opus-4-1", max_output_tokens: 4096, input: "Hello").to_a

    done = events.find { |event| event.is_a?(SimpleInference::Responses::Events::ToolCallDone) }
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    call = completed.result.tool_calls.fetch(0)

    assert_equal partial, done.arguments
    assert_equal partial, call.fetch("arguments")
    assert_equal "max_tokens", completed.result.finish_reason
    assert_raises(JSON::ParserError) { JSON.parse(call.fetch("arguments")) }
  end

  # --- Stream terminal truth (deterministic constructions, not wire
  # captures): a mid-stream `event: error` voids the message_stop terminal
  # guarantee and must SURFACE; a stream that ends without message_stop is an
  # interruption, never a normal Result. ---

  def test_mid_stream_error_event_surfaces_as_typed_failure
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}\n\n)
          sse << %(event: error\n)
          sse << %(data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::Protocols::AnthropicMessages::StreamOverloadedError) do
        protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
      end

    assert_kind_of SimpleInference::ProviderStreamInterruptedError, error,
                   "the HTTP-200 event is the stream equivalent of retryable HTTP 529"
    assert_includes error.message, "overloaded_error"
    assert_includes error.message, "Overloaded"
    assert_includes error.message, "voided"
  end

  def test_non_overload_stream_error_remains_terminal
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield %(event: error\n)
        yield %(data: {"type":"error","error":{"type":"invalid_request_error","message":"Bad request"}}\n\n)

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter
    )

    error = assert_raises(SimpleInference::Error) do
      protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
    end

    refute_kind_of SimpleInference::ProviderStreamInterruptedError, error,
      "only overloaded_error is equivalent to retryable HTTP 529"
    assert_includes error.message, "invalid_request_error"
  end

  def test_stream_without_message_stop_raises_interruption_instead_of_result
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::Error) do
        protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
      end

    refute_instance_of SimpleInference::ValidationError, error
    assert_includes error.message, "message_stop"
  end

  # --- Usage truth (deterministic constructions): message_delta token fields
  # are documented cumulative (last value wins); the TTL cache breakdown rides
  # message_start/terminal ONLY and must survive message_delta merges; a field
  # absent on the wire stays absent — never fabricated as 0. ---

  def test_stream_usage_preserves_ttl_breakdown_from_message_start_across_message_delta
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":1,"cache_creation_input_tokens":2048,"cache_read_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":2048,"ephemeral_1h_input_tokens":0}}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"input_tokens":3,"output_tokens":10,"cache_creation_input_tokens":2048,"cache_read_input_tokens":100}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
    usage = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }.result.usage

    assert_equal 10, usage.fetch("output_tokens"), "cumulative: last message_delta value wins"
    assert_equal 3, usage.fetch("input_tokens")
    assert_equal 2048, usage.fetch("cache_creation_input_tokens")
    assert_equal 100, usage.fetch("cache_read_input_tokens")
    assert_equal(
      { "ephemeral_5m_input_tokens" => 2048, "ephemeral_1h_input_tokens" => 0 },
      usage.fetch("cache_creation"),
      "the TTL breakdown never rides message_delta and must survive the merge"
    )
  end

  def test_stream_usage_fields_absent_on_the_wire_stay_absent
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":4}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
    usage = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }.result.usage

    assert_equal({ "input_tokens" => 1, "output_tokens" => 4 }, usage, "absent wire fields must never be fabricated as 0")
  end

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

  # F10c + F8 (stream): message_start's input_transformations and the
  # message_delta's stop_details / input_transformations reach the
  # assembled message the streamed Result carries.
  def test_stream_merges_stop_details_and_input_transformations_into_the_assembled_message
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_s","role":"assistant","content":[],"input_transformations":[{"path":"messages.1.content.0","reason":"model_binding_mismatch"}],"usage":{"input_tokens":3,"output_tokens":0}}}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"bio"},"input_transformations":[{"path":"messages.5.content.0","reason":"prefix_binding_mismatch"}]},"usage":{"output_tokens":0}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)
          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    result = protocol.stream(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096).final_result

    assert_equal "refusal", result.finish_reason
    assert_equal "refusal", result.finish_detail
    body = result.provider_response.body
    assert_equal({ "type" => "refusal", "category" => "bio" }, body.fetch("stop_details"))
    assert_equal(
      [
        { "path" => "messages.1.content.0", "reason" => "model_binding_mismatch" },
        { "path" => "messages.5.content.0", "reason" => "prefix_binding_mismatch" },
      ],
      body.fetch("input_transformations")
    )
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
