require "test_helper"
require "tmpdir"

# C2-2 WP5: pricing. Exact-decimal rates in the configured Account unit; the unit echo is a
# precondition and never a second authority (a mismatch makes cost unknown, not a compile error);
# lanes without a provider-native total cost reject provider_reported_only — and only that kind, a
# complete catalog fallback policy stays legal there. Shipped rates are owner- reviewed manual data:
# foreign-unit conversion is an authoring-time convention, never runtime provenance machinery.
class ModelCatalog::PricingTest < ActiveSupport::TestCase
  SCHEMA = ModelCatalog::FileBase::SCHEMA_VERSION

  def write_fragment(root, models:, providers: { "openai_api" => { "base_url" => "https://api.openai.com", "api_format" => "openai_responses", "concurrency_limit" => 8 } })
    File.write(File.join(root, "10_base.yml"),
      { "schema_version" => SCHEMA, "providers" => providers, "models" => models }.to_yaml)
  end

  def text_entry(pricing = nil)
    entry = {
      "capabilities" => text_capabilities(
        limits: { "combined_input_output_tokens" => 1_050_000, "output_tokens" => 128_000 }
      ),
    }
    entry["pricing"] = pricing if pricing
    entry
  end

  # The native cost contract is the PROVIDER's, exactly as the shipped
  # fragment states it: xAI reports a total in its own integer ticks on every
  # lane it serves, and that is a fact about the vendor, not about one model.
  def xai_provider
    {
      "xai" => {
        "base_url" => "https://api.x.ai", "api_format" => "xai_responses",
        "concurrency_limit" => 8,
        "native_cost_contract" => {
          "amount_field" => "cost_in_usd_ticks", "unit" => "USD",
          "scale" => "0.0000000001",
          "maximum_wire_amount" => "999999999999999999999999999999",
          "maximum_fractional_digits" => 0,
        },
      },
    }
  end

  def xai_entry(pricing)
    {
      # Image input re-proved under grok-4.6's own 2026-08-13 capture; the
      # reasoning vocabulary was not exercised, so no reasoning claim.
      "capabilities" => text_capabilities(
        # `output_tokens` is the lane's PLATFORM cap (2026-08-17): xai
        # publishes no output ceiling, and a conservative maximum needs a
        # finite bound on both sides or the lane cannot be priced at all.
        limits: { "combined_input_output_tokens" => 500_000, "output_tokens" => 128_000 },
        input_modalities: %w[image]
      ),
      "pricing" => pricing,
    }
  end

  def non_text_entry(formula, pricing)
    {
      "api_format" => formula.fetch(:api_format),
      "capabilities" => non_text_capabilities(formula),
      "pricing" => pricing,
    }
  end

  def text_capabilities(limits:, reasoning: nil, input_modalities: ["image"])
    capabilities = {
      "input_modalities" => input_modalities,
      "output_modalities" => ["text"],
      "limits" => limits,
    }
    capabilities["reasoning"] = reasoning if reasoning
    capabilities
  end

  def non_text_capabilities(formula)
    input_modalities, output_modalities, generation_parameters = case formula.fetch(:workload)
    when "image_generation"
      [[], ["image"], {}]
    when "speech_generation"
      [[], ["audio"], {
        "voice" => {
          "kind" => "string", "default" => "alloy", "minimum" => nil,
          "maximum" => nil, "allowed_values" => ["alloy"],
        },
      }]
    when "transcription"
      [["audio"], ["text"], {}]
    when "embedding"
      [[], ["embedding"], {}]
    else
      raise ArgumentError, "unknown non-text workload #{formula.fetch(:workload).inspect}"
    end

    {
      "input_modalities" => input_modalities,
      "output_modalities" => output_modalities,
      "limits" => formula.fetch(:catalog_limits),
      "generation_parameters" => generation_parameters,
    }
  end

  # Composed the way the compiler composes it: the wire's defaults plus this
  # model's identity and bounds.
  # An image row in the shipped gpt-image row's shape, pricing supplied.
  def image_entry(pricing)
    {
      "api_format" => "openai_images",
      "capabilities" => {
        "input_modalities" => [], "output_modalities" => %w[image],
        "limits" => { "result_count" => 1 },
      },
      "pricing" => pricing,
    }
  end

  def formula_profile(formula)
    ModelCatalog::ProfileBuilder.call(
      model_ref: formula.fetch(:model_ref),
      provider: { "base_url" => "https://api.openai.com", "api_format" => "openai_responses" },
      model: { "api_format" => formula.fetch(:api_format),
               "capabilities" => { "limits" => formula.fetch(:local_limits) } }
    )
  end

  def non_text_formulas
    [
      {
        workload: "image_generation",
        model_ref: "openai_api/image",
        api_format: "openai_images",
        rate_key: "per_image",
        local_limits: { "result_count" => 4 },
        # The lane's profile declares a platform cap now (2026-08-17), so the
        # catalog must restate one — a limit the profile reviewed is required,
        # not optional.
        catalog_limits: { "result_count" => 1 },
      },
      {
        workload: "speech_generation",
        model_ref: "openai_api/speech",
        api_format: "openai_audio_speech",
        rate_key: "per_mchar",
        local_limits: { "input_bytes" => 2_000, "input_characters" => 4_096 },
        catalog_limits: { "input_bytes" => 2_000, "input_characters" => 4_096 },
      },
      {
        workload: "transcription",
        model_ref: "openai_api/transcription",
        api_format: "openai_audio_transcriptions",
        rate_key: "per_minute",
        local_limits: { "audio_duration_seconds" => 90 },
        catalog_limits: {},
      },
      {
        workload: "embedding",
        model_ref: "openai_api/embedding",
        api_format: "openai_embeddings",
        rate_key: "input_per_mtok",
        local_limits: { "input_tokens" => 8_191, "input_bytes" => 8_191 },
        catalog_limits: { "input_tokens" => 8_191, "input_bytes" => 8_191 },
      },
    ]
  end

  def compile(root)
    ModelCatalog::FileBase.compile(root: root, override_dir: nil)
  end

  def usd_pricing(rates: { "input_per_mtok" => "1.25", "output_per_mtok" => "10" })
    { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only", "rates" => rates } }
  end

  # Missing and null pricing both leave computed money absent while retaining usage.
  test "an absent pricing declaration is unmetered, exactly like an explicit null" do
    entry = { "capabilities" => {} }

    declared = ModelCatalog::EffectivePricing.project(
      entry: entry.merge("pricing" => nil), account_unit: nil
    )
    omitted = ModelCatalog::EffectivePricing.project(entry: entry, account_unit: nil)

    assert_predicate declared, :unmetered?
    assert_nil declared.account_unit, "there is no unit to echo and none is required"
    assert_empty declared.rates

    assert_equal declared, omitted,
      "billing is opt-in: saying nothing and saying " \
      "nothing-under-the-key are the same declaration"
  end

  # Unmetered is not free, and the two must never collapse into one word.
  # Known-free PROVES an all-zero formula, so a receipt may honestly say the
  # work cost nothing; unmetered proves nothing about the amount.
  test "unmetered and known-free are different claims" do
    unmetered = ModelCatalog::EffectivePricing.project(
      entry: { "pricing" => nil }, account_unit: "USD"
    )

    assert_predicate unmetered, :unmetered?
    assert_not_predicate unmetered, :known_free_candidate?
    assert_nil unmetered.source_policy, "it declares no policy because it consulted none"
  end

  # The predecessor's cache tiers, restored by the settlement review: the
  # basic text family ACCEPTS the two cache-tier rates and REQUIRES neither
  # — a schedule that authors none keeps billing every input class at the
  # input rate, and completeness is still judged on the required pair alone.
  test "the basic text family takes optional cache tiers and refuses strangers" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing(rates: {
        "input_per_mtok" => "2", "output_per_mtok" => "10",
        "cached_input_per_mtok" => "0.2", "cache_write_per_mtok" => "2.5",
      })) })
      assert compile(root)
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing(rates: {
        "input_per_mtok" => "2", "output_per_mtok" => "10", "cached_per_mtok" => "0.2",
      })) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/unknown rate keys/, error.message)
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing(rates: {
        "input_per_mtok" => "2", "cached_input_per_mtok" => "0.2",
      })) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/incomplete rate formula omits output_per_mtok/, error.message)
    end
  end

  # THE SECOND WRITE TIER AND THE LONG-CONTEXT TIER (alignment audit F9,
  # F19): Anthropic publishes a 1-hour write rate beside the 5-minute one,
  # and the gpt-6-astra page prices prompts over 272K input at multipliers
  # (2x input and cache, 1.5x output) — stated as multipliers, so a second
  # copy of every rate cannot go stale. The triple is all-or-none and the
  # threshold a positive whole number.
  test "the basic text family takes the 1-hour write rate and the long-context triple, all or none" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing(rates: {
        "input_per_mtok" => "10", "output_per_mtok" => "50",
        "cached_input_per_mtok" => "1", "cache_write_per_mtok" => "12.5", "cache_write_1h_per_mtok" => "20",
        "long_context_threshold_tokens" => "272000",
        "long_context_input_multiplier" => "2", "long_context_output_multiplier" => "1.5",
      })) })
      assert compile(root)
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing(rates: {
        "input_per_mtok" => "10", "output_per_mtok" => "50", "long_context_input_multiplier" => "2",
      })) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/long_context/, error.message)
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing(rates: {
        "input_per_mtok" => "10", "output_per_mtok" => "50", "long_context_threshold_tokens" => "0.5",
        "long_context_input_multiplier" => "2", "long_context_output_multiplier" => "1.5",
      })) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/long_context_threshold_tokens/, error.message)
    end
  end

  # THE IMAGE LANE BILLS PER TOKEN TOO (F17): the gpt-image-2.5 pages price
  # text in, image in and image out per Mtok (cached classes optional and
  # unbilled until a wire reports a cached count); xAI's row still bills
  # per image. A row picks one family, never both.
  test "the image family is per-image or per-token, never both" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/image" => image_entry(usd_pricing(rates: {
        "text_input_per_mtok" => "5", "image_input_per_mtok" => "8", "image_output_per_mtok" => "30",
        "cached_text_input_per_mtok" => "1.25", "cached_image_input_per_mtok" => "2",
      })) })
      candidate = compile(root)
      effective = ModelCatalog::EffectivePricing.project(
        entry: candidate.models.fetch("openai_api/image"), account_unit: "USD"
      )
      assert_predicate effective, :priced?
      assert_equal BigDecimal("30"), effective.rates.fetch("image_output_per_mtok")
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/image" => image_entry(usd_pricing(rates: {
        "per_image" => "0.04", "image_output_per_mtok" => "30",
      })) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/per_image/, error.message)
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/image" => image_entry(usd_pricing(rates: {
        "text_input_per_mtok" => "5", "image_output_per_mtok" => "30",
      })) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/incomplete rate formula omits image_input_per_mtok/, error.message)
    end
  end

  # THE SERVED TIER'S MULTIPLIER: a schedule may state the vendor's per-tier factors (Flex 50%, Fast
  # 2x) as a map beside its rates; settlement applies the one the RESPONSE echoed. Exact decimals,
  # like every rate.
  test "a schedule states tier multipliers as a map of tier to decimal and projects them" do
    Dir.mktmpdir do |root|
      pricing = usd_pricing
      pricing["schedule"]["tier_multipliers"] = { "flex" => "0.5", "priority" => "2" }
      write_fragment(root, models: { "openai_api/text" => text_entry(pricing) })
      candidate = compile(root)
      effective = ModelCatalog::EffectivePricing.project(
        entry: candidate.models.fetch("openai_api/text"), account_unit: "USD"
      )
      assert_equal({ "flex" => BigDecimal("0.5"), "priority" => BigDecimal("2") }, effective.tier_multipliers)
    end

    Dir.mktmpdir do |root|
      pricing = usd_pricing
      pricing["schedule"]["tier_multipliers"] = { "flex" => 0.5 }
      write_fragment(root, models: { "openai_api/text" => text_entry(pricing) })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_match(/tier_multipliers/, error.message)
    end

    assert_empty ModelCatalog::EffectivePricing.project(
      entry: text_entry(usd_pricing), account_unit: "USD"
    ).tier_multipliers, "a schedule silent on tiers multiplies nothing"
  end

  test "a well-formed catalog_only bundle compiles; malformed decimals and floats refuse" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing) })
      assert compile(root)
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(usd_pricing(rates: { "input_per_mtok" => "not-a-number" })),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "input_per_mtok"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(usd_pricing(rates: { "input_per_mtok" => 1.25 })),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "exact decimal string"
    end
  end

  test "a priced account unit is an exact bounded nonblank string" do
    [" USD ", " ", "x" * 65, 7].each do |unit|
      Dir.mktmpdir do |root|
        pricing = usd_pricing.merge("account_unit" => unit)
        write_fragment(root, models: {
          "openai_api/text" => text_entry(pricing),
        })

        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, "account_unit"
      end
    end
  end

  test "catalog formulas reject missing branches, unknown rates, excessive scale, and overflow" do
    failures = [
      [{ "input_per_mtok" => "1" }, "output_per_mtok"],
      [{ "input_per_mtok" => "1", "output_per_mtok" => "2", "surprise" => "3" }, "surprise"],
      [{ "input_per_mtok" => "0.0000000000001", "output_per_mtok" => "2" }, "12 fractional"],
    ]

    failures.each do |rates, message|
      Dir.mktmpdir do |root|
        write_fragment(root, models: {
          "openai_api/text" => text_entry(usd_pricing(rates: rates)),
        })

        error = assert_raises(ModelCatalog::CompileError) { compile(root) }
        assert_includes error.message, message
      end
    end
  end

  test "catalog schedules require rates while provider_reported_only rejects them" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "account_unit" => "USD", "schedule" => { "kind" => "catalog_only" }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "complete catalog rate formula"
    end

    Dir.mktmpdir do |root|
      write_fragment(root,
        providers: xai_provider,
        models: {
          "xai/grok-4.6" => xai_entry(
              "account_unit" => "USD",
              "schedule" => {
                "kind" => "provider_reported_only",
                "rates" => { "input_per_mtok" => "1", "output_per_mtok" => "2" },
              },
            ),
        })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "must not carry catalog rates"
    end
  end

  test "provider_reported_only refuses on a lane with no native total cost" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "account_unit" => "USD",
          "schedule" => { "kind" => "provider_reported_only" }
        ),
      })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "provider_reported_only"
    end
  end

  test "provider_reported_only compiles only from an exact native contract and projects priced" do
    Dir.mktmpdir do |root|
      write_fragment(root, providers: xai_provider, models: {
        "xai/grok-4.6" => xai_entry(
          "account_unit" => "USD",
          "schedule" => { "kind" => "provider_reported_only" }
        ),
      })

      candidate = compile(root)
      entry = candidate.models.fetch("xai/grok-4.6")
      effective = ModelCatalog::EffectivePricing.project(
        entry: entry, model_ref: "xai/grok-4.6",
        provider: candidate.providers.fetch("xai"), account_unit: "USD"
      )

      assert_predicate effective, :priced?
      assert_equal "USD", effective.account_unit
      assert_equal "provider_reported_only", effective.source_policy
      assert_empty effective.rates
      assert_equal "0.0000000001",
        effective.native_cost_contracts
          .fetch("xai/grok-4.6@xai_responses").fetch("scale")
    end
  end

  test "provider_reported_only rejects an unpinned decimal contract and native-unit mismatch" do
    Dir.mktmpdir do |root|
      write_fragment(root, providers: { "openrouter" => { "base_url" => "https://openrouter.ai/api", "api_format" => "openrouter_chat", "concurrency_limit" => 8 } }, models: {
        "openrouter/moonshotai/kimi-k3:exacto" => {
          "capabilities" => text_capabilities(
            limits: { "combined_input_output_tokens" => 200_000 }, input_modalities: []
          ),
          "pricing" => {
            "account_unit" => "USD", "schedule" => { "kind" => "provider_reported_only" },
          },
        },
      })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "exact native cost contract"
    end

    Dir.mktmpdir do |root|
      write_fragment(root, providers: xai_provider, models: {
        "xai/grok-4.6" => xai_entry(
          "account_unit" => "credits",
          "schedule" => { "kind" => "provider_reported_only" }
        ),
      })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "native unit"
    end
  end

  test "a complete catalog fallback policy compiles on a lane with no native total cost" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "account_unit" => "USD",
          "schedule" => {
            "kind" => "provider_reported_then_catalog_fallback",
            "rates" => { "input_per_mtok" => "1.25", "output_per_mtok" => "10" },
          }
        ),
      })

      entry = compile(root).models.fetch("openai_api/text")
      effective = ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD")
      # Either provider-reported policy stays priced and must reserve even
      # when its catalog fallback is all-zero; known-free requires an exact
      # catalog_only formula.
      assert_predicate effective, :priced?
      assert_equal "provider_reported_then_catalog_fallback", effective.source_policy
      assert_empty effective.native_cost_contracts
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "account_unit" => "USD",
          "schedule" => {
            "kind" => "provider_reported_then_catalog_fallback",
            "rates" => { "input_per_mtok" => "0", "output_per_mtok" => "0" },
          }
        ),
      })

      entry = compile(root).models.fetch("openai_api/text")
      refute_predicate ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD"),
        :known_free_candidate?
    end
  end

  test "the effective projection gates on the exact Account-unit echo" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: { "openai_api/text" => text_entry(usd_pricing) })
      candidate = compile(root)

      effective = ModelCatalog::EffectivePricing.project(
        entry: candidate.models.fetch("openai_api/text"),
        account_unit: "USD")
      assert_predicate effective, :priced?
      assert_equal "catalog_only", effective.source_policy
      assert_equal BigDecimal("1.25"), effective.rates.fetch("input_per_mtok")

      mismatched = ModelCatalog::EffectivePricing.project(
        entry: candidate.models.fetch("openai_api/text"),
        account_unit: "credits")
      assert_predicate mismatched, :cost_unknown?
      assert_equal :account_unit_mismatch, mismatched.reason

      unconfigured = ModelCatalog::EffectivePricing.project(
        entry: candidate.models.fetch("openai_api/text"),
        account_unit: nil)
      assert_predicate unconfigured, :cost_unknown?
      assert_equal :account_unit_unconfigured, unconfigured.reason
    end
  end

  test "an unpriced entry is unmetered and an explicit all-zero catalog_only is the known-free candidate" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry,
      })
      entry = compile(root).models.fetch("openai_api/text")
      effective = ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD")
      assert_predicate effective, :unmetered?
    end

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(usd_pricing(rates: { "input_per_mtok" => "0", "output_per_mtok" => "0" })),
      })
      entry = compile(root).models.fetch("openai_api/text")
      effective = ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD")
      assert_predicate effective, :known_free_candidate?
      assert_equal "USD", effective.account_unit
    end
  end

  # An all-zero catalog-only schedule is free independently of the Account unit.
  test "a unitless schedule refuses at compile even when all-zero" do
    Dir.mktmpdir do |root|
      pricing = {
        "account_unit" => nil,
        "schedule" => {
          "kind" => "catalog_only",
          "rates" => { "input_per_mtok" => "0", "output_per_mtok" => "0" },
        },
      }
      write_fragment(root, models: { "openai_api/text" => text_entry(pricing) })

      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "account_unit"
    end
  end

  test "known-free catalog_only does not require a nonzero quote bound" do
    Dir.mktmpdir do |root|
      pricing = {
        "account_unit" => "USD",
        "schedule" => {
          "kind" => "catalog_only",
          "rates" => { "input_per_mtok" => "0", "output_per_mtok" => "0" },
        },
      }
      write_fragment(root, providers: xai_provider, models: {
        "xai/grok-4.6" => xai_entry(pricing),
      })

      entry = compile(root).models.fetch("xai/grok-4.6")
      assert_predicate ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD"),
        :known_free_candidate?
    end
  end

  test "each non-text workload has one complete catalog formula and all-zero needs no quote bound" do
    non_text_formulas.each do |formula|
      pricing = {
        "account_unit" => "USD",
        "schedule" => {
          "kind" => "catalog_only", "rates" => { formula.fetch(:rate_key) => "0" },
        },
      }
      profile = formula_profile(formula)

      assert ModelCatalog::PricingValidation.validate(
        formula.fetch(:model_ref), pricing, [profile]
      )

      Dir.mktmpdir do |root|
        entry = non_text_entry(formula, pricing)
        write_fragment(root, models: { formula.fetch(:model_ref) => entry })
        compiled = compile(root).models.fetch(formula.fetch(:model_ref))
        effective = ModelCatalog::EffectivePricing.project(entry: compiled, account_unit: "USD")

        assert_predicate effective, :known_free_candidate?
        assert_equal BigDecimal("0"), effective.rates.fetch(formula.fetch(:rate_key))
      end
    end
  end

  # The real transcription profile declares no audio-duration ceiling (the
  # provider bound is unpinned — register watch item), so a priced entry
  # cannot compile against it: per-minute pricing needs the bound. The
  # deployment states one, which is the whole shape of the round — a
  # delegator used to stand in for a shipped row that declared it.
  test "a nonzero per-minute transcription formula compiles through the complete catalog chain" do
    formula = non_text_formulas.find { |candidate| candidate.fetch(:workload) == "transcription" }
    bounded_formula = formula.merge(
      local_limits: { "audio_duration_seconds" => 90 },
      catalog_limits: { "audio_duration_seconds" => 90 }
    )
    pricing = usd_pricing(rates: { formula.fetch(:rate_key) => "1" })

    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        formula.fetch(:model_ref) => non_text_entry(bounded_formula, pricing),
      })

      entry = compile(root).models.fetch(formula.fetch(:model_ref))
      effective = ModelCatalog::EffectivePricing.project(entry: entry, account_unit: "USD")

      assert_predicate effective, :priced?
      assert_equal BigDecimal("1"), effective.rates.fetch("per_minute")
      assert_equal 90, entry.dig("capabilities", "limits", "audio_duration_seconds")
    end
  end

  test "non-text rate keys are closed per workload" do
    non_text_formulas.each do |formula|
      profile = formula_profile(formula)
      pricing = usd_pricing(rates: { "another_rate" => "1" })

      error = assert_raises(ModelCatalog::CompileError) do
        ModelCatalog::PricingValidation.validate(
          formula.fetch(:model_ref), pricing, [profile]
        )
      end
      assert_includes error.message, "another_rate"
    end
  end

  # --- the shipped DeepSeek schedule (owner-reviewed manual data) --------------------

  # The shipped rates are the PEAK half of DeepSeek's peak/off-peak billing. A `catalog_only`
  # schedule carries one flat number and that number is the provider-cost/debit FLOOR, so it takes
  # the rate that is never too low — off-peak would under-state the cost for the seven peak hours a
  # day.
  test "the shipped deepseek fragment carries the reviewed peak USD rates and projects priced" do
    entry = ModelCatalog.current.models.fetch("deepseek/deepseek-flash")
    effective = ModelCatalog::EffectivePricing.project(
      entry: entry, account_unit: "USD")

    assert_predicate effective, :priced?
    assert_equal BigDecimal("0.006"), effective.rates.fetch("input_cache_hit_per_mtok")
    assert_equal BigDecimal("0.3"), effective.rates.fetch("input_cache_miss_per_mtok")
    assert_equal BigDecimal("1.2"), effective.rates.fetch("output_per_mtok")
  end

  test "a provenance block is no longer a recognized schedule key" do
    Dir.mktmpdir do |root|
      write_fragment(root, models: {
        "openai_api/text" => text_entry(
          "account_unit" => "USD",
          "schedule" => { "kind" => "catalog_only", "rates" => { "input_per_mtok" => "1" },
                          "provenance" => { "native_unit" => "CNY" } }
        ),
      })
      error = assert_raises(ModelCatalog::CompileError) { compile(root) }
      assert_includes error.message, "provenance"
    end
  end
end
