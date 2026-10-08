require "json"
require "test_helper"

class TestReasoningEnabled < Minitest::Test
  TEXT_FORMATS = SimpleInference::ApiFormat::FORMATS.select do |format|
    SimpleInference::ApiFormat.workload(format) == "text_generation"
  end.freeze
  RESPONSE_FORMATS = %w[openai_responses codex_responses deepseek_responses xai_responses].freeze

  class NoIO < SimpleInference::HTTPAdapter
    def call(_env) = raise "compiling reasoning controls must not perform IO"
    def call_stream(_env) = raise "compiling reasoning controls must not perform IO"
  end

  def test_every_text_protocol_accepts_the_independent_boolean
    TEXT_FORMATS.each do |format|
      assert_includes SimpleInference::ApiFormat.protocol_class(format).request_option_keys,
        :reasoning_enabled, format
    end
  end

  def test_nil_preserves_each_protocols_existing_effort_request
    TEXT_FORMATS.each do |format|
      assert_equal compile(format, reasoning_effort: "high"),
        compile(format, reasoning_enabled: nil, reasoning_effort: "high"), format
    end
  end

  def test_invalid_booleans_fail_locally_on_every_text_protocol
    TEXT_FORMATS.each do |format|
      error = assert_raises(SimpleInference::ValidationError) do
        compile(format, reasoning_enabled: "false", reasoning_effort: "high")
      end
      assert_includes error.message, "reasoning_enabled", format
    end
  end

  def test_enabled_true_rejects_the_contradictory_native_none_effort
    TEXT_FORMATS.each do |format|
      error = assert_raises(SimpleInference::ValidationError) do
        compile(format, reasoning_enabled: true, reasoning_effort: "none")
      end
      assert_includes error.message, "conflicts", format
    end

    (RESPONSE_FORMATS + ["openrouter_chat"]).each do |format|
      assert_raises(SimpleInference::ValidationError) do
        compile(format, reasoning_enabled: true, reasoning: { effort: "none" })
      end
    end
  end

  def test_responses_disable_overrides_effort_and_drops_reasoning_context_and_summary
    RESPONSE_FORMATS.each do |format|
      [false, true].each do |stream|
        body = compile(format, stream: stream, reasoning_enabled: false, reasoning_effort: "high")

        expected = { "effort" => "none" }
        expected["context"] = "all_turns" if format == "codex_responses"
        assert_equal expected, body.fetch("reasoning"), format
        refute_includes body, "reasoning_enabled"
        refute_includes body, "reasoning_effort"
      end
    end

    nested = { effort: "high", summary: "detailed", context: "all_turns" }.freeze
    body = compile("openai_responses", reasoning_enabled: false, reasoning: nested)
    assert_equal({ "effort" => "none" }, body.fetch("reasoning"))
    assert_equal({ effort: "high", summary: "detailed", context: "all_turns" }, nested)
  end

  def test_responses_enabled_keeps_the_selected_effort_and_protocol_defaults
    RESPONSE_FORMATS.each do |format|
      body = compile(format, reasoning_enabled: true, reasoning_effort: "high")

      assert_equal "high", body.dig("reasoning", "effort"), format
      refute_includes body, "reasoning_enabled"
      refute_includes body.fetch("reasoning"), "enabled"
    end
  end

  def test_openrouter_switch_only_model_sends_a_boolean_without_inventing_effort
    [false, true].each do |enabled|
      [false, true].each do |stream|
        body = compile("openrouter_chat", stream: stream, reasoning_enabled: enabled)

        assert_equal({ "enabled" => enabled }, body.fetch("reasoning"))
        assert_equal({ "require_parameters" => true }, body.fetch("provider"))
        refute_includes body, "reasoning_enabled"
      end
    end
  end

  def test_openrouter_disabling_suppresses_flat_and_nested_effort
    body = compile("openrouter_chat", reasoning_enabled: false, reasoning_effort: "high",
      reasoning: { effort: "low", max_tokens: 2048 }.freeze)

    assert_equal({ "enabled" => false }, body.fetch("reasoning"))
    assert_equal({ "enabled" => true, "effort" => "high" }, compile("openrouter_chat",
      reasoning_enabled: true, reasoning_effort: "high").fetch("reasoning"))
  end

  def test_anthropic_disable_keeps_structured_output_without_effort
    [false, true].each do |stream|
      body = compile("anthropic_messages", stream: stream, reasoning_enabled: false, reasoning_effort: "high",
        output_config: { effort: "medium" }.freeze,
        response_format: { type: "json_schema", schema: { type: "object" } })

      assert_equal({ "type" => "disabled" }, body.fetch("thinking"))
      assert_equal({ "format" => { "type" => "json_schema", "schema" => { "type" => "object" } } },
        body.fetch("output_config"))
      refute_includes body, "reasoning_enabled"
    end
  end

  def test_anthropic_enabled_without_effort_uses_adaptive_without_inventing_effort
    body = compile("anthropic_messages", reasoning_enabled: true)

    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body.fetch("thinking"))
    refute_includes body, "output_config"
  end

  def test_generic_chat_default_control_uses_none_and_never_guesses_a_chat_template
    body = compile("openai_compatible_chat", reasoning_enabled: false, reasoning_effort: "high")

    assert_equal "none", body.fetch("reasoning_effort")
    refute_includes body, "chat_template_kwargs"
    refute_includes body, "reasoning_enabled"
  end

  def test_generic_chat_template_control_lowers_the_boolean_independently_of_effort
    [false, true].each do |stream|
      [false, true].each do |enabled|
        body = compile("openai_compatible_chat", stream: stream, control: "chat_template_kwargs",
          reasoning_enabled: enabled, reasoning_effort: "low")

        expected = {
          "model" => "test-model", "messages" => [{ "role" => "user", "content" => "Hello" }],
          "chat_template_kwargs" => { "enable_thinking" => enabled },
        }
        expected["reasoning_effort"] = "low" if enabled
        expected.merge!("stream" => true, "stream_options" => { "include_usage" => true }) if stream
        assert_equal expected, body
      end
    end
  end

  def test_generic_chat_template_switch_only_request_does_not_need_an_effort
    [false, true].each do |enabled|
      body = compile("openai_compatible_chat", control: "chat_template_kwargs", reasoning_enabled: enabled)

      assert_equal({ "enable_thinking" => enabled }, body.fetch("chat_template_kwargs"))
      refute_includes body, "reasoning_effort"
    end
  end

  def test_declaring_a_chat_template_control_does_not_select_an_omitted_boolean
    body = compile("openai_compatible_chat", control: "chat_template_kwargs", reasoning_effort: "low")

    assert_equal "low", body.fetch("reasoning_effort")
    refute_includes body, "chat_template_kwargs"
  end

  def test_chat_template_control_is_closed_and_only_available_on_generic_chat
    assert_nil profile_for("openai_compatible_chat", wire_options: { reasoning_control: nil }).wire_option(:reasoning_control)
    %w[reasoning_effort chat_template_kwargs].each do |control|
      assert_equal control,
        profile_for("openai_compatible_chat", wire_options: { reasoning_control: control }).wire_option(:reasoning_control)
    end

    assert_raises(SimpleInference::ConfigurationError) do
      profile_for("openai_compatible_chat", wire_options: { reasoning_control: "unsupported_thinking_control" })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      profile_for("openrouter_chat", wire_options: { reasoning_control: "chat_template_kwargs" })
    end
    ["unknown", false].each do |control|
      assert_raises(SimpleInference::ConfigurationError) do
        SimpleInference::Protocols::OpenAICompatibleResponses.new(base_url: "http://example.com", reasoning_control: control)
      end
    end
  end

  def test_gemini_enabled_preserves_levels_but_the_wire_cannot_express_disabled
    body = compile("gemini_generate_content", reasoning_enabled: true, reasoning_effort: "low")
    assert_equal({ "includeThoughts" => true, "thinkingLevel" => "low" }, body.dig("generationConfig", "thinkingConfig"))

    error = assert_raises(SimpleInference::ValidationError) do
      compile("gemini_generate_content", reasoning_enabled: false, reasoning_effort: "low")
    end
    assert_includes error.message, "cannot disable"
  end

  private

  def compile(format, stream: false, control: nil, **options)
    wire = SimpleInference::ApiFormat.defaults(format).fetch(:wire_options, {})
    wire = wire.merge(reasoning_control: control) if control
    profile = profile_for(format, wire_options: wire)
    client = SimpleInference::Client.new(execution_profile: profile, base_url: "http://example.com", adapter: NoIO.new)
    options = { max_output_tokens: 4096 }.merge(options) if format == "anthropic_messages"

    JSON.parse(client.responses.compile(model: profile.model_pin, input: "Hello", stream: stream, **options).payload)
  end
end
