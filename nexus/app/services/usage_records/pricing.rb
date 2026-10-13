require "bigdecimal"

module UsageRecords
  # THE CATALOG'S ARITHMETIC, ONE COPY: whether settlement writes money for a lane at all, the
  # one precedence a call's amount is settled by — the provider's own reported bill under its
  # reviewed contract, else the formula a schedule's rates settle it by — and both halves of that
  # precedence: pure functions of the projection, counts, rates and the usage hash, loadable
  # without Rails. The receipt (`Record`) settles through them, and a text bench stamps and prices
  # its recorded calls through them, so one call is never priced two ways. Rates arrive from
  # `EffectivePricing` as exact BigDecimals; `tokens` is `Tokens.read`'s counts, every class
  # present and nil when the wire did not report it.
  module Pricing
    MTOK = BigDecimal(1_000_000)
    # Only the wire measures audio: bounded by a day, since JSON can deliver Float::INFINITY.
    MAX_WIRE_SECONDS = 86_400

    class << self
      # THE RECEIPT'S GATE over an `EffectivePricing` projection: money is written unless the cost
      # is unknown (no amount can be known, and unknown is never free) or the lane is unmetered
      # (declared not billed); a known-free lane writes its zero.
      def settles_money?(projection) = !(projection.cost_unknown? || projection.unmetered?)

      # ONE CALL'S AMOUNT: the provider's own bill under its contract is the authority, and the
      # formula the fallback, at the tier and over the audio the usage says it served; nil when
      # neither can price the call. `tokens`, `images` and `characters` are the formula's counts.
      def amount(usage:, contract:, account_unit:, adapter_profile:, tokens:, rates:, tier_multipliers:,
                 images: nil, characters: nil)
        provider_reported(usage: usage, contract: contract, account_unit: account_unit, adapter_profile: adapter_profile) ||
          formula(tokens: tokens, rates: rates, tier_multipliers: tier_multipliers,
            service_tier: usage["service_tier"], seconds: usage["seconds"], images: images, characters: characters)
      end

      # One closed family per workload, selected the way PricingValidation authored it: by its
      # rate keys. `service_tier` and `seconds` are the usage's echoed tier and measured audio.
      # `images` and `characters` are the two counts the kernel measures rather than the wire
      # reports — the delivered images and the sealed input's characters — each a callable asked
      # only when its family prices: a text result has no images, and the sealed body is a read.
      def formula(tokens:, rates:, tier_multipliers:, service_tier:, seconds: nil, images: nil, characters: nil)
        return nil if rates.empty?

        if rates.key?("per_image") then per_unit(images&.call, rates.fetch("per_image"))
        elsif rates.key?("image_output_per_mtok") then image_token_cost(tokens, rates)
        elsif rates.key?("per_mchar") then per_mtok(characters&.call, rates.fetch("per_mchar"))
        elsif rates.key?("per_minute") then duration_cost(seconds, rates)
        elsif rates.key?("input_cache_hit_per_mtok") then cached_text_cost(tokens, rates)
        else token_cost(tokens, rates, tier_multipliers, service_tier)
        end
      end

      # The provider's own bill under the profile's reviewed contract; anything the contract did
      # not anticipate decodes to nothing and the caller falls through to the formula.
      def provider_reported(usage:, contract:, account_unit:, adapter_profile:)
        # A BYOK `usage.cost` is only the broker fee, so the formula is the honest fallback; an
        # absent discriminator proves neither branch.
        return nil if adapter_profile == "openrouter_chat" && usage["is_byok"] != false
        return nil if contract.nil?
        return nil unless contract.fetch("unit") == account_unit

        wire = wire_amount(usage[contract.fetch("amount_field")], contract)
        return nil if wire.nil? || wire > BigDecimal(contract.fetch("maximum_wire_amount"))

        wire * BigDecimal(contract.fetch("scale"))
      end

      private

        def wire_amount(raw, contract)
          text = raw.to_s
          return nil unless text.match?(/\A\d+(?:\.\d+)?\z/)

          fraction = text.split(".", 2)[1]
          return nil if fraction && fraction.length > contract.fetch("maximum_fractional_digits")

          BigDecimal(text)
        end

        # Four input classes — plain, cache read, and the two cache-write tiers — each rate
        # defaulting to the one above it (the 1-hour write to the write rate, both writes and the
        # read to the input rate); non-cached input subtracts the cache classes so a write is
        # never charged twice. The long-context tier multiplies the classes past the threshold;
        # the served tier's factor multiplies the whole.
        def token_cost(tokens, rates, tier_multipliers, service_tier)
          return nil if tokens.fetch(:input_tokens).nil? && tokens.fetch(:output_tokens).nil?

          input_factor, output_factor = long_context_factors(tokens, rates)
          amount = input_classes_cost(tokens, rates) * input_factor
          output_rate = rates["output_per_mtok"]
          amount += priced_output_tokens(tokens) * output_rate * output_factor unless output_rate.nil?
          amount * served_tier_factor(tier_multipliers, service_tier) / MTOK
        end

        def input_classes_cost(tokens, rates)
          input_rate = rates.fetch("input_per_mtok")
          cached_rate = rates["cached_input_per_mtok"] || input_rate
          cache_write_rate = rates["cache_write_per_mtok"] || input_rate
          cache_write_1h_rate = rates["cache_write_1h_per_mtok"] || cache_write_rate

          input = tokens.fetch(:input_tokens).to_i
          cache_read = [tokens.fetch(:cache_read_tokens).to_i, input].min
          cache_creation = [tokens.fetch(:cache_creation_tokens).to_i, input - cache_read].min
          # The 1-hour share of the persisted creation sum: the wire's breakdown member, bounded
          # by the sum it belongs to.
          one_hour = [tokens.fetch(:cache_creation_1h_tokens).to_i, cache_creation].min

          (input - cache_read - cache_creation) * input_rate +
            cache_read * cached_rate +
            (cache_creation - one_hour) * cache_write_rate +
            one_hour * cache_write_1h_rate
        end

        # The long-context tier: past the threshold the vendor prices the WHOLE request at its
        # multipliers — every input class at the input factor, output at the output factor. The
        # Responses wire's `usage.input_tokens` is the full prompt, cached included.
        def long_context_factors(tokens, rates)
          threshold = rates["long_context_threshold_tokens"]
          return [1, 1] if threshold.nil? || tokens.fetch(:input_tokens).to_i <= threshold

          [rates.fetch("long_context_input_multiplier"), rates.fetch("long_context_output_multiplier")]
        end

        # THE TIER THE RESPONSE REPORTS: the usage's echoed `service_tier` selects the schedule's
        # factor; absent, `default` or a tier the schedule never named multiplies nothing. Never
        # the requested tier — flex/auto can be served at another.
        def served_tier_factor(tier_multipliers, service_tier)
          tier = service_tier.to_s
          return 1 if tier.empty?

          tier_multipliers.fetch(tier, 1)
        end

        # DeepSeek's authored family: cache hits at the hit rate, everything else the wire counted
        # as input at the miss rate.
        def cached_text_cost(tokens, rates)
          return nil if tokens.fetch(:input_tokens).nil? && tokens.fetch(:output_tokens).nil?

          input = tokens.fetch(:input_tokens).to_i
          hit = [tokens.fetch(:cache_read_tokens).to_i, input].min
          (
            hit * rates.fetch("input_cache_hit_per_mtok") +
              (input - hit) * rates.fetch("input_cache_miss_per_mtok") +
              priced_output_tokens(tokens) * rates.fetch("output_per_mtok")
          ) / MTOK
        end

        # The gpt-image token family: the three classes the gem flattens from the wire's
        # `{input,output}_tokens_details`. A class the wire did not report is absent, never zero;
        # the cached rates are authored, and bill only once a wire reports a cached count — none
        # does.
        def image_token_cost(tokens, rates)
          text_in = tokens.fetch(:text_input_tokens)
          image_in = tokens.fetch(:image_input_tokens)
          image_out = tokens.fetch(:image_output_tokens)
          return nil if text_in.nil? && image_in.nil? && image_out.nil?

          (
            text_in.to_i * rates.fetch("text_input_per_mtok") +
              image_in.to_i * rates.fetch("image_input_per_mtok") +
              image_out.to_i * rates.fetch("image_output_per_mtok")
          ) / MTOK
        end

        def duration_cost(seconds, rates)
          measured = Float(seconds.to_s, exception: false)
          return nil if measured.nil? || !measured.finite? || measured.negative?
          return nil if measured > MAX_WIRE_SECONDS

          BigDecimal(measured.to_s) * rates.fetch("per_minute") / BigDecimal(60)
        end

        # A count the kernel measured. A failed call delivered nothing to count and its bill, if
        # any, is unknowable — absent, not zero.
        def per_unit(count, rate) = count.nil? ? nil : count * rate

        def per_mtok(count, rate) = count.nil? ? nil : count * rate / MTOK

        # Every text wire reports an inclusive output total; reasoning_tokens is a subset kept for
        # statistics, never a second billable class.
        def priced_output_tokens(tokens) = tokens.fetch(:output_tokens).to_i
    end
  end
end
