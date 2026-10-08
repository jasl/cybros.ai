require "json"
require "test_helper"

class TestAnthropicModelControls < Minitest::Test
  def protocol(**options)
    SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://example.test", **options)
  end

  def body(protocol, **options)
    JSON.parse(protocol.compile_create(model: "same-model", input: "Hello", max_output_tokens: 32_768, **options).payload)
  end

  def test_model_controls_choose_budget_or_adaptive_for_the_same_model_identifier
    adaptive = body(protocol, reasoning_effort: "high")
    budget = body(protocol(anthropic_thinking_control: "budget"), reasoning_effort: "high")

    assert_equal({ "type" => "adaptive", "display" => "summarized" }, adaptive.fetch("thinking"))
    assert_equal({ "effort" => "high" }, adaptive.fetch("output_config"))
    assert_equal({ "type" => "enabled", "budget_tokens" => 16_384, "display" => "summarized" }, budget.fetch("thinking"))
    refute_includes budget, "output_config"
    assert_equal 32_768, budget.fetch("max_tokens")
  end

  def test_budget_efforts_fit_inside_the_declared_output_ceiling_and_keep_answer_room
    client = protocol(anthropic_thinking_control: "budget", thinking_budgets: { "high" => 20_000 })
    compiled = client.compile_create(model: "model", input: "Hi", reasoning_effort: "high", max_output_tokens: 8192)
    request = JSON.parse(compiled.payload)
    assert_equal 7168, request.dig("thinking", "budget_tokens")
    assert_equal 8192, request.fetch("max_tokens")
    assert_equal 1024, body(client, reasoning_effort: "minimal").dig("thinking", "budget_tokens")

    assert_raises(SimpleInference::ValidationError) do
      client.compile_create(model: "model", input: "Hi", reasoning_effort: "high", max_output_tokens: 1024)
    end
    assert_raises(SimpleInference::ValidationError) do
      client.compile_create(model: "model", input: "Hi", max_output_tokens: 2048,
        thinking: { type: "enabled", budget_tokens: 2048 })
    end
  end

  def test_budget_controls_disable_without_an_effort_and_preserve_structured_output
    client = protocol(anthropic_thinking_control: "budget", thinking_omits_temperature: true)
    active = body(client, reasoning_enabled: true, temperature: 0.2)
    assert_equal 1024, active.dig("thinking", "budget_tokens")
    refute_includes active, "temperature"

    disabled = body(client, reasoning_enabled: false, reasoning_effort: "high", temperature: 0.2,
      response_format: { type: "json_schema", schema: { type: "object" } })
    assert_equal({ "type" => "disabled" }, disabled.fetch("thinking"))
    assert_equal 0.2, disabled.fetch("temperature")
    assert_equal "json_schema", disabled.dig("output_config", "format", "type")
    refute_includes disabled.fetch("output_config"), "effort"
  end

  def test_empty_signatures_are_preserved_only_for_a_declared_compatible_model
    input = [
      { role: "assistant", content: [{ type: "thinking", thinking: "Reasoned", signature: "" },
        { type: "text", text: "Answer" }] },
      { role: "user", content: "Continue" },
    ]
    compile = ->(client) { JSON.parse(client.compile_create(model: "m", input: input, max_output_tokens: 4096).payload) }
    ordinary = compile.call(protocol).fetch("messages").first.fetch("content")
    compatible = compile.call(protocol(allow_empty_thinking_signature: true)).fetch("messages").first.fetch("content")

    assert_equal ["text"], ordinary.map { |part| part.fetch("type") }
    assert_equal({ "type" => "thinking", "thinking" => "Reasoned", "signature" => "" }, compatible.first)
  end

  def test_malformed_model_controls_fail_at_construction
    assert_raises(SimpleInference::ConfigurationError) { protocol(anthropic_thinking_control: "guess") }
    [-1, 512, "2048", 2048.5].each do |budget|
      assert_raises(SimpleInference::ConfigurationError) { protocol(thinking_budgets: { "high" => budget }) }
    end
  end
end
