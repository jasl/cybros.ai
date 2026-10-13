require "test_helper"
require "delegate"

# The receipt writer: identity, normalization, and the settlement-time price.
# Attempts and outcomes come from the REAL chain (admission, the start claim,
# request build, dispatch against a fake adapter); only the pricing projection
# is stubbed where the dev catalog cannot author the formula family under
# test.
class UsageRecords::RecordTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  # THE VALUE NO FAKE LANE CAN HAND US, injected at the one seam a real gem
  # hands it over.
  #
  # The OpenRouter protocol decodes that lane's decimals with
  # `decimal_class: BigDecimal` on purpose — parsed as binary Floats the wire
  # digits silently drop, which is an undercount path. So a real paid turn
  # arrives with `usage.cost` as a BigDecimal. Every fake lane in this suite
  # builds its usage by writing JSON and reading it back, which can only ever
  # produce Integers, Floats and Strings; that is why this had to be injected
  # here, and why a live turn was the first thing to see it.
  #
  # What it cost before: canonicalizing the evidence raised, the raise was
  # not the class `bounded_usage` rescues, and the whole attempt died — the
  # turn hung in `running` until its budget ran out. Every paid turn on that
  # provider, not an edge case.
  test "a receipt keeps an exact decimal the wire reported as a BigDecimal" do
    attempt, outcome = dispatched(
      behaviour: sse_success("hi", usage: { "input_tokens" => 3, "output_tokens" => 4 })
    )
    provider_usage = {
      "input_tokens" => 3, "output_tokens" => 4,
      "cost" => BigDecimal("5.4e-7"),
      "cost_details" => { "upstream_inference_cost" => BigDecimal("5.4e-7") },
    }

    # The value rides a copy of the gem's Result and the outcome delegates
    # to it — the seam, not a rewrite of the lane.
    result = outcome.result.with(usage: provider_usage)
    patched = SimpleDelegator.new(outcome)
    patched.define_singleton_method(:result) { result }

    record = UsageRecords::Record.call(attempt: attempt, outcome: patched, status: "succeeded")

    assert_equal 3, record.input_tokens
    assert_equal 4, record.output_tokens
    # Kept, and kept EXACTLY: a String is the encoding canonical JSON itself
    # names for a number it has no exponent-free form for, and every wire
    # digit survives it. Dropping the evidence would be the designed
    # degradation for a value we cannot store — this one we can.
    assert_equal "0.00000054", record.provider_usage.fetch("cost")
    assert_equal "0.00000054", record.provider_usage.fetch("cost_details").fetch("upstream_inference_cost")
  end

  test "a priced receipt computes the catalog formula from settlement-time rates" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: { "input_tokens" => 100, "output_tokens" => 10 })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal "#{attempt.model_invocation.internal_creation_key}:1", record.idempotency_key
    assert_equal 100, record.input_tokens
    assert_equal 10, record.output_tokens
    assert_equal 110, record.total_tokens
    # (100 × 0.5 + 10 × 1.5) ÷ 1e6, the dev priced fixture's authored rates.
    assert_equal BigDecimal("0.000065"), record.cost_amount
    assert_equal "USD", record.cost_unit
    assert_equal({ "input_per_mtok" => "0.5", "output_per_mtok" => "1.5" }, record.unit_pricing)
    assert_equal "priced", record.admission_shape
    assert_equal "req_1", record.provider_request_id
    assert_not_nil record.duration_ms
    assert_equal "settled", attempt.reload.settlement_state
  end

  test "replay converges on the first receipt" do
    attempt, outcome = dispatched(behaviour: sse_success("hi"))

    first = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    summary = ModelUsageSummary.find_by!(subject_kind: "inference_request", subject_id: attempt.model_invocation.inference_request_id)
    attempt.update_columns(settlement_state: "pending")
    replay = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "discarded")

    assert_equal first.id, replay.id
    assert_equal "succeeded", replay.status, "the first disposition stands"
    assert_equal 1, UsageRecord.where(model_invocation_public_id: first.model_invocation_public_id).count
    assert_equal 1, summary.reload.request_count, "replay never increments the summary twice"
    assert_equal "settled", attempt.reload.settlement_state,
      "a replay repairs a historical receipt-with-pending-settlement gap"
  end

  test "a late real result preserves an admitted-free abandoned winner" do
    attempt, outcome = dispatched(behaviour: sse_success("late"))
    attempt.update!(status: "timed_out", terminal_at: Time.current)

    abandoned = UsageRecords::Record.call(
      attempt: attempt, outcome: nil,
      status: UsageRecord::ABANDONED, error_code: "settlement_abandoned"
    )
    ModelInvocationAttempt.where(id: attempt.id).update_all(settlement_state: "settled")
    late = UsageRecords::Record.call(
      attempt: attempt, outcome: outcome, status: "discarded"
    )

    assert_equal abandoned.id, late.id
    assert_equal UsageRecord::ABANDONED, late.status
    assert_equal BigDecimal(0), late.cost_amount
    assert_nil late.cost_unit
    assert_nil late.provider_request_id
    assert_equal "abandoned", attempt.reload.settlement_state
  end

  test "a settlement write failure rolls back the receipt and summary together" do
    attempt, outcome = dispatched(behaviour: sse_success("hi"))
    subject_id = attempt.model_invocation.inference_request_id
    invalid = ActiveRecord::RecordInvalid.new(attempt)

    assert_raises(ActiveRecord::RecordInvalid) do
      attempt.stub(:update!, ->(**) { raise invalid }) do
        UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
      end
    end

    assert_not UsageRecord.exists?(
      model_invocation_public_id: attempt.model_invocation.public_id,
      attempt_ordinal: attempt.ordinal
    )
    assert_not ModelUsageSummary.exists?(subject_kind: "inference_request", subject_id: subject_id)
    assert_equal "pending", attempt.reload.settlement_state
  end

  test "the subject summary increments once per receipt, replay-proof (item 7)" do
    attempt, outcome = dispatched(
      behaviour: sse_success("hi", usage: { "input_tokens" => 100, "output_tokens" => 10 })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    subject_id = InferenceRequest.find_by!(public_id: record.inference_request_public_id).id
    summary = ModelUsageSummary.find_by!(subject_kind: "inference_request", subject_id: subject_id)
    assert_equal 1, summary.request_count,
      "only the row that actually inserted moves the cumulative cache"
    assert_equal 100, summary.input_tokens
  end

  test "admitted-free records exact zero even on an Account with no unit" do
    attempt, outcome = dispatched(behaviour: sse_success("hi"))

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal "admitted_free", record.admission_shape
    assert_equal BigDecimal(0), record.cost_amount
    assert_nil record.cost_unit
    assert_nil record.unit_pricing
  end

  test "unmetered records the tokens with the money blank" do
    attempt, outcome = dispatched(
      model: DevModelLane::UNMETERED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: { "input_tokens" => 7, "output_tokens" => 2 })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal "unmetered", record.admission_shape
    assert_equal 7, record.input_tokens
    assert_nil record.cost_amount
    assert_nil record.cost_unit
    assert_nil record.unit_pricing
  end

  test "usage the wire never sent stays absent and prices nothing" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: nil)
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_nil record.input_tokens, "absent is absent, never a fabricated zero"
    assert_nil record.total_tokens
    assert_nil record.cost_amount, "unknown cost is never zero"
    assert_equal "USD", record.cost_unit, "the schedule answered even though the wire did not"
  end

  # ---- reasoning is a subset of the provider's output total ---------------

  test "nested reasoning is already inside the priced output" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: {
        "input_tokens" => 100, "output_tokens" => 10,
        "output_tokens_details" => { "reasoning_tokens" => 4 },
      })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal 4, record.reasoning_tokens
    # Output term is 10, not 14: the nested spelling reports a subset.
    assert_equal BigDecimal("0.000065"), record.cost_amount
  end

  test "Gemini adapter output includes thoughts exactly once in the receipt price" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("placeholder")
    )
    provider_result = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com",
      api_key: "secret",
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "candidates" => [{
          "content" => { "parts" => [
            { "thought" => true, "text" => "Consider the answer." },
            { "text" => "The answer." },
          ] },
          "finishReason" => "STOP",
        }],
        "usageMetadata" => {
          "promptTokenCount" => 100,
          "candidatesTokenCount" => 10,
          "thoughtsTokenCount" => 6,
          "totalTokenCount" => 116,
        },
      }))
    ).create(model: "gemini-3.5-flash", input: "Hello")

    record = UsageRecords::Record.call(
      attempt: attempt,
      outcome: outcome_with_result(outcome, provider_result),
      status: "succeeded"
    )

    assert_equal 16, provider_result.usage.fetch("output_tokens"),
      "the adapter converts candidates + thoughts to the canonical inclusive total"
    assert_equal 16, record.output_tokens
    assert_equal 6, record.reasoning_tokens
    # 100 input x 0.5 + the inclusive 16 output x 1.5 = 74 per-mtok units.
    # Adding reasoning again would incorrectly price 22 output tokens.
    assert_equal BigDecimal("0.000074"), record.cost_amount
  end

  test "OpenRouter completion total remains reasoning-inclusive" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("placeholder")
    )
    provider_result = SimpleInference::Protocols::OpenRouterResponses.new(
      base_url: "https://openrouter.ai/api",
      api_key: "secret",
      stream_include_usage: false,
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "id" => "gen_1",
        "choices" => [{
          "message" => { "role" => "assistant", "content" => "The answer." },
          "finish_reason" => "stop",
        }],
        "usage" => {
          "prompt_tokens" => 100,
          "completion_tokens" => 10,
          "completion_tokens_details" => { "reasoning_tokens" => 4 },
          "total_tokens" => 110,
          "is_byok" => false,
        },
      }))
    ).create(model: "anthropic/claude-sonnet-4.5", input: "Hello")

    record = UsageRecords::Record.call(
      attempt: attempt,
      outcome: outcome_with_result(outcome, provider_result),
      status: "succeeded"
    )

    assert_equal 10, record.output_tokens
    assert_equal 4, record.reasoning_tokens
    assert_equal BigDecimal("0.000065"), record.cost_amount,
      "completion_tokens already contains the reasoning subset"
  end

  test "anthropic's split cache classes fold into the normalized input" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => 10, "output_tokens" => 3,
      "cache_read_input_tokens" => 90, "cache_creation_input_tokens" => 20,
    }))
    outcome = mark_anthropic(attempt, outcome)
    writer = UsageRecords::Record.new(attempt: attempt, outcome: outcome, status: "succeeded")

    record = writer.call

    assert_equal 120, record.input_tokens, "the split classes report BESIDE input"
    assert_equal 90, record.cache_read_tokens
    assert_equal 20, record.cache_creation_tokens
    assert_equal 123, record.total_tokens
  end

  test "the same keys on a non-anthropic wire do not fold" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => 100, "output_tokens" => 3, "cache_read_input_tokens" => 90,
    }))

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal 100, record.input_tokens, "OpenAI-family input already contains its cache reads"
    assert_equal 90, record.cache_read_tokens
  end

  # THE BROKER'S SPELLING (cache audit 2026-09-16, usage-6): every bench
  # record rides OpenRouter Chat Completions' `prompt_tokens_details.
  # cached_tokens` — the ninth entry of the read list, pinned here so a
  # reorder or rename cannot go green in this suite and read 0.0 on the
  # next paid run. Inclusive, like the whole OpenAI family: no fold.
  test "the broker's prompt_tokens_details spelling reads as the cache classes, inclusive" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi"))
    provider_result = SimpleInference::Protocols::OpenRouterResponses.new(
      base_url: "https://openrouter.ai/api",
      api_key: "secret",
      stream_include_usage: false,
      adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
        "id" => "gen_2",
        "choices" => [{ "message" => { "role" => "assistant", "content" => "hi" }, "finish_reason" => "stop" }],
        "usage" => {
          "prompt_tokens" => 100,
          "completion_tokens" => 3,
          "prompt_tokens_details" => { "cached_tokens" => 90, "cache_write_tokens" => 5 },
        },
      }))
    ).create(model: "moonshotai/kimi-k3", input: "Hello")

    record = UsageRecords::Record.call(
      attempt: attempt, outcome: outcome_with_result(outcome, provider_result), status: "succeeded"
    )

    assert_equal 100, record.input_tokens, "inclusive: the broker's prompt count already holds the hits"
    assert_equal 90, record.cache_read_tokens
    assert_equal 5, record.cache_creation_tokens, "the sibling spelling of the write class"
    assert_equal 0.9, UsageRecord.cache_hit_rate(record.input_tokens, record.cache_read_tokens),
      "the rate every scorecard reads, from this fixture"
  end

  test "a negative wire count reads as absent and never subtracts" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: { "input_tokens" => 100, "output_tokens" => -10 })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_nil record.output_tokens, "a negative count is a malformed claim, not evidence"
    # Input term only: the malformed output neither subtracts nor prices.
    assert_equal BigDecimal("0.00005"), record.cost_amount
  end

  test "a negative cache class never shrinks the anthropic fold" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => 1000, "output_tokens" => 3, "cache_creation_input_tokens" => -500,
    }))
    outcome = mark_anthropic(attempt, outcome)
    writer = UsageRecords::Record.new(attempt: attempt, outcome: outcome, status: "succeeded")

    record = writer.call

    assert_equal 1000, record.input_tokens, "the fold adds evidence, never a malformed subtraction"
    assert_nil record.cache_creation_tokens
  end

  # Round-2 review: the breakdown members are wire counts like every other —
  # a signed read either subtracted inside the sum or netted the column
  # negative, where the row validation cost the WHOLE receipt through
  # terminal apply's best-effort rescue.
  test "a negative breakdown member is dropped and its honest sibling kept" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => 1000, "output_tokens" => 3,
      "cache_creation" => { "ephemeral_5m_input_tokens" => -500, "ephemeral_1h_input_tokens" => 600 },
    }))
    outcome = mark_anthropic(attempt, outcome)
    writer = UsageRecords::Record.new(attempt: attempt, outcome: outcome, status: "succeeded")

    record = writer.call

    assert_equal 600, record.cache_creation_tokens
    assert_equal 1600, record.input_tokens, "the fold adds the honest member alone"
  end

  test "an all-negative breakdown reads as absent and the receipt still lands" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => 100, "output_tokens" => 10,
      "cache_creation" => { "ephemeral_5m_input_tokens" => -500 },
    }))

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_nil record.cache_creation_tokens
    assert_equal 100, record.input_tokens
    assert_equal "settled", attempt.reload.settlement_state, "the receipt landed"
  end

  test "a negative wire duration prices nothing and the receipt still lands" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "transcription", model: "dev/mock-transcription", input: "a hint",
      upload: { media_type: "audio/wav", bytes: "RIFF\x00\x00\x00\x00WAVEfmt probe".b },
      behaviour: json_response(200, { "text" => "hello", "usage" => {
        "type" => "duration", "seconds" => -30,
        "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15,
      } })
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_minute" => BigDecimal("6"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_nil record.cost_amount, "a malformed duration is not evidence"
    assert_equal 10, record.input_tokens, "and it costs only the money, never the receipt"
  end

  test "an honest wire duration still prices" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "transcription", model: "dev/mock-transcription", input: "a hint",
      upload: { media_type: "audio/wav", bytes: "RIFF\x00\x00\x00\x00WAVEfmt probe".b },
      behaviour: json_response(200, { "text" => "hello", "usage" => {
        "type" => "duration", "seconds" => 90,
        "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15,
      } })
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_minute" => BigDecimal("6"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    # 90 seconds = 1.5 minutes at 6 per minute.
    assert_equal BigDecimal("9"), record.cost_amount
  end

  test "authored cache tiers price reads and writes at their own rates" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: {
        "input_tokens" => 1000, "output_tokens" => 50,
        "input_tokens_details" => { "cached_tokens" => 200, "cache_write_tokens" => 100 },
      })
    )
    pricing = priced_projection(
      "input_per_mtok" => BigDecimal("5"), "output_per_mtok" => BigDecimal("30"),
      "cached_input_per_mtok" => BigDecimal("0.5"), "cache_write_per_mtok" => BigDecimal("6.25")
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    # The predecessor's pinned arithmetic, key for key: 700 non-cached × 5 +
    # 200 reads × 0.5 + 100 writes × 6.25 + 50 out × 30 = 5725 per-mtok units.
    assert_equal BigDecimal("0.005725"), record.cost_amount
  end

  # THE SHIPPED ROWS CARRY THEIR CACHE RATES: the rows this deployment actually bills — the broker's
  # glm-5.3 read rate, the two Anthropic rows' published read and 5-minute write rates — settle
  # cached input and cache writes at the row's own numbers, never at the input rate. The arithmetic
  # is `token_cost`'s: 1000 input of which 200 were read from cache and 100 written to it, 50 out.
  test "the shipped cache rates settle cached input and cache writes at the row's rate" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    expected = {
      # 700 × 2 + 200 × 0.2 + 100 × 2.5 + 50 × 10 per-mtok units
      "anthropic/claude-sonnet-5" => BigDecimal("0.00219"),
      # 700 × 10 + 200 × 1 + 100 × 12.5 + 50 × 50
      "anthropic/claude-fable-5" => BigDecimal("0.01095"),
      # no write rate authored: 800 × 1.4 + 200 × 0.26 + 0 + 50 × 4.4 (the write class is the input rate)
      "openrouter/z-ai/glm-5.3" => BigDecimal("0.001392"),
    }

    expected.each do |model_ref, cost|
      usage = { "input_tokens" => 1000, "output_tokens" => 50, "cache_read_input_tokens" => 200 }
      usage["cache_creation_input_tokens"] = 100 unless model_ref.end_with?("glm-5.3")
      attempt, outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: usage))

      record = ModelCatalog::EffectivePricing.stub(:project, shipped_pricing(model_ref)) do
        UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
      end

      assert_equal cost, record.cost_amount, model_ref
    end
  end

  # TWO WRITE TIERS, TWO RATES (alignment audit F9): the wire reports the
  # 5-minute and the 1-hour creation classes side by side and the pricing
  # page bills them differently (Fable 5: 12.5 vs 20). The persisted
  # `cache_creation_tokens` stays their sum; the 1-hour share is read from
  # the breakdown and priced at its own rate, inside the same input bound.
  # 700 × 10 + 200 × 1 + 60 × 12.5 + 40 × 20 + 50 × 50 = 11250 per-mtok units
  # (the input count is the normalized, cache-inclusive one).
  test "a 1-hour cache write bills at its own rate beside the 5-minute class" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: {
      "input_tokens" => 1000, "output_tokens" => 50, "cache_read_input_tokens" => 200,
      "cache_creation_input_tokens" => 100,
      "cache_creation" => { "ephemeral_5m_input_tokens" => 60, "ephemeral_1h_input_tokens" => 40 },
    }))
    pricing = priced_projection(
      "input_per_mtok" => BigDecimal("10"), "output_per_mtok" => BigDecimal("50"),
      "cached_input_per_mtok" => BigDecimal("1"), "cache_write_per_mtok" => BigDecimal("12.5"),
      "cache_write_1h_per_mtok" => BigDecimal("20")
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_equal 100, record.cache_creation_tokens, "the persisted count is still the sum"
    assert_equal BigDecimal("0.01125"), record.cost_amount
  end

  # A schedule without the 1-hour key settles exactly as before: the whole
  # creation class at the one write rate (100 × 12.5 instead of 750 + 800).
  test "without a 1-hour rate the breakdown settles at the one write rate" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: {
      "input_tokens" => 1000, "output_tokens" => 50, "cache_read_input_tokens" => 200,
      "cache_creation_input_tokens" => 100,
      "cache_creation" => { "ephemeral_5m_input_tokens" => 60, "ephemeral_1h_input_tokens" => 40 },
    }))
    pricing = priced_projection(
      "input_per_mtok" => BigDecimal("10"), "output_per_mtok" => BigDecimal("50"),
      "cached_input_per_mtok" => BigDecimal("1"), "cache_write_per_mtok" => BigDecimal("12.5")
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_equal BigDecimal("0.01095"), record.cost_amount
  end

  # THE LONG-CONTEXT TIER (F19): over the threshold the page prices the
  # WHOLE request at 2x input (and cache) and 1.5x output — the Responses
  # wire's `usage.input_tokens` is the full prompt, cached included.
  # (200000 × 10 + 100000 × 1) × 2 + 1000 × 50 × 1.5 = 4,275,000 units.
  test "a prompt over the long-context threshold bills the whole request at the tier's multipliers" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    rates = {
      "input_per_mtok" => BigDecimal("10"), "output_per_mtok" => BigDecimal("50"),
      "cached_input_per_mtok" => BigDecimal("1"),
      "long_context_threshold_tokens" => BigDecimal("272000"),
      "long_context_input_multiplier" => BigDecimal("2"), "long_context_output_multiplier" => BigDecimal("1.5"),
    }

    over, over_outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: {
      "input_tokens" => 300_000, "output_tokens" => 1000,
      "input_tokens_details" => { "cached_tokens" => 100_000 },
    }))
    record = ModelCatalog::EffectivePricing.stub(:project, priced_projection(rates)) do
      UsageRecords::Record.call(attempt: over, outcome: over_outcome, status: "succeeded")
    end
    assert_equal BigDecimal("4.275"), record.cost_amount

    # At the threshold exactly: "more than 272K" — the base rates.
    under, under_outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: {
      "input_tokens" => 272_000, "output_tokens" => 1000,
    }))
    record = ModelCatalog::EffectivePricing.stub(:project, priced_projection(rates)) do
      UsageRecords::Record.call(attempt: under, outcome: under_outcome, status: "succeeded")
    end
    assert_equal BigDecimal("2.77"), record.cost_amount
  end

  # THE TIER THE RESPONSE REPORTS: a request for flex can be served at another tier, so the factor
  # keys on the usage's echoed `service_tier` — absent or `default` is 1, never the requested tier.
  test "the served tier multiplies the settlement; absent and default multiply nothing" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    rates = { "input_per_mtok" => BigDecimal("10"), "output_per_mtok" => BigDecimal("50") }
    multipliers = { "flex" => BigDecimal("0.5"), "priority" => BigDecimal("2") }

    { "flex" => BigDecimal("0.0025"), "priority" => BigDecimal("0.01"),
      "default" => BigDecimal("0.005"), nil => BigDecimal("0.005") }.each do |tier, cost|
      usage = { "input_tokens" => 100, "output_tokens" => 80 }
      usage["service_tier"] = tier unless tier.nil?
      attempt, outcome = dispatched(model: DevModelLane::PRICED_TEXT_MODEL, behaviour: sse_success("hi", usage: usage))

      pricing = tiered_projection(rates, multipliers)
      record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
        UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
      end

      assert_equal cost, record.cost_amount, tier.inspect
    end
  end

  test "unauthored cache tiers default to the input rate" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: {
        "input_tokens" => 1000, "output_tokens" => 50,
        "input_tokens_details" => { "cached_tokens" => 200, "cache_write_tokens" => 100 },
      })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    # All 1000 input tokens at 0.5, 50 out at 1.5 — identical to the flat
    # formula, which is what makes the tiers optional.
    assert_equal BigDecimal("0.000575"), record.cost_amount
  end

  # Round 3: the class came back as MAGNITUDE. Every count now crosses one
  # boundary — signed, non-finite, radix-prefixed, or beyond honest scale
  # reads as absent, and the receipt always lands.
  test "a count beyond any honest scale reads as absent and the receipt lands" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: { "input_tokens" => 10**19, "output_tokens" => 10 })
    )

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_nil record.input_tokens
    assert_equal 10, record.output_tokens
    assert_equal "settled", attempt.reload.settlement_state, "the receipt landed"
  end

  test "an oversized breakdown member is dropped and the receipt lands" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => 100, "output_tokens" => 10,
      "cache_creation" => { "ephemeral_5m_input_tokens" => 10**20, "ephemeral_1h_input_tokens" => 7 },
    }))

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal 7, record.cache_creation_tokens
    assert_equal "settled", attempt.reload.settlement_state
  end

  test "a radix-prefixed string count reads as decimal, agreeing with the native boundary" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => "010", "output_tokens" => 3,
    }))

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_equal 10, record.input_tokens, "Kernel#Integer read this as octal 8"
  end

  test "a hex-spelled count reads as absent, like every spelling JSON cannot produce" do
    attempt, outcome = dispatched(behaviour: sse_success("hi", usage: {
      "input_tokens" => "0x10", "output_tokens" => 3,
    }))

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_nil record.input_tokens, "Float alone honored C99 hex literals; the digits gate does not"
  end

  test "an amount that would round up to the column cap reads as absent" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: { "input_tokens" => 1, "output_tokens" => 0 })
    )
    # 1 token × this rate ÷ 1e6 = 1e20 − 1e-19: under the cap as compared,
    # exactly the cap once the column rounds to scale 18.
    sliver = BigDecimal("1e26") - BigDecimal("1e-13")
    pricing = priced_projection("input_per_mtok" => sliver, "output_per_mtok" => BigDecimal(0))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_nil record.cost_amount, "the column must never be the first thing to find out"
  end

  test "an absurd or non-finite wire duration prices nothing and the receipt lands" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    # JSON itself delivers 1e400 as Float::INFINITY, so the frame is built
    # raw — JSON.generate would refuse to write what JSON.parse accepts.
    raw_body = '{"text":"hello","usage":{"type":"duration","seconds":1e400,' \
      '"input_tokens":10,"output_tokens":5,"total_tokens":15}}'
    attempt, outcome = dispatched(
      workload: "transcription", model: "dev/mock-transcription", input: "a hint",
      upload: { media_type: "audio/wav", bytes: "RIFF\x00\x00\x00\x00WAVEfmt probe".b },
      behaviour: { status: 200, headers: { "content-type" => "application/json" }, body: raw_body }
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_minute" => BigDecimal("6"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_nil record.cost_amount
    assert_equal 10, record.input_tokens, "only the malformed member is lost"
  end

  test "a finite but absurd duration prices nothing" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "transcription", model: "dev/mock-transcription", input: "a hint",
      upload: { media_type: "audio/wav", bytes: "RIFF\x00\x00\x00\x00WAVEfmt probe".b },
      behaviour: json_response(200, { "text" => "hello", "usage" => {
        "type" => "duration", "seconds" => 1.0e30,
        "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15,
      } })
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_minute" => BigDecimal("6"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_nil record.cost_amount, "a thirty-billion-year recording is not evidence"
  end

  # ---- the formula families the dev catalog cannot author ------------------

  test "the deepseek family prices hits and misses at their own rates" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: {
        "input_tokens" => 100, "output_tokens" => 10, "prompt_cache_hit_tokens" => 40,
      })
    )
    pricing = priced_projection(
      "input_cache_hit_per_mtok" => BigDecimal("0.1"),
      "input_cache_miss_per_mtok" => BigDecimal("1"),
      "output_per_mtok" => BigDecimal("2")
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    # 40 hits × 0.1 + 60 misses × 1 + 10 out × 2 = 84 per-mtok units.
    assert_equal BigDecimal("0.000084"), record.cost_amount
  end

  test "the image family prices delivered images" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "image_generation", model: "dev/mock-image",
      behaviour: json_response(200, {
        "created" => 0,
        "data" => [{ "b64_json" => [png_bytes].pack("m0") },
                   { "b64_json" => [png_bytes].pack("m0") }],
        "usage" => { "prompt_tokens" => 5, "completion_tokens" => 0, "total_tokens" => 5 },
      })
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_image" => BigDecimal("0.06"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_equal BigDecimal("0.12"), record.cost_amount
  end

  # THE IMAGE TOKEN FAMILY (F17): the gpt-image pages bill text in, image
  # in and image out per Mtok, and the gem flattens the wire's
  # `{input,output}_tokens_details.{text,image}_tokens` into those exact
  # classes. 50 × 5 + 100 × 8 + 1000 × 30 = 31050 per-mtok units; a cached
  # class the wire never reports bills nothing.
  test "the image token family prices the flattened token classes" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "image_generation", model: "dev/mock-image",
      behaviour: json_response(200, {
        "created" => 0,
        "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
        "usage" => {
          "input_tokens" => 150, "output_tokens" => 1000, "total_tokens" => 1150,
          "input_tokens_details" => { "image_tokens" => 100, "text_tokens" => 50 },
          "output_tokens_details" => { "image_tokens" => 1000 },
        },
      })
    )
    reshape_to_priced(attempt)
    pricing = priced_projection(
      "text_input_per_mtok" => BigDecimal("5"), "image_input_per_mtok" => BigDecimal("8"),
      "image_output_per_mtok" => BigDecimal("30"), "cached_text_input_per_mtok" => BigDecimal("1.25")
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_equal BigDecimal("0.03105"), record.cost_amount
    assert_equal 150, record.input_tokens
    assert_equal 1000, record.output_tokens
  end

  test "the speech family prices the sealed input characters" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "speech_generation", model: "dev/mock-speech", input: "read this aloud",
      behaviour: { status: 200, headers: { "content-type" => "audio/wav" }, body: wav_bytes }
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_mchar" => BigDecimal("15"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    # "read this aloud" is 15 characters at 15 per million.
    assert_equal BigDecimal("0.000225"), record.cost_amount
  end

  test "speech pricing hydrates sealed text once without walking uploads" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "speech_generation", model: "dev/mock-speech", input: "read this aloud",
      behaviour: { status: 200, headers: { "content-type" => "audio/wav" }, body: wav_bytes }
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_mchar" => BigDecimal("15"))
    content_queries = []
    content_tables = %w[
      content_bodies content_body_entries content_fragments
      content_body_uploads content_uploads active_storage_attachments active_storage_blobs
    ]
    subscriber = lambda do |*, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      sql = payload.fetch(:sql)
      if content_tables.any? { |table| sql.include?(%(FROM "#{table}")) }
        content_queries << sql
      end
    end
    connection = ActiveRecord::Base.lease_connection
    connection.clear_query_cache
    connection.materialize_transactions

    record = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      ModelCatalog::EffectivePricing.stub(:project, pricing) do
        UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
      end
    end

    assert_equal BigDecimal("0.000225"), record.cost_amount,
      "the narrow hydration must preserve the speech formula"
    assert_equal 1, content_queries.length,
      "pricing plucks the accepted entry payloads in one query; uploads are not an input"
    query = content_queries.sole
    assert_includes query, 'FROM "content_body_entries"'
    assert_includes query, 'JOIN "content_fragments"'
    assert_includes query, 'FROM "content_bodies"'
  end

  # The predecessor's schema comment pinned the semantics: milliseconds to
  # the first streamed TOKEN, null when none streamed. A tokenless stream
  # (administrative frames straight to completion) must leave it null —
  # first-event-of-any-type stamping is the drift the re-audit caught.
  test "time to first token is null when no token ever streamed (re-audit)" do
    frames = [
      %(data: {"type":"response.created","response":{"id":"r1"}}\n\n),
      %(data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":""}]}],"usage":{"input_tokens":2,"output_tokens":0}}}\n\n),
      "data: [DONE]\n\n",
    ]
    attempt, outcome = dispatched(behaviour: { sse: frames, status: 200,
      headers: { "content-type" => "text/event-stream" } })

    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_nil record.time_to_first_token_ms,
      "response.created arrived first and is not a token"
    assert_not_nil record.duration_ms
  end

  test "a streamed token stamps time to first token (re-audit)" do
    attempt, outcome = dispatched(behaviour: sse_success("hi"))
    record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

    assert_not_nil record.time_to_first_token_ms
  end

  test "a failed speech attempt is not priced from its own input (re-audit)" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "speech_generation", model: "dev/mock-speech", input: "read this aloud",
      behaviour: { status: 500, headers: {}, body: "boom" }
    )
    reshape_to_priced(attempt)
    pricing = priced_projection("per_mchar" => BigDecimal("15"))

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "failed")
    end

    assert_nil record.cost_amount,
      "the sealed input is a measurement, not billing evidence: no delivered audio, no " \
      "money — a retrying speech invocation must not charge once per started attempt"
  end

  test "a provider-reported amount is the authority over the formula" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: {
        "input_tokens" => 100, "output_tokens" => 10, "cost_in_usd_ticks" => 600_000_000,
      })
    )
    pricing = ModelCatalog::EffectivePricing::Result.new(
      state: :priced, reason: nil, account_unit: "USD",
      source_policy: "provider_reported_then_catalog_fallback",
      rates: { "input_per_mtok" => BigDecimal("0.5"), "output_per_mtok" => BigDecimal("1.5") },
      native_cost_contracts: {
        outcome.profile.profile_id => {
          "amount_field" => "cost_in_usd_ticks", "unit" => "USD",
          "scale" => "0.0000000001", "maximum_wire_amount" => "999999999999999999999999999999",
          "maximum_fractional_digits" => 0,
        },
      }
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    # 600_000_000 ticks × 1e-10 = 0.06 — not the formula's 0.000065.
    assert_equal BigDecimal("0.06"), record.cost_amount
  end

  test "shipped OpenRouter cost is authoritative through budget settlement" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    budget = UsageBudget.create!(
      account: @account, user: @human, user_public_id: @human.public_id,
      user_kind: @human.kind, starts_at: 1.minute.ago,
      credited_amount: BigDecimal("10"), last_entry_sequence: 0
    )
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("placeholder", usage: {
        "input_tokens" => 100, "output_tokens" => 10,
      })
    )
    result = openrouter_result(cost: "0.123456789012345684", is_byok: false)
    outcome = retargeted_outcome(
      attempt, outcome,
      model_ref: "openrouter/anthropic/claude-sonnet-5:exacto", result: result
    )

    record = UsageRecords::Record.call(
      attempt: attempt, outcome: outcome, status: "succeeded"
    )
    UsageRecords::SettleSpend.call

    assert_equal BigDecimal("0.123456789012345684"), record.cost_amount
    assert_equal record.cost_amount, budget.reload.debited_amount,
      "the exact provider amount is the amount charged to the payer"
  end

  test "shipped OpenRouter requires strict non-BYOK evidence for native cost" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    [true, "false", :absent].each do |byok_evidence|
      attempt, outcome = dispatched(
        model: DevModelLane::PRICED_TEXT_MODEL,
        behaviour: sse_success("placeholder", usage: {
          "input_tokens" => 100, "output_tokens" => 10,
        })
      )
      result = openrouter_result(cost: "0.9", is_byok: byok_evidence)
      outcome = retargeted_outcome(
        attempt, outcome,
        model_ref: "openrouter/anthropic/claude-sonnet-5:exacto", result: result
      )

      record = UsageRecords::Record.call(
        attempt: attempt, outcome: outcome, status: "succeeded"
      )

      assert_equal BigDecimal("0.0003"), record.cost_amount,
        "#{byok_evidence.inspect} does not prove the non-BYOK total-cost branch"
    end
  end

  test "shipped xAI text cost ticks override the token formula" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("placeholder", usage: {
        "input_tokens" => 100, "output_tokens" => 10,
      })
    )
    result = xai_text_result(cost_in_usd_ticks: 600_000_000)
    outcome = retargeted_outcome(
      attempt, outcome, model_ref: "xai/grok-4.6", result: result
    )

    record = UsageRecords::Record.call(
      attempt: attempt, outcome: outcome, status: "succeeded"
    )

    assert_equal BigDecimal("0.06"), record.cost_amount
  end

  # xAI's long-context tier is INCLUSIVE — "Requests whose prompt reaches
  # 200k tokens are billed at the higher rate for all tokens in the
  # request" (docs.x.ai/developers/models/grok-4.7, read 2026-09-27) — and
  # the formula's threshold is exclusive, so the grok-4.7 row states
  # 199,999. Settled from the catalog when the answer carries no ticks:
  # 200,000 × $2 × 2 + 1,000 × $6 × 2 = $0.812; one token fewer is
  # 199,999 × $2 + 1,000 × $6 = $0.405998.
  test "the shipped grok-4.7 fallback bills a prompt reaching 200,000 tokens at the long-context rates" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    { 200_000 => BigDecimal("0.812"), 199_999 => BigDecimal("0.405998") }.each do |input_tokens, cost|
      attempt, outcome = dispatched(
        model: DevModelLane::PRICED_TEXT_MODEL,
        behaviour: sse_success("placeholder", usage: { "input_tokens" => 100, "output_tokens" => 10 })
      )
      result = xai_text_result(cost_in_usd_ticks: nil, usage: { "input_tokens" => input_tokens, "output_tokens" => 1000 })
      outcome = retargeted_outcome(attempt, outcome, model_ref: "xai/grok-4.7", result: result)

      record = UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")

      assert_equal cost, record.cost_amount, "#{input_tokens} prompt tokens"
    end
  end

  test "shipped xAI image cost ticks override the per-image formula" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      workload: "image_generation", model: "dev/mock-image",
      behaviour: json_response(200, {
        "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
      })
    )
    reshape_to_priced(attempt)
    result = xai_image_result(cost_in_usd_ticks: 200_000_000)
    outcome = retargeted_outcome(
      attempt, outcome, model_ref: "xai/grok-imagine-image-2.0", result: result
    )

    record = UsageRecords::Record.call(
      attempt: attempt, outcome: outcome, status: "succeeded"
    )

    assert_equal BigDecimal("0.02"), record.cost_amount,
      "the provider's discounted bill wins over the static 0.06 per-image fallback"
  end

  test "a malformed provider amount falls through to the formula" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: sse_success("hi", usage: {
        "input_tokens" => 100, "output_tokens" => 10, "cost_in_usd_ticks" => "6e8",
      })
    )
    pricing = ModelCatalog::EffectivePricing::Result.new(
      state: :priced, reason: nil, account_unit: "USD",
      source_policy: "provider_reported_then_catalog_fallback",
      rates: { "input_per_mtok" => BigDecimal("0.5"), "output_per_mtok" => BigDecimal("1.5") },
      native_cost_contracts: {
        outcome.profile.profile_id => {
          "amount_field" => "cost_in_usd_ticks", "unit" => "USD",
          "scale" => "0.0000000001", "maximum_wire_amount" => "999999999999999999999999999999",
          "maximum_fractional_digits" => 0,
        },
      }
    )

    record = ModelCatalog::EffectivePricing.stub(:project, pricing) do
      UsageRecords::Record.call(attempt: attempt, outcome: outcome, status: "succeeded")
    end

    assert_equal BigDecimal("0.000065"), record.cost_amount
  end

  # ---- failures still meter -----------------------------------------------

  test "a provider that processed and failed with usage still meters it" do
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    attempt, outcome = dispatched(
      model: DevModelLane::PRICED_TEXT_MODEL,
      behaviour: { sse: [
        %(data: {"type":"response.failed","response":{"id":"resp_1","status":"failed","error":{"code":"server_error","message":"boom"},"usage":{"input_tokens":100,"output_tokens":10}}}\n\n),
      ], status: 200, headers: { "content-type" => "text/event-stream" } }
    )

    assert_nil outcome.result
    record = UsageRecords::Record.call(
      attempt: attempt, outcome: outcome, status: "failed", error_code: "provider_error"
    )

    assert_equal "failed", record.status
    assert_equal 100, record.input_tokens
    assert_equal BigDecimal("0.000065"), record.cost_amount, "billed is billed"
  end

  private

    def outcome_with_result(outcome, result)
      SimpleDelegator.new(outcome).tap do |patched|
        patched.define_singleton_method(:result) { result }
      end
    end

    def mark_anthropic(attempt, outcome)
      ModelInvocation.where(id: attempt.model_invocation_id)
        .update_all(provider_id: "claude_proxy", model_ref: "claude-test")
      attempt.model_invocation.reload

      profile = SimpleDelegator.new(outcome.profile)
      profile.define_singleton_method(:adapter_profile) { "anthropic_messages" }
      outcome_with_profile(outcome, profile)
    end

    def outcome_with_profile(outcome, profile)
      ModelInvocations::Dispatch::Result.new(
        outcome: outcome.outcome, result: outcome.result, error: outcome.error,
        timing: outcome.timing, profile: profile, request_id: outcome.request_id
      )
    end

    def retargeted_outcome(attempt, outcome, model_ref:, result:)
      provider_id, model_tail = model_ref.split("/", 2)
      invocation = attempt.model_invocation
      ModelInvocation.where(id: invocation.id)
        .update_all(provider_id: provider_id, model_ref: model_tail)
      invocation.reload
      catalog = ModelCatalog.current
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: model_ref, provider: catalog.providers.fetch(provider_id),
        model: catalog.models.fetch(model_ref)
      )
      outcome_with_profile(outcome_with_result(outcome, result), profile)
    end

    def openrouter_result(cost:, is_byok:)
      byok_member = is_byok == :absent ? "" : %Q(,"is_byok":#{JSON.generate(is_byok)})
      body = %({"id":"gen_1","choices":[{"message":{"role":"assistant","content":"ok"},) +
        %("finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":10,) +
        %("total_tokens":110,"cost":#{cost}#{byok_member}}})
      SimpleInference::Protocols::OpenRouterResponses.new(
        base_url: "https://openrouter.ai/api", api_key: "secret",
        stream_include_usage: false,
        adapter: InvocationHarness::FakeAdapter.new(
          status: 200, headers: { "content-type" => "application/json" }, body: body
        )
      ).create(model: "anthropic/claude-sonnet-5:exacto", input: "Hello")
    end

    # `cost_in_usd_ticks: nil` answers without the provider's amount, the
    # case the catalog formula settles.
    def xai_text_result(cost_in_usd_ticks:, usage: { "input_tokens" => 100, "output_tokens" => 10 })
      SimpleInference::Protocols::XAIResponses.new(
        base_url: "https://api.x.ai", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "resp_1", "status" => "completed",
          "output" => [{
            "type" => "message", "role" => "assistant",
            "content" => [{ "type" => "output_text", "text" => "ok" }],
          }],
          "usage" => usage.merge(
            "total_tokens" => usage.values.sum, "cost_in_usd_ticks" => cost_in_usd_ticks
          ).compact,
        }))
      ).create(model: "grok-4.6", input: "Hello")
    end

    def xai_image_result(cost_in_usd_ticks:)
      SimpleInference::Protocols::OpenAIImages.new(
        base_url: "https://api.x.ai", api_key: "secret", image_response_format: "b64_json",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
          "usage" => { "cost_in_usd_ticks" => cost_in_usd_ticks },
        }))
      ).generate(model: "grok-imagine-image-2.0", prompt: "a cat")
    end

    def dispatched(behaviour:, workload: "text_generation", model: nil, input: "say hi",
                   upload: nil)
      attempt = admitted_attempt(workload: workload, model: model, input: input, upload: upload)
      started = start(attempt)
      built = build(attempt)
      raise "build refused: #{built.refusal.inspect}" unless built.built?

      outcome = fake_dispatch(behaviour) do
        ModelInvocations::Dispatch.call(
          attempt: started.attempt, context: started.context, request: built.request
        )
      end
      [started.attempt, outcome]
    end

    # The dev catalog authors no priced image/speech lane, so the ONE fact a
    # hand mutation injects is the frozen shape — through SQL, because the
    # column is honestly readonly at the model layer.
    def reshape_to_priced(attempt)
      ModelInvocationAttempt.where(id: attempt.id).update_all(admission_shape: "priced")
      attempt.reload
    end

    # The row as the catalog ships it, projected the way admission projects
    # it — a rate this test asserts is one the deployment bills.
    def shipped_pricing(model_ref)
      catalog = ModelCatalog.current
      ModelCatalog::EffectivePricing.project(
        entry: catalog.models.fetch(model_ref), model_ref: model_ref,
        provider: catalog.providers.fetch(model_ref.split("/").first), account_unit: "USD"
      )
    end

    def priced_projection(rates)
      ModelCatalog::EffectivePricing::Result.new(
        state: :priced, reason: nil, account_unit: "USD", source_policy: "catalog_only",
        rates: rates, native_cost_contracts: {}
      )
    end

    # The same projection carrying the schedule's per-tier factors.
    def tiered_projection(rates, multipliers)
      priced_projection(rates).with(tier_multipliers: multipliers)
    end
end
