require "bigdecimal"
require "json"
require "test_helper"

# The audited openrouter_chat lane contract (format `openrouter_chat`,
# served by Protocols::OpenRouterResponses):
#
# - every request carries the frozen provider block
#   ({require_parameters: true}; the :exacto variant rides the model
#   string, owner ruling 2026-08-14) and the X-OpenRouter-Metadata:
#   enabled header,
# - usage is always-on server-side: the deprecated
#   stream_options.include_usage no-op is never emitted,
# - decimal usage values retain their exact wire precision, and
#   reasoning_details remain available on the assistant message for replay.
#
# All negative/malformed/interruption bodies in this file are DETERMINISTIC
# CONSTRUCTIONS for the parser contract — none of them is a wire capture.
class TestOpenRouterProtocols < Minitest::Test
  PINNING_BLOCK = {
    "require_parameters" => true,
  }.freeze

  # --- request contract: pinning block + metadata header ---

  def test_create_pins_the_provider_routing_block_and_metadata_header
    adapter = capturing_chat_adapter
    protocol = build_chat_protocol(adapter: adapter)

    protocol.create(model: "anthropic/claude-sonnet-4.5", input: "Hello")

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal PINNING_BLOCK, body.fetch("provider")
    assert_equal "enabled", adapter.last_request.fetch(:headers).fetch("X-OpenRouter-Metadata")
  end

  def test_stream_pins_the_routing_block_metadata_header_and_never_emits_include_usage
    adapter = capturing_stream_adapter
    protocol = build_chat_protocol(adapter: adapter)

    protocol.stream(model: "anthropic/claude-sonnet-4.5", input: "Hello").final_result

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal PINNING_BLOCK, body.fetch("provider")
    assert_equal true, body.fetch("stream")
    refute body.key?("stream_options"), "usage accounting is always-on; the deprecated opt-in must never be emitted"
    assert_equal "enabled", adapter.last_request.fetch(:headers).fetch("X-OpenRouter-Metadata")
  end

  # :stream_options is removed from the inherited request vocabulary
  # (register fact): usage accounting is always-on for this broker, so a
  # caller-supplied stream_options is a loud unknown-option rejection —
  # never a silent pass-through that could emit the deprecated
  # stream_options.include_usage opt-in.
  def test_stream_options_request_option_is_a_loud_rejection
    adapter = capturing_chat_adapter
    protocol = build_chat_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "anthropic/claude-sonnet-4.5",
          input: "Hello",
          stream_options: { include_usage: true },
        )
      end

    assert_includes error.message, "stream_options"
    assert_nil adapter.last_request, "a rejected option must never reach the wire"
  end

  def test_stream_rejects_the_stream_options_request_option_eagerly
    adapter = capturing_stream_adapter
    protocol = build_chat_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.stream(model: "anthropic/claude-sonnet-4.5", input: "Hello", stream_options: { include_usage: true })
      end

    assert_includes error.message, "stream_options"
  end

  def test_request_option_keys_exclude_stream_options
    keys = SimpleInference::Protocols::OpenRouterResponses.request_option_keys

    refute_includes keys, :stream_options
    assert_includes keys, :reasoning
    assert_includes keys, :reasoning_summary
    assert keys.frozen?
  end

  # The always-on-usage fact is a REGISTRY fact (post-Stage-4 re-audit,
  # fix 2): every openrouter row declares wire_options
  # {stream_include_usage: false}, the parent's construction vocabulary is
  # inherited rather than emptied, and this lane refuses to exist with the
  # opt-in enabled — whether requested explicitly or left to the generic
  # gateway default.
  def test_stream_include_usage_must_be_constructed_false_for_this_lane
    [
      { stream_include_usage: true },
      {},
    ].each do |options|
      error = assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Protocols::OpenRouterResponses.new(
          base_url: "http://example.com",
          api_key: "secret",
          adapter: capturing_chat_adapter,
          **options,
        )
      end
      assert_includes error.message, "stream_include_usage: false"
    end

    # The construction fact rides the FORMAT, so every lane a deployment
    # composes on this wire inherits it — there is no row left to forget it.
    assert_equal false,
                 SimpleInference::ApiFormat.defaults("openrouter_chat")[:wire_options]
                   .fetch(:stream_include_usage)
  end

  def test_extra_body_provider_collides_with_the_pinned_routing_block
    protocol = build_chat_protocol(adapter: capturing_chat_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(
          model: "anthropic/claude-sonnet-4.5",
          input: "Hello",
          extra_body: { "provider" => { "order" => ["other"] } },
        )
      end

    assert_includes error.message, "provider"
  end


  def test_create_retains_exact_decimal_values_in_provider_usage
    usage = {
      "prompt_tokens" => 2,
      "completion_tokens" => 3,
      "total_tokens" => 5,
      "cost" => 0.000096,
      "is_byok" => false,
      "cost_details" => {
        "upstream_inference_cost" => 0.00009,
        "upstream_inference_prompt_cost" => 0.00003,
        "upstream_inference_completions_cost" => 0.00006,
      },
    }
    protocol = build_chat_protocol(adapter: chat_adapter_with(usage: usage))

    result = protocol.create(model: "anthropic/claude-sonnet-4.5", input: "Hello")

    assert_instance_of SimpleInference::Responses::Result, result
    assert_equal BigDecimal("0.000096"), result.usage.fetch("cost")
    assert_equal BigDecimal("0.00009"),
                 result.usage.dig("cost_details", "upstream_inference_cost")
    assert_equal false, result.usage.fetch("is_byok")
  end

  # Wire-precision regression (finding 4b): a decimal credit amount beyond
  # Float precision must survive the parse verbatim. Through JSON.parse as a
  # Float, 0.123456789012345684 collapses to 0.12345678901234568 — a real
  # undercount path; this lane must retain the exact wire digits.
  def test_cost_decimals_retain_full_wire_precision_end_to_end
    wire_digits = "0.123456789012345684"
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: %({"id":"gen_1","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],) +
                %("usage":{"prompt_tokens":1,"completion_tokens":1,"is_byok":false,"cost":#{wire_digits},) +
                %("cost_details":{"upstream_inference_cost":#{wire_digits}}}}),
        }
      end
    end.new
    protocol = build_chat_protocol(adapter: adapter)

    result = protocol.create(model: "anthropic/claude-sonnet-4.5", input: "Hello")

    assert_instance_of BigDecimal, result.usage.fetch("cost")
    assert_equal wire_digits, result.usage.fetch("cost").to_s("F"),
                 "the retained value must equal the wire digits exactly"
    assert_equal wire_digits,
                 result.usage.dig("cost_details", "upstream_inference_cost").to_s("F")
  end

  def test_usage_fields_absent_on_the_wire_stay_absent
    protocol = build_chat_protocol(
      adapter: chat_adapter_with(usage: { "prompt_tokens" => 1, "is_byok" => false })
    )

    result = protocol.create(model: "anthropic/claude-sonnet-4.5", input: "Hello")

    refute result.usage.key?("cost")
    refute result.usage.key?("cost_details")
  end

  def test_response_without_usage_keeps_the_output
    protocol = build_chat_protocol(adapter: chat_adapter_with(usage: nil))

    result = protocol.create(model: "anthropic/claude-sonnet-4.5", input: "Hello")

    assert_nil result.usage
    assert_equal "ok", result.output_text
  end

  def test_stream_bad_accounting_members_still_complete_with_provider_output
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield %(data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n)
        yield %(data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":3,"is_byok":"false","cost":"bad"}}\n\n)
        yield "data: [DONE]\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new

    result = build_chat_protocol(adapter: adapter)
             .stream(model: "anthropic/claude-sonnet-4.5", input: "Hello")
             .final_result

    assert_equal "Hi", result.output_text
    assert_equal "bad", result.usage.fetch("cost")
  end

  # --- reasoning contract (frozen openrouter row) ---

  def test_create_maps_reasoning_effort_and_summary_into_the_nested_reasoning_object
    adapter = capturing_chat_adapter
    protocol = build_chat_protocol(adapter: adapter)

    protocol.create(
      model: "anthropic/claude-sonnet-4.5",
      input: "Hello",
      reasoning_effort: "high",
      reasoning_summary: "detailed",
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    refute_includes body, "reasoning_effort"
    assert_equal({ "effort" => "high", "summary" => "detailed" }, body.fetch("reasoning"))
  end

  def test_stream_accumulates_reasoning_details_and_echoes_them_on_the_result
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield %(data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","text":"Need ","signature":"sig1"}]}}]}\n\n)
        yield %(data: {"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"opaque"}]}}]}\n\n)
        yield %(data: {"choices":[{"delta":{"content":"Done."},"finish_reason":"stop"}],"usage":{"total_tokens":3,"is_byok":false}}\n\n)
        yield "data: [DONE]\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = build_chat_protocol(adapter: adapter)

    result = protocol.stream(model: "anthropic/claude-sonnet-4.5", input: "Hello").final_result

    expected = [
      { "type" => "reasoning.text", "text" => "Need ", "signature" => "sig1" },
      { "type" => "reasoning.encrypted", "data" => "opaque" },
    ]
    assert_equal expected, result.assistant_message.fetch("reasoning_details"),
                 "reasoning_details must ride the assistant message so later turns can echo them back"
  end

  def test_assistant_input_reasoning_details_pass_to_the_wire_unmodified
    adapter = capturing_chat_adapter
    protocol = build_chat_protocol(adapter: adapter)

    details = [
      { "type" => "reasoning.text", "text" => "prior", "signature" => "sig9" },
      { "type" => "reasoning.encrypted", "data" => "blob" },
    ]
    protocol.create(
      model: "anthropic/claude-sonnet-4.5",
      input: [
        { "role" => "user", "content" => "again" },
        { "role" => "assistant", "content" => "earlier", "reasoning_details" => details },
      ],
    )

    messages = JSON.parse(adapter.last_request.fetch(:body)).fetch("messages")
    assert_equal details, messages.fetch(1).fetch("reasoning_details"),
                 "consecutive reasoning_details blocks must be echoed back unmodified"
  end

  # --- stream terminals ---

  # Deterministic construction of the register-documented mid-stream failure
  # shape: a data event with a top-level error object under HTTP 200.
  def test_mid_stream_top_level_error_object_is_a_typed_error
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield %(data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n)
        yield %(data: {"error":{"code":502,"message":"upstream exploded"},"choices":[{"delta":{},"finish_reason":"error"}]}\n\n)
        yield "data: [DONE]\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = build_chat_protocol(adapter: adapter)

    error =
      assert_raises(SimpleInference::HTTPError) do
        protocol.stream(model: "anthropic/claude-sonnet-4.5", input: "Hello").final_result
      end

    assert_equal 502, error.status
    assert_includes error.message, "upstream exploded"
  end

  # --- declared vocabulary ---

  def test_request_option_keys_extend_the_chat_completions_vocabulary
    keys = SimpleInference::Protocols::OpenRouterResponses.request_option_keys

    assert_includes keys, :reasoning
    assert_includes keys, :reasoning_summary
    assert_includes keys, :reasoning_effort
    assert keys.frozen?
  end

  def test_create_rejects_unknown_symbol_options_and_points_at_extra_body
    protocol = build_chat_protocol(adapter: capturing_chat_adapter)

    error =
      assert_raises(SimpleInference::ValidationError) do
        protocol.create(model: "anthropic/claude-sonnet-4.5", input: "Hello", reasonig: { effort: "high" })
      end

    assert_includes error.message, "reasonig"
    assert_includes error.message, "extra_body"
  end

  private

  # stream_include_usage: false is the registry-declared construction fact
  # every openrouter row carries (wire_options); the lane refuses
  # construction without it.
  def build_chat_protocol(adapter:)
    SimpleInference::Protocols::OpenRouterResponses.new(
      base_url: "http://example.com",
      api_key: "secret",
      adapter: adapter,
      stream_include_usage: false,
    )
  end

  def capturing_chat_adapter
    chat_adapter_with(usage: { "prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3, "is_byok" => false })
  end

  def chat_adapter_with(usage:)
    body = {
      "id" => "gen_1",
      "choices" => [
        { "message" => { "role" => "assistant", "content" => "ok" }, "finish_reason" => "stop" },
      ],
    }
    body["usage"] = usage unless usage.nil?

    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      define_method(:call) do |env|
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(body),
        }
      end
    end.new
  end

  def capturing_stream_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call_stream(env)
        @last_request = env
        yield %(data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}\n\n)
        yield %(data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":3,"is_byok":false}}\n\n)
        yield "data: [DONE]\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
  end
end
