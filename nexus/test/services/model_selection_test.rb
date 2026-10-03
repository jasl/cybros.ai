require "test_helper"

# Selection's two halves: the M2 regression matrix (configuration
# normalization and refusal vocabulary, now driven through the REAL resolver
# over the mounted dev lane — WP7d), and the fact that deployable
# composition without an explicit port still resolves nothing.
class ModelSelectionTest < ActiveSupport::TestCase
  setup do
    DevModelLane.ensure_enabled!
  end

  test "deployable composition refuses every workload before anything can be created" do
    Nexus::ModelWorkloads::ALL.each do |workload|
      result = ModelSelection.resolve(
        account: accounts(:cybros), workload: workload,
        submitted: DevModelLane.submission_for(workload)
      )

      assert_not_predicate result, :resolved?
      assert_equal :model_plane_unavailable, result.refusal
      assert_nil result.selection
    end
  end

  test "an exact model never falls back to a different candidate" do
    unknown = resolve(
      workload: "text_generation",
      submitted: submission(model: "dev/does-not-exist")
    )
    wrong_lane = resolve(
      workload: "text_generation",
      submitted: DevModelLane.submission_for("image_generation")
    )

    assert_equal :unknown_model, unknown.refusal
    assert_equal :unsupported_workload, wrong_lane.refusal
  end

  test "unknown providers and selectors are distinct fail-closed refusals" do
    provider = resolve(
      workload: "text_generation",
      submitted: submission(model: "mystery/model")
    )
    selector = resolve(
      workload: "text_generation",
      submitted: submission(model: "model_selector:missing")
    )

    assert_equal :unknown_provider, provider.refusal
    assert_equal :unknown_model_selector, selector.refusal
  end

  test "a selector is text-only and freezes its selected candidate and effort" do
    result = resolve(
      workload: "text_generation",
      submitted: submission(model: "model_selector:fast-text")
    )

    assert_predicate result, :resolved?
    assert_equal "model_selector:fast-text", result.selection.submitted.model
    assert_equal "fast-text", result.selection.submitted.model_selector
    assert_equal "dev/mock-text", "#{result.selection.provider_id}/#{result.selection.model_ref}"
    assert_equal "low", result.selection.reasoning.effort

    refused = resolve(
      workload: "embedding",
      submitted: submission(model: "model_selector:fast-text")
    )
    assert_equal :selector_not_supported, refused.refusal
  end

  test "exact text reasoning is derived from the selected candidate" do
    result = resolve(
      workload: "text_generation",
      submitted: DevModelLane.submission_for("text_generation", reasoning_effort: "high")
    )

    assert_predicate result, :resolved?
    assert_equal "high", result.selection.reasoning.effort

    refused = resolve(
      workload: "text_generation",
      submitted: DevModelLane.submission_for("text_generation", reasoning_effort: "extreme")
    )
    assert_equal :unsupported_reasoning_effort, refused.refusal
  end

  test "configuration is normalized from candidate defaults and lowered once" do
    speech = resolve(workload: "speech_generation")
    text = resolve(
      workload: "text_generation",
      configuration: { temperature: 0.4, max_output_tokens: 512 }
    )

    assert_equal "Kore", speech.selection.generation_config.fetch(:voice)
    assert_equal "wav", speech.selection.generation_config.fetch(:format)
    assert_equal 0.4, text.selection.generation_config.fetch(:temperature)
    assert_equal 512, text.selection.request_options.fetch(:max_output_tokens)
  end

  test "provider-neutral configuration accepts each workload's declared controls" do
    image = resolve(workload: "image_generation", configuration: { result_count: 4 })
    # The speech lane declares no `language`: its protocol accepts none, and
    # a definitional lane may not claim a control its adapter would refuse
    # (narrowed by C2-4 WP-A).
    speech = resolve(
      workload: "speech_generation",
      configuration: { voice: "Puck", format: "mp3" }
    )
    transcription = resolve(
      workload: "transcription", configuration: { language: "zh" }
    )
    embedding = resolve(workload: "embedding", configuration: { dimensions: 8 })

    assert_equal 4, image.selection.request_options.fetch(:result_count)
    assert_equal "Puck", speech.selection.request_options.fetch(:voice)
    assert_equal "mp3", speech.selection.request_options.fetch(:format)
    assert_equal "zh", transcription.selection.request_options.fetch(:language)
    assert_equal 8, embedding.selection.request_options.fetch(:dimensions)
  end

  # OFFERED WITHOUT BEING IMPOSED. A control carrying a default rides every
  # turn, so `language` used to be a choice between forcing one on callers who
  # wanted the endpoint to detect it and not offering the control at all — the
  # dev lane papered over it with an invented `auto` value. With no default the
  # control is reachable and a request that did not ask for it carries nothing.
  test "an offered control with no default is absent from a request that never asked" do
    detected = resolve(workload: "transcription")
    refute detected.selection.request_options.key?(:language),
      "nothing was asked for, so nothing may be sent — not a value invented to fill the slot"

    asked = resolve(workload: "transcription", configuration: { language: "zh" })
    assert_equal "zh", asked.selection.request_options.fetch(:language),
      "and the control is still genuinely offered"
  end

  test "text numeric controls accept their bounds and reject non-finite or out-of-range values" do
    lower = resolve(
      workload: "text_generation",
      configuration: { temperature: 0.0, top_p: 0.0, max_output_tokens: 1 }
    )
    upper = resolve(
      workload: "text_generation",
      configuration: { temperature: 2.0, top_p: 1.0, max_output_tokens: 2_048 }
    )
    nan = resolve(workload: "text_generation", configuration: { temperature: Float::NAN })
    exponent = resolve(
      workload: "text_generation", configuration: { temperature: 1.0e-10 }
    )
    string_number = resolve(
      workload: "text_generation", configuration: { temperature: "0.4" }
    )
    float_integer = resolve(
      workload: "text_generation", configuration: { max_output_tokens: 1.0 }
    )
    too_many = resolve(
      workload: "text_generation", configuration: { max_output_tokens: 2_049 }
    )

    assert_predicate lower, :resolved?
    assert_predicate upper, :resolved?
    assert_equal :invalid_generation_parameter, nan.refusal
    assert_equal :invalid_generation_parameter, exponent.refusal
    assert_equal :invalid_generation_parameter, string_number.refusal
    assert_equal :invalid_generation_parameter, float_integer.refusal
    assert_equal :invalid_generation_parameter, too_many.refusal
  end

  test "text output formats are closed, normalized, and bounded" do
    object = resolve(
      workload: "text_generation", configuration: { output_format: { type: "json_object" } }
    )
    schema = resolve(
      workload: "text_generation",
      configuration: {
        output_format: {
          type: "json_schema",
          name: "answer_v1",
          schema: { "type" => "object", "properties" => {} },
          strict: false,
        },
      }
    )

    assert_equal({ type: "json_object" }, object.selection.request_options.fetch(:output_format))
    assert_equal(
      {
        type: "json_schema",
        name: "answer_v1",
        schema: { "properties" => {}, "type" => "object" },
        strict: false,
      },
      schema.selection.request_options.fetch(:output_format)
    )

    strict_default = {
      type: "json_schema",
      name: "strict_default",
      schema: { "type" => "object" },
    }
    omitted = resolve(
      workload: "text_generation", configuration: { output_format: strict_default }
    )
    hash_nil = resolve(
      workload: "text_generation",
      configuration: { output_format: strict_default.merge(strict: nil) }
    )
    typed_nil = resolve(
      workload: "text_generation",
      configuration: {
        output_format: Nexus::OutputFormat.new(**strict_default, strict: nil),
      }
    )
    [omitted, hash_nil, typed_nil].each do |result|
      assert_equal true,
        result.selection.request_options.dig(:output_format, :strict)
    end

    schema_frame = Nexus::CanonicalJson.bytesize(
      { "description" => "", "type" => "object" }
    )
    at_bound = resolve(
      workload: "text_generation",
      configuration: {
        output_format: {
          type: "json_schema",
          name: "bounded",
          schema: {
            "type" => "object",
            "description" => "x" * (
              Nexus::SizeBounds.fetch(:model_output_schema_bound) - schema_frame
            ),
          },
        },
      }
    )
    assert_predicate at_bound, :resolved?

    invalid_values = [
      { type: "json_schema", name: "bad name", schema: { "type" => "object" } },
      { type: "json_schema", name: "answer", schema: { "type" => "array" } },
      {
        type: "json_schema",
        name: "answer",
        schema: { "type" => "object", "description" => "x" * 16_384 },
      },
      Nexus::OutputFormat.new(type: "json_schema", name: nil, schema: {}, strict: nil),
    ]
    invalid_values.each do |output_format|
      result = resolve(
        workload: "text_generation", configuration: { output_format: output_format }
      )
      assert_equal :invalid_generation_parameter, result.refusal
    end
  end

  test "unsupported parameters and values are typed refusals" do
    tools = resolve(
      workload: "text_generation",
      configuration: { tools: [{ name: "shell" }] }
    )
    dimensions = resolve(workload: "embedding", configuration: { dimensions: 4 })
    count = resolve(workload: "image_generation", configuration: { result_count: 5 })

    assert_equal :unsupported_generation_parameter, tools.refusal
    assert_equal :unsupported_generation_value, dimensions.refusal
    assert_equal :invalid_generation_parameter, count.refusal
  end

  test "effective configuration cannot exceed its capability limits" do
    image_capabilities = capabilities_with_limits(
      "image_generation", "result_count" => 1
    )
    embedding_capabilities = capabilities_with_limits(
      "embedding", "embedding_dimensions" => [3]
    )

    count = ModelSelection::Workloads.normalize_configuration(
      configuration: { result_count: 4 }, capabilities: image_capabilities
    )
    dimensions = ModelSelection::Workloads.normalize_configuration(
      configuration: { dimensions: 8 }, capabilities: embedding_capabilities
    )

    assert_equal :invalid_generation_parameter, count.refusal
    assert_equal :unsupported_generation_value, dimensions.refusal
  end

  test "unsupported catalog-declared workload values are refused" do
    voice = resolve(workload: "speech_generation", configuration: { voice: "Unknown" })
    format = resolve(workload: "speech_generation", configuration: { format: "flac" })
    language = resolve(
      workload: "transcription", configuration: { language: "xx" }
    )

    assert_equal :unsupported_generation_value, voice.refusal
    assert_equal :unsupported_generation_value, format.refusal
    assert_equal :unsupported_generation_value, language.refusal
  end

  test "an incomplete or malformed selection is refused rather than guessed" do
    assert_equal :missing_model_selection, refusal_for(submitted: submission)
    assert_equal :invalid_model_selection,
      refusal_for(submitted: submission(model: "mock-text"))
    assert_equal :invalid_model_selection,
      refusal_for(submitted: submission(model: "model_selector:"))
    assert_nil refusal_for(
      submitted: submission(model: "dev/vendor/text")
    )
    assert_equal :unexpected_reasoning_effort,
      refusal_for(
        submitted: submission(model: "model_selector:fast-text", reasoning_effort: "high")
      )
  end

  test "non-text workloads reject reasoning effort" do
    %w[image_generation speech_generation transcription embedding].each do |workload|
      submitted = DevModelLane.submission_for(workload, reasoning_effort: "high")

      assert_equal :unexpected_reasoning_effort,
        refusal_for(workload: workload, submitted: submitted)
    end
  end

  # The Account is the one fact C2-2's resolver reads that no other argument
  # carries; a port that let a caller forget it would compile and then scope
  # nothing. The deployable port ignores it and still refuses.
  test "selection cannot be attempted without Account context" do
    assert_raises ArgumentError do
      ModelSelection.resolve(
        workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation")
      )
    end

    assert_raises ArgumentError do
      DevModelLane.port.resolve(
        account: nil, workload: "text_generation",
        submitted: DevModelLane.submission_for("text_generation")
      )
    end

    refused = ModelSelection.resolve(
      account: accounts(:cybros), workload: "text_generation",
      submitted: DevModelLane.submission_for("text_generation")
    )
    assert_equal :model_plane_unavailable, refused.refusal
  end

  test "an unknown workload is refused by name" do
    assert_equal :unsupported_workload,
      refusal_for(workload: "video_generation", submitted: submission(model: "dev/mock-text"))
  end

  private

    def resolve(workload:, submitted: DevModelLane.submission_for(workload), configuration: {})
      ModelSelection.resolve(
        account: accounts(:cybros), workload: workload, submitted: submitted,
        configuration: configuration, port: DevModelLane.port
      )
    end

    def refusal_for(workload: "text_generation", submitted:)
      ModelSelection::Workloads.refusal_for(workload: workload, submitted: submitted)
    end

    def capabilities_with_limits(workload, overrides)
      payload = DevModelLane.selection(workload: workload).capabilities.to_h
      payload.fetch("limits").merge!(overrides)
      Nexus::ModelCapabilitySnapshot.from_h(payload)
    end

    def submission(model: "", reasoning_effort: nil)
      Nexus::SubmittedModelSelection.new(model: model, reasoning_effort: reasoning_effort)
    end
end
