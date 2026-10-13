require "test_helper"

# THE CATALOG'S ARITHMETIC AS PURE FUNCTIONS: the receipt settles through them and a text bench
# prices its recorded calls through them, so each figure below is one `record_test.rb` settles
# through the real chain — the same counts, the same rates, the same answer, with no invocation.
class UsageRecords::PricingTest < ActiveSupport::TestCase
  test "the four input classes each bill at their own rate, a write never charged twice" do
    rates = decimals("input_per_mtok" => "5", "output_per_mtok" => "30",
                     "cached_input_per_mtok" => "0.5", "cache_write_per_mtok" => "6.25")

    # 700 non-cached × 5 + 200 reads × 0.5 + 100 writes × 6.25 + 50 out × 30 = 5725 per-mtok units.
    assert_equal BigDecimal("0.005725"),
      formula(tokens(input: 1000, output: 50, cache_read: 200, cache_creation: 100), rates)
  end

  test "unauthored cache rates default to the input rate" do
    rates = decimals("input_per_mtok" => "0.5", "output_per_mtok" => "1.5")

    assert_equal BigDecimal("0.000575"),
      formula(tokens(input: 1000, output: 50, cache_read: 200, cache_creation: 100), rates)
  end

  test "the 1-hour write share bills at its own rate, and at the write rate when none is authored" do
    counts = tokens(input: 1000, output: 50, cache_read: 200, cache_creation: 100, one_hour: 40)
    rates = decimals("input_per_mtok" => "10", "output_per_mtok" => "50",
                     "cached_input_per_mtok" => "1", "cache_write_per_mtok" => "12.5")

    assert_equal BigDecimal("0.01125"), formula(counts, rates.merge("cache_write_1h_per_mtok" => BigDecimal("20")))
    assert_equal BigDecimal("0.01095"), formula(counts, rates)
  end

  test "past the long-context threshold the whole request bills at the tier's multipliers" do
    rates = decimals("input_per_mtok" => "10", "output_per_mtok" => "50", "cached_input_per_mtok" => "1",
                     "long_context_threshold_tokens" => "272000",
                     "long_context_input_multiplier" => "2", "long_context_output_multiplier" => "1.5")

    assert_equal BigDecimal("4.275"), formula(tokens(input: 300_000, output: 1000, cache_read: 100_000), rates)
    assert_equal BigDecimal("2.77"), formula(tokens(input: 272_000, output: 1000), rates), "at the threshold: the base rates"
  end

  test "the served tier multiplies the whole; absent, default and an unnamed tier multiply nothing" do
    rates = decimals("input_per_mtok" => "10", "output_per_mtok" => "50")
    multipliers = decimals("flex" => "0.5", "priority" => "2")

    { "flex" => "0.0025", "priority" => "0.01", "default" => "0.005", "scale" => "0.005", nil => "0.005" }.each do |tier, cost|
      assert_equal BigDecimal(cost),
        UsageRecords::Pricing.formula(tokens: tokens(input: 100, output: 80), rates: rates,
          tier_multipliers: multipliers, service_tier: tier), tier.inspect
    end
  end

  test "the deepseek family prices hits and misses at their own rates" do
    rates = decimals("input_cache_hit_per_mtok" => "0.1", "input_cache_miss_per_mtok" => "1", "output_per_mtok" => "2")

    # 40 hits × 0.1 + 60 misses × 1 + 10 out × 2 = 84 per-mtok units.
    assert_equal BigDecimal("0.000084"), formula(tokens(input: 100, output: 10, cache_read: 40), rates)
  end

  test "no reported count and no schedule both price nothing" do
    assert_nil formula(tokens, decimals("input_per_mtok" => "1", "output_per_mtok" => "2"))
    assert_nil formula(tokens, decimals("input_cache_hit_per_mtok" => "1", "input_cache_miss_per_mtok" => "1", "output_per_mtok" => "1"))
    assert_nil formula(tokens(input: 100, output: 10), {})
  end

  test "the image family prices the delivered images the kernel counted" do
    rates = decimals("per_image" => "0.06")

    assert_equal BigDecimal("0.12"), formula(tokens, rates, images: -> { 2 })
    assert_nil formula(tokens, rates, images: -> { nil }), "a call that delivered none is absent, not zero"
  end

  test "the image token family prices the three flattened classes" do
    rates = decimals("text_input_per_mtok" => "5", "image_input_per_mtok" => "8", "image_output_per_mtok" => "30",
                     "cached_text_input_per_mtok" => "1.25")

    assert_equal BigDecimal("0.03105"), formula(tokens(text_input: 50, image_input: 100, image_output: 1000), rates)
    assert_nil formula(tokens, rates)
  end

  test "the speech family prices the sealed characters the kernel counted" do
    rates = decimals("per_mchar" => "15")

    assert_equal BigDecimal("0.000225"), formula(tokens, rates, characters: -> { 15 })
    assert_nil formula(tokens, rates, characters: -> { nil }), "an undelivered attempt is absent"
  end

  # The two counts the kernel measures are read only when their family prices: a text result has
  # no images to count, and the sealed input is a query.
  test "the measured counts are never read for another family" do
    unread = -> { flunk "a text schedule read a count only its family needs" }

    assert_equal BigDecimal("0.00001"),
      formula(tokens(input: 10), decimals("input_per_mtok" => "1"), images: unread, characters: unread)
  end

  test "the duration family prices the wire's seconds and nothing it cannot have measured" do
    rates = decimals("per_minute" => "6")

    assert_equal BigDecimal("3"), formula(tokens, rates, seconds: 30)
    assert_equal BigDecimal("3"), formula(tokens, rates, seconds: "30")
    [nil, -1, "1e400", Float::INFINITY, 1.0e30, "thirty"].each do |seconds|
      assert_nil formula(tokens, rates, seconds: seconds), seconds.inspect
    end
  end

  test "a provider-reported amount decodes under its contract" do
    ticks = contract("amount_field" => "cost_in_usd_ticks", "scale" => "0.0000000001",
                     "maximum_wire_amount" => "999999999999999999999999999999", "maximum_fractional_digits" => 0)

    # 600_000_000 ticks × 1e-10 = 0.06.
    assert_equal BigDecimal("0.06"), reported({ "cost_in_usd_ticks" => 600_000_000 }, ticks)
    assert_nil reported({ "cost_in_usd_ticks" => "6e8" }, ticks), "a spelling the contract did not anticipate"
    assert_nil reported({ "cost_in_usd_ticks" => "1.5" }, ticks), "more fraction digits than the contract bounds"
    assert_nil reported({ "cost_in_usd_ticks" => "9#{"9" * 30}" }, ticks), "over the contract's maximum"
    assert_nil reported({ "cost_in_usd_ticks" => -1 }, ticks)
    assert_nil reported({}, ticks)
    assert_nil reported({ "cost_in_usd_ticks" => 600_000_000 }, ticks, account_unit: "EUR"), "another unit"
    assert_nil reported({ "cost_in_usd_ticks" => 600_000_000 }, nil), "no contract"
  end

  # A BYOK `usage.cost` is only the broker fee: the broker's total is the authority only on strict
  # non-BYOK evidence; an absent or spelled discriminator proves neither branch.
  test "the broker's cost is the authority only on strict non-BYOK evidence" do
    broker = contract("amount_field" => "cost", "scale" => "1",
                      "maximum_wire_amount" => "99999999999999999999.999999999999999999", "maximum_fractional_digits" => 18)

    assert_equal BigDecimal("0.123456789012345684"),
      reported({ "cost" => "0.123456789012345684", "is_byok" => false }, broker, adapter_profile: "openrouter_chat")
    [true, "false", nil].each do |evidence|
      usage = { "cost" => "0.9", "is_byok" => evidence }.compact
      assert_nil reported(usage, broker, adapter_profile: "openrouter_chat"), evidence.inspect
    end
    assert_equal BigDecimal("0.9"), reported({ "cost" => "0.9" }, broker, adapter_profile: "xai_responses"),
      "the discriminator is the broker's; another wire's contract stands alone"
  end

  # THE RECEIPT'S GATE, one copy: settlement writes money for a projection unless its cost is
  # unknown or the lane is unmetered; a known-free lane writes its zero.
  test "settlement writes money for a priced or known-free projection, never an unknown or unmetered one" do
    priced = schedule("input_per_mtok" => "1", "output_per_mtok" => "2")
    free = schedule("input_per_mtok" => "0", "output_per_mtok" => "0")

    assert settles?(priced, "USD")
    assert settles?(free, nil), "exact zero costs nothing in every unit"
    refute settles?(priced, "EUR"), "a bill in another unit is unknown, never free"
    refute settles?(priced, nil), "an unconfigured unit is unknown"
    refute settles?({}, "USD"), "an unpriced lane is unmetered"
  end

  # ONE CALL'S AMOUNT, one precedence: the provider's bill under its contract is the authority and
  # the formula the fallback — read at the tier the usage says it served; nothing to price is nil.
  test "the provider's bill wins and the formula at the served tier settles a call without one" do
    ticks = contract("amount_field" => "cost_in_usd_ticks", "scale" => "0.0000000001",
                     "maximum_wire_amount" => "999999999999999999999999999999", "maximum_fractional_digits" => 0)
    rates = decimals("input_per_mtok" => "10", "output_per_mtok" => "50")
    multipliers = decimals("priority" => "2")
    counts = tokens(input: 100, output: 80)

    # 600_000_000 ticks × 1e-10 = 0.06, never the formula's 0.005.
    assert_equal BigDecimal("0.06"), amount({ "cost_in_usd_ticks" => 600_000_000 }, ticks, counts, rates, multipliers)
    # 100 × 10 + 80 × 50 = 5000 per-mtok units, twice at the tier the answer echoed.
    assert_equal BigDecimal("0.005"), amount({}, ticks, counts, rates, multipliers), "no bill: the formula"
    assert_equal BigDecimal("0.01"), amount({ "service_tier" => "priority" }, ticks, counts, rates, multipliers)
    assert_equal BigDecimal("0.005"), amount({ "cost_in_usd_ticks" => "6e8" }, ticks, counts, rates, multipliers),
      "a bill the contract cannot decode falls through"
    assert_nil amount({}, ticks, tokens, rates, multipliers), "no bill and no count"
  end

  private

    def schedule(rates) = { "pricing" => { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only", "rates" => rates } } }

    def settles?(entry, account_unit)
      UsageRecords::Pricing.settles_money?(ModelCatalog::EffectivePricing.project(entry: entry, account_unit: account_unit))
    end

    def amount(usage, contract, tokens, rates, tier_multipliers)
      UsageRecords::Pricing.amount(usage: usage, contract: contract, account_unit: "USD", adapter_profile: "xai_responses",
        tokens: tokens, rates: rates, tier_multipliers: tier_multipliers)
    end

    # The receipt reader's own shape (`UsageRecords::Tokens`), every class absent unless named.
    def tokens(input: nil, output: nil, cache_read: nil, cache_creation: nil, one_hour: nil,
               text_input: nil, image_input: nil, image_output: nil)
      UsageRecords::Tokens.read({}, adapter_profile: "").merge(
        input_tokens: input, output_tokens: output, cache_read_tokens: cache_read,
        cache_creation_tokens: cache_creation, cache_creation_1h_tokens: one_hour,
        text_input_tokens: text_input, image_input_tokens: image_input, image_output_tokens: image_output
      )
    end

    def decimals(hash) = hash.transform_values { |value| BigDecimal(value) }

    def formula(tokens, rates, **measured)
      UsageRecords::Pricing.formula(tokens: tokens, rates: rates, tier_multipliers: {}, service_tier: nil, **measured)
    end

    def contract(fields) = { "unit" => "USD" }.merge(fields)

    def reported(usage, contract, account_unit: "USD", adapter_profile: "xai_responses")
      UsageRecords::Pricing.provider_reported(usage: usage, contract: contract, account_unit: account_unit,
        adapter_profile: adapter_profile)
    end
end
