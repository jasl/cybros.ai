require "test_helper"

class AgentAPI::ModelPresenterTest < ActiveSupport::TestCase
  test "discovery publishes semantic controls and effective bounds from the profile" do
    entry = { "capabilities" => {
      "reasoning" => { "efforts" => %w[low high], "default_effort" => "low", "disable_supported" => true },
      "service_tiers" => ["priority"],
      "limits" => { "input_tokens" => 64_000, "output_tokens" => 8_192, "effective_input_tokens" => 48_000 },
      "generation_parameters" => {
        "temperature" => { "kind" => "number", "default" => 0.5, "minimum" => 0, "maximum" => 1, "allowed_values" => nil },
        "output_format" => { "kind" => "output_format", "default" => "text", "minimum" => nil, "maximum" => nil,
          "allowed_values" => %w[text json_schema] },
      },
    } }
    capabilities = row(entry).fetch(:capabilities)

    assert_equal({ supported: true, default_enabled: true, disable_supported: true,
      efforts: %w[low high], default_effort: "low" }, capabilities.fetch(:reasoning))
    assert_equal entry.dig("capabilities", "generation_parameters"), capabilities.fetch(:generation_parameters)
    assert_equal ["priority"], capabilities.fetch(:service_tiers)
    assert_equal entry.dig("capabilities", "limits"), capabilities.fetch(:limits)
    refute capabilities.key?(:wire_options)
    refute capabilities.key?(:adapter_profile)
  end

  test "reasoning discovery distinguishes absent switch-only and default-off capabilities" do
    [
      [{}, { supported: false, default_enabled: nil, disable_supported: false, efforts: [], default_effort: nil }],
      [{ "disable_supported" => true },
        { supported: true, default_enabled: true, disable_supported: true, efforts: [], default_effort: nil }],
      [{ "disable_supported" => true, "default_enabled" => false },
        { supported: true, default_enabled: false, disable_supported: true, efforts: [], default_effort: nil }],
      [{ "efforts" => %w[low high], "default_effort" => "high" },
        { supported: true, default_enabled: true, disable_supported: false, efforts: %w[low high], default_effort: "high" }],
    ].each do |declaration, expected|
      assert_equal expected, row({ "capabilities" => { "reasoning" => declaration } }).dig(:capabilities, :reasoning)
    end
  end

  test "wire defaults and model opt-outs are reflected without granting undeclared controls" do
    inherited = row({}).fetch(:capabilities)
    assert_equal %w[text json_object json_schema], inherited.dig(:generation_parameters, "output_format", "allowed_values")
    assert_nil inherited.dig(:generation_parameters, "output_format", "default")
    assert_equal %w[default priority], inherited.fetch(:service_tiers)
    assert_equal({ "input_tokens" => 128_000 }, inherited.fetch(:limits))

    narrowed = row({ "capabilities" => { "generation_parameters" => { "output_format" => false },
      "service_tiers" => [] } }).fetch(:capabilities)
    assert_empty narrowed.fetch(:generation_parameters)
    assert_empty narrowed.fetch(:service_tiers)
  end

  test "non-text models retain their own limits without an invented token window" do
    capabilities = row({ "api_format" => "openai_embeddings",
      "capabilities" => { "limits" => { "input_tokens" => 8_000, "embedding_dimensions" => [256, 1024] } } })
      .fetch(:capabilities)

    assert_equal({ "input_tokens" => 8_000, "embedding_dimensions" => [256, 1024] }, capabilities.fetch(:limits))
    refute capabilities.dig(:reasoning, :supported)
    refute capabilities.fetch(:generation_parameters).key?("output_format")
  end

  private

    def row(entry)
      AgentAPI::ModelPresenter.row(ref: "fixture/text", entry: entry, provider_id: "fixture",
        provider: { "api_format" => "openai_responses", "service_tiers" => %w[default priority] },
        refusal: nil, account_unit: nil)
    end
end
