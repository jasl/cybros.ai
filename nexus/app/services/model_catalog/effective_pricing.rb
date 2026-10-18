require "bigdecimal"

module ModelCatalog
  # The per-Account effective-pricing projection. A mismatched unit makes
  # cost unknown, never a compile failure; an all-zero `catalog_only`
  # schedule projects known-free — the row's own fact, which admission reads
  # as it stands for both file and account definitions.
  module EffectivePricing
    # `tier_multipliers` is the schedule's map of service tier to exact
    # factor, empty for a schedule that states none; settlement applies
    # the one the response echoed.
    Result = Data.define(
      :state, :reason, :account_unit, :source_policy, :rates, :native_cost_contracts, :tier_multipliers
    ) do
      def initialize(tier_multipliers: {}.freeze, **) = super

      def priced? = state == :priced
      def known_free_candidate? = state == :known_free_candidate
      # Declared not-billed is not free: known-free is a fact about the
      # lane, unmetered a decision about us, and a receipt must say which.
      def unmetered? = state == :unmetered
      def cost_unknown? = state == :cost_unknown
    end

    class << self
      def project(entry:, account_unit:, model_ref: nil, provider: nil)
        # Billing is optional in both file and account definitions: an absent
        # or null pricing leaves money unknown while usage remains recorded.
        pricing = entry["pricing"]
        return unmetered if pricing.nil?

        schedule = pricing.fetch("schedule")
        source_policy = schedule.fetch("kind")
        rates = (schedule["rates"] || {}).transform_values { |value| BigDecimal(value) }
          .freeze

        return unknown(:incomplete_pricing) if rates.empty? && source_policy != "provider_reported_only"

        # Known-free comes before both unit preconditions: exact zero costs
        # nothing in every unit, so an unconfigured Account still reaches
        # it. The guard above already handled empty rates.
        if source_policy == "catalog_only" && rates.values.all?(&:zero?)
          return Result.new(
            state: :known_free_candidate,
            reason: nil,
            account_unit: account_unit,
            source_policy: source_policy,
            rates: rates,
            native_cost_contracts: {}.freeze
          )
        end

        return unknown(:account_unit_unconfigured) if account_unit.nil?
        return unknown(:account_unit_mismatch) unless pricing.fetch("account_unit") == account_unit

        Result.new(
          state: :priced,
          reason: nil,
          account_unit: account_unit,
          source_policy: source_policy,
          rates: rates,
          native_cost_contracts: native_cost_contracts(entry, model_ref, provider, source_policy),
          tier_multipliers: (schedule["tier_multipliers"] || {}).transform_values { |value| BigDecimal(value) }.freeze
        )
      end

      private

      # Keyed by the current profile id ProviderStart wrote, because that is
      # what settlement carries back. One entry now instead of one per
      # workload: a model runs on one wire, so it has one composed profile.
      def native_cost_contracts(entry, model_ref, provider, source_policy)
        return {}.freeze if source_policy == "catalog_only"
        return {}.freeze if provider.nil? || model_ref.nil?

        profile = ProfileBuilder.call(
          model_ref: model_ref, provider: provider, model: entry
        )
        return {}.freeze if profile.native_cost_contract.nil?

        { profile.profile_id.dup.freeze => profile.native_cost_contract.to_h }.freeze
      end

      # No unit, no rates, no source policy: there is nothing to echo and
      # nothing to compute. Unlike known-free it makes no claim about the
      # amount — settlement records the tokens and leaves the money blank.
      def unmetered
        Result.new(
          state: :unmetered, reason: nil, account_unit: nil, source_policy: nil,
          rates: {}.freeze, native_cost_contracts: {}.freeze
        )
      end

      def unknown(reason)
        Result.new(
          state: :cost_unknown,
          reason: reason,
          account_unit: nil,
          source_policy: nil,
          rates: {}.freeze,
          native_cost_contracts: {}.freeze
        )
      end
    end
  end
end
