# THE KERNEL HALF OF `BenchSpend.derive`, run by `bin/rails runner` inside one tree's Nexus: it
# reads a JSON document on stdin — `account_unit` (the unit a screen states its money in) and
# `models` (the catalog refs the screen pays for) — and writes one JSON line: each ref's schedule
# exactly as settlement projects it (`ModelCatalog::EffectivePricing.project`, the call
# `UsageRecords::Record` makes), the wire its profile speaks (`ModelCatalog::ProfileBuilder`'s
# adapter profile, which decides the Anthropic fold and the broker's BYOK rule), the native cost
# contract settlement would read for that profile, and `settles_money` — the receipt's own gate,
# the one predicate `Record` settles by (`UsageRecords::Pricing.settles_money?`), so the harness
# never spells a projection's states. The catalog is the tree's shipped snapshot with no
# Account's policy overlay — a bench's call reaches the provider with no Account between. Exact
# decimals ride as plain-notation strings. A ref the catalog does not name fails the runner by
# name. Nothing here opens a database connection.
require "json"

input = JSON.parse($stdin.read)
account_unit = input.fetch("account_unit")
catalog = ModelCatalog.current
exact = ->(values) { values.transform_values { |value| value.to_s("F") } }

document = input.fetch("models").to_h do |ref|
  entry = catalog.models.fetch(ref) { raise KeyError, "#{ref.inspect} is not a catalog model ref" }
  provider = catalog.providers.fetch(Nexus::ModelRef.parse(ref).provider_id)
  profile = ModelCatalog::ProfileBuilder.call(model_ref: ref, provider: provider, model: entry)
  pricing = ModelCatalog::EffectivePricing.project(entry: entry, model_ref: ref, provider: provider, account_unit: account_unit)
  [ref, { "adapter_profile" => profile.adapter_profile, "state" => pricing.state.to_s, "reason" => pricing.reason&.to_s,
          "settles_money" => UsageRecords::Pricing.settles_money?(pricing),
          "account_unit" => pricing.account_unit, "source_policy" => pricing.source_policy,
          "rates" => exact.(pricing.rates), "tier_multipliers" => exact.(pricing.tier_multipliers),
          "native_cost_contract" => pricing.native_cost_contracts[profile.profile_id] }]
end

puts JSON.generate(document)
