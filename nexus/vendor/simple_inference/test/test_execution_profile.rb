require_relative "test_helper"

# The audited execution-profile value object is fail-closed by construction:
# every fact is explicit, unknown vocabulary raises, and the per-profile
# total_execution_deadline must be a positive, finite, bounded duration —
# rejected at construction, before any credential/file read or network IO.
class TestExecutionProfile < Minitest::Test
  def valid_attributes
    {
      profile_id: "openai_api.openai_responses.text_generation.v1",
      provider_id: "openai_api",
      adapter_profile: "openai_responses",
      protocol_route: "responses_http_sse",
      workload: "text_generation",
      model_pin: "gpt-6-sol",
      credential_lane: "api_key",
      total_execution_deadline_seconds: 600,
      primary_execution_pair: {
        execution_host_kind: "model_runner", http_transport_kind: "async_http",
      },
      allowed_execution_pairs: [
        { execution_host_kind: "model_runner", http_transport_kind: "async_http" },
        { execution_host_kind: "solid_queue", http_transport_kind: "httpx" },
      ],
      capabilities: %w[streaming tool_calls reasoning],
      input_modalities: %w[image],
      output_modalities: %w[text],
      generation_parameters: {
        max_output_tokens: {
          kind: "integer", default: 128, minimum: nil, maximum: nil, allowed_values: [128],
        },
      },
      wire_options: { responses_path: "/v1/responses" },
    }
  end

  # The second time axis. Undeclared lanes take the lesser of the release
  # ceiling and half their own exchange budget, which is what keeps the two
  # numbers coherent instead of merely both present.
  def test_stream_idle_timeout_defaults_under_the_exchange_budget
    assert_equal 120, build(total_execution_deadline_seconds: 600).stream_idle_timeout_seconds
    assert_equal 60, build(total_execution_deadline_seconds: 120).stream_idle_timeout_seconds
    assert_equal 5.0, build(total_execution_deadline_seconds: 10).stream_idle_timeout_seconds
  end

  def test_stream_idle_timeout_accepts_a_lane_that_declares_its_own
    assert_equal 300, build(stream_idle_timeout_seconds: 300,
                            total_execution_deadline_seconds: 3600).stream_idle_timeout_seconds
  end

  # A silence bound at or past the whole deadline can never fire, so a lane
  # declaring one would believe it had a watchdog and have none.
  def test_rejects_an_idle_timeout_that_can_never_fire
    [600, 601].each do |value|
      error = assert_raises(SimpleInference::ConfigurationError) do
        build(stream_idle_timeout_seconds: value, total_execution_deadline_seconds: 600)
      end
      assert_includes error.message, "can never fire"
    end
  end

  def test_rejects_a_non_positive_or_non_finite_idle_timeout
    [0, -1, Float::INFINITY, Float::NAN].each do |value|
      assert_raises(SimpleInference::ConfigurationError) { build(stream_idle_timeout_seconds: value) }
    end
    assert_raises(SimpleInference::ConfigurationError) { build(stream_idle_timeout_seconds: "120") }
  end

  def build(**overrides)
    SimpleInference::ExecutionProfile.new(**valid_attributes.merge(overrides))
  end

  def test_builds_and_freezes_a_valid_profile
    profile = build

    assert_predicate profile, :frozen?
    assert_predicate profile.capabilities, :frozen?
    assert_predicate profile.input_modalities, :frozen?
    assert_predicate profile.output_modalities, :frozen?
    assert_predicate profile.service_tiers, :frozen?
    assert_predicate profile.generation_parameters, :frozen?
    assert_predicate profile.primary_execution_pair, :frozen?
    assert_predicate profile.allowed_execution_pairs, :frozen?
    assert profile.allowed_execution_pairs.all?(&:frozen?)
    assert_predicate profile.wire_options, :frozen?
    assert_equal "openai_api", profile.provider_id
    assert_equal 600, profile.total_execution_deadline_seconds
    assert_predicate profile.reasoning_options, :frozen?
    assert_predicate profile.local_safety_limits, :frozen?
    assert_nil profile.native_cost_contract
  end

  # --- total_execution_deadline: missing/zero/negative/non-finite/overflow all
  # reject the profile at construction time (zero IO by construction). ---

  def test_rejects_nil_deadline
    error = assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: nil) }
    assert_match(/total_execution_deadline/, error.message)
  end

  def test_rejects_zero_deadline
    assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: 0) }
  end

  def test_rejects_negative_deadline
    assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: -5) }
  end

  def test_rejects_infinite_deadline
    assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: Float::INFINITY) }
  end

  def test_rejects_nan_deadline
    assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: Float::NAN) }
  end

  def test_rejects_overflowed_deadline_beyond_release_bound
    max = SimpleInference::ExecutionProfile::MAX_TOTAL_EXECUTION_DEADLINE_SECONDS
    assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: max + 1) }
    assert_equal max, build(total_execution_deadline_seconds: max).total_execution_deadline_seconds
  end

  def test_rejects_non_numeric_deadline
    assert_raises(SimpleInference::ConfigurationError) { build(total_execution_deadline_seconds: "600") }
  end

  # --- closed vocabularies ---

  def test_rejects_unknown_workload
    assert_raises(SimpleInference::ConfigurationError) { build(workload: "video_generation") }
  end

  def test_rejects_unknown_adapter_profile
    assert_raises(SimpleInference::ConfigurationError) { build(adapter_profile: "mystery_adapter") }
  end

  def test_rejects_unknown_protocol_route
    assert_raises(SimpleInference::ConfigurationError) { build(protocol_route: "carrier_pigeon") }
  end

  def test_multipart_is_derived_from_the_validated_protocol_route
    refute_predicate build, :multipart?
    assert_predicate build(protocol_route: "audio_transcriptions_http_multipart"), :multipart?
  end

  def test_rejects_unknown_credential_lane
    assert_raises(SimpleInference::ConfigurationError) { build(credential_lane: "password") }
  end

  def test_accepts_the_credentialless_lane
    assert_equal "none", build(credential_lane: "none").credential_lane
  end

  # The two generation-contract shapes: enumerated, and range-typed numeric
  # (nil allowed_values). String-family kinds must enumerate — a free-text
  # control is not a reviewable contract — and a range-typed default must
  # fall inside its own range.
  def test_range_typed_generation_contracts
    ranged = build(generation_parameters: {
      temperature: { kind: "number", default: 1.0, minimum: 0.0, maximum: 2.0, allowed_values: nil },
    })
    assert_nil ranged.generation_parameters.fetch("temperature").allowed_values

    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: {
        voice: { kind: "string", default: nil, minimum: nil, maximum: nil, allowed_values: nil },
      })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: {
        temperature: { kind: "number", default: 3.0, minimum: 0.0, maximum: 2.0, allowed_values: nil },
      })
    end
  end

  def test_rejects_blank_identity_fields
    assert_raises(SimpleInference::ConfigurationError) { build(profile_id: " ") }
    assert_raises(SimpleInference::ConfigurationError) { build(provider_id: "") }
    assert_raises(SimpleInference::ConfigurationError) { build(model_pin: nil) }
    assert_raises(SimpleInference::ConfigurationError) { build(model_pin: " gpt-6-sol ") }
  end

  def test_execution_pairs_are_closed_and_primary_must_be_allowed
    illegal = { execution_host_kind: "model_runner", http_transport_kind: "httpx" }
    unknown = { execution_host_kind: "puma", http_transport_kind: "httpx" }
    runner = { execution_host_kind: "model_runner", http_transport_kind: "async_http" }
    job = { execution_host_kind: "solid_queue", http_transport_kind: "httpx" }

    assert_raises(SimpleInference::ConfigurationError) do
      build(primary_execution_pair: illegal)
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(primary_execution_pair: unknown)
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(primary_execution_pair: runner, allowed_execution_pairs: [job])
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(allowed_execution_pairs: [runner, runner])
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(allowed_execution_pairs: [])
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(primary_execution_pair: runner.merge(extra: "authority"))
    end
  end

  def test_execution_pair_validation_does_not_freeze_caller_owned_values
    primary = { execution_host_kind: "model_runner", http_transport_kind: "async_http" }
    allowed = [primary]
    profile = build(primary_execution_pair: primary, allowed_execution_pairs: allowed)

    refute_predicate primary, :frozen?
    refute_predicate allowed, :frozen?
    allowed << { execution_host_kind: "solid_queue", http_transport_kind: "httpx" }
    assert_equal [profile.primary_execution_pair], profile.allowed_execution_pairs
  end

  # --- capabilities are fail-closed: absent means disabled, unknown names are
  # rejected in the declaration AND in the query (a typo'd gate can never
  # silently return an open or closed answer for a capability that does not
  # exist). ---

  def test_capability_absent_means_disabled
    profile = build(capabilities: [])

    refute profile.capability_enabled?("streaming")
    refute profile.streaming?
  end

  def test_capability_present_means_enabled
    profile = build(capabilities: %w[streaming])

    assert profile.capability_enabled?("streaming")
    assert profile.streaming?
  end

  def test_rejects_unknown_capability_in_declaration
    assert_raises(SimpleInference::ConfigurationError) { build(capabilities: %w[telepathy]) }
  end

  def test_rejects_duplicate_capability_declaration
    assert_raises(SimpleInference::ConfigurationError) { build(capabilities: %w[streaming streaming]) }
  end

  def test_rejects_unknown_capability_in_query
    assert_raises(ArgumentError) { build.capability_enabled?("telepathy") }
  end

  # STRUCTURED OUTPUT IS NOT A CAPABILITY WORD (owner 2026-09-16): it is a
  # wire's `response_format` declaration, offered through the profile's
  # `output_format` generation parameter — the word never reached a
  # reader, so a profile that declares it is a typo'd fact, refused.
  def test_rejects_the_retired_structured_output_word
    refute_includes SimpleInference::ExecutionProfile::CAPABILITIES, "structured_output"
    assert_raises(SimpleInference::ConfigurationError) { build(capabilities: %w[structured_output]) }
    assert_raises(ArgumentError) { build.capability_enabled?("structured_output") }
  end

  # --- input modalities are fail-closed: empty means text-only. ---

  def test_empty_modalities_mean_no_media_input
    profile = build(input_modalities: [])

    refute profile.input_modality_enabled?("image")
  end

  def test_declared_modality_is_enabled
    profile = build(input_modalities: %w[image])

    assert profile.input_modality_enabled?("image")
    refute profile.input_modality_enabled?("audio")
  end

  def test_rejects_unknown_modality_in_declaration
    assert_raises(SimpleInference::ConfigurationError) { build(input_modalities: %w[smell]) }
  end

  def test_rejects_unknown_modality_in_query
    assert_raises(ArgumentError) { build.input_modality_enabled?("smell") }
  end

  def test_output_modalities_are_closed_and_fail_closed
    assert_equal %w[text], build.output_modalities
    assert_empty build(output_modalities: []).output_modalities
    assert_raises(SimpleInference::ConfigurationError) do
      build(output_modalities: %w[hologram])
    end
  end

  def test_service_tiers_are_exact_profile_values
    profile = build(service_tiers: %w[standard priority])

    assert_equal %w[standard priority], profile.service_tiers
    assert_raises(SimpleInference::ConfigurationError) do
      build(service_tiers: ["standard", "standard"])
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(service_tiers: [" standard"])
    end
  end

  def test_generation_parameters_are_closed_typed_and_frozen
    profile = build
    parameter = profile.generation_parameters.fetch("max_output_tokens")

    assert_equal "integer", parameter.kind
    assert_equal 128, parameter.default
    assert_equal [128], parameter.allowed_values
    assert_predicate parameter, :frozen?
    assert_predicate parameter.allowed_values, :frozen?
  end

  # `verbosity` is a reviewed name (alignment 2026-09-16, F21): the
  # Responses wire's `text.verbosity`, a string contract that enumerates
  # low, medium and high — a row states its default, never a free text.
  def test_verbosity_is_a_reviewed_string_contract
    descriptor = { kind: "string", default: "low", minimum: nil, maximum: nil, allowed_values: %w[low medium high] }
    parameter = build(generation_parameters: { verbosity: descriptor }).generation_parameters.fetch("verbosity")

    assert_equal "low", parameter.default
    assert_equal %w[low medium high], parameter.allowed_values
    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: { verbosity: descriptor.merge(allowed_values: nil) })
    end
  end

  def test_generation_parameters_reject_unreviewed_names_and_invalid_descriptors
    valid = {
      kind: "string", default: "alloy", minimum: nil, maximum: nil, allowed_values: ["alloy"],
    }

    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: { hidden_provider_knob: valid })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: { voice: valid.merge(kind: "symbol") })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: { voice: valid.merge(default: "nova") })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(generation_parameters: { voice: valid.merge(source: "guessed") })
    end
  end

  # --- wire options: closed key set, typed values. ---

  def test_rejects_unknown_wire_option
    assert_raises(SimpleInference::ConfigurationError) { build(wire_options: { hidden_retry: true }) }
  end

  def test_rejects_non_boolean_responses_lite_flag
    assert_raises(SimpleInference::ConfigurationError) { build(wire_options: { use_responses_lite: "yes" }) }
  end

  def test_rejects_path_wire_option_without_leading_slash
    assert_raises(SimpleInference::ConfigurationError) { build(wire_options: { responses_path: "v1/responses" }) }
  end

  # THE ANTHROPIC ROW FACTS (alignment 2026-09-16, F10/F11): a catalog row
  # states `thinking_binding` (a non-blank word the protocol validates
  # against its own vocabulary) and `mid_conversation_system` (a boolean)
  # under `wire_options`, and `ApiFormat.protocol_for` forwards them to the
  # protocol's construction keywords — so the profile must admit both.
  def test_admits_the_anthropic_row_facts_as_wire_options
    profile = build(wire_options: { thinking_binding: "drop_block", mid_conversation_system: true })

    assert_equal "drop_block", profile.wire_option(:thinking_binding)
    assert_equal true, profile.wire_option(:mid_conversation_system)
    assert_raises(SimpleInference::ConfigurationError) { build(wire_options: { thinking_binding: " " }) }
    assert_raises(SimpleInference::ConfigurationError) { build(wire_options: { thinking_binding: true }) }
    assert_raises(SimpleInference::ConfigurationError) { build(wire_options: { mid_conversation_system: "yes" }) }
  end

  def test_wire_option_reader_is_closed
    profile = build(wire_options: { use_responses_lite: true })

    assert_equal true, profile.wire_option(:use_responses_lite)
    assert_nil profile.wire_option(:responses_path)
    assert_raises(ArgumentError) { profile.wire_option(:hidden_retry) }
  end

  # --- unknown attributes: a typo'd profile fact never no-ops. ---

  def test_rejects_unknown_attribute
    assert_raises(ArgumentError) do
      SimpleInference::ExecutionProfile.new(**valid_attributes, optimistic_default: true)
    end
  end

  def test_reasoning_options_are_plain_declared_value_lists
    profile = build(reasoning_options: { efforts: %w[low high] })

    assert_equal %w[low high], profile.reasoning_option_values("efforts")
    assert_empty profile.reasoning_option_values("modes")
    assert_raises(ArgumentError) { profile.reasoning_option_values("intensity") }
  end

  def test_reasoning_options_reject_unknown_kinds_values_and_duplicates
    assert_raises(SimpleInference::ConfigurationError) do
      build(reasoning_options: { intensity: %w[low] })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(reasoning_options: { efforts: %w[galaxy] })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(reasoning_options: { efforts: %w[low low] })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(reasoning_options: { efforts: [] })
    end
  end

  def test_local_safety_limits_are_closed_positive_integer_facts
    dimensions = [128, 3_072]
    profile = build(
      local_safety_limits: {
        input_tokens: 1_000, output_tokens: 200, audio_duration_seconds: 90,
        embedding_dimensions: dimensions,
      }
    )

    assert_equal 90, profile.local_safety_limits.audio_duration_seconds
    assert_equal [128, 3_072], profile.local_safety_limits.embedding_dimensions
    assert_predicate profile.local_safety_limits.embedding_dimensions, :frozen?
    refute_predicate dimensions, :frozen?, "constructing a profile must not freeze caller-owned input"
    dimensions << 9_999
    assert_equal [128, 3_072], profile.local_safety_limits.embedding_dimensions
    assert_raises(SimpleInference::ConfigurationError) do
      build(local_safety_limits: { context_tokens: 1_000 })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(local_safety_limits: { input_tokens: 0 })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(local_safety_limits: { embedding_dimensions: 3_072 })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(local_safety_limits: { embedding_dimensions: [3_072, 3_072] })
    end
  end

  # --- input media facts: byte-truth allowlists bound to declared modalities ---

  def test_input_media_facts_bind_only_to_declared_modalities
    assert_raises(SimpleInference::ConfigurationError) do
      build(input_modalities: [], input_media: { "image" => { "mime_allowlist" => ["image/png"] } })
    end
  end

  def test_input_media_rejects_unknown_fact_keys_and_unknown_types
    assert_raises(SimpleInference::ConfigurationError) do
      build(input_media: { "image" => { "max_pixels" => 1 } })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(input_media: { "image" => { "mime_allowlist" => ["image/tiff"] } })
    end
    assert_raises(SimpleInference::ConfigurationError) do
      build(input_media: { "image" => { "mime_allowlist" => [] } })
    end
  end

  def test_mime_allowlist_reader_is_fail_closed
    profile = build(input_media: { "image" => { "mime_allowlist" => %w[image/png image/jpeg] } })

    assert_equal %w[image/png image/jpeg], profile.mime_allowlist("image")
    assert_nil build.mime_allowlist("image"), "no facts recorded means nothing to accept"
    assert_raises(ArgumentError) { profile.mime_allowlist("smell") }
  end

  # --- native cost: exact reviewed amount/unit/scale facts, or absent. ---

  def test_native_cost_contract_is_closed_bounded_and_frozen
    contract = {
      "amount_field" => "cost_in_usd_ticks",
      "unit" => "USD",
      "scale" => "0.0000000001",
      "maximum_wire_amount" => "999999999999999999999999999999",
      "maximum_fractional_digits" => 0,
    }

    profile = build(native_cost_contract: contract)

    assert_equal contract, profile.native_cost_contract.to_h
    assert_predicate profile.native_cost_contract, :frozen?
    assert_predicate profile.native_cost_contract.amount_field, :frozen?
  end

  def test_native_cost_contract_rejects_open_or_unbounded_shapes
    valid = {
      "amount_field" => "cost",
      "unit" => "USD",
      "scale" => "1",
      "maximum_wire_amount" => "99999999999999999999.999999999999999999",
      "maximum_fractional_digits" => 18,
    }

    [
      valid.merge("source" => "adapter-name-heuristic"),
      valid.except("amount_field"),
      valid.merge("amount_field" => " "),
      valid.merge("unit" => ""),
      valid.merge("unit" => " USD "),
      valid.merge("scale" => "1e-10"),
      valid.merge("scale" => "0"),
      valid.merge("maximum_wire_amount" => "unbounded"),
      valid.merge("maximum_fractional_digits" => 19),
      valid.merge("maximum_fractional_digits" => -1),
      valid.merge("maximum_wire_amount" => "1.55", "maximum_fractional_digits" => 1),
      valid.merge("scale" => "0.0000000001", "maximum_fractional_digits" => 9),
    ].each do |contract|
      assert_raises(SimpleInference::ConfigurationError) do
        build(native_cost_contract: contract)
      end
    end
  end

  def test_native_cost_contract_rejects_a_maximum_that_overflows_account_amount_storage
    assert_raises(SimpleInference::ConfigurationError) do
      build(native_cost_contract: {
        "amount_field" => "cost_in_usd_ticks",
        "unit" => "USD",
        "scale" => "1",
        "maximum_wire_amount" => "100000000000000000000",
        "maximum_fractional_digits" => 0,
      })
    end
  end
end
