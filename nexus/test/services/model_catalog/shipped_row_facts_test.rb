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

  test "every shipped effort vocabulary has a valid default and thinking is independently enabled" do
    CATALOG.models.each do |ref, entry|
      reasoning = entry.dig("capabilities", "reasoning")
      next if reasoning.nil? || reasoning.empty?

      selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
      assert_nil refusal, ref
      assert_equal true, selected.enabled, ref
      if reasoning.key?("efforts")
        refute_includes reasoning.fetch("efforts"), "none", ref
        assert_includes reasoning.fetch("efforts"), reasoning.fetch("default_effort"), ref
      else
        assert_nil selected.effort, "#{ref}: a switch-only model invents no effort"
      end
      disabled, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil, enabled: false)
      assert_nil refusal, ref
      assert_equal !reasoning.fetch("disable_supported", false), disabled.enabled, ref
    end
  end

  test "catalog effort defaults follow the selected family policy and explicit exceptions" do
    {
      "high" => %w[anthropic/claude-fable-5-2 anthropic/claude-opus-5-5 anthropic/claude-sonnet-5-5
        anthropic/claude-haiku-5-5 openrouter/anthropic/claude-fable-5.2 openrouter/anthropic/claude-opus-5.5
        openrouter/anthropic/claude-sonnet-5.5 openrouter/anthropic/claude-haiku-5.5
        openrouter/qwen/qwen4-max openrouter/qwen/qwen4-max:exacto],
      "medium" => %w[openai_api/gpt-6.2-astra openai_api/gpt-6.2-sol openai_api/gpt-6.1-terra
        codex_subscription/gpt-6.2-astra codex_subscription/gpt-6.2-sol codex_subscription/gpt-6.1-terra
        openrouter/openai/gpt-6.2-sol openrouter/openai/gpt-6.2-astra openrouter/openai/gpt-6.1-terra],
      "low" => %w[deepseek/deepseek-flash deepseek/deepseek-v4-pro openrouter/moonshotai/kimi-k3.1-pro
        openrouter/deepseek/deepseek-v4.1-flash-1017 openrouter/deepseek/deepseek-v4-pro-0813
        openrouter/z-ai/glm-5.3 openrouter/z-ai/glm-5.3-flash openrouter/tencent/hy4],
    }.each do |effort, refs|
      refs.each { |ref| assert_equal effort, shipped_reasoning(ref).fetch("default_effort"), ref }
    end
  end

  test "the shipped catalog projects the closed facts WP7 consumes without invented surfaces" do
    candidate = ModelCatalog::FileBase.compile(
      root: Rails.root.join("config/model_catalog"), override_dir: nil
    )
    codex = candidate.models.fetch("codex_subscription/gpt-6.2-sol").fetch("capabilities")
    speech = candidate.models.fetch(
      "openai_api/gpt-4o-mini-tts-2025-12-15"
    ).fetch("capabilities")

    assert_equal ["text"], shipped_profile("gemini/gemini-4-hydrogen").output_modalities
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

  test "OpenAI routes use the current model pins and list rates" do
    rates_by_model = {
      "gpt-6.2-astra" => %w[8 0.4 10 20 40],
      "gpt-6.2-sol" => %w[2 0.1 2.5 5 10],
      "gpt-6.1-terra" => %w[1 0.05 1.25 2.5 5],
    }
    rates_by_model.each do |name, (input, cached, write, long_write, output)|
      %w[openai_api codex_subscription].each do |provider|
        ref = "#{provider}/#{name}"
        profile = shipped_profile(ref)
        assert_equal name, profile.model_pin
        assert profile.capability_enabled?("tool_calls"), ref
        assert_equal 128_000, profile.local_safety_limits.output_tokens, ref
        rates = CATALOG.models.fetch(ref).dig("pricing", "schedule", "rates")
        assert_equal [input, cached, write, output],
          rates.values_at("input_per_mtok", "cached_input_per_mtok", "cache_write_per_mtok", "output_per_mtok"), ref
      end

      ref = "openai_api/#{name}"
      rates = CATALOG.models.fetch(ref).dig("pricing", "schedule", "rates")
      assert_equal [long_write, "272000", "2", "1.5"], rates.values_at("cache_write_12h_per_mtok",
        "long_context_threshold_tokens", "long_context_input_multiplier", "long_context_output_multiplier"), ref
      reasoning = shipped_reasoning(ref)
      assert_equal %w[low medium high xhigh max], reasoning.fetch("efforts"), ref
      %w[none minimal].each do |effort|
        _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, effort)
        assert_equal :unsupported_reasoning_effort, refusal, ref
      end
      off, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil, enabled: false)
      assert_nil refusal, ref
      assert_equal name != "gpt-6.1-terra", off.enabled, ref
    end

    %w[openai_api codex_subscription].each do |provider|
      %w[gpt-6-astra gpt-6-sol gpt-6.1-sol gpt-6-luna].each do |retired|
        refute CATALOG.models.key?("#{provider}/#{retired}")
      end
    end
  end

  test "the four shipped Gemini 4 profiles expose their serving limits, reasoning defaults and cache prices" do
    models = {
      "gemini-4-argon" => %w[medium 2 10 0.1],
      "gemini-4-carbon" => %w[medium 2 10 0.1],
      "gemini-4-hydrogen" => %w[high 1.5 7.5 0.075],
      "gemini-4-neon" => %w[high 3 15 0.15],
    }
    assert_equal models.keys, CATALOG.model_definitions.keys.grep(/\Agemini-/).sort
    assert_equal models.keys.map { |name| "gemini/#{name}" }, CATALOG.models.keys.grep(%r{\Agemini/}).sort

    models.each do |name, (effort, input_price, output_price, cache_price)|
      ref = "gemini/#{name}"
      profile = shipped_profile(ref)
      entry = CATALOG.models.fetch(ref)
      assert_equal name, profile.model_pin
      assert_equal %w[image file], profile.input_modalities, ref
      assert_equal({ "combined_input_output_tokens" => 1_048_576, "output_tokens" => 65_536 },
        entry.dig("capabilities", "limits"), ref)
      assert_equal effort, shipped_reasoning(ref).fetch("default_effort"), ref
      assert_equal({ "input_per_mtok" => input_price, "output_per_mtok" => output_price, "cached_input_per_mtok" => cache_price },
        entry.dig("pricing", "schedule", "rates"), ref)
    end
  end

  # The broker supplies capability vocabulary; catalog policy selects low
  # for these open-weight models when the caller omits an effort.
  test "the broker rows carry the inventory's reasoning vocabulary" do
    %w[
      openrouter/deepseek/deepseek-v4.1-flash-1017 openrouter/z-ai/glm-5.3-flash
      openrouter/z-ai/glm-5.3 openrouter/moonshotai/kimi-k3.1-pro
    ].each do |model_ref|
      reasoning = shipped_reasoning(model_ref)
      refute_nil reasoning, "#{model_ref} states no reasoning vocabulary"

      selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil)
      assert_nil refusal, "#{model_ref} refuses an effort-less turn"
      assert_equal "low", selected.effort, "#{model_ref} uses the catalog effort default"

      _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, "high")
      assert_nil refusal, "#{model_ref} refuses the inventory's `high`"
    end
  end

  test "the broker's flash GLM row accepts image input against the wire's register" do
    profile = shipped_profile("openrouter/z-ai/glm-5.3-flash")

    assert_equal %w[image], profile.input_modalities
    assert profile.input_media.key?("image"), "the openrouter_chat image register bounds the upload"
  end

  test "the four direct Claude models support adaptive thinking, PDFs and the Messages output ceiling" do
    models = %w[claude-fable-5-2 claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5]
    assert_equal models.sort, CATALOG.models.keys.grep(%r{\Aanthropic/}).map { |ref| ref.delete_prefix("anthropic/") }.sort

    models.each do |model|
      ref = "anthropic/#{model}"
      profile = shipped_profile(ref)
      reasoning = shipped_reasoning(ref)
      assert_equal %w[low medium high xhigh max], reasoning.fetch("efforts"), ref
      assert_equal %w[image file], profile.input_modalities, ref
      assert_equal 1_000_000, profile.local_safety_limits.input_tokens, ref
      parameter = profile.generation_parameters.fetch("max_output_tokens")
      assert_equal 128_000, parameter.default, ref
      assert_equal 128_000, parameter.maximum, ref
      assert_equal true, profile.wire_option(:mid_conversation_system), ref
      assert_equal "drop_block", profile.wire_option(:thinking_binding), ref
      assert_empty profile.service_tiers, ref

      modes = model == "claude-sonnet-5-5" ? %w[adaptive between_tools] : %w[adaptive]
      assert_equal modes, profile.reasoning_option_values(:modes), ref
      off, refusal = Nexus::EffectiveReasoning.derive(reasoning, nil, enabled: false)
      assert_nil refusal, ref
      assert_equal model != "claude-haiku-5-5", off.enabled, ref
      if model == "claude-haiku-5-5"
        assert_nil profile.wire_option(:forced_tool_choice), ref
      else
        assert_equal false, profile.wire_option(:forced_tool_choice), ref
      end
    end
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
    %w[openrouter/moonshotai/kimi-k3.1-pro openrouter/z-ai/glm-5.3 openrouter/qwen/qwen4-max:exacto].each do |ref|
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
      deepseek/deepseek-flash deepseek/deepseek-v4-pro
      kimi_code/k3.1-pro kimi_code/k3.1-pro-highspeed
      moonshot/kimi-k3.1-pro moonshot/kimi-k3.1-pro-highspeed
      moonshot_global/kimi-k3.1-pro moonshot_global/kimi-k3.1-pro-highspeed
      openrouter/deepseek/deepseek-v4-pro-0813
      openrouter/deepseek/deepseek-v4.1-flash-1017 openrouter/moonshotai/kimi-k3.1-pro
    ], required.keys.sort
  end

  # The OpenAI API rows ask the service to render every earlier turn's
  # reasoning items, since the kernel replays them all — the codex rows'
  # knob, authored as the request's rather than as a vendor default.
  test "the GPT-6 API rows ask for every turn's reasoning to be rendered" do
    %w[openai_api/gpt-6.2-sol openai_api/gpt-6.1-terra openai_api/gpt-6.2-astra].each do |ref|
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

  # gpt-6.2-astra on both OpenAI lanes (F15): the page's five efforts (no `none`), text and images in
  # on the API row; medium as the catalog default on both lanes; the tiers each source
  # declares; `text.verbosity` as a stated row default on every gpt
  # row of both lanes (F21) so a plain turn carries `low`.
  test "the astra rows select medium, and every gpt row states a verbosity" do
    %w[openai_api/gpt-6.2-astra codex_subscription/gpt-6.2-astra].each do |ref|
      reasoning = shipped_reasoning(ref)
      assert_equal %w[low medium high xhigh max], reasoning.fetch("efforts"), ref
      _selected, refusal = Nexus::EffectiveReasoning.derive(reasoning, "xhigh")
      assert_nil refusal, "#{ref} refuses the page's `xhigh`"
    end
    assert_equal "medium", shipped_reasoning("openai_api/gpt-6.2-astra").fetch("default_effort")
    assert_equal "medium", shipped_reasoning("codex_subscription/gpt-6.2-astra").fetch("default_effort")
    assert_equal %w[image file], shipped_profile("openai_api/gpt-6.2-astra").input_modalities
    assert_equal %w[image], shipped_profile("codex_subscription/gpt-6.2-astra").input_modalities
    assert_equal %w[priority fast ultrafast], shipped_profile("openai_api/gpt-6.2-astra").service_tiers
    assert_equal %w[priority ultrafast], shipped_profile("codex_subscription/gpt-6.2-astra").service_tiers

    %w[
      openai_api/gpt-6.2-astra openai_api/gpt-6.2-sol openai_api/gpt-6.1-terra
      codex_subscription/gpt-6.2-astra codex_subscription/gpt-6.2-sol codex_subscription/gpt-6.1-terra
    ].each do |ref|
      verbosity = shipped_profile(ref).generation_parameters.fetch("verbosity")
      assert_equal "low", verbosity.default, "#{ref}: a plain turn carries text.verbosity low"
      assert_equal %w[low medium high], verbosity.allowed_values, ref
    end
  end

  # The image rows (F17/F18/F23): the two 2.6 models and the codex-named
  # gpt-image-2 take an image in (the edits route), answer an image, and
  # the codex lane's image row rides the codex base with its marker.
  test "the image rows take an image in and the codex image row carries the codex marker" do
    %w[
      openai_api/gpt-image-2.6-sunburst
      openai_api/gpt-image-2.6-flare codex_subscription/gpt-image-2
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
    refute codex.generation_parameters.key?("complexity")
    %w[gpt-image-2.6-flare gpt-image-2.6-sunburst].each do |name|
      api = shipped_profile("openai_api/#{name}")
      assert_nil api.wire_option(:originator)
      complexity = api.generation_parameters.fetch("complexity")
      assert_equal %w[low medium high], complexity.allowed_values
      assert_nil complexity.default
    end
  end

  test "Qwen4 Max and its quality-sorted route accept image input and optional thinking" do
    %w[qwen4-max qwen4-max:exacto].each do |name|
      ref = "openrouter/qwen/#{name}"
      assert_equal "qwen/#{name}", shipped_profile(ref).model_pin
      assert_equal %w[image], shipped_profile(ref).input_modalities
      assert_equal %w[low high xhigh], shipped_reasoning(ref).fetch("efforts")
      assert shipped_reasoning(ref).fetch("disable_supported")
    end
  end

  test "the broker exposes current OpenAI, Claude and Gemini routes on its chat wire" do
    {
      "openai" => %w[gpt-6.2-astra gpt-6.2-sol gpt-6.1-terra],
      "anthropic" => %w[claude-fable-5.2 claude-opus-5.5 claude-sonnet-5.5 claude-haiku-5.5],
      "google" => %w[gemini-4-argon gemini-4-carbon gemini-4-hydrogen gemini-4-neon],
    }.each do |vendor, models|
      prefix = "openrouter/#{vendor}/"
      assert_equal models.sort, CATALOG.models.keys.filter_map { |ref| ref.delete_prefix(prefix) if ref.start_with?(prefix) }.sort
      models.each do |model|
        ref = "#{prefix}#{model}"
        profile = shipped_profile(ref)
        assert_equal "#{vendor}/#{model}", profile.model_pin, ref
        assert_equal "openrouter_chat", profile.adapter_profile, ref
        assert_equal ["image"], profile.input_modalities, ref
        assert_equal "chat_reasoning", replay_format(ref), ref
        assert profile.capability_enabled?("tool_calls"), ref
        disabled, = Nexus::EffectiveReasoning.derive(shipped_reasoning(ref), nil, enabled: false)
        assert_equal !%w[claude-haiku-5.5 gpt-6.1-terra].include?(model), disabled.enabled, ref
      end
    end
  end

  test "the gpt-6.2-sol and gpt-6.1-terra rows state the vendor's reasoning and vision on both wires" do
    %w[
      openai_api/gpt-6.2-sol openai_api/gpt-6.1-terra
      codex_subscription/gpt-6.2-sol codex_subscription/gpt-6.1-terra
    ].each do |model_ref|
      _selected, refusal = Nexus::EffectiveReasoning.derive(shipped_reasoning(model_ref), "high")
      assert_nil refusal, "#{model_ref} refuses the vendor's `high`"
    end

    { "openai_api" => %w[image file], "codex_subscription" => %w[image] }.each do |provider, modalities|
      %w[gpt-6.2-sol gpt-6.1-terra].each do |model|
        model_ref = "#{provider}/#{model}"
        assert_equal modalities, shipped_profile(model_ref).input_modalities, model_ref
      end
    end
  end

  # THE PRICE STEP IS THE PLANNING BOUND on the GPT-6 API rows: past
  # 272,000 input tokens every input class bills 2x and output 1.5x for the
  # whole request (the model pages, read 2026-09-26), so the kernel fits and
  # compacts to 272,000 there — the figure Codex's own models.json plans to
  # on Astra. Sol and Terra have separate subscription planning bounds.
  test "the gpt-6 API and broker rows plan to the long-context price step" do
    %w[openai_api/gpt-6.2-astra openai_api/gpt-6.2-sol openai_api/gpt-6.1-terra openrouter/openai/gpt-6.2-sol openrouter/openai/gpt-6.2-astra openrouter/openai/gpt-6.1-terra].each do |model_ref|
      limits = CATALOG.models.fetch(model_ref).dig("capabilities", "limits")
      rates = CATALOG.models.fetch(model_ref).dig("pricing", "schedule", "rates")
      assert_equal 272_000, limits.fetch("effective_input_tokens"), model_ref
      assert_equal rates.fetch("long_context_threshold_tokens").to_i, limits.fetch("effective_input_tokens"), model_ref
      assert_equal 922_000, limits.fetch("input_tokens"), model_ref
      assert_equal 128_000, limits.fetch("output_tokens"), model_ref
    end
  end

  test "GLM and Kimi expose their broker context windows and image support" do
    glm = shipped_profile("openrouter/z-ai/glm-5.3")
    assert_equal [], glm.input_modalities, "the broker lists text alone for z-ai/glm-5.3"
    assert_equal 1_048_576, CATALOG.models.fetch("openrouter/z-ai/glm-5.3").dig("capabilities", "limits", "combined_input_output_tokens")

    kimi = shipped_profile("openrouter/moonshotai/kimi-k3.1-pro")
    assert_equal %w[image], kimi.input_modalities, "the broker lists image for moonshotai/kimi-k3.1-pro"
    assert kimi.input_media.key?("image"), "the openrouter_chat image register bounds the upload"
    assert_equal 1_048_576, CATALOG.models.fetch("openrouter/moonshotai/kimi-k3.1-pro").dig("capabilities", "limits", "combined_input_output_tokens")
    assert_equal 943_718, kimi.local_safety_limits.output_tokens

    rates = CATALOG.models.fetch("openrouter/moonshotai/kimi-k3.1-pro").dig("pricing", "schedule", "rates")
    assert_equal(
      { "input_per_mtok" => "0.253", "output_per_mtok" => "8.8", "cached_input_per_mtok" => "0.18" },
      rates, "Kimi's fallback rates are the card's per-million prices"
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
  # and no stated output ceiling; text and
  # image in; reasoning always on at low, medium, high (the default) or
  # xhigh. grok-4.6 stays: nothing retires it.
  test "the grok-4.7 row states xAI's rates, window and efforts without inventing an output ceiling" do
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
    assert_equal({ "combined_input_output_tokens" => 500_000, "effective_input_tokens" => 199_999 },
      limits, "the shared window and input planning threshold are independent of the optional output control")
    parameter = profile.generation_parameters.fetch("max_output_tokens")
    assert_nil parameter.default, "omission leaves xAI's 128,000 default to the provider"
    assert_nil parameter.maximum, "the provider default is not a hard ceiling"

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
