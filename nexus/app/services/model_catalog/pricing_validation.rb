require "bigdecimal"

module ModelCatalog
  # Rates are exact decimal strings (a YAML float is lossy and refuses),
  # owner-reviewed and maintained by hand; a lane without a provider-native
  # total cost cannot select provider_reported_only.
  module PricingValidation
    PRICING_KEYS = %w[account_unit schedule].freeze
    # `tier_multipliers`: the vendor's per-service-tier factors (Flex
    # 50%, Fast 2x) as a map of tier id to exact decimal, applied at
    # settlement from the tier the RESPONSE echoed — never the requested
    # one.
    SCHEDULE_KEYS = %w[kind rates tier_multipliers].freeze
    SCHEDULE_KINDS = %w[catalog_only provider_reported_then_catalog_fallback provider_reported_only].freeze
    CATALOG_SCHEDULE_KINDS = %w[catalog_only provider_reported_then_catalog_fallback].freeze
    BASIC_TEXT_RATE_KEYS = %w[input_per_mtok output_per_mtok].freeze
    # The long-context tier, stated as the vendor states it — a
    # threshold and two multipliers over the base rates (2x input and
    # cache, 1.5x output past 272K on gpt-6-astra) — so a second copy of
    # every rate cannot go stale. All three or none.
    LONG_CONTEXT_RATE_KEYS = %w[
      long_context_threshold_tokens long_context_input_multiplier long_context_output_multiplier
    ].freeze
    # Cache tiers are optional: a schedule without them bills every input
    # class at the input rate, over-billing reads up to 10x. The 1-hour
    # write rate is the second write tier the wire's
    # `cache_creation.ephemeral_1h_input_tokens` bills at; absent, the
    # one write rate covers both classes as before.
    BASIC_TEXT_OPTIONAL_RATE_KEYS = (
      %w[cached_input_per_mtok cache_write_per_mtok cache_write_1h_per_mtok] + LONG_CONTEXT_RATE_KEYS
    ).freeze
    CACHED_TEXT_RATE_KEYS = %w[
      input_cache_hit_per_mtok input_cache_miss_per_mtok output_per_mtok
    ].freeze
    # Two image families, a row picks one: per delivered image (xAI), or
    # per token as the gpt-image pages price text in / image in / image
    # out. The cached classes are authored, unbilled until a wire
    # reports a cached count.
    IMAGE_RATE_KEYS = %w[per_image].freeze
    IMAGE_TOKEN_RATE_KEYS = %w[text_input_per_mtok image_input_per_mtok image_output_per_mtok].freeze
    IMAGE_TOKEN_OPTIONAL_RATE_KEYS = %w[cached_text_input_per_mtok cached_image_input_per_mtok].freeze
    SPEECH_RATE_KEYS = %w[per_mchar].freeze
    TRANSCRIPTION_RATE_KEYS = %w[per_minute].freeze
    EMBEDDING_RATE_KEYS = %w[input_per_mtok].freeze
    DECIMAL_PATTERN = /\A\d+(?:\.\d{1,12})?\z/
    ACCOUNT_UNIT_MAX_LENGTH = Account::COST_UNIT_MAX_LENGTH

    class << self
      def validate(model_ref, pricing, profiles)
        case pricing
        when Hash then nil
        else raise CompileError, "model #{model_ref}: pricing must be a mapping"
        end

        unknown = pricing.keys - PRICING_KEYS
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown pricing keys #{unknown.sort.join(", ")}"
        end
        unless pricing.key?("account_unit")
          raise CompileError, "model #{model_ref}: pricing must declare account_unit"
        end
        unit = pricing.fetch("account_unit")

        schedule = pricing.fetch("schedule", nil)
        case schedule
        when Hash then nil
        else raise CompileError, "model #{model_ref}: pricing schedule must be a mapping"
        end

        unknown = schedule.keys - SCHEDULE_KEYS
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown schedule keys #{unknown.sort.join(", ")}"
        end

        kind = schedule["kind"]
        unless SCHEDULE_KINDS.include?(kind)
          raise CompileError, "model #{model_ref}: schedule kind must be one of #{SCHEDULE_KINDS.join(", ")}"
        end
        rates = validate_rate_policy(model_ref, kind, schedule, profiles)
        validate_tier_multipliers(model_ref, kind, schedule) if schedule.key?("tier_multipliers")
        validate_account_unit(model_ref, unit, kind, rates)
        validate_native_cost_policy(model_ref, kind, profiles, unit)

        true
      end

      private

      def validate_account_unit(model_ref, unit, kind, rates)
        if unit.nil?
          raise CompileError,
            "model #{model_ref}: pricing must echo its expected account_unit"
        end

        valid_unit = case unit
        when String
          !unit.empty? && unit == unit.strip && unit.length <= ACCOUNT_UNIT_MAX_LENGTH
        else false
        end
        unless valid_unit
          raise CompileError,
            "model #{model_ref}: pricing account_unit must be an already-trimmed nonblank String of at " \
            "most #{ACCOUNT_UNIT_MAX_LENGTH} characters"
        end
      end

      def validate_native_cost_policy(model_ref, kind, profiles, unit)
        return unless kind == "provider_reported_only"

        contracts = profiles.map(&:native_cost_contract)
        if contracts.all? && contracts.map(&:unit).uniq.one?
          return if contracts.first.unit == unit
        end

        if contracts.any?(&:nil?)
          raise CompileError,
            "model #{model_ref}: provider_reported_only needs an exact native cost contract on " \
            "every execution profile (a complete catalog fallback policy remains legal)"
        end

        raise CompileError,
          "model #{model_ref}: provider_reported_only native unit must exactly equal pricing " \
          "account_unit #{unit.inspect}"
      end

      def validate_rate_policy(model_ref, kind, schedule, profiles)
        if kind == "provider_reported_only"
          if schedule.key?("rates")
            raise CompileError, "model #{model_ref}: provider_reported_only must not carry catalog rates"
          end
          return {}.freeze
        end

        unless CATALOG_SCHEDULE_KINDS.include?(kind)
          raise CompileError, "model #{model_ref}: unsupported catalog schedule kind #{kind.inspect}"
        end
        unless schedule.key?("rates")
          raise CompileError, "model #{model_ref}: #{kind} requires a complete catalog rate formula"
        end

        rates = validate_rates(model_ref, schedule.fetch("rates"), profiles)
        rates.freeze
      end

      def validate_rates(model_ref, rates, profiles)
        case rates
        when Hash then nil
        else raise CompileError, "model #{model_ref}: rates must be a mapping"
        end

        expected = expected_rate_keys(model_ref, profiles, rates)
        unknown = rates.keys - expected - optional_rate_keys(expected)
        missing = expected - rates.keys
        unless unknown.empty?
          raise CompileError, "model #{model_ref}: unknown rate keys #{unknown.sort.join(", ")}"
        end

        parsed = rates.to_h { |key, value| [key, decimal_rate(model_ref, key, value)] }

        unless missing.empty?
          raise CompileError, "model #{model_ref}: incomplete rate formula omits #{missing.sort.join(", ")}"
        end
        validate_long_context_tier(model_ref, parsed)
        parsed
      end

      def decimal_rate(model_ref, key, value)
        case value
        when String
          unless value.match?(DECIMAL_PATTERN)
            raise CompileError,
              "model #{model_ref}: rate #{key} must be a plain nonnegative decimal with at most 12 fractional digits"
          end
        else
          raise CompileError,
            "model #{model_ref}: rate #{key} must be an exact decimal string, never a YAML number"
        end

        BigDecimal(value)
      end

      # The triple is one fact: a threshold without its multipliers (or
      # the reverse) prices nothing the vendor states. The threshold is a
      # token count — a positive whole number.
      def validate_long_context_tier(model_ref, parsed)
        present = LONG_CONTEXT_RATE_KEYS & parsed.keys
        return if present.empty?

        unless present.length == LONG_CONTEXT_RATE_KEYS.length
          raise CompileError,
            "model #{model_ref}: the long_context tier needs all of #{LONG_CONTEXT_RATE_KEYS.join(", ")}"
        end
        threshold = parsed.fetch("long_context_threshold_tokens")
        return if threshold.positive? && threshold.frac.zero?

        raise CompileError,
          "model #{model_ref}: rate long_context_threshold_tokens must be a positive whole token count"
      end

      # A map of tier id to exact decimal factor; only a formula can be
      # multiplied, so a provider-reported-only schedule declares none.
      def validate_tier_multipliers(model_ref, kind, schedule)
        multipliers = schedule.fetch("tier_multipliers")
        unless CATALOG_SCHEDULE_KINDS.include?(kind)
          raise CompileError, "model #{model_ref}: tier_multipliers need a catalog rate formula to multiply"
        end
        case multipliers
        when Hash then nil
        else raise CompileError, "model #{model_ref}: tier_multipliers must be a mapping of tier to decimal"
        end

        multipliers.each do |tier, factor|
          id = tier.to_s
          if id.strip.empty? || id != id.strip
            raise CompileError, "model #{model_ref}: tier_multipliers keys must be trimmed nonblank tier ids"
          end

          decimal_rate(model_ref, "tier_multipliers.#{id}", factor)
        end
      end

      # Optional keys extend a family without loosening its completeness
      # check: `missing` is still judged against the required set alone.
      def optional_rate_keys(expected)
        case expected
        when BASIC_TEXT_RATE_KEYS then BASIC_TEXT_OPTIONAL_RATE_KEYS
        when IMAGE_TOKEN_RATE_KEYS then IMAGE_TOKEN_OPTIONAL_RATE_KEYS
        else []
        end
      end

      def expected_rate_keys(model_ref, profiles, rates)
        workloads = profiles.map(&:workload).uniq
        unless workloads.one?
          raise CompileError,
            "model #{model_ref}: catalog pricing cannot mix workload formula families"
        end

        workload = workloads.first
        case workload
        when "text_generation"
          text_rate_keys(model_ref, profiles)
        when "image_generation"
          image_rate_keys(rates)
        when "speech_generation"
          SPEECH_RATE_KEYS
        when "transcription"
          TRANSCRIPTION_RATE_KEYS
        when "embedding"
          EMBEDDING_RATE_KEYS
        else
          raise CompileError,
            "model #{model_ref}: no reviewed catalog pricing formula exists for #{workload}"
        end
      end

      # The family the row authored: any token-class key selects the
      # per-token family, and `per_image` is then a stranger to it (a row
      # picks one, never both); a row without one bills per image.
      def image_rate_keys(rates)
        token_keys = IMAGE_TOKEN_RATE_KEYS + IMAGE_TOKEN_OPTIONAL_RATE_KEYS
        (rates.keys & token_keys).any? ? IMAGE_TOKEN_RATE_KEYS : IMAGE_RATE_KEYS
      end

      def text_rate_keys(model_ref, profiles)
        adapters = profiles.map(&:adapter_profile).uniq
        if adapters == ["deepseek_responses"]
          CACHED_TEXT_RATE_KEYS
        elsif adapters.length == 1
          BASIC_TEXT_RATE_KEYS
        else
          raise CompileError,
            "model #{model_ref}: catalog pricing cannot mix execution-profile formula families"
        end
      end
    end
  end
end
