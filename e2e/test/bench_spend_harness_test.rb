$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "tmpdir"
require "support/bench_spend"
require_relative "recording_adapter"

# A SCREEN'S MONEY, PRICED THE WAY THE RECEIPT PRICES IT: each lane's schedule is the kernel's own
# projection (`ModelCatalog::EffectivePricing`), derived once per launch inside the tree's Nexus and
# stamped as `rates.json`; each recorded call is priced by the receipt's own arithmetic
# (`UsageRecords::Pricing`) — the cached and cache-write classes at their rates, a folded Anthropic
# input never charged twice, the broker's own bill only under its contract. Nothing here reads the
# catalog's YAML or restates a formula.
class BenchSpendHarnessTest < Minitest::Test
  Spend = E2E::BenchSpend
  ROOT = File.expand_path("../..", __dir__)

  # A stamped document as the runner writes it: exact decimals as strings, one row per lane.
  def self.row(adapter_profile, rates, source_policy: "catalog_only", tier_multipliers: {}, contract: nil)
    { "adapter_profile" => adapter_profile, "state" => "priced", "reason" => nil, "settles_money" => true, "account_unit" => "USD",
      "source_policy" => source_policy, "rates" => rates, "tier_multipliers" => tier_multipliers,
      "native_cost_contract" => contract }
  end

  DOCUMENT = {
    "anthropic/test-model" => row("anthropic_messages",
      { "input_per_mtok" => "5", "output_per_mtok" => "25", "cached_input_per_mtok" => "0.5", "cache_write_per_mtok" => "6.25" }),
    "openai_api/test-model" => row("openai_responses",
      { "input_per_mtok" => "2", "output_per_mtok" => "8", "cached_input_per_mtok" => "0.2" },
      tier_multipliers: { "flex" => "0.5", "priority" => "2" }),
    "deepseek/test-model" => row("deepseek_responses",
      { "input_cache_hit_per_mtok" => "0.1", "input_cache_miss_per_mtok" => "1", "output_per_mtok" => "2" }),
    "openrouter/acme/test-model" => row("openrouter_chat",
      { "input_per_mtok" => "1.4", "output_per_mtok" => "4.4", "cached_input_per_mtok" => "0.26" },
      source_policy: "provider_reported_then_catalog_fallback",
      contract: { "amount_field" => "cost", "unit" => "USD", "scale" => "1",
                  "maximum_wire_amount" => "99999999999999999999.999999999999999999", "maximum_fractional_digits" => 18 }),
    "xai/test-model" => row("xai_responses",
      { "input_per_mtok" => "2", "output_per_mtok" => "6", "cached_input_per_mtok" => "0.5" },
      source_policy: "provider_reported_then_catalog_fallback", tier_multipliers: { "priority" => "2" },
      contract: { "amount_field" => "cost_in_usd_ticks", "unit" => "USD", "scale" => "0.0000000001",
                  "maximum_wire_amount" => "999999999999999999999999999999", "maximum_fractional_digits" => 0 }),
  }.freeze

  def test_the_stamped_rates_read_back_as_the_kernels_exact_schedules
    Dir.mktmpdir do |home|
      Spend.write(home, DOCUMENT)
      assert_equal DOCUMENT, JSON.parse(File.read(File.join(home, "rates.json"))), "the document is stamped as derived"

      responses = Spend.rates(home).fetch("openai_api/test-model")
      assert_equal "openai_responses", responses.adapter_profile
      assert_equal BigDecimal("0.2"), responses.rates.fetch("cached_input_per_mtok")
      assert_equal({ "flex" => BigDecimal("0.5"), "priority" => BigDecimal("2") }, responses.tier_multipliers)
      assert_nil responses.native_cost_contract
      assert_equal "cost", Spend.rates(home).fetch("openrouter/acme/test-model").native_cost_contract.fetch("amount_field")
    end
  end

  # The Responses wire counts its cached share inside the input it reports.
  # 808 × 2 + 8192 × 0.2 + 40 × 8 = 3574.4 per-mtok units.
  def test_a_cached_share_prices_at_the_cached_rate
    usage = { "input_tokens" => 9_000, "output_tokens" => 40, "cache_read_tokens" => 8_192 }
    assert_equal BigDecimal("0.0035744"), Spend.price(usage, schedule("openai_api/test-model"))
  end

  # The recorded Anthropic input is FOLDED (`ManualClient` spends through `UsageRecords::Tokens`):
  # 9,170 = 20 plain + 9,000 read + 150 written, so the plain class is what remains —
  # 20 × 5 + 9000 × 0.5 + 150 × 6.25 + 300 × 25 = 13037.5 units, never 9,170 at the input rate
  # beside the cache classes.
  def test_a_folded_anthropic_input_is_never_charged_twice
    usage = { "input_tokens" => 9_170, "output_tokens" => 300, "cache_read_tokens" => 9_000, "cache_creation_tokens" => 150 }
    assert_equal BigDecimal("0.0130375"), Spend.price(usage, schedule("anthropic/test-model"))
  end

  # The tier the response says it served multiplies the call; absent, it multiplies nothing.
  def test_the_served_tier_multiplies_the_call
    usage = { "input_tokens" => 1_000, "output_tokens" => 100 }
    assert_equal BigDecimal("0.0028"), Spend.price(usage, schedule("openai_api/test-model"))
    assert_equal BigDecimal("0.0014"), Spend.price(usage.merge("service_tier" => "flex"), schedule("openai_api/test-model"))
  end

  # 40 hits × 0.1 + 60 misses × 1 + 10 out × 2 = 84 units: the miss rate never prices a hit.
  def test_the_deepseek_family_prices_hits_and_misses_at_their_own_rates
    usage = { "input_tokens" => 100, "output_tokens" => 10, "cache_read_tokens" => 40 }
    assert_equal BigDecimal("0.000084"), Spend.price(usage, schedule("deepseek/test-model"))
  end

  # The broker's `cost` is its whole bill only on strict non-BYOK evidence; otherwise the formula
  # (800 × 1.4 + 200 × 0.26 + 50 × 4.4 = 1392 units). A recorded Float the wire wrote in plain
  # decimal reads exactly, however small.
  def test_the_brokers_cost_is_the_bill_only_on_strict_non_byok_evidence
    broker = schedule("openrouter/acme/test-model")
    usage = { "input_tokens" => 1_000, "output_tokens" => 50, "cache_read_tokens" => 200, "cost" => 0.002 }

    assert_equal BigDecimal("0.002"), Spend.price(usage.merge("is_byok" => false), broker)
    assert_equal BigDecimal("0.00000054"), Spend.price(usage.merge("cost" => 5.4e-07, "is_byok" => false), broker)
    [usage, usage.merge("is_byok" => true)].each do |unproven|
      assert_equal BigDecimal("0.001392"), Spend.price(unproven, broker), unproven.inspect
    end
    assert_equal BigDecimal("0.001392"), Spend.price(usage.merge("is_byok" => false), broker.with(account_unit: "EUR")),
      "a bill in another unit than the contract's is not this one"
  end

  # xAI BILLS IN ITS OWN TICKS ON THE LANE'S CONTRACT, the receipt's authority: a xai call recorded
  # over its real wire keeps the integer the wire sent, and read back from disk it prices at
  # 600,000,000 × 10^-10 = 0.06 — never the formula's 900 × 2 + 40 × 6 = 2040 units. A call that
  # carried no ticks settles by the formula, at the tier the answer echoed.
  def test_an_xai_call_prices_at_xais_own_bill_and_by_the_formula_without_one
    xai = schedule("xai/test-model")
    route = E2E::ProviderLanes::Route.new(ref: "xai/test-model", lane: E2E::ProviderLanes.lane("xai"), model: "test-model")
    wire = RecordingAdapter.new({ "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [],
      "usage" => { "input_tokens" => 900, "output_tokens" => 40, "cost_in_usd_ticks" => 600_000_000 } })
    result = E2E::ManualClient.for(route, env: { "XAI_API_KEY" => "xai-placeholder" }, adapter: wire)
      .responses.create(model: route.model, input: [{ "role" => "user", "content" => "x" }], max_output_tokens: 64)
    recorded = JSON.parse(JSON.generate(E2E::ManualClient.facts(result, route.lane))).fetch("usage")

    assert_equal BigDecimal("0.06"), Spend.price(recorded, xai)
    unbilled = recorded.except("cost_in_usd_ticks")
    assert_equal BigDecimal("0.00204"), Spend.price(unbilled, xai)
    assert_equal BigDecimal("0.00408"), Spend.price(unbilled.merge("service_tier" => "priority"), xai)
  end

  # THE STAMP REFUSES, BY LANE, A PROVIDER WHOSE BILL NO RECORDED CALL CARRIES: priced by the formula
  # while its receipt reads the bill, the bench would read one call two ways with no error.
  def test_a_lane_billed_in_a_field_no_record_carries_is_refused_by_name
    assert_equal DOCUMENT, Spend.stampable(DOCUMENT), "every bill a stamped lane names is one a record keeps"

    xai = DOCUMENT.fetch("xai/test-model")
    nano = xai.merge("native_cost_contract" => xai.fetch("native_cost_contract").merge("amount_field" => "cost_in_nano_usd"))
    error = assert_raises(RuntimeError) { Spend.stampable(DOCUMENT.merge("xai/test-model" => nano)) }
    assert_includes error.message, "xai/test-model bills in cost_in_nano_usd"
  end

  def test_a_call_that_reported_nothing_adds_nothing
    [nil, {}].each { |usage| assert_equal BigDecimal(0), Spend.price(usage, schedule("openai_api/test-model")) }
  end

  # A compose draw paid its first call and its repair; a task draw paid each of its messages — and
  # only those, whatever the record copies beside them.
  def test_a_draw_sums_every_call_it_paid_for
    schedules = DOCUMENT.transform_values { |row| Spend::Schedule.from_h(row) }
    first = { "input_tokens" => 1_000, "output_tokens" => 100 }
    repair = { "input_tokens" => 2_000, "output_tokens" => 100 }

    compose = { "model" => "openai_api/test-model", "usage" => first, "repaired_usage" => repair }
    assert_equal BigDecimal("0.0028") + BigDecimal("0.0048"), Spend.record(compose, schedules)
    assert_equal BigDecimal("0.0028"), Spend.record(compose.except("repaired_usage"), schedules)

    task = { "model" => "openai_api/test-model", "usage" => repair,
             "messages" => [{ "index" => 1, "usage" => first }, { "index" => 2, "usage" => repair }, { "index" => 3 }] }
    assert_equal BigDecimal("0.0076"), Spend.record(task, schedules)

    error = assert_raises(KeyError) { Spend.record({ "model" => "openrouter/acme/unpriced-model", "usage" => first }, schedules) }
    assert_includes error.message, "openrouter/acme/unpriced-model"
  end

  # A HOME'S PRICER is built before Stage 0 stamps the rates and reads them when the first draw asks:
  # every draw priced as `record` prices it on the stamped schedules.
  def test_a_homes_pricer_reads_the_stamped_rates_when_the_first_draw_asks
    Dir.mktmpdir do |home|
      price = Spend.pricer(home)
      Spend.write(home, DOCUMENT)
      draw = { "model" => "openai_api/test-model", "usage" => { "input_tokens" => 1_000, "output_tokens" => 100 } }
      assert_equal Spend.record(draw, Spend.rates(home)), price.call(draw)
      assert_equal BigDecimal("0.0028"), price.call(draw)
    end
  end

  # THE TREE'S OWN KERNEL DERIVES THE SCHEDULES: `bin/rails runner` inside the tree's Nexus, under
  # its own bundle, projects each lane as settlement would; the harness stamps and prices what
  # came back. On the shipped glm-5.3 row the bench's price of a call is the receipt's
  # (`record_test.rb`'s shipped-rates figure for the same counts), and on grok xAI's own bill is
  # decoded by the shipped contract. A lane the catalog does not name, or one it cannot price in
  # the screen's unit, stops the derivation by name.
  def test_the_trees_own_kernel_derives_each_lanes_schedule
    refs = %w[openrouter/z-ai/glm-5.3 anthropic/claude-opus-5-5 deepseek/deepseek-flash openai_api/gpt-6.1-sol xai/grok-4.7]
    document = Spend.derive(root: ROOT, models: refs)

    assert_equal refs.sort, document.keys.sort
    assert_equal %w[openrouter_chat anthropic_messages deepseek_responses openai_responses xai_responses],
      refs.map { |ref| document.fetch(ref).fetch("adapter_profile") }
    assert(document.values.all? { |row| row.fetch("settles_money") && row.fetch("account_unit") == "USD" }, document.inspect)
    assert_equal "cost", document.dig("openrouter/z-ai/glm-5.3", "native_cost_contract", "amount_field")
    assert_equal "cost_in_usd_ticks", document.dig("xai/grok-4.7", "native_cost_contract", "amount_field")
    assert_nil document.dig("anthropic/claude-opus-5-5", "native_cost_contract")

    Dir.mktmpdir do |home|
      Spend.write(home, document)
      usage = { "input_tokens" => 1_000, "output_tokens" => 50, "cache_read_tokens" => 200 }
      assert_equal BigDecimal("0.001392"), Spend.price(usage, Spend.rates(home).fetch("openrouter/z-ai/glm-5.3"))
      billed = { "input_tokens" => 900, "output_tokens" => 40, "cost_in_usd_ticks" => 600_000_000 }
      assert_equal BigDecimal("0.06"), Spend.price(billed, Spend.rates(home).fetch("xai/grok-4.7")),
        "xAI's own bill, decoded by the shipped contract"
    end

    unknown = assert_raises(RuntimeError) { Spend.derive(root: ROOT, models: %w[openrouter/nobody/none]) }
    assert_includes unknown.message, "openrouter/nobody/none"
    unpriced = assert_raises(RuntimeError) { Spend.derive(root: ROOT, models: %w[openai_api/gpt-6.1-sol], account_unit: "EUR") }
    assert_match(/openai_api\/gpt-6.1-sol.*cost_unknown/, unpriced.message)
  end

  private

    def schedule(ref) = Spend::Schedule.from_h(DOCUMENT.fetch(ref))
end
