require "test_helper"

# The resolver's short-lived acceptance value. It carries the current Catalog
# view only while the boundary validates a command; persistence extracts the
# Invocation's narrow semantic facts instead of serializing this whole object.
class Nexus::ResolvedModelSelectionTest < ActiveSupport::TestCase
  test "one resolution carries the candidate and normalized semantic controls" do
    selection = DevModelLane.selection(
      workload: "text_generation",
      reasoning_effort: "high",
      configuration: { temperature: 0.4, output_format: { type: "text" } }
    )

    assert_equal "dev", selection.provider_id
    assert_equal "mock-text", selection.model_ref
    assert_equal "text_generation", selection.workload
    assert_equal 0.4, selection.generation_config.fetch(:temperature)
    assert_equal "high", selection.reasoning.effort
    assert_equal "dev/mock-text@openai_responses", selection.execution_profile.profile_id
  end

  test "execution and capability facts come from the same workload candidate" do
    selection = DevModelLane.selection(workload: "embedding")

    assert_equal "embedding", selection.workload
    assert_equal "embeddings_http", selection.execution_profile.protocol_route
    assert_empty selection.capabilities.input_modalities
    assert_equal %w[embedding], selection.capabilities.output_modalities
    assert_equal [3, 8], selection.capabilities.limits.embedding_dimensions
    assert_equal 3, selection.generation_config.fetch(:dimensions)
  end

  # The codec keys off value shape, not a parameter name: `output_format` may
  # legitimately be a scalar while another control carries OutputFormat.
  test "generation config renders request options under any parameter spelling" do
    {
      string_named_output_format: { output_format: "png" },
      structured_under_another_name: {
        response_format: Nexus::OutputFormat.from_h({ "type" => "text" }),
      },
      structured_under_its_own_name: {
        output_format: Nexus::OutputFormat.from_h({ "type" => "text" }),
      },
      plain_scalars: { temperature: 0.7, max_output_tokens: 512, stream: true, unset: nil },
    }.each do |name, values|
      config = Nexus::EffectiveGenerationConfig.new(values: values.freeze)

      assert_equal config, Nexus::EffectiveGenerationConfig.from_h(config.to_h), name
      assert_nothing_raised { config.request_options }
    end
  end

  test "reasoning remains one closed composable value" do
    selection = DevModelLane.selection(
      workload: "text_generation", reasoning_effort: "high"
    )

    assert_predicate selection.reasoning, :enabled
    assert_equal "high", selection.reasoning.effort
    assert_nil selection.reasoning.mode
    assert_empty selection.capabilities.reasoning_modes
    assert_nil selection.reasoning.budget_tokens
    assert_nil selection.reasoning.summary_policy
  end

  test "a selector keeps the caller ask beside its resolved candidate in memory" do
    selection = DevModelLane.selection(
      workload: "text_generation", model: "model_selector:fast-text"
    )

    assert_equal "fast-text", selection.submitted.model_selector
    assert_equal "mock-text", selection.model_ref
  end
end
