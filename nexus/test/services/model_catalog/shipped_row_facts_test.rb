require "test_helper"

# THE SHIPPED ROWS STATE THE PROVIDER'S FACTS (owner 2026-09-16: every
# 「until a capture exercises it」 gate goes). A reasoning vocabulary the
# broker's inventory or the vendor's model page documents is authored on
# the row, and so is image input; nothing here is a proof — the profile
# build and `EffectiveReasoning.derive` are fact-driven, so these read the
# rows as shipped and check that a caller's effort and an image reach the
# lane instead of refusing at selection.
class ModelCatalog::ShippedRowFactsTest < ActiveSupport::TestCase
  CATALOG = ModelCatalog::FileBase.compile(
    root: Rails.root.join("config/model_catalog"), override_dir: nil
  )

  test "the complete shipped catalog satisfies exact profile reasoning and safety authorities" do
    assert ModelCatalog.current
  end

  test "the shipped catalog projects the closed facts WP7 consumes without invented surfaces" do
    candidate = ModelCatalog::FileBase.compile(
      root: Rails.root.join("config/model_catalog"), override_dir: nil
    )
    gemini = candidate.models.fetch("gemini/gemini-3.7-flash").fetch("capabilities")
    codex = candidate.models.fetch("codex_subscription/gpt-6.1-sol").fetch("capabilities")
    speech = candidate.models.fetch(
      "openai_api/gpt-4o-mini-tts-2025-12-15"
    ).fetch("capabilities")

    assert_equal ["text"], gemini.fetch("output_modalities")
    # THE FEATURE BITS ARE THE WIRES' DEFAULTS, NOT PER-MODEL CLAIMS ON
    # EVIDENCE (owner 2026-09-16): every text lane has `tool_calls` on
    # because its protocol declares `tools`, `streaming` on because its
    # protocol parses a stream, and `prompt_caching` on because every text
    # wire caches a stable prefix (the Anthropic wire alone through the
    # kernel-placed `cache_control` breakpoints, the rest implicitly) —
    # each derived at profile build from the lowering's fact, so no
    # shipped row writes a `true` that restates its wire's default, and
    # the floor's first loop is a run, not a proof. `false` is the one
    # opt-out a row may write, for a model known not to. A model names its
    # own format or inherits the provider's.
    format_of = lambda do |ref, entry|
      entry["api_format"] ||
        candidate.providers.fetch(ref.split("/", 2).first).fetch("api_format")
    end
    profile_of = lambda do |ref, entry|
      ModelCatalog::ProfileBuilder.call(
        model_ref: ref, provider: candidate.providers.fetch(ref.split("/", 2).first), model: entry
      )
    end
    text_models, other_models = candidate.models.partition do |ref, entry|
      SimpleInference::ApiFormat.workload(format_of.call(ref, entry)) == "text_generation"
    end
    assert text_models.any?, "the pin is vacuous without shipped text lanes"
    assert(candidate.models.none? do |_ref, entry|
      %w[tool_calls streaming prompt_caching].any? { |key| entry.fetch("capabilities")[key] == true }
    end, "a shipped row never restates its wire's default")
    floor = candidate.models.fetch("deepseek/deepseek-flash")
    refute floor.fetch("capabilities").key?("tool_calls"), "the direct DeepSeek row is silent"
    assert profile_of.call("deepseek/deepseek-flash", floor).capability_enabled?("tool_calls"),
      "and its profile has tools on, from the wire"
    assert profile_of.call("deepseek/deepseek-flash", floor).capability_enabled?("prompt_caching"),
      "and prompt caching on, from the wire: it caches implicitly, with nothing for the kernel to mark"
    refute ModelRequests::WireLowering.carries_cache_breakpoints?(format_of.call("deepseek/deepseek-flash", floor))
    assert(other_models.none? { |_ref, entry| entry.fetch("capabilities")["tool_calls"] },
      "and no image/speech/embedding lane claims a surface it does not have")
    anthropic = candidate.models.select { |ref, entry| format_of.call(ref, entry) == "anthropic_messages" }
    assert anthropic.any?, "the shipped Anthropic cohort"
    anthropic.each do |ref, entry|
      profile = profile_of.call(ref, entry)
      assert profile.capability_enabled?("prompt_caching"), "#{ref}: prompt caching from the wire, with no line in the row"
      assert ModelRequests::WireLowering.carries_cache_breakpoints?(format_of.call(ref, entry)),
        "#{ref}: and the breakpoints the kernel places are this wire's"
      assert_equal %w[json_schema], profile.generation_parameters.fetch("output_format").allowed_values,
        "#{ref}: structured output from the wire, json_schema alone, with no descriptor in the row"
      assert_nil profile.generation_parameters.fetch("output_format").default
    end
    assert codex.key?("limits")
    assert speech.key?("limits")

    # ROUTING POLICY IS A DEPLOYMENT DECISION: which models to try and in what order is not
    # something this repository can be right about, so it ships no selector at all.
    assert_empty candidate.selectors
  end

  test "Sol 6.1 replaces Sol on the direct lanes with its own rates and reasoning vocabulary" do
    %w[openai_api codex_subscription].each do |provider|
      ref = "#{provider}/gpt-6.1-sol"
      refute CATALOG.models.key?("#{provider}/gpt-6-sol")
      profile = shipped_profile(ref)
      assert_equal "gpt-6.1-sol", profile.model_pin
      assert profile.capability_enabled?("tool_calls")

      reasoning = shipped_reasoning(ref)
      assert_equal %w[low medium high xhigh max], reasoning.fetch("efforts")
      assert_equal "medium", reasoning.fetch("default_effort")
      %w[none minimal].each do |effort|
        _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, effort)
        assert_equal :unsupported_reasoning_effort, refusal
      end

      rates = CATALOG.models.fetch(ref).dig("pricing", "schedule", "rates")
      assert_equal({ "input_per_mtok" => "2", "cached_input_per_mtok" => "0.1",
                     "cache_write_per_mtok" => "2.5", "output_per_mtok" => "10" },
        rates.slice("input_per_mtok", "cached_input_per_mtok", "cache_write_per_mtok", "output_per_mtok"))
      assert_equal 128_000, profile.local_safety_limits.output_tokens
    end

    rates = CATALOG.models.fetch("openai_api/gpt-6.1-sol").dig("pricing", "schedule", "rates")
    assert_equal "272000", rates.fetch("long_context_threshold_tokens")
    assert_equal "2", rates.fetch("long_context_input_multiplier")
    assert_equal "1.5", rates.fetch("long_context_output_multiplier")
    assert CATALOG.models.key?("openrouter/openai/gpt-6-sol:exacto"), "the broker has its own model identity"
  end

  # The broker's `/api/v1/models` inventory lists `reasoning` on every text
  # row here, with the upstream's own default enabled: an effort-less turn
  # selects that default (nothing rides the wire), and an effort the
  # inventory names is a member of the row's vocabulary.
  test "the broker rows carry the inventory's reasoning vocabulary" do
    %w[
      openrouter/deepseek/deepseek-v4.1-flash openrouter/z-ai/glm-5.3-flash
      openrouter/z-ai/glm-5.3 openrouter/moonshotai/kimi-k3
    ].each do |model_ref|
      reasoning = shipped_reasoning(model_ref)
      refute_nil reasoning, "#{model_ref} states no reasoning vocabulary"

      selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
      assert_nil refusal, "#{model_ref} refuses an effort-less turn"
      assert_nil selected.effort, "#{model_ref} would send an effort the caller never chose"

      _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, "high")
      assert_nil refusal, "#{model_ref} refuses the inventory's `high`"
    end
  end

  test "the broker's flash GLM row accepts image input against the wire's register" do
    profile = shipped_profile("openrouter/z-ai/glm-5.3-flash")

    assert_equal %w[image], profile.input_modalities
    assert profile.input_media.key?("image"), "the openrouter_chat image register bounds the upload"
  end

  # The vendor's model pages: adaptive thinking with `effort` on the whole
  # Claude 5 family, text and images in; fable-5-1 (the references'
  # default Fable model, alignment 2026-09-16 F14) beside them. Opus 5.5
  # defaults to `medium` where the rest of the family defaults to `high`
  # (platform.claude.com/docs/en/build-with-claude/effort, read 2026-09-26).
  test "the Anthropic rows state the family's thinking vocabulary and vision" do
    _selected, refusal = Nexus::EffectiveReasoning.derive(shipped_reasoning("anthropic/claude-sonnet-5"), "low")
    assert_nil refusal, "claude-sonnet-5 refuses an in-family effort"
    _selected, refusal = Nexus::EffectiveReasoning.derive(shipped_reasoning("anthropic/claude-fable-5-1"), "max")
    assert_nil refusal, "claude-fable-5-1 refuses the page's `max`"
    selected, refusal = Nexus::EffectiveReasoning.derive(shipped_reasoning("anthropic/claude-opus-5-5"), nil)
    assert_nil refusal, "claude-opus-5-5 refuses an effort-less turn"
    assert_equal "medium", selected.effort, "an effort-less turn runs at the vendor's default"

    %w[anthropic/claude-opus-5-5 anthropic/claude-sonnet-5 anthropic/claude-fable-5 anthropic/claude-fable-5-1].each do |model_ref|
      assert_equal %w[image], shipped_profile(model_ref).input_modalities, "#{model_ref} refuses images"
    end
  end

  # THE OUTPUT CEILING RIDES AS `max_tokens` (F1): the Messages protocol
  # refuses a request without `max_output_tokens`, and both references send
  # the model's limit, so every Anthropic row states it as the control's
  # default (128,000, the vendor's max output) — a plain turn carries it.
  # The fable-5-1 row's two wire facts (F10/F11), which the opus-5-5 row
  # shares (the vendor's Opus 5.5 pages, read 2026-09-26: thinking blocks
  # prefix-bound as on Fable 5.1, no Priority Tier), and the family's
  # mid-conversation system fact reach the profile's wire options.
  test "the Anthropic rows default max_output_tokens to the vendor's ceiling and state their wire facts" do
    %w[anthropic/claude-opus-5-5 anthropic/claude-fable-5 anthropic/claude-fable-5-1 anthropic/claude-sonnet-5].each do |ref|
      parameter = shipped_profile(ref).generation_parameters.fetch("max_output_tokens")
      assert_equal 128_000, parameter.default, "#{ref}: a plain turn must carry the ceiling"
      assert_equal 128_000, parameter.maximum
    end
    %w[anthropic/claude-opus-5-5 anthropic/claude-fable-5 anthropic/claude-fable-5-1].each do |ref|
      assert_equal true, shipped_profile(ref).wire_option(:mid_conversation_system), "#{ref}: role: system is a wire message"
    end
    assert_nil shipped_profile("anthropic/claude-sonnet-5").wire_option(:mid_conversation_system), "not on Sonnet 5 (the vendor)"
    %w[anthropic/claude-fable-5-1 anthropic/claude-opus-5-5].each do |ref|
      assert_equal "drop_block", shipped_profile(ref).wire_option(:thinking_binding), ref
      assert_empty shipped_profile(ref).service_tiers, "#{ref}: Priority Tier unsupported"
    end
    assert_nil shipped_profile("anthropic/claude-fable-5").wire_option(:thinking_binding), "scoped by model id"
  end

  # EVERY REASONING ROW REPLAYS IN ITS WIRE'S OWN FIELD: a row that reasons
  # declares the native shape its wire takes back — Anthropic's thinking
  # blocks, the Responses items, Gemini's thought parts, the chat message's
  # reasoning field on the broker, DeepSeek's plain-text reasoning item —
  # and the kernel's default replays all of it. No row falls back to a
  # fence in content, which a vendor that ignores old reasoning cannot
  # ignore and which is billed as words on every request.
  test "every shipped reasoning row declares a native replay format and replays every turn" do
    rows = CATALOG.models.select { |_ref, entry| entry.dig("capabilities", "reasoning") }
    assert_operator rows.length, :>=, 25, "the sweep reads the shipped reasoning rows"
    rows.each do |ref, entry|
      capability = Nexus::ReasoningReplayCapability.from_h(entry.dig("capabilities", "reasoning_replay"))
      refute_equal "none", capability.format, "#{ref} replays nothing"
      assert_includes Nexus::ReasoningReplayCapability::NATIVE_FORMATS, capability.format, ref
    end
    %w[openrouter/moonshotai/kimi-k3 openrouter/z-ai/glm-5.3 openrouter/qwen/qwen3.8-max-0902:exacto].each do |ref|
      assert_equal "chat_reasoning", replay_format(ref), ref
    end
    %w[deepseek/deepseek-flash deepseek/deepseek-v4-pro].each do |ref|
      assert_equal "responses_reasoning_text", replay_format(ref), ref
    end
  end

  # THE LANES THAT REFUSE A TOOL ROUND WITHOUT ITS REASONING say so: DeepSeek with tools ("the
  # reasoning_content of all previous turns should be passed back", else a 400) on its own API and
  # through the broker, and Kimi K3 ("add the complete assistant message"). A fallback into one of
  # them stands on a history of tool rounds another model produced.
  test "the lanes that need every tool round's reasoning back declare it, and no other row does" do
    required = CATALOG.models.select do |_ref, entry|
      Nexus::ReasoningReplayCapability.from_h(entry.dig("capabilities", "reasoning_replay")).required_for_tool_rounds
    end
    assert_equal %w[
      deepseek/deepseek-flash deepseek/deepseek-v4-pro openrouter/deepseek/deepseek-v4-pro-0813
      openrouter/deepseek/deepseek-v4.1-flash openrouter/moonshotai/kimi-k3
    ], required.keys.sort
  end

  # The OpenAI API rows ask the service to render every earlier turn's
  # reasoning items, since the kernel replays them all — the codex rows'
  # knob, authored as the request's rather than as a vendor default.
  test "the GPT-6 API rows ask for every turn's reasoning to be rendered" do
    %w[openai_api/gpt-6.1-sol openai_api/gpt-6-luna openai_api/gpt-6-astra].each do |ref|
      reasoning = shipped_reasoning(ref)
      assert_equal %w[all_turns], reasoning.fetch("contexts"), ref
      selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
      assert_nil refusal, ref
      assert_equal "all_turns", selected.context_policy, ref
    end
  end

  # xAI's price doubles past 200k input (`long_context_threshold_tokens`),
  # so the row plans against the step, as the OpenAI rows plan against theirs.
  test "the xAI rows plan against their price step" do
    %w[xai/grok-4.6 xai/grok-4.7].each do |ref|
      assert_equal 199_999, CATALOG.models.fetch(ref).dig("capabilities", "limits", "effective_input_tokens"), ref
    end
  end

  # gpt-6-astra on both OpenAI lanes (F15): the page's five efforts (no `none`), text and images in
  # on the API row; each lane's own default (the API's stated default `medium`, Codex's stated
  # `low`); the tiers each source declares; `text.verbosity` as a stated row default on every gpt
  # row of both lanes (F21) so a plain turn carries `low`.
  test "the astra rows state each lane's own defaults, and every gpt row a verbosity" do
    %w[openai_api/gpt-6-astra codex_subscription/gpt-6-astra].each do |ref|
      reasoning = shipped_reasoning(ref)
      assert_equal %w[low medium high xhigh max], reasoning.fetch("efforts"), ref
      _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, "xhigh")
      assert_nil refusal, "#{ref} refuses the page's `xhigh`"
    end
    assert_equal "medium", shipped_reasoning("openai_api/gpt-6-astra").fetch("default_effort")
    assert_equal "low", shipped_reasoning("codex_subscription/gpt-6-astra").fetch("default_effort")
    assert_equal %w[image], shipped_profile("openai_api/gpt-6-astra").input_modalities
    assert_equal %w[image], shipped_profile("codex_subscription/gpt-6-astra").input_modalities
    assert_equal %w[flex priority], shipped_profile("openai_api/gpt-6-astra").service_tiers
    assert_equal %w[priority], shipped_profile("codex_subscription/gpt-6-astra").service_tiers

    %w[
      openai_api/gpt-6-astra openai_api/gpt-6.1-sol openai_api/gpt-6-luna
      codex_subscription/gpt-6-astra codex_subscription/gpt-6.1-sol codex_subscription/gpt-6-luna
    ].each do |ref|
      verbosity = shipped_profile(ref).generation_parameters.fetch("verbosity")
      assert_equal "low", verbosity.default, "#{ref}: a plain turn carries text.verbosity low"
      assert_equal %w[low medium high], verbosity.allowed_values, ref
    end
  end

  # The image rows (F17/F18/F23): the two 2.5 snapshots and the codex-named
  # gpt-image-2 take an image in (the edits route), answer an image, and
  # the codex lane's image row rides the codex base with its marker.
  test "the image rows take an image in and the codex image row carries the codex marker" do
    %w[
      openai_api/gpt-image-2-2026-04-21 openai_api/gpt-image-2.5-sunburst-2026-09-08
      openai_api/gpt-image-2.5-flare-2026-09-08 codex_subscription/gpt-image-2
    ].each do |ref|
      profile = shipped_profile(ref)
      assert_equal "openai_images", profile.adapter_profile, ref
      assert_equal %w[image], profile.input_modalities, "#{ref} refuses an edit's source image"
      assert_equal %w[image], profile.output_modalities, ref
      assert profile.input_media.key?("image"), "#{ref}: the wire's image register bounds the upload"
    end
    codex = shipped_profile("codex_subscription/gpt-image-2")
    assert_equal "codex_cli_rs", codex.wire_option(:originator)
    assert_equal "/images/generations", codex.wire_option(:images_path)
    assert_equal "/images/edits", codex.wire_option(:images_edits_path)
    assert_equal "json", codex.wire_option(:images_edits_encoding)
    assert_nil shipped_profile("openai_api/gpt-image-2.5-flare-2026-09-08").wire_option(:originator), "a plain row carries no marker"
  end

  # The broker's inventory of 2026-09-16 lists `qwen/qwen3.8-max-0902`, not
  # the bare `qwen3.8-max`: the row is re-pinned to the id the inventory
  # carries and now states the facts that read carries (vision, reasoning).
  test "the qwen3.8-max row is pinned to the broker's dated id" do
    refute CATALOG.models.key?("openrouter/qwen/qwen3.8-max:exacto"), "the bare id is not in the inventory"
    profile = shipped_profile("openrouter/qwen/qwen3.8-max-0902:exacto")
    assert_equal %w[image], profile.input_modalities
    _selected, refusal = Nexus::EffectiveReasoning.derive(shipped_reasoning("openrouter/qwen/qwen3.8-max-0902:exacto"), nil)
    assert_nil refusal, "an effort-less turn selects the broker's default"
  end

  # The vendor's model pages for the gpt-6.1-sol and gpt-6-luna tiers (read
  # 2026-09-26): reasoning effort on the Responses wire, text and images in;
  # the same tiers on the Codex subscription wire carry the same vocabulary
  # the wire knows.
  test "the gpt-6.1-sol and gpt-6-luna rows state the vendor's reasoning and vision on both wires" do
    %w[
      openai_api/gpt-6.1-sol openai_api/gpt-6-luna
      codex_subscription/gpt-6.1-sol codex_subscription/gpt-6-luna
    ].each do |model_ref|
      _selected, refusal = Nexus::EffectiveReasoning.derive(shipped_reasoning(model_ref), "high")
      assert_nil refusal, "#{model_ref} refuses the vendor's `high`"
    end

    %w[
      openai_api/gpt-6.1-sol openai_api/gpt-6-luna
      codex_subscription/gpt-6.1-sol codex_subscription/gpt-6-luna
    ].each do |model_ref|
      assert_equal %w[image], shipped_profile(model_ref).input_modalities, "#{model_ref} refuses images"
    end
  end

  # THE PRICE STEP IS THE PLANNING BOUND on the GPT-6 API rows: past
  # 272,000 input tokens every input class bills 2x and output 1.5x for the
  # whole request (the model pages, read 2026-09-26), so the kernel fits and
  # compacts to 272,000 there — the figure Codex's own models.json plans to
  # on the same models — while the 1,050,000 window stays the hard bound.
  test "the gpt-6 API and broker rows plan to the long-context price step" do
    %w[openai_api/gpt-6-astra openai_api/gpt-6.1-sol openai_api/gpt-6-luna openrouter/openai/gpt-6-sol:exacto].each do |model_ref|
      limits = CATALOG.models.fetch(model_ref).dig("capabilities", "limits")
      rates = CATALOG.models.fetch(model_ref).dig("pricing", "schedule", "rates")
      assert_equal 272_000, limits.fetch("effective_input_tokens"), model_ref
      assert_equal rates.fetch("long_context_threshold_tokens").to_i, limits.fetch("effective_input_tokens"), model_ref
      assert_equal 1_050_000, limits.fetch("combined_input_output_tokens"), model_ref
    end
  end

  # THE TWO SCORING ROWS AGAINST THE BROKER'S CARDS (C-1, `/api/v1/models`
  # read 2026-09-17): `z-ai/glm-5.3` lists `input_modalities` text alone,
  # so the row declares no image ingress and the kernel's index line
  # stands in for a PNG; `moonshotai/kimi-k3` lists text, image and video,
  # a 1 048 576 window, 943 718 max completion, and the card's per-token
  # prices are 0.000003 / 0.000015 / 0.0000003 — per million, the
  # fallback rates the row carries (the 2026-09-13 headline was one
  # endpoint's 2.648138063 / 13.28272425 / 0.30264435; the card moved).
  test "the glm-5.3 and kimi-k3 rows state the broker's cards of 2026-09-17" do
    glm = shipped_profile("openrouter/z-ai/glm-5.3")
    assert_equal [], glm.input_modalities, "the broker lists text alone for z-ai/glm-5.3"
    assert_equal 1_310_720, glm.local_safety_limits.input_tokens

    kimi = shipped_profile("openrouter/moonshotai/kimi-k3")
    assert_equal %w[image], kimi.input_modalities, "the broker lists image for moonshotai/kimi-k3"
    assert kimi.input_media.key?("image"), "the openrouter_chat image register bounds the upload"
    assert_equal 1_048_576, kimi.local_safety_limits.input_tokens
    assert_equal 943_718, kimi.local_safety_limits.output_tokens

    rates = CATALOG.models.fetch("openrouter/moonshotai/kimi-k3").dig("pricing", "schedule", "rates")
    assert_equal(
      { "input_per_mtok" => "3", "output_per_mtok" => "15", "cached_input_per_mtok" => "0.3" },
      rates, "kimi-k3's fallback rates are the card's per-million prices"
    )
  end

  # GROK 4.6 AND THE IMAGE ROW AGAINST THE SAME PAGES (read 2026-09-27): the
  # grok-4.6 detail page states grok-4.7's figures — $0.50 cached, the 200k
  # tier at 2x, priority at 2x — which the row had not carried; the pricing
  # page now lists grok-imagine-image-2.0 at $0.04 an image.
  test "the grok-4.6 and image rows carry the rates xAI's pages state" do
    schedule = CATALOG.models.fetch("xai/grok-4.6").dig("pricing", "schedule")
    assert_equal(
      { "input_per_mtok" => "2", "output_per_mtok" => "6", "cached_input_per_mtok" => "0.5",
        "long_context_threshold_tokens" => "199999",
        "long_context_input_multiplier" => "2", "long_context_output_multiplier" => "2" },
      schedule.fetch("rates")
    )
    assert_equal({ "priority" => "2" }, schedule.fetch("tier_multipliers"))
    image = CATALOG.models.fetch("xai/grok-imagine-image-2.0").dig("pricing", "schedule", "rates")
    assert_equal({ "per_image" => "0.04" }, image)
  end

  # GROK 4.7 AGAINST xAI's PAGES (docs.x.ai/developers/models/grok-4.7 and
  # …/developers/pricing, read 2026-09-27): $2 input, $0.50 cached, $6
  # output per million; a prompt that REACHES 200,000 tokens bills every
  # class at 2x; priority 2x on every token type; a 500,000-token window
  # and no stated output ceiling (the platform's 128,000 cap); text and
  # image in; reasoning always on at low, medium, high (the default) or
  # xhigh. grok-4.6 stays: nothing retires it.
  test "the grok-4.7 row states xAI's rates, window, cap and efforts" do
    assert CATALOG.models.key?("xai/grok-4.6"), "no deprecation retires grok-4.6"
    schedule = CATALOG.models.fetch("xai/grok-4.7").dig("pricing", "schedule")
    assert_equal "provider_reported_then_catalog_fallback", schedule.fetch("kind")
    assert_equal(
      { "input_per_mtok" => "2", "output_per_mtok" => "6", "cached_input_per_mtok" => "0.5",
        "long_context_threshold_tokens" => "199999",
        "long_context_input_multiplier" => "2", "long_context_output_multiplier" => "2" },
      schedule.fetch("rates")
    )
    assert_equal({ "priority" => "2" }, schedule.fetch("tier_multipliers"))

    profile = shipped_profile("xai/grok-4.7")
    assert_equal %w[xai_responses grok-4.7], [profile.adapter_profile, profile.model_pin]
    assert_equal %w[image], profile.input_modalities
    assert_empty profile.service_tiers, "the lane sends no tier; the multiplier prices an echo"
    limits = CATALOG.models.fetch("xai/grok-4.7").dig("capabilities", "limits")
    assert_equal({ "combined_input_output_tokens" => 500_000, "effective_input_tokens" => 199_999,
                   "output_tokens" => 128_000 }, limits, "the window, the price step it plans to, the cap")

    reasoning = shipped_reasoning("xai/grok-4.7")
    assert_equal %w[low medium high xhigh], reasoning.fetch("efforts")
    selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
    assert_nil refusal
    assert_equal "high", selected.effort, "an effort-less turn runs at the vendor's default"
    _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, "none")
    assert_equal :unsupported_reasoning_effort, refusal, "reasoning cannot be disabled"
    assert_equal "responses_reasoning", CATALOG.models.fetch("xai/grok-4.7").dig("capabilities", "reasoning_replay", "format")
  end

  private

    def shipped_reasoning(model_ref)
      CATALOG.models.fetch(model_ref).dig("capabilities", "reasoning")
    end

    def replay_format(model_ref)
      CATALOG.models.fetch(model_ref).dig("capabilities", "reasoning_replay", "format")
    end

    def shipped_profile(model_ref)
      provider_id = model_ref.split("/", 2).first
      ModelCatalog::ProfileBuilder.call(
        model_ref: model_ref,
        provider: CATALOG.providers.fetch(provider_id),
        model: CATALOG.models.fetch(model_ref)
      )
    end
end
