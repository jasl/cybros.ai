require "test_helper"

# The settle batch: unsettled receipts become charge entries on the payer's
# usable budget, everything scanned gets the flag, and nothing settles twice.
# Receipts are hand-built here on purpose — the writer's own contract lives in
# record_test; what this suite feeds the batch is the READ contract.
class UsageRecords::SettleSpendTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @payer = users(:member)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
  end

  test "a priced receipt charges the payer's usable budget and flags itself" do
    budget = open_budget(credited: "10")
    receipt = build_receipt(cost_amount: BigDecimal("0.25"))

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:settled]
    assert_equal 1, result[:charged]
    assert_not_nil receipt.reload.spend_settled_at

    budget.reload
    assert_equal BigDecimal("0.25"), budget.debited_amount
    entry = budget.entries.order(:entry_sequence).last
    assert_equal "charge", entry.kind
    assert_equal BigDecimal("0.25"), entry.amount
    assert_equal receipt.public_id, entry.usage_record_public_id
    assert_equal "settle:#{receipt.public_id}", entry.operation_key
    assert_equal budget.last_entry_sequence, entry.entry_sequence
  end

  test "a second run settles nothing" do
    open_budget(credited: "10")
    build_receipt(cost_amount: BigDecimal("0.25"))
    UsageRecords::SettleSpend.call

    result = UsageRecords::SettleSpend.call

    assert_equal 0, result[:settled]
    assert_equal 1, UsageBudgetEntry.where(kind: "charge").count
  end

  test "the charge never refuses: headroom exhausts into deficit" do
    budget = open_budget(credited: "0.1")
    build_receipt(cost_amount: BigDecimal("0.75"))

    UsageRecords::SettleSpend.call

    budget.reload
    assert_equal BigDecimal("0.75"), budget.debited_amount,
      "the provider was already paid; an administrator can repair the deficit"
  end

  test "a payer with no usable budget settles flag-only" do
    receipt = build_receipt(cost_amount: BigDecimal("0.25"))

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:settled]
    assert_equal 0, result[:charged]
    assert_not_nil receipt.reload.spend_settled_at
    assert_equal 0, UsageBudgetEntry.where(kind: "charge").count
  end

  test "free, unmetered, and unknown-cost receipts never charge" do
    open_budget(credited: "10")
    free = build_receipt(
      admission_shape: "admitted_free", cost_amount: BigDecimal(0), cost_unit: nil,
      idempotency_key: "free:1", attempt_ordinal: 2
    )
    unmetered = build_receipt(
      admission_shape: "unmetered", cost_amount: nil, cost_unit: nil,
      input_tokens: 5, idempotency_key: "unmetered:1", attempt_ordinal: 3
    )
    unknown = build_receipt(
      cost_amount: nil, cost_unit: nil, idempotency_key: "unknown:1", attempt_ordinal: 4
    )
    abandoned = build_receipt(
      status: UsageRecord::ABANDONED,
      cost_amount: nil, cost_unit: nil,
      idempotency_key: "abandoned:1", attempt_ordinal: 5
    )

    result = UsageRecords::SettleSpend.call

    assert_equal 4, result[:settled]
    assert_equal 0, result[:charged]
    assert_equal 2, result[:unknown_cost],
      "priced and abandoned unknowns are counted, never summed as zero"
    [free, unmetered, unknown, abandoned].each do |receipt|
      assert_not_nil receipt.reload.spend_settled_at
    end
    assert_equal 0, UsageBudgetEntry.where(kind: "charge").count
  end

  test "a unit that no longer matches the Account's never reaches the heads" do
    budget = open_budget(credited: "10")
    receipt = build_receipt(cost_amount: BigDecimal("0.25"), cost_unit: "EUR")

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:settled]
    assert_equal 0, result[:charged]
    assert_not_nil receipt.reload.spend_settled_at
    assert_equal BigDecimal(0), budget.reload.debited_amount,
      "summing a foreign unit into USD heads would corrupt them"
  end

  # The replay guard's breadth IS the pin: the per-budget unique index
  # already refuses a same-budget duplicate, so the scenario that
  # distinguishes the deliberately wide owner-scoped lookup is an entry that
  # landed on an EARLIER, now-expired budget whose flag write lost — the
  # receipt is still unsettled, a fresh usable window exists, and charging it
  # again would bill the same receipt twice across the rollover (the item-3
  # review killed a scope-narrowing mutant with exactly this fixture).
  test "a replayed operation key charges once, across a budget rollover" do
    expired = open_budget(credited: "10", starts_at: 2.days.ago, expires_at: 1.day.ago)
    fresh = open_budget(credited: "10")
    receipt = build_receipt(cost_amount: BigDecimal("0.25"))
    expired.entries.create!(
      account_public_id: @account.public_id, user_public_id: @payer.public_id,
      entry_sequence: expired.last_entry_sequence + 1, kind: "charge",
      amount: BigDecimal("0.25"), cost_unit: "USD",
      usage_record_public_id: receipt.public_id,
      operation_key: "settle:#{receipt.public_id}"
    )
    expired.update!(last_entry_sequence: expired.last_entry_sequence + 1)

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:settled]
    assert_equal 0, result[:charged]
    assert_equal 1, UsageBudgetEntry.where(kind: "charge").count
    assert_equal BigDecimal(0), fresh.reload.debited_amount,
      "the earlier window's entry is the operation; a rollover never re-bills it"
  end

  # Same guard, same-budget spelling: the graceful skip instead of a raise
  # off the unique index.
  test "a replayed operation key on the same budget charges once" do
    budget = open_budget(credited: "10")
    receipt = build_receipt(cost_amount: BigDecimal("0.25"))
    budget.entries.create!(
      account_public_id: @account.public_id, user_public_id: @payer.public_id,
      entry_sequence: budget.last_entry_sequence + 1, kind: "charge",
      amount: BigDecimal("0.25"), cost_unit: "USD",
      usage_record_public_id: receipt.public_id,
      operation_key: "settle:#{receipt.public_id}"
    )
    budget.update!(last_entry_sequence: budget.last_entry_sequence + 1)

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:settled]
    assert_equal 0, result[:charged]
    assert_equal 1, UsageBudgetEntry.where(kind: "charge").count
  end

  # C10's gap closed: the per-payer grouping, the per-group sum, and the
  # multi-entry sequence advance are only distinguishable with MORE than one
  # chargeable receipt and MORE than one payer — a mutant charging only the
  # first of either passes every single-receipt test while silently losing
  # money forever (flagged rows are never rescanned).
  test "the batch charges every receipt of every payer" do
    member_budget = open_budget(credited: "10")
    other = users(:owner)
    other_budget = open_budget(credited: "10", user: other)
    build_receipt(cost_amount: BigDecimal("0.25"))
    build_receipt(cost_amount: BigDecimal("0.50"), idempotency_key: "settle-test:2",
      attempt_ordinal: 2)
    build_receipt(cost_amount: BigDecimal("0.10"), idempotency_key: "settle-test:3",
      attempt_ordinal: 3, consumer_user_public_id: other.public_id,
      payer_user_public_id: other.public_id)

    result = UsageRecords::SettleSpend.call

    assert_equal 3, result[:settled]
    assert_equal 3, result[:charged]
    member_budget.reload
    assert_equal BigDecimal("0.75"), member_budget.debited_amount
    assert_equal 2, member_budget.entries.where(kind: "charge").count
    assert_equal 2, member_budget.last_entry_sequence
    other_budget.reload
    assert_equal BigDecimal("0.10"), other_budget.debited_amount
    assert_equal 1, other_budget.entries.where(kind: "charge").count
  end

  test "settlement query count stays flat as one budget's receipt batch grows" do
    open_budget(credited: "100")
    build_receipt(cost_amount: BigDecimal("0.01"))

    single_queries = settlement_query_count do
      assert_equal 1, UsageRecords::SettleSpend.call[:charged]
    end

    20.times do |index|
      build_receipt(
        cost_amount: BigDecimal("0.01"),
        idempotency_key: "settle-scale:#{index}", attempt_ordinal: index + 2
      )
    end
    batch_queries = settlement_query_count do
      assert_equal 20, UsageRecords::SettleSpend.call[:charged]
    end

    assert_operator batch_queries, :<=, single_queries + 1,
      "receipt cardinality must change row counts, not add per-receipt SQL"
  end

  test "settlement query count stays flat as payer cardinality grows" do
    open_budget(credited: "100")
    build_receipt(cost_amount: BigDecimal("0.01"))
    single_queries = settlement_query_count do
      assert_equal 1, UsageRecords::SettleSpend.call[:charged]
    end

    payers = [@payer, users(:owner), users(:curator)]
    payers.drop(1).each { |payer| open_budget(credited: "100", user: payer) }
    payers.each_with_index do |payer, index|
      build_receipt(
        cost_amount: BigDecimal("0.01"),
        idempotency_key: "settle-payer-scale:#{index}",
        attempt_ordinal: index + 2,
        consumer_user_public_id: payer.public_id,
        payer_user_public_id: payer.public_id
      )
    end
    multi_queries = settlement_query_count do
      assert_equal payers.length, UsageRecords::SettleSpend.call[:charged]
    end

    assert_operator multi_queries, :<=, single_queries + 1,
      "payer cardinality must change locked rows, not add one lock query per payer"
  end

  # A budget ROW that exists but covers no usable window must be as good as
  # no budget: `.first` instead of the usable_at? filter charged an expired
  # window in the review's mutant.
  test "an expired window never charges" do
    expired = open_budget(credited: "10", starts_at: 2.days.ago, expires_at: 1.day.ago)
    receipt = build_receipt(cost_amount: BigDecimal("0.25"))

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:settled]
    assert_equal 0, result[:charged]
    assert_not_nil receipt.reload.spend_settled_at
    assert_equal BigDecimal(0), expired.reload.debited_amount
  end

  # The unknown-cost count is the catalog-outage audit signal, and it keeps
  # the predecessor's billable discriminator: a failed attempt whose wire
  # carried nothing is a routine transient, and a 5xx retry storm must not
  # drown the signal.
  test "a failed transient is not a pricing gap" do
    unpriced_failure = build_receipt(
      status: "failed", error_code: "provider_http_error",
      cost_amount: nil, cost_unit: nil
    )
    unpriced_success = build_receipt(
      cost_amount: nil, cost_unit: nil, idempotency_key: "settle-test:2", attempt_ordinal: 2
    )

    result = UsageRecords::SettleSpend.call

    assert_equal 2, result[:settled]
    assert_equal 1, result[:unknown_cost], "only the billable row is a pricing gap"
    assert_not_nil unpriced_failure.reload.spend_settled_at
    assert_not_nil unpriced_success.reload.spend_settled_at
  end

  # Billed is billed: a provider that processed and failed reported the
  # usage it charged for, and the receipt writer priced it — the scan is
  # status-blind on purpose.
  test "a billed failure charges" do
    budget = open_budget(credited: "10")
    build_receipt(status: "failed", error_code: "provider_error",
      cost_amount: BigDecimal("0.33"))

    result = UsageRecords::SettleSpend.call

    assert_equal 1, result[:charged]
    assert_equal BigDecimal("0.33"), budget.reload.debited_amount
  end

  private

    def open_budget(credited:, user: @payer, starts_at: 1.minute.ago, expires_at: nil)
      UsageBudget.create!(
        account: @account, user: user, user_public_id: user.public_id,
        user_kind: user.kind, starts_at: starts_at, expires_at: expires_at,
        credited_amount: BigDecimal(credited), last_entry_sequence: 0
      )
    end

    def build_receipt(**overrides)
      UsageRecord.create!(
        account: @account, idempotency_key: "settle-test:1",
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: @payer.public_id, payer_user_public_id: @payer.public_id,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "one_shot_attempt", service_class: "interactive",
        admission_shape: "priced", status: "succeeded",
        recorded_at: Time.current, cost_unit: "USD",
        **overrides
      )
    end

    def settlement_query_count
      connection = ActiveRecord::Base.lease_connection
      connection.materialize_transactions
      connection.clear_query_cache
      count = 0
      subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
        count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
      end

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      count
    end
end
