require "test_helper"

# THE TWO HALVES OF PROVIDER-REPORTED BILLING MUST MEET IN SHIPPED DATA.
#
# `UsageRecords::Pricing.amount` prefers the provider's own bill
# over this catalog's formula. It needs two things that live in two different
# places: a MODEL whose schedule kind says the provider wins, and a PROVIDER
# that declares the `native_cost_contract` telling this side how to decode the
# amount. `EffectivePricing#native_cost_contracts` returns `{}` unless BOTH are
# present — a `catalog_only` model short-circuits before the contract is even
# looked up.
#
# This is not a claim the code can make about itself — it is a statement about
# the DATA — so it is pinned here rather than inferred at runtime. A model
# that promises provider authority without a contract, or a contract no model
# can reach, is a compile-green billing bug and must fail this test.
class ModelCatalog::ShippedBillingAuthorityTest < ActiveSupport::TestCase
  PROVIDER_REPORTED_KINDS = %w[provider_reported_then_catalog_fallback provider_reported_only].freeze

  test "every shipped provider-reported policy has a native cost contract" do
    catalog = ModelCatalog.current

    stranded = catalog.models.filter_map do |model_ref, entry|
      kind = entry.dig("pricing", "schedule", "kind")
      next unless PROVIDER_REPORTED_KINDS.include?(kind)

      provider_id = model_ref.split("/").first
      pricing = ModelCatalog::EffectivePricing.project(
        entry: entry, model_ref: model_ref,
        provider: catalog.providers.fetch(provider_id),
        account_unit: entry.dig("pricing", "account_unit")
      )
      model_ref if pricing.native_cost_contracts.empty?
    end

    assert_empty stranded,
      "provider-reported schedules must be able to read the provider's own bill"
  end

  test "every shipped native cost contract is used by a pricing policy" do
    catalog = ModelCatalog.current

    inert = catalog.providers.filter_map do |provider_id, entry|
      next if entry["native_cost_contract"].nil?

      asked = catalog.models.any? do |model_ref, model|
        next false unless model_ref.start_with?("#{provider_id}/")
        next false unless PROVIDER_REPORTED_KINDS.include?(model.dig("pricing", "schedule", "kind"))

        ModelCatalog::EffectivePricing.project(
          entry: model, model_ref: model_ref, provider: entry,
          account_unit: model.dig("pricing", "account_unit")
        ).native_cost_contracts.any?
      end
      provider_id unless asked
    end

    assert_empty inert, "native cost contracts must not be inert catalog decoration"
  end
end
