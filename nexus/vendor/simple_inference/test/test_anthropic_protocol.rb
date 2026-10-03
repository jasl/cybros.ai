require "json"
require "test_helper"

class TestAnthropicProtocol < Minitest::Test
  PNG_BYTES = ("\x89PNG\r\n\x1a\n".b + "deterministic-test-pixels".b).freeze

  def test_create_maps_messages_payload_into_responses_result
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              id: "msg_123",
              content: [
                {
                  type: "text",
                  text: "Claude hello",
                },
                {
                  type: "tool_use",
                  id: "toolu_123",
                  name: "calculator",
                  input: {
                    expression: "2 + 2",
                  },
                },
              ],
              stop_reason: "end_turn",
              usage: {
                input_tokens: 2,
                output_tokens: 3,
              },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    result = protocol.create(
      model: "claude-opus-4-1", max_output_tokens: 4096,
      input: [
        { role: "system", content: "Be terse" },
        { role: "user", content: "Hello" },
        {
          type: "function_call",
          call_id: "toolu_123",
          name: "calculator",
          arguments: "{\"expression\":\"2 + 2\"}",
        },
        {
          type: "function_call_output",
          call_id: "toolu_123",
          output: "{\"value\":4}",
        },
      ],
      tools: [
        {
          type: "function",
          name: "calculator",
          parameters: {
            type: "object",
            properties: {
              expression: { type: "string" },
            },
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))

    assert_instance_of SimpleInference::Responses::Result, result
    assert_equal "Claude hello", result.output_text
    assert_equal "responses", result.provider_format
    assert_equal "function_call", result.output_items.fetch(1).fetch("type")
    assert_equal "calculator", result.output_items.fetch(1).fetch("name")
    assert_equal "calculator", result.tool_calls.fetch(0).fetch("name")
    assert_equal "Be terse", request_body.fetch("system")
    assert_equal "Hello", request_body.fetch("messages").fetch(0).fetch("content").fetch(0).fetch("text")
    assert_equal "tool_use", request_body.fetch("messages").fetch(1).fetch("content").fetch(0).fetch("type")
    assert_equal "tool_result", request_body.fetch("messages").fetch(2).fetch("content").fetch(0).fetch("type")
    assert_equal "calculator", request_body.fetch("tools").fetch(0).fetch("name")
  end

  def test_create_maps_thinking_content_part_into_native_anthropic_block
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Continue." },
        {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "Replayed reasoning.", signature: "sig_abc" },
            { type: "input_text", text: "Prior answer." },
          ],
        },
        { role: "user", content: "Next." },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assistant = request_body.fetch("messages").fetch(1)
    assert_equal "assistant", assistant.fetch("role")
    thinking_block = assistant.fetch("content").fetch(0)
    assert_equal "thinking", thinking_block.fetch("type")
    assert_equal "Replayed reasoning.", thinking_block.fetch("thinking")
    assert_equal "sig_abc", thinking_block.fetch("signature")
    assert_equal "text", assistant.fetch("content").fetch(1).fetch("type")
  end

  def test_create_drops_thinking_content_part_without_signature
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Continue." },
        {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "Unsigned reasoning.", signature: "" },
            { type: "input_text", text: "Prior answer." },
          ],
        },
        { role: "user", content: "Next." },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    content_types = request_body.fetch("messages").fetch(1).fetch("content").map { |block| block.fetch("type") }
    refute_includes content_types, "thinking"
    assert_equal %w[text], content_types
  end

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

  def test_stream_yields_thinking_as_reasoning_deltas
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(event: message_start\n)
          sse << %(data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-opus-4-1","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2,"output_tokens":0}}}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need "}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"tool."}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_123"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":0}\n\n)
          sse << %(event: content_block_start\n)
          sse << %(data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n)
          sse << %(event: content_block_delta\n)
          sse << %(data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Done"}}\n\n)
          sse << %(event: content_block_stop\n)
          sse << %(data: {"type":"content_block_stop","index":1}\n\n)
          sse << %(event: message_delta\n)
          sse << %(data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}\n\n)
          sse << %(event: message_stop\n)
          sse << %(data: {"type":"message_stop"}\n\n)

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    events = protocol.stream(model: "claude-opus-4-1", max_output_tokens: 4096, input: "Hello").to_a
    reasoning_deltas = events.grep(SimpleInference::Responses::Events::ReasoningDelta).map(&:delta)
    completed = events.find { |event| event.is_a?(SimpleInference::Responses::Events::Completed) }
    reasoning_item = completed.result.output_items.find { |item| item["type"] == "reasoning" }

    assert_equal ["Need ", "tool."], reasoning_deltas
    assert_equal "Done", completed.result.output_text
    assert_equal "Need tool.", reasoning_item.fetch("text")
    assert_equal "sig_123", reasoning_item.fetch("signature")
  end

  # --- Reasoning lowering. Model-name dispatch is DEAD: the same request
  # options lower to the same wire bytes on every model id. Legality lives
  # with the caller/profile and the server, never in a claude-* regex. ---

  def test_reasoning_effort_lowers_identically_across_model_ids
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    # An Opus 5.x id (claude-opus-5-5) matches NONE of the excised model
    # regexes, so it would fall into the manual-budget branch the register
    # records as a 4.7+ server 400.
    bodies =
      %w[claude-opus-4-1 claude-sonnet-4-6 claude-opus-5-5 claude-mythos-preview].map do |model|
        protocol.create(model: model, input: "Hello", max_output_tokens: 4096, reasoning_effort: "medium")
        JSON.parse(adapter.last_request.fetch(:body)).tap { |body| body.delete("model") }
      end

    bodies.each do |body|
      assert_equal({ "type" => "adaptive", "display" => "summarized" }, body.fetch("thinking"))
      assert_equal({ "effort" => "medium" }, body.fetch("output_config"))
      assert_equal 4096, body.fetch("max_tokens"), "the caller's number on every model — the protocol invents none"
    end
    assert_equal 1, bodies.uniq.length, "model id must not select a lowering branch"
  end

  def test_reasoning_effort_result_still_surfaces_thinking_items
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              id: "msg_123",
              content: [
                { type: "thinking", thinking: "Need a short answer.", signature: "sig_123" },
                { type: "text", text: "ok" },
              ],
              stop_reason: "end_turn",
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    result = protocol.create(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello", reasoning_effort: "high")
    request_body = JSON.parse(adapter.last_request.fetch(:body))
    reasoning_item = result.output_items.find { |item| item["type"] == "reasoning" }

    assert_equal({ "type" => "adaptive", "display" => "summarized" }, request_body.fetch("thinking"))
    assert_equal({ "effort" => "high" }, request_body.fetch("output_config"))
    assert_equal "Need a short answer.", reasoning_item.fetch("text")
    assert_equal "sig_123", reasoning_item.fetch("signature")
    assert_equal "ok", result.output_text
  end

  def test_xhigh_reasoning_effort_is_lowered_natively_never_clamped
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    # claude-sonnet-4-6 used to be clamped xhigh->max by a model regex.
    protocol.create(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", reasoning_effort: "xhigh")
    request_body = JSON.parse(adapter.last_request.fetch(:body))

    assert_equal({ "type" => "adaptive", "display" => "summarized" }, request_body.fetch("thinking"))
    assert_equal({ "effort" => "xhigh" }, request_body.fetch("output_config"))
  end

  # "none" is an explicit disable request; omitting the param would silently
  # run adaptive thinking on default-adaptive models. The explicit wire
  # disable is the faithful lowering for EVERY model id.
  def test_none_reasoning_effort_lowers_to_explicit_disabled_thinking_for_every_model
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    %w[claude-fable-5 claude-sonnet-5 claude-opus-4-1].each do |model|
      protocol.create(model: model, input: "Hello", max_output_tokens: 4096, reasoning_effort: "none")
      request_body = JSON.parse(adapter.last_request.fetch(:body))

      assert_equal({ "type" => "disabled" }, request_body.fetch("thinking"), model)
      refute request_body.key?("output_config"), model
    end
  end

  # Deterministic construction: out-of-vocabulary efforts are locally rejected
  # with zero outbound IO (the old code clamped unknown->medium, minimal->low).
  def test_out_of_vocabulary_reasoning_effort_raises_without_io
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    %w[minimal bogus].each do |effort|
      error =
        assert_raises(SimpleInference::ValidationError) do
          protocol.create(model: "claude-opus-5-5", max_output_tokens: 4096, input: "Hello", reasoning_effort: effort)
        end

      assert_includes error.message, effort.inspect
      assert_includes error.message, "never clamps"
    end
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_explicit_manual_thinking_lowers_verbatim_without_max_tokens_bump
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-1",
      input: "Hello",
      max_output_tokens: 4096,
      thinking: { type: "enabled", budget_tokens: 2048 }
    )
    request_body = JSON.parse(adapter.last_request.fetch(:body))

    assert_equal({ "type" => "enabled", "budget_tokens" => 2048 }, request_body.fetch("thinking"))
    assert_equal 4096, request_body.fetch("max_tokens")
  end

  # Deterministic construction: the old code silently RAISED max_tokens to
  # budget+1024; the faithful protocol rejects the contradiction instead.
  def test_manual_thinking_budget_at_or_above_max_tokens_raises_instead_of_silent_bump
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-1",
          input: "Hello",
          max_output_tokens: 2048,
          thinking: { type: "enabled", budget_tokens: 2048 }
        )
      end

    assert_includes error.message, "max_tokens"
    assert_includes error.message, "budget_tokens"
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  # Deterministic construction: register minimum for manual budgets is 1,024.
  def test_manual_thinking_budget_below_minimum_raises
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-1",
          input: "Hello",
          max_output_tokens: 4096,
          thinking: { type: "enabled", budget_tokens: 512 }
        )
      end

    assert_includes error.message, "1024"
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  # Deterministic construction: effort rides output_config.effort in adaptive
  # mode only; pairing it with a manual/disabled thinking hash is a
  # contradiction the protocol surfaces instead of silently dropping effort.
  def test_reasoning_effort_conflicts_with_non_adaptive_explicit_thinking
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-1",
          input: "Hello",
          max_output_tokens: 4096,
          reasoning_effort: "high",
          thinking: { type: "enabled", budget_tokens: 2048 }
        )
      end

    assert_includes error.message, "adaptive"
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_reasoning_effort_composes_with_explicit_adaptive_thinking
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: "Hello",
      reasoning_effort: "high",
      thinking: { type: "adaptive", display: "summarized" }
    )
    request_body = JSON.parse(adapter.last_request.fetch(:body))

    # The caller's explicit display choice reaches the wire verbatim; the
    # protocol itself never injects one (the default is a register fixture
    # pin, not an implementation guess).
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, request_body.fetch("thinking"))
    assert_equal({ "effort" => "high" }, request_body.fetch("output_config"))
  end

  def test_create_maps_tool_choice_parallel_control_and_default_input_schema
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              id: "msg_123",
              content: [
                { type: "text", text: "ok" },
              ],
              stop_reason: "end_turn",
              usage: {
                input_tokens: 1,
                output_tokens: 1,
              },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "claude-opus-4-1", max_output_tokens: 4096,
      input: "Hello",
      tool_choice: { type: "function", function: { name: "calculator" } },
      parallel_tool_calls: false,
      tools: [
        {
          type: "function",
          function: {
            name: "calculator",
            description: "Solve arithmetic",
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    tool = request_body.fetch("tools").fetch(0)
    tool_choice = request_body.fetch("tool_choice")

    assert_equal "calculator", tool.fetch("name")
    assert_equal "object", tool.fetch("input_schema").fetch("type")
    assert_equal({}, tool.fetch("input_schema").fetch("properties"))
    assert_equal [], tool.fetch("input_schema").fetch("required")
    assert_equal false, tool.fetch("input_schema").fetch("additionalProperties")
    # strict is a top-level tool field in the Anthropic API, never a JSON
    # Schema keyword, and is only emitted when the caller asks for it.
    refute tool.fetch("input_schema").key?("strict")
    refute tool.key?("strict")
    assert_equal "tool", tool_choice.fetch("type")
    assert_equal "calculator", tool_choice.fetch("name")
    assert_equal true, tool_choice.fetch("disable_parallel_tool_use")
  end

  def test_create_emits_caller_strict_flag_as_top_level_tool_field
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: "Hello",
      tools: [
        {
          type: "function",
          name: "flat_tool",
          strict: true,
          parameters: { type: "object", properties: {} },
        },
        {
          type: "function",
          function: {
            name: "nested_tool",
            strict: false,
            parameters: { type: "object", properties: {} },
          },
        },
      ]
    )

    tools = JSON.parse(adapter.last_request.fetch(:body)).fetch("tools")
    assert_equal true, tools.fetch(0).fetch("strict")
    assert_equal false, tools.fetch(1).fetch("strict")
    refute tools.fetch(0).fetch("input_schema").key?("strict")
    refute tools.fetch(1).fetch("input_schema").key?("strict")
  end

  def test_create_does_not_treat_symbol_tool_enums_as_protocol_values
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env

        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              id: "msg_123",
              content: [
                { type: "text", text: "ok" },
              ],
              stop_reason: "end_turn",
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)
    protocol.create(
      model: "claude-opus-4-1", max_output_tokens: 4096,
      input: "Hello",
      tool_choice: { type: :function, function: { name: "calculator" } },
      tools: [
        {
          type: :function,
          function: {
            name: "calculator",
          },
        },
      ]
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    refute request_body.key?("tools")
    refute request_body.key?("tool_choice")

    protocol.create(
      model: "claude-opus-4-1", max_output_tokens: 4096,
      input: "Hello",
      tool_choice: :auto,
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    refute request_body.key?("tool_choice")
  end

  # --- The declared-vocabulary + extra_body contract (see
  # test_openai_embeddings_protocol.rb for the template) ---

  def test_declared_sampling_options_reach_the_wire
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(model: "claude-sonnet-4-6", input: "Hello", max_output_tokens: 2000, temperature: 0.5, top_p: 0.9, top_k: 5)

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal 2000, request_body.fetch("max_tokens")
    assert_equal 0.5, request_body.fetch("temperature")
    assert_equal 0.9, request_body.fetch("top_p")
    assert_equal 5, request_body.fetch("top_k")
  end

  def test_unknown_symbol_options_raise_and_point_at_extra_body
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: capturing_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", temperture: 0.5)
      end

    assert_includes error.message, "temperture"
    assert_includes error.message, "extra_body"
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

  def test_extra_body_merges_string_keyed_fields_verbatim
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: "Hello",
      extra_body: { "metadata" => { "user_id" => "u1" }, "stop_sequences" => ["END"] }
    )

    request_body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "user_id" => "u1" }, request_body.fetch("metadata"))
    assert_equal ["END"], request_body.fetch("stop_sequences")
  end

  def test_extra_body_collisions_with_built_wire_fields_raise
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: capturing_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", extra_body: { "max_tokens" => 16 })
      end

    assert_includes error.message, "max_tokens"
  end

  def test_stream_extra_body_collision_with_forced_stream_flag_raises
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: capturing_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", extra_body: { "stream" => false }).to_a
      end

    assert_includes error.message, "stream"
  end

  def test_request_option_keys_are_introspectable
    keys = SimpleInference::Protocols::AnthropicMessages.request_option_keys

    assert_includes keys, :reasoning_effort
    assert_includes keys, :max_output_tokens
    assert keys.frozen?
  end

  # :n and :response_format stay DECLARED (the kernel's catalog can emit
  # result_count ("n") and response_format for Anthropic-routed generations)
  # but the former silent drops are now loud inventoried local rejections.
  # Deterministic constructions: zero outbound IO on rejection.
  def test_n_is_loudly_rejected_never_silently_dropped
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", n: 2)
      end

    assert_equal(
      "anthropic_messages locally rejects n (result_count): /v1/messages has no multi-candidate " \
      "concept and rejects unknown top-level fields with a 400; remove the option instead of " \
      "expecting a silent drop",
      error.message
    )
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_json_object_response_format_is_loudly_rejected_never_silently_dropped
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "claude-sonnet-4-6", max_output_tokens: 4096, input: "Hello", response_format: { type: "json_object" })
      end

    assert_equal(
      "anthropic_messages locally rejects response_format type \"json_object\": " \
      "output_config.format accepts only json_schema (no Anthropic equivalent exists)",
      error.message
    )
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_json_schema_response_format_maps_to_output_config_format
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    schema = { "type" => "object", "properties" => { "answer" => { "type" => "string" } } }
    protocol.create(
      model: "claude-sonnet-4-6", max_output_tokens: 4096,
      input: "Hello",
      response_format: { "type" => "json_schema", "schema" => schema }
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("response_format")
    assert_equal({ "format" => { "type" => "json_schema", "schema" => schema } }, body.fetch("output_config"))
  end

  def test_json_schema_response_format_accepts_openai_nested_envelope_and_merges_with_effort
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    schema = { "type" => "object", "properties" => {} }
    protocol.create(
      model: "claude-fable-5", max_output_tokens: 4096,
      input: "Hello",
      reasoning_effort: "high",
      response_format: { type: "json_schema", json_schema: { name: "answer", schema: schema } }
    )

    output_config = JSON.parse(adapter.last_request.fetch(:body)).fetch("output_config")
    assert_equal "high", output_config.fetch("effort")
    assert_equal({ "type" => "json_schema", "schema" => schema }, output_config.fetch("format"))
  end

  def test_redacted_thinking_blocks_round_trip
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        attr_reader :last_request

        def call(env)
          @last_request = env
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              id: "msg_123",
              content: [
                { type: "redacted_thinking", data: "opaque-blob" },
                { type: "text", text: "ok" },
              ],
              stop_reason: "end_turn"
            ),
          }
        end
      end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    result = protocol.create(model: "claude-fable-5", max_output_tokens: 4096, input: "Hello")
    item = result.output_items.find { |candidate| candidate["type"] == "redacted_thinking" }

    refute_nil item
    assert_equal "opaque-blob", item.fetch("data")
    assert_equal({ "type" => "redacted_thinking", "data" => "opaque-blob" }, item.fetch("provider_payload"))
    assert_equal "ok", result.output_text

    # Replay direction: the block must reach the wire verbatim, not raise.
    protocol.create(
      model: "claude-fable-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Continue." },
        {
          role: "assistant",
          content: [
            { type: "redacted_thinking", data: "opaque-blob" },
            { type: "input_text", text: "Prior answer." },
          ],
        },
        { role: "user", content: "Next." },
      ]
    )

    assistant = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").fetch(1)
    assert_equal "assistant", assistant.fetch("role")
    assert_equal({ "type" => "redacted_thinking", "data" => "opaque-blob" }, assistant.fetch("content").fetch(0))
    assert_equal "text", assistant.fetch("content").fetch(1).fetch("type")
  end

  # The Responses family's `developer` role has no twin on this wire: it
  # lowers to `user` and stays WHERE THE CALLER PLACED IT in the list —
  # hoisting it into the system field would move it ahead of everything
  # behind it (Nexus S-F r2 (5)). An unknown role is still the loud refusal.
  def test_create_lowers_developer_to_user_and_still_refuses_unknown_roles
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter
    )

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "system", content: "slots" }, { role: "user", content: "memory" },
        { role: "developer", content: "env" }, { role: "user", content: "Hi" },
      ]
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    message = body.fetch("messages").fetch(0)
    assert_equal 1, body.fetch("messages").length, "adjacent user turns merge, as this wire always did"
    assert_equal "user", message.fetch("role")
    assert_equal ["memory", "env", "Hi"], message.fetch("content").map { |block| block.fetch("text") },
      "the developer text stays between memory and the prompt — lowered in place"
    assert_equal "slots", body.fetch("system"), "system alone is lifted"
    # The kernel's admission reads ACCEPTED_ROLES, so the constant must name
    # what normalize_role admits: without `developer` here every rho
    # conversation on the direct Anthropic lane was parked
    # unsupported_input_role at turn 1 (the paid live_cache_tier lane,
    # 2026-09-18) before the wire that would have carried it.
    assert_includes SimpleInference::Protocols::AnthropicMessages::ACCEPTED_ROLES, "developer"

    refusing = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "secret", adapter: refusing
    )
    error = assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "claude-opus-5-5", max_output_tokens: 4096, input: [{ role: "banana", content: "x" }])
    end
    assert_includes error.message, "banana"
    assert_nil refusing.last_request, "an unknown role must never silently reach the wire"
  end

  def test_create_lowers_structured_instructions_into_a_cache_controlled_system_array
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [{ role: "user", content: "Hello" }],
      instructions: [
        { type: "text", text: "You are a coding agent.", cache_control: { type: "ephemeral" } },
      ]
    )

    system = JSON.parse(adapter.last_request.fetch(:body)).fetch("system")
    assert_instance_of Array, system
    assert_equal "text", system.fetch(0).fetch("type")
    assert_equal "You are a coding agent.", system.fetch(0).fetch("text")
    assert_equal({ "type" => "ephemeral" }, system.fetch(0).fetch("cache_control"))
  end

  def test_create_preserves_cache_control_on_structured_system_message_content
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        {
          role: "system",
          content: [
            { type: "text", text: "System preamble.", cache_control: { type: "ephemeral" } },
          ],
        },
        { role: "user", content: "Hello" },
      ]
    )

    system = JSON.parse(adapter.last_request.fetch(:body)).fetch("system")
    assert_instance_of Array, system
    assert_equal "System preamble.", system.fetch(0).fetch("text")
    assert_equal({ "type" => "ephemeral" }, system.fetch(0).fetch("cache_control"))
  end

  def test_create_keeps_string_system_when_instructions_carry_no_cache_control
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [{ role: "user", content: "Hello" }],
      instructions: "Be terse."
    )

    assert_equal "Be terse.", JSON.parse(adapter.last_request.fetch(:body)).fetch("system")
  end

  def test_create_preserves_cache_control_on_a_message_text_block
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        {
          role: "user",
          content: [
            { type: "text", text: "cached turn", cache_control: { type: "ephemeral" } },
          ],
        },
      ]
    )

    block = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").fetch(0).fetch("content").fetch(0)
    assert_equal "text", block.fetch("type")
    assert_equal "cached turn", block.fetch("text")
    assert_equal({ "type" => "ephemeral" }, block.fetch("cache_control"))
  end

  def test_create_preserves_cache_control_on_a_tool_result_tail_block
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        { role: "user", content: "run it" },
        { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
        { type: "function_call_output", call_id: "toolu_1", output: "done", cache_control: { type: "ephemeral" } },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    tool_result = messages.last.fetch("content").fetch(0)
    assert_equal "tool_result", tool_result.fetch("type")
    assert_equal "done", tool_result.fetch("content")
    assert_equal({ "type" => "ephemeral" }, tool_result.fetch("cache_control"))
  end

  # --- Media ingress: bytes only (MediaInput), carriers rejected ---
  # Transport policy (register Input-media profiles v1): provider requests
  # embed prepared bytes inline as base64; caller data URIs, URLs, host
  # paths, and provider file handles are loud rejections at the lane's
  # lowering — even though the Anthropic wire accepts a url source.

  def test_media_input_bytes_lower_to_the_base64_source_block
    media = SimpleInference::MediaInput.from_bytes(PNG_BYTES)
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-4-8", max_output_tokens: 4096,
      input: [
        {
          role: "user",
          content: [
            { type: "text", text: "look" },
            { type: "input_image", image_url: media },
          ],
        },
      ]
    )

    block = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").fetch(0).fetch("content").fetch(1)
    assert_equal "image", block.fetch("type")
    assert_equal(
      { "type" => "base64", "media_type" => "image/png", "data" => [PNG_BYTES].pack("m0") },
      block.fetch("source")
    )
  end

  def test_caller_data_uri_image_is_a_loud_rejection_with_zero_io
    protocol = exploding_protocol

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-4-8", max_output_tokens: 4096,
          input: [{ role: "user", content: [{ type: "input_image", image_url: "data:image/png;base64,AAAA" }] }]
        )
      end

    assert_includes error.message, "MediaInput"
  end

  def test_caller_remote_url_image_is_a_loud_rejection_with_zero_io
    protocol = exploding_protocol

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "claude-opus-4-8", max_output_tokens: 4096,
        input: [{ role: "user", content: [{ type: "image", image_url: { url: "https://example.com/cat.png" } }] }]
      )
    end
  end

  def test_caller_native_url_source_block_is_a_loud_rejection_with_zero_io
    protocol = exploding_protocol

    assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "claude-opus-4-8", max_output_tokens: 4096,
        input: [{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://example.com/cat.png" } }] }]
      )
    end
  end

  # --- Role/final-turn disposition (the vendor's Opus 5.5 migration guide:
  # claude-opus-5-5 rejects a last nonempty assistant prefill; prior
  # assistant history remains eligible).
  # Deterministic constructions: zero outbound IO on rejection. ---

  def test_assistant_last_input_is_rejected_preflight
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-5-5", max_output_tokens: 4096,
          input: [
            { role: "user", content: "Hello" },
            { role: "assistant", content: "A prefill." },
          ]
        )
      end

    assert_equal(
      "anthropic_messages rejects assistant-last input: the final nonempty turn must not be an " \
      "assistant prefill (prior assistant turns remain eligible)",
      error.message
    )
    assert_nil adapter.last_request, "rejection must produce zero outbound IO"
  end

  def test_unanswered_function_call_tail_is_rejected_as_assistant_last
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "claude-opus-5-5", max_output_tokens: 4096,
          input: [
            { role: "user", content: "run it" },
            { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
          ]
        )
      end

    assert_includes error.message, "assistant-last"
    assert_nil adapter.last_request
  end

  def test_prior_assistant_history_with_user_last_turn_is_accepted
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Prior answer." },
        { role: "user", content: "Next." },
      ]
    )

    roles = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").map { |message| message.fetch("role") }
    assert_equal %w[user assistant user], roles
  end

  # The continuation replays the refused call beside its error result; the
  # wire needs an object there, so the partial lowers to `{}` on the way
  # BACK — the refusal itself rides in the paired tool_result.
  def test_create_replays_a_truncated_call_as_an_empty_tool_use_input
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "Compute." },
        { "type" => "function_call", "call_id" => "toolu_123", "name" => "calculator", "arguments" => %({"expression":"2 + ) },
        { "type" => "function_call_output", "call_id" => "toolu_123", "output" => "<tool_use_error>invalid_tool_arguments</tool_use_error>" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    tool_use = messages.fetch(1).fetch("content").fetch(0)
    assert_equal({ "type" => "tool_use", "id" => "toolu_123", "name" => "calculator", "input" => {} }, tool_use)
    assert_equal "toolu_123", messages.fetch(2).fetch("content").fetch(0).fetch("tool_use_id")
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

  # --- The 2026-09-16 alignment (docs/plans/2026-09-16-model-integration-alignment.md §2.1) ---

  # F1: `max_tokens` is a REQUIRED Messages field. The old `|| 1024` put a
  # 1,024-token ceiling on every turn whose caller stated nothing; a missing
  # value is now a loud refusal, never an invented number.
  def test_missing_max_output_tokens_is_a_loud_refusal_never_an_invented_ceiling
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    error = assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "claude-fable-5-1", input: "Hello")
    end
    assert_includes error.message, "max_output_tokens is required"
    assert_nil adapter.last_request, "refusal must produce zero outbound IO"

    error = assert_raises(SimpleInference::ValidationError) do
      protocol.stream(model: "claude-fable-5-1", input: "Hello")
    end
    assert_includes error.message, "max_output_tokens is required"

    error = assert_raises(SimpleInference::ValidationError) do
      protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 0)
    end
    assert_includes error.message, "max_output_tokens"
    assert_nil adapter.last_request
  end

  # F10a: `betas` is a registry-declared construction fact rendered as the
  # comma-joined `anthropic-beta` header; no betas, no header.
  def test_betas_construction_fact_renders_the_anthropic_beta_header_comma_joined
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter,
      betas: ["mid-conversation-system-clear-at-2026-08-21", "server-side-fallback-2026-07-01"]
    )
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096)

    headers = adapter.last_request.fetch(:headers)
    assert_equal "mid-conversation-system-clear-at-2026-08-21,server-side-fallback-2026-07-01", headers.fetch("anthropic-beta")
    assert_equal "2023-06-01", headers.fetch("anthropic-version")

    plain = capturing_adapter
    SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: plain)
      .create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    refute plain.last_request.fetch(:headers).key?("anthropic-beta"), "no betas declared, no header"

    keys = SimpleInference::Protocols::AnthropicMessages.protocol_option_keys
    assert_equal %i[messages_path anthropic_version betas thinking_binding mid_conversation_system], keys

    error = assert_raises(SimpleInference::ConfigurationError) do
      SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", betas: ["ok", " "])
    end
    assert_includes error.message, "betas"
  end

  # F10b: the `thinking_binding` construction fact (the fable-5-1 row's
  # wire option, scoped by model id) lowers to
  # thinking.block_binding.prefix_mismatch_behavior on adaptive AND manual
  # enabled thinking, never on disabled, and the field brings its beta.
  def test_thinking_binding_lowers_to_block_binding_on_adaptive_and_enabled_never_disabled
    build = lambda do
      adapter = capturing_adapter
      protocol = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, thinking_binding: "drop_block"
      )
      [adapter, protocol]
    end

    adapter, protocol = build.call
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096, reasoning_effort: "high")
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal(
      { "type" => "adaptive", "display" => "summarized", "block_binding" => { "prefix_mismatch_behavior" => "drop_block" } },
      body.fetch("thinking")
    )
    assert_equal "thinking-binding-controls-2026-08-01", adapter.last_request.fetch(:headers).fetch("anthropic-beta")

    adapter, protocol = build.call
    protocol.create(
      model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096,
      thinking: { type: "enabled", budget_tokens: 2048 }
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "prefix_mismatch_behavior" => "drop_block" }, body.fetch("thinking").fetch("block_binding"))
    assert_equal 2048, body.fetch("thinking").fetch("budget_tokens")
    assert_equal "thinking-binding-controls-2026-08-01", adapter.last_request.fetch(:headers).fetch("anthropic-beta")

    adapter, protocol = build.call
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096, reasoning_effort: "none")
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "type" => "disabled" }, body.fetch("thinking"), "disabled thinking binds nothing")
    refute adapter.last_request.fetch(:headers).key?("anthropic-beta"), "no field, no beta"

    adapter, protocol = build.call
    protocol.create(model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096)
    body = JSON.parse(adapter.last_request.fetch(:body))
    refute body.key?("thinking"), "no thinking requested, nothing to bind"
    refute adapter.last_request.fetch(:headers).key?("anthropic-beta")

    adapter, protocol = build.call
    protocol.create(
      model: "claude-fable-5-1", input: "Hello", max_output_tokens: 4096,
      thinking: { type: "adaptive", block_binding: { prefix_mismatch_behavior: "error" } }
    )
    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "prefix_mismatch_behavior" => "error" }, body.fetch("thinking").fetch("block_binding"),
      "a caller's explicit block_binding wins over the construction fact")

    unbound = capturing_adapter
    SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: unbound)
      .create(model: "claude-fable-5", input: "Hello", max_output_tokens: 4096, reasoning_effort: "high")
    body = JSON.parse(unbound.last_request.fetch(:body))
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body.fetch("thinking"),
      "a row without the fact sends today's bytes")

    error = assert_raises(SimpleInference::ConfigurationError) do
      SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", thinking_binding: "strip")
    end
    assert_includes error.message, "thinking_binding"
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

  # F7: the wire has an `is_error` field on tool_result; the neutral payload's
  # flag lowers to it (absent when false), on both input spellings.
  def test_tool_result_is_error_lowers_to_the_wire_field
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "run both" },
        { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
        { type: "function_call", call_id: "toolu_2", name: "bash", arguments: "{}" },
        { type: "function_call_output", call_id: "toolu_1", output: "<tool_use_error>boom</tool_use_error>", is_error: true },
        { role: "tool", tool_call_id: "toolu_2", content: "fine" },
      ]
    )

    results = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").last.fetch("content")
    assert_equal true, results.fetch(0).fetch("is_error")
    assert_equal "<tool_use_error>boom</tool_use_error>", results.fetch(0).fetch("content"), "the text marker stays beside the field"
    refute results.fetch(1).key?("is_error"), "false is absence, never a false byte"

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "run" },
        { type: "function_call", call_id: "toolu_3", name: "bash", arguments: "{}" },
        { role: "tool", tool_call_id: "toolu_3", content: "boom", is_error: true },
      ]
    )
    tool_result = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages").last.fetch("content").fetch(0)
    assert_equal true, tool_result.fetch("is_error")
  end

  # A FOREIGN call id reaches this wire after a model switch: kimi's
  # `read:0` is a 400 (`tool_use.id` must match ^[a-zA-Z0-9_-]+$). The
  # lowering scrubs it the way opencode does
  # (anthropic-messages.ts scrubToolCallID) — deterministically, so the
  # tool_use and its tool_result still pair — on both input spellings.
  def test_foreign_call_ids_are_scrubbed_to_the_wire_pattern_and_still_pair
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    protocol.create(
      model: "claude-opus-5-5", max_output_tokens: 4096,
      input: [
        { role: "user", content: "read both" },
        { type: "function_call", call_id: "read:0", name: "read", arguments: "{}" },
        { type: "function_call_output", call_id: "read:0", output: "alpha" },
        { role: "assistant", content: "", tool_calls: [{ id: "functions.ls:1", type: "function", function: { name: "ls", arguments: "{}" } }] },
        { role: "tool", tool_call_id: "functions.ls:1", content: "a.txt" },
      ]
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    uses = messages.flat_map { |m| m.fetch("content") }.select { |b| b["type"] == "tool_use" }
    results = messages.flat_map { |m| m.fetch("content") }.select { |b| b["type"] == "tool_result" }
    assert_equal %w[read_0 functions_ls_1], uses.map { |b| b.fetch("id") }
    assert_equal %w[read_0 functions_ls_1], results.map { |b| b.fetch("tool_use_id") }
  end

  # F11 (without the fact): a NON-LEADING system entry lowers IN PLACE to
  # user text — the developer-role rule in the vendor's own spelling —
  # never hoisted ahead of the history it follows; the leading run is
  # still the top-level `system`.
  def test_non_leading_system_lowers_in_place_to_user_text_without_the_row_fact
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter)

    protocol.create(
      model: "claude-sonnet-5", max_output_tokens: 4096,
      input: [
        { role: "system", content: "slots" }, { role: "system", content: "memory" },
        { role: "user", content: "first" },
        { role: "assistant", content: "reply" },
        { role: "system", content: [{ type: "text", text: "operator note", cache_control: { type: "ephemeral" } }] },
        { role: "user", content: "second" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "slots\n\nmemory", body.fetch("system"), "the leading run alone is hoisted"
    messages = body.fetch("messages")
    assert_equal %w[user assistant user], messages.map { |message| message.fetch("role") }
    assert_equal ["operator note", "second"], messages.fetch(2).fetch("content").map { |block| block.fetch("text") }
    assert_equal({ "type" => "ephemeral" }, messages.fetch(2).fetch("content").fetch(0).fetch("cache_control"))
  end

  # F11 (with the fact): the entry stays a wire `role: system` message where
  # the caller placed it, cache_control kept; the leading run is still hoisted.
  def test_non_leading_system_stays_in_place_as_a_system_message_under_the_row_fact
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, mid_conversation_system: true
    )

    protocol.create(
      model: "claude-fable-5-1", max_output_tokens: 4096,
      input: [
        { role: "system", content: "slots" },
        { role: "user", content: "first" },
        { role: "assistant", content: "reply" },
        { role: "user", content: "second" },
        { role: "system", content: [{ type: "text", text: "operator note", cache_control: { type: "ephemeral" } }] },
        { role: "assistant", content: "ack" },
        { role: "user", content: "third" },
        { role: "system", content: "trailing directive" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal "slots", body.fetch("system")
    messages = body.fetch("messages")
    assert_equal %w[user assistant user system assistant user system], messages.map { |message| message.fetch("role") }
    assert_equal(
      [{ "type" => "text", "text" => "operator note", "cache_control" => { "type" => "ephemeral" } }],
      messages.fetch(3).fetch("content")
    )
    assert_equal [{ "type" => "text", "text" => "trailing directive" }], messages.fetch(6).fetch("content")
    refute adapter.last_request.fetch(:headers).key?("anthropic-beta"), "GA on the row's models — no beta"
  end

  # F11's placement guard (opencode's canUseNativeSystemUpdate as a local
  # refusal, since the vendor 400s the same shapes): a system entry must
  # follow a user turn (or tool results), never an assistant turn or another
  # system entry, and what follows it must be the assistant's turn.
  def test_mid_conversation_system_placement_is_guarded_locally_under_the_row_fact
    refusal = lambda do |input|
      adapter = capturing_adapter
      protocol = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, mid_conversation_system: true
      )
      error = assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "claude-fable-5-1", max_output_tokens: 4096, input: input)
      end
      assert_nil adapter.last_request, "a refused placement produces zero outbound IO"
      error.message
    end

    after_assistant = refusal.call([
      { role: "user", content: "first" }, { role: "assistant", content: "reply" },
      { role: "system", content: "note" }, { role: "user", content: "second" },
    ])
    assert_includes after_assistant, "must follow a user turn"

    adjacent = refusal.call([
      { role: "user", content: "first" },
      { role: "system", content: "one" }, { role: "system", content: "two" },
    ])
    assert_includes adjacent, "must follow a user turn"

    before_user = refusal.call([
      { role: "user", content: "first" }, { role: "system", content: "note" }, { role: "user", content: "second" },
    ])
    assert_includes before_user, "must be the assistant's"

    splits_tool_results = refusal.call([
      { role: "user", content: "run" },
      { type: "function_call", call_id: "toolu_1", name: "bash", arguments: "{}" },
      { role: "system", content: "note" },
      { type: "function_call_output", call_id: "toolu_1", output: "done" },
    ])
    assert_includes splits_tool_results, "must follow a user turn"
  end

  # F13's gem half: an `output_config`-only system entry (content []) passes
  # through in place as a wire message under the fact, bringing the
  # mid-conversation-output-config beta; a row without the fact has no
  # lowering for it and refuses.
  def test_output_config_only_system_entry_passes_through_in_place_under_the_row_fact
    adapter = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com", api_key: "k", adapter: adapter, mid_conversation_system: true
    )

    protocol.create(
      model: "claude-fable-5-1", max_output_tokens: 4096, reasoning_effort: "high",
      input: [
        { role: "user", content: "first" }, { role: "assistant", content: "reply" },
        { role: "user", content: "second" },
        { role: "system", content: [], output_config: { effort: "low" } },
        { role: "assistant", content: "ack" }, { role: "user", content: "third" },
      ]
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal({ "role" => "system", "content" => [], "output_config" => { "effort" => "low" } }, body.fetch("messages").fetch(3))
    assert_equal({ "effort" => "high" }, body.fetch("output_config"), "the top-level effort is the caller's, untouched")
    assert_equal "mid-conversation-output-config-2026-07-01", adapter.last_request.fetch(:headers).fetch("anthropic-beta")

    plain = capturing_adapter
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", adapter: plain)
    error = assert_raises(SimpleInference::ValidationError) do
      protocol.create(
        model: "claude-sonnet-5", max_output_tokens: 4096,
        input: [
          { role: "user", content: "first" },
          { role: "system", content: [], output_config: { effort: "low" } },
        ]
      )
    end
    assert_includes error.message, "output_config"
    assert_nil plain.last_request
  end

  private

  def exploding_protocol
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          raise "prepare must not touch the adapter"
        end

        def call_stream(_env)
          raise "prepare must not touch the adapter"
        end
      end.new

    SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com",
      api_key: "sk-ant-secret",
      adapter: adapter
    )
  end

  def capturing_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            id: "msg_capture",
            content: [{ type: "text", text: "ok" }],
            stop_reason: "end_turn",
            usage: { input_tokens: 1, output_tokens: 1 }
          ),
        }
      end
    end.new
  end
end
