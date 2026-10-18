require_relative "support/anthropic_protocol_helpers"

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

  def test_stream_rejects_unknown_symbol_options_eagerly
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: capturing_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        # No iteration on purpose: the typo must raise at the call site.
        protocol.stream(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", temperture: 0.5)
      end

    assert_includes error.message, "temperture"
  end

  def test_stream_extra_body_collision_with_forced_stream_flag_raises
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: capturing_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", extra_body: { "stream" => false }).to_a
      end

    assert_includes error.message, "stream"
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

  def test_stream_api_error_is_retryable_without_becoming_an_overload
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield %(event: error\n)
        yield %(data: {"type":"error","error":{"type":"api_error","message":"Internal server error"}}\n\n)

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter
    )

    error = assert_raises(SimpleInference::Protocols::AnthropicMessages::StreamServerError) do
      protocol.stream(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello").to_a
    end

    assert_predicate error, :transient?
    refute_predicate error, :overloaded?
    assert_includes error.message, "api_error"
  end

  def test_invalid_request_stream_error_remains_terminal
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
    refute_predicate error, :transient?
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
end
