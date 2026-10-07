require "test_helper"

class UsageRecords::SettleSpendAtomicityTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @payer = users(:member)
    @previous_cost_unit = @account.cost_unit
    Account.where(id: @account.id).update_all(cost_unit: "USD")
    @budget = UsageBudget.create!(
      account: @account, user: @payer, user_public_id: @payer.public_id,
      user_kind: @payer.kind, starts_at: 1.minute.ago,
      credited_amount: BigDecimal("10"), last_entry_sequence: 0
    )
    @receipts = Array.new(2) do |index|
      UsageRecord.create!(
        account: @account, idempotency_key: "settle-atomic:#{index}",
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        consumer_user_public_id: @payer.public_id, payer_user_public_id: @payer.public_id,
        provider_id: "dev", catalog_model_ref: "dev/text",
        wire_model_id: "text", workload: "text_generation",
        purpose: "inference_request", service_class: "interactive",
        admission_shape: "priced", status: "succeeded", recorded_at: Time.current,
        cost_amount: BigDecimal("0.25"), cost_unit: "USD"
      )
    end
  end

  teardown do
    UsageBudgetEntry.where(usage_budget_id: @budget.id).delete_all
    UsageBudget.where(id: @budget.id).delete_all
    UsageRecord.where(id: @receipts.map(&:id)).delete_all
    Account.where(id: @account.id).update_all(cost_unit: @previous_cost_unit)
  end

  test "a failure after the receipt marker write rolls back charges heads and every marker" do
    marker_written = false
    subscriber = ->(*, payload) do
      if payload[:sql].start_with?('UPDATE "usage_records" SET "spend_settled_at"')
        marker_written = true
        assert_equal 2, @budget.entries.count
        assert_equal BigDecimal("0.50"), @budget.reload.debited_amount
        assert_equal 2, @budget.last_entry_sequence
        assert @receipts.all? { |receipt| receipt.reload.spend_settled_at.present? }
        raise "settlement write interrupted"
      end
    end

    error = assert_raises(RuntimeError) do
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        UsageRecords::SettleSpend.call(batch_size: 2)
      end
    end

    assert_equal "settlement write interrupted", error.message
    assert marker_written
    assert_equal 0, @budget.entries.count
    assert_equal BigDecimal(0), @budget.reload.debited_amount
    assert_equal 0, @budget.last_entry_sequence
    assert @receipts.all? { |receipt| receipt.reload.spend_settled_at.nil? }

    retry_result = UsageRecords::SettleSpend.call(batch_size: 2)
    assert_equal 2, retry_result[:settled]
    assert_equal 2, retry_result[:charged]
    assert_equal BigDecimal("0.50"), @budget.reload.debited_amount
    assert_equal 2, @budget.last_entry_sequence
    assert @receipts.all? { |receipt| receipt.reload.spend_settled_at.present? }
  end
end
