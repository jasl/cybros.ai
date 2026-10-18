require "test_helper"

class Nexus::EffectiveReasoningTest < ActiveSupport::TestCase
  test "reasoning defaults on and keeps effort independent of supported disablement" do
    declaration = { "efforts" => %w[low high], "default_effort" => "low", "disable_supported" => true }
    reasoning, refusal = Nexus::EffectiveReasoning.derive(declaration, nil)
    assert_nil refusal
    assert_equal true, reasoning.enabled
    assert_equal "low", reasoning.effort

    reasoning, refusal = Nexus::EffectiveReasoning.derive(declaration, "high", enabled: false)
    assert_nil refusal
    assert_equal false, reasoning.enabled
    assert_equal "high", reasoning.effort

    _, refusal = Nexus::EffectiveReasoning.derive(declaration, "none", enabled: false)
    assert_equal :unsupported_reasoning_effort, refusal
  end

  test "default-off switch-only models can enable thinking without inventing an effort" do
    declaration = { "default_enabled" => false, "disable_supported" => true }
    [nil, true, false].each do |enabled|
      reasoning, refusal = Nexus::EffectiveReasoning.derive(declaration, nil, enabled: enabled)
      assert_nil refusal
      assert_equal enabled == true, reasoning.enabled
      assert_nil reasoning.effort
    end
  end

  test "unsupported disablement is ignored and catalog silence remains unselected" do
    reasoning, refusal = Nexus::EffectiveReasoning.derive(
      { "efforts" => %w[medium high], "default_effort" => "medium" }, "high", enabled: false
    )
    assert_nil refusal
    assert_equal true, reasoning.enabled
    assert_equal "high", reasoning.effort

    [nil, true, false].each do |enabled|
      reasoning, refusal = Nexus::EffectiveReasoning.derive(nil, nil, enabled: enabled)
      assert_nil refusal
      assert_nil reasoning.enabled
      assert_nil reasoning.effort
    end
  end
end
