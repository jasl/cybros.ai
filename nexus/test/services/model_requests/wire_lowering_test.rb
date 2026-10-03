require "test_helper"

# C2-4 WP-A: the crossing between Nexus's semantic vocabulary and a lane's
# wire spelling. The entry gate found this layer missing entirely — Nexus
# persisted semantic keys while the gem's seam raises on anything outside its
# own `request_option_keys`, and nothing owned the translation.
class ModelRequests::WireLoweringTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
  end

  # The contract that keeps the table honest: every wire name it produces
  # must be a kwarg the lane's own protocol declares. Without this the table
  # could name a key the gem raises on, and the failure would arrive at the
  # provider boundary instead of here.
  #
  # EVERY FORMAT THE GEM SHIPS LOWERS ITS CONTROLS. A row is written from
  # the protocol's own `request_option_keys` (the `codex_responses` row is
  # the Responses row minus `max_output_tokens`, which its declaration
  # subtracts), never from a witnessed call: a format without a row would
  # refuse every declared control `uncarriable_generation_parameter` before
  # any provider call, and the walk below only covers the dev lane's
  # `openai_*` profiles — which is exactly how a real OpenRouter turn was once
  # refused a `max_output_tokens` its own protocol declares.
  test "every format the gem ships has a lowering row" do
    assert_equal SimpleInference::ApiFormat::FORMATS.sort, ModelRequests::WireLowering::TABLE.keys.sort
  end

  test "the codex_responses row is the Responses row minus the control its protocol subtracts" do
    codex = ModelRequests::WireLowering::TABLE.fetch("codex_responses")
    responses = ModelRequests::WireLowering::TABLE.fetch("openai_responses")

    assert_equal responses.fetch(:options).except("max_output_tokens"), codex.fetch(:options)
    assert_empty codex.fetch(:arguments)
    refute_includes ModelRequests::WireLowering.declared_wire_keys("codex_responses"), :max_output_tokens
  end

  # THE WIRES' DEFAULTS (owner 2026-09-16): whether a lane offers
  # structured output, places cache breakpoints or streams is the
  # protocol's fact, read here and nowhere else — the catalog derives the
  # capability for a silent row from these three predicates.
  test "structured output is carried by every text wire whose protocol declares response_format" do
    SimpleInference::ApiFormat::FORMATS.each do |adapter_profile|
      text = SimpleInference::ApiFormat.workload(adapter_profile) == "text_generation"
      declares = ModelRequests::WireLowering.declared_wire_keys(adapter_profile)
        .include?(ModelRequests::WireLowering::OUTPUT_FORMAT_WIRE_KEY)
      carries = ModelRequests::WireLowering.carries_output_format?(adapter_profile)

      assert_equal text && declares, carries, adapter_profile
      # The table and the predicate name the same wires: a synthesized
      # descriptor on a lane the table cannot lower would refuse itself.
      assert_equal carries,
        ModelRequests::WireLowering::TABLE.fetch(adapter_profile).fetch(:options).key?("output_format"),
        "#{adapter_profile}: the table maps output_format iff the wire carries it"
      assert_equal carries, ModelRequests::WireLowering::ALLOWED_OUTPUT_FORMATS.key?(adapter_profile),
        "#{adapter_profile}: the allowed kinds are inventoried iff the wire carries it"
    end
    # A speech or image lane declares `response_format` for its container;
    # that is not a structured output.
    refute ModelRequests::WireLowering.carries_output_format?("openai_audio_speech")
    refute ModelRequests::WireLowering.carries_output_format?("openai_images")
  end

  test "every allowed output kind is one the grammar can normalize" do
    ModelRequests::WireLowering::ALLOWED_OUTPUT_FORMATS.each do |adapter_profile, kinds|
      assert kinds.any?, adapter_profile
      assert_empty kinds - %w[text json_object json_schema], "#{adapter_profile} names an unknown kind"
    end
    assert_equal %w[json_schema], ModelRequests::WireLowering.allowed_output_formats("anthropic_messages")
  end

  test "cache breakpoints are the anthropic_messages wire's alone" do
    SimpleInference::ApiFormat::FORMATS.each do |adapter_profile|
      assert_equal adapter_profile == "anthropic_messages",
        ModelRequests::WireLowering.carries_cache_breakpoints?(adapter_profile), adapter_profile
    end
  end

  # PROMPT CACHING IS EVERY TEXT WIRE'S PROPERTY (owner 2026-09-16): the
  # provider caches a stable prefix on every text lane — explicitly marked
  # on the one breakpoint wire, implicitly everywhere else — and no other
  # workload has a prompt to cache. The breakpoint predicate above is the
  # narrower fact Build places by.
  test "prompt caching is carried by every text wire and no other" do
    SimpleInference::ApiFormat::FORMATS.each do |adapter_profile|
      text = SimpleInference::ApiFormat.workload(adapter_profile) == "text_generation"
      assert_equal text, ModelRequests::WireLowering.carries_prompt_caching?(adapter_profile), adapter_profile
    end
    assert ModelRequests::WireLowering.carries_prompt_caching?("openai_responses")
    assert ModelRequests::WireLowering.carries_prompt_caching?("deepseek_responses")
    refute ModelRequests::WireLowering.carries_prompt_caching?("openai_images")
  end

  # The gem states the same fact twice — the lane's declared `streaming`
  # capability and the protocol's public streaming entry point — and the
  # predicate reads the parser; this pins that the two never disagree.
  test "streaming is carried by every wire whose protocol has a streaming parser" do
    SimpleInference::ApiFormat::FORMATS.each do |adapter_profile|
      lane_streams = SimpleInference::ApiFormat.defaults(adapter_profile).fetch(:capabilities).include?("streaming")

      assert_equal lane_streams, ModelRequests::WireLowering.carries_streaming?(adapter_profile), adapter_profile
    end
    assert ModelRequests::WireLowering.carries_streaming?("codex_responses")
    refute ModelRequests::WireLowering.carries_streaming?("openai_embeddings")
  end

  # THE TWO RESPONSES CONTROLS THE REFERENCES CARRY (alignment audit F20,
  # F21): `service_tier` and `text.verbosity` are declared on both the
  # Responses and the codex protocol and lower on both rows; a lane whose
  # protocol never declared them refuses the control, as every row does.
  test "service_tier and verbosity lower on both Responses rows and nowhere the wire lacks them" do
    %w[openai_responses codex_responses].each do |adapter_profile|
      options = ModelRequests::WireLowering::TABLE.fetch(adapter_profile).fetch(:options)
      assert_equal :service_tier, options.fetch("service_tier"), adapter_profile
      assert_equal :verbosity, options.fetch("verbosity"), adapter_profile
    end

    verbosity = Nexus::EffectiveGenerationConfig.new(values: { verbosity: "low" }.freeze)
    lowered = ModelRequests::WireLowering.lower(
      adapter_profile: "codex_responses", generation_config: verbosity
    )
    assert_predicate lowered, :accepted?
    assert_equal({ verbosity: "low" }, lowered.options)
    refused = ModelRequests::WireLowering.lower(
      adapter_profile: "anthropic_messages", generation_config: verbosity
    )
    assert_equal ModelRequests::WireLowering::REFUSAL, refused.refusal
  end

  # CODEX'S RULE, VERBATIM (protocol/src/openai_models.rs
  # service_tier_for_request): a tier is sent only when it is neither
  # absent nor `default` AND the row declares it; an undeclared tier is
  # refused before IO rather than guessed at. Never a default of ours.
  test "a service tier lowers by codex's rule: omitted when default, refused when the row never declared it" do
    lower = lambda do |tier, declared|
      ModelRequests::WireLowering.lower_service_tier(
        adapter_profile: "codex_responses", tier: tier, service_tiers: declared
      )
    end

    assert_empty lower.call(nil, %w[priority]).options
    assert_empty lower.call("default", %w[priority]).options
    assert_equal({ service_tier: "priority" }, lower.call("priority", %w[priority]).options)
    assert_equal ModelRequests::WireLowering::SERVICE_TIER_REFUSAL, lower.call("flex", %w[priority]).refusal
    assert_equal ModelRequests::WireLowering::SERVICE_TIER_REFUSAL, lower.call("priority", []).refusal
    # A lane without the row cannot carry any tier: the table's own refusal.
    unmapped = ModelRequests::WireLowering.lower_service_tier(
      adapter_profile: "anthropic_messages", tier: "priority", service_tiers: %w[priority]
    )
    assert_equal ModelRequests::WireLowering::REFUSAL, unmapped.refusal
  end

  # THE PROMPT CACHE KEY IS TWO WIRES' PROPERTY (F4): OpenAI routes its
  # prefix cache by `prompt_cache_key` on the Responses and the codex lanes
  # (codex-rs client.rs prompt_cache_key, opencode transform.ts
  # promptCacheKey); the compatible dialect stays out until a provider is
  # known to honour it, and every other family keys on nothing.
  test "the prompt cache key is carried by the two Responses wires alone" do
    SimpleInference::ApiFormat::FORMATS.each do |adapter_profile|
      assert_equal %w[openai_responses codex_responses].include?(adapter_profile),
        ModelRequests::WireLowering.carries_cache_key?(adapter_profile), adapter_profile
    end
  end

  # The anthropic row's `thinking_binding` is a WIRE-OPTION fact (F10): a
  # construction keyword the protocol lowers into
  # `thinking.block_binding.prefix_mismatch_behavior`, stated by the row's
  # `wire_options` — never a generation control a caller could send.
  test "the anthropic row states thinking_binding as a wire option its protocol constructs from" do
    assert_includes SimpleInference::Protocols::AnthropicMessages.protocol_option_keys, :thinking_binding
    refute ModelRequests::WireLowering::TABLE.fetch("anthropic_messages").fetch(:options).key?("thinking_binding"),
      "a wire option is the row's fact, not a request control"
  end

  # An edit's source images are the image lane's one new parameter (F23):
  # a row in the table, lowered 1:1 onto the gem's `images:`.
  test "the image row lowers an edit's images" do
    assert_equal :images,
      ModelRequests::WireLowering::TABLE.fetch("openai_images").fetch(:options).fetch("images")
  end

  # A LOCALLY REJECTED OPTION IS DECLARED AND STILL UNMAPPABLE, which is the
  # one way the "declared kwarg" test above can pass while the lane is broken:
  # Gemini declares temperature/top_p/top_k/n and then refuses them, citing
  # Google's register that they are deprecated or removed here. Mapping one
  # would offer a caller a control guaranteed to fail at the protocol.
  test "no row maps an option its protocol rejects locally" do
    ModelRequests::WireLowering::TABLE.each do |adapter_profile, lane|
      protocol = SimpleInference::ApiFormat::PROTOCOL_CLASSES.fetch(adapter_profile)
      next unless protocol.const_defined?(:LOCALLY_REJECTED_OPTIONS)

      offered = lane.fetch(:options).values & protocol.const_get(:LOCALLY_REJECTED_OPTIONS)
      assert_empty offered,
        "#{adapter_profile} maps #{offered.join(", ")}, which its own protocol refuses"
    end
  end

  test "every mapped wire name is a kwarg its protocol actually declares" do
    ModelRequests::WireLowering::TABLE.each do |adapter_profile, lane|
      declared = ModelRequests::WireLowering.declared_wire_keys(adapter_profile)

      excess = lane.fetch(:options).values - declared
      assert_empty excess,
        "#{adapter_profile} maps to #{excess.join(", ")}, which its protocol would refuse"
      # An ARGUMENT is passed by name to the seam method, so it must NOT be
      # in the option vocabulary — that is exactly what makes it an argument.
      collision = lane.fetch(:arguments).values & declared
      assert_empty collision,
        "#{adapter_profile} treats #{collision.join(", ")} as an argument, but its protocol declares it as an option"
    end
  end

  # The converse, and the direction that was missing: a control a SHIPPED
  # profile declares must resolve to a row in the table. Without it a lane
  # could offer a caller a control the table has never heard of, and every
  # request on that lane would be refused `uncarriable_generation_parameter`
  # before any provider call — a lane broken for everyone, discovered by its
  # first user.
  #
  # It is NOT vacuous: seven registry profiles declare controls today — the
  # shipped speech lane's `voice` and six dev-lane profiles — so this walks
  # real declarations. (No shipped CATALOG fragment declares any, which is a
  # different statement about a different file.)
  test "every control a shipped lane declares resolves to a table row" do
    DevModelLane.each_catalog_profile do |profile|
      declared = profile.generation_parameters.keys
      next if declared.empty?

      lane = ModelRequests::WireLowering::TABLE[profile.adapter_profile] || {}
      known = lane.fetch(:options, {}).keys.map(&:to_s) + lane.fetch(:arguments, {}).keys.map(&:to_s)
      unmapped = declared.map(&:to_s) - known
      assert_empty unmapped,
        "#{profile.profile_id} offers #{unmapped.join(", ")}, which nothing can lower to its wire"
    end
  end

  test "semantic controls lower to their lane's wire names" do
    selection = DevModelLane.selection(
      workload: "text_generation", account: @account,
      configuration: { temperature: 0.4, max_output_tokens: 512 }
    )

    result = ModelRequests::WireLowering.lower(
      adapter_profile: selection.execution_profile.adapter_profile,
      generation_config: selection.generation_config
    )

    assert_predicate result, :accepted?
    assert_equal 0.4, result.options.fetch(:temperature)
    assert_equal 512, result.options.fetch(:max_output_tokens)
    # The semantic name never survives the crossing.
    refute result.options.key?(:output_format)
  end

  test "a structured control renders its own wire form" do
    selection = DevModelLane.selection(
      workload: "text_generation", account: @account,
      configuration: { output_format: { type: "json_object" } }
    )

    result = ModelRequests::WireLowering.lower(
      adapter_profile: selection.execution_profile.adapter_profile,
      generation_config: selection.generation_config
    )

    assert_predicate result, :accepted?
    assert_equal({ type: "json_object" }, result.options.fetch(:response_format))
  end

  test "each non-text lane lowers its own declared controls" do
    {
      "image_generation" => [{ result_count: 2 }, :n],
      # `voice` is the speech seam's required ARGUMENT, not an option.
      "speech_generation" => [{ voice: "Puck" }, :voice],
      "transcription" => [{ language: "zh" }, :language],
      "embedding" => [{ dimensions: 8 }, :dimensions],
    }.each do |workload, (configuration, wire_key)|
      selection = DevModelLane.selection(
        workload: workload, account: @account, configuration: configuration
      )

      result = ModelRequests::WireLowering.lower(
        adapter_profile: selection.execution_profile.adapter_profile,
        generation_config: selection.generation_config
      )

      assert_predicate result, :accepted?, "#{workload}: #{result.refusal.inspect}"
      carried = result.options.merge(result.arguments)
      assert carried.key?(wire_key), "#{workload} must lower to #{wire_key}"
    end
  end

  # A control the catalog offered and the wire cannot carry is an authoring
  # error. It is refused rather than dropped, because a silently missing
  # control is a request the caller did not ask for.
  test "an uncarriable semantic control refuses instead of vanishing" do
    config = Nexus::EffectiveGenerationConfig.new(values: { seed: 7 }.freeze)

    result = ModelRequests::WireLowering.lower(
      adapter_profile: "openai_responses", generation_config: config
    )

    refute_predicate result, :accepted?
    assert_equal ModelRequests::WireLowering::REFUSAL, result.refusal
  end

  test "a lane with no mapped controls carries none" do
    empty = Nexus::EffectiveGenerationConfig.new(values: {}.freeze)

    result = ModelRequests::WireLowering.lower(
      adapter_profile: "anthropic_messages", generation_config: empty
    )

    assert_predicate result, :accepted?
    assert_empty result.options
  end

  # C2-4 WP-D. Reasoning has no table row because it needs none: the name is
  # the gem's own normalized control, and each protocol lowers it further
  # inside itself. This pins that the name really is declared wherever a text
  # lane ships, so asking the protocol is a sound substitute for a table.
  test "every text lane declares the one reasoning name this layer lowers to" do
    text_lanes = DevModelLane.each_catalog_profile
      .select { |profile| profile.workload == "text_generation" }
      .map(&:adapter_profile).uniq

    text_lanes.each do |adapter_profile|
      assert_includes ModelRequests::WireLowering.declared_wire_keys(adapter_profile),
        ModelRequests::WireLowering::REASONING_WIRE_KEY,
        "#{adapter_profile} would refuse the reasoning name at the seam"
    end
  end

  test "a selected effort lowers, and an unselected one omits the field" do
    selection = DevModelLane.selection(
      workload: "text_generation", account: @account, reasoning_effort: "low"
    )

    carried = ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: selection.execution_profile.adapter_profile,
      effort: selection.reasoning.effort
    )
    absent = ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: "openai_responses", effort: nil
    )

    assert_equal "low", carried.options.fetch(ModelRequests::WireLowering::REASONING_WIRE_KEY)
    assert_predicate absent, :accepted?
    assert_empty absent.options
  end

  # The row's reasoning context rides beside the effort on a wire whose
  # vocabulary names contexts, and nowhere else: a Responses row that asks
  # for every turn's reasoning to be rendered says so on every request.
  test "a row's reasoning context lowers beside the effort on a wire that has contexts" do
    carried = ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: "openai_responses", effort: "medium", context: "all_turns"
    )
    assert_equal({ reasoning_effort: "medium", reasoning: { context: "all_turns" } }, carried.options)

    assert_equal({ reasoning_effort: "high" }, ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: "anthropic_messages", effort: "high", context: "all_turns"
    ).options, "a wire with no contexts never carries one")
    assert_equal({ reasoning_effort: "none" }, ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: "openai_responses", effort: "none", context: "all_turns"
    ).options, "reasoning off renders nothing, so no context rides")
    assert_empty ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: "openai_responses", effort: nil, context: "all_turns"
    ).options, "the provider's default governs an unselected effort, context and all"
  end

  # Same rule as every other control: a lane that cannot carry a selection
  # refuses it rather than sending a request the caller did not ask for.
  test "an effort a lane cannot carry refuses instead of vanishing" do
    result = ModelRequests::WireLowering.lower_reasoning(
      adapter_profile: "openai_embeddings", effort: "low"
    )

    refute_predicate result, :accepted?
    assert_equal ModelRequests::WireLowering::REFUSAL, result.refusal
  end
end
