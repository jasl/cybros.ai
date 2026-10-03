require "test_helper"

class UsageRecords::SettleSpendBatchTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @payer = users(:member)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
  end

  test "one call settles one batch and leaves the remaining receipt for a continuation" do
    budget = open_budget
    receipts = create_receipts(3)

    first = UsageRecords::SettleSpend.call(batch_size: 2)

    assert_equal [true, true, false], receipts.map { |receipt| receipt.reload.spend_settled_at.present? }
    assert_equal [2, 2, 0], [first[:settled], first[:charged], first[:unknown_cost]]
    assert_predicate first, :more?
    assert_nil first.cursor
    assert_equal BigDecimal("0.50"), budget.reload.debited_amount
    assert_equal 2, budget.last_entry_sequence
    assert_equal receipts.first(2).map(&:public_id),
      budget.entries.order(:entry_sequence).pluck(:usage_record_public_id)

    last = UsageRecords::SettleSpend.call(batch_size: 2)

    assert_equal [1, 1, 0], [last[:settled], last[:charged], last[:unknown_cost]]
    assert_not_predicate last, :more?
    assert_equal BigDecimal("0.75"), budget.reload.debited_amount
    assert_equal 3, budget.last_entry_sequence
    assert_equal receipts.map(&:public_id),
      budget.entries.order(:entry_sequence).pluck(:usage_record_public_id)
    assert receipts.all? { |receipt| receipt.reload.spend_settled_at.present? }

    empty = UsageRecords::SettleSpend.call(batch_size: 2)
    assert_equal [0, 0, 0], [empty[:settled], empty[:charged], empty[:unknown_cost]]
    assert_not_predicate empty, :more?
    assert_equal 3, budget.entries.count
  end

  test "a full final page asks for one empty continuation" do
    create_receipts(2)

    full = UsageRecords::SettleSpend.call(batch_size: 2)
    assert_equal 2, full[:settled]
    assert_predicate full, :more?

    empty = UsageRecords::SettleSpend.call(batch_size: 2)
    assert_equal 0, empty[:settled]
    assert_not_predicate empty, :more?
  end

  test "a job yields after a full batch and its continuation parks after the partial page" do
    budget = open_budget
    create_receipts(3)
    settle = UsageRecords::SettleSpend.method(:call)

    UsageRecords::SettleSpend.stub(:call, -> { settle.call(batch_size: 2) }) do
      assert_enqueued_jobs 1, only: UsageRecords::SettleSpendJob do
        assert_enqueued_with(job: UsageRecords::SettleSpendJob, args: []) do
          UsageRecords::SettleSpendJob.perform_now
        end
      end
      assert_equal 1, UsageRecord.unsettled.count
      assert_equal BigDecimal("0.50"), budget.reload.debited_amount

      assert_performed_jobs 1, only: UsageRecords::SettleSpendJob do
        perform_enqueued_jobs(only: UsageRecords::SettleSpendJob)
      end
      assert_no_enqueued_jobs(only: UsageRecords::SettleSpendJob)
      assert_equal 0, UsageRecord.unsettled.count
      assert_equal BigDecimal("0.75"), budget.reload.debited_amount
      assert_equal 3, budget.entries.count
    end
  end

  test "the exact production claim uses the unsettled index and stops before retained history" do
    now = Time.current
    seed_receipts(8_000, prefix: "settled", recorded_at: 2.days.ago, spend_settled_at: now)
    seed_receipts(3_000, prefix: "pending", recorded_at: 1.day.ago, spend_settled_at: nil)
    ApplicationRecord.lease_connection.execute("ANALYZE usage_records")

    queries = capture_claims { UsageRecords::SettleSpend.call }

    assert_equal 1, queries.length, "one invocation may claim only one source window"
    assert_equal 2_000, UsageRecord.unsettled.count
    sql, binds = queries.sole
    plan = ApplicationRecord.lease_connection.select_values(
      "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
    ).join("\n")
    assert_match(/\ALimit\s/, plan)
    assert_match(/LockRows/, plan)
    assert_match(/Index Scan using index_usage_records_on_unsettled/, plan)
    assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Rows Removed by Filter: [1-9]/, plan)
    assert_match(/actual [^\n]*rows=1000(?:\.0+)? loops=1/, plan)
    assert_match(/FOR UPDATE SKIP LOCKED/, sql)
  end

  private

    def open_budget
      UsageBudget.create!(
        account: @account, user: @payer, user_public_id: @payer.public_id,
        user_kind: @payer.kind, starts_at: 1.minute.ago,
        credited_amount: BigDecimal("10"), last_entry_sequence: 0
      )
    end

    def create_receipts(count)
      recorded_at = Time.current
      Array.new(count) do |index|
        UsageRecord.create!(**receipt_attributes(
          key: "batch:#{index}", recorded_at: recorded_at + index.seconds
        ))
      end
    end

    def receipt_attributes(key:, recorded_at:)
      {
        account_id: @account.id, idempotency_key: key,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: @payer.public_id, payer_user_public_id: @payer.public_id,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "one_shot_attempt", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: recorded_at,
        cost_amount: BigDecimal("0.25"), cost_unit: "USD",
      }
    end

    def seed_receipts(count, prefix:, recorded_at:, spend_settled_at:)
      UsageRecord.insert_all!(Array.new(count) do |index|
        receipt_attributes(key: "#{prefix}:#{index}", recorded_at: recorded_at).merge(
          spend_settled_at: spend_settled_at
        )
      end)
    end

    def capture_claims
      queries = []
      subscriber = ->(*, payload) do
        sql = payload[:sql]
        if !payload[:cached] && sql.start_with?('SELECT "usage_records"') &&
            sql.include?("FOR UPDATE SKIP LOCKED")
          queries << [sql.dup, payload.fetch(:binds).dup]
        end
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      queries
    end
end
