require "json"
require "test_helper"
require_relative "anthropic_protocol_helpers"

class TestAnthropicProtocol < Minitest::Test
  include AnthropicProtocolHelpers

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
    assert_equal %i[messages_path anthropic_version betas thinking_binding mid_conversation_system
      anthropic_thinking_control thinking_budgets allow_empty_thinking_signature thinking_omits_temperature], keys

    error = assert_raises(SimpleInference::ConfigurationError) do
      SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://api.anthropic.com", api_key: "k", betas: ["ok", " "])
    end
    assert_includes error.message, "betas"
  end
end
