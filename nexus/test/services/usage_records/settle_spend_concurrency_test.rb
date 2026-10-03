require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# The recurring settlement job may overlap a slow earlier run. Each worker
# claims a disjoint receipt with SKIP LOCKED before they converge on the same
# payer and budget; both charges must land exactly once whichever waiter wins.
class UsageRecords::SettleSpendConcurrencyTest < ActiveSupport::TestCase
  include RowLockTestHelper

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
    @receipts = [
      build_receipt(sequence: 1, amount: "0.25"),
      build_receipt(sequence: 2, amount: "0.50"),
    ]
  end

  teardown do
    UsageBudgetEntry.where(usage_budget_id: @budget.id).delete_all
    UsageBudget.where(id: @budget.id).delete_all
    UsageRecord.where(id: @receipts.map(&:id)).delete_all
    Account.where(id: @account.id).update_all(cost_unit: @previous_cost_unit)
  end

  test "overlapping workers charge disjoint receipts exactly once" do
    held_payer = hold_row_lock(User, @payer.id)
    workers = 2.times.map do
      start_database_call { UsageRecords::SettleSpend.new(batch_size: 1).call }
    end
    wait_until_transitively_blocked_by(held_payer.pid, *workers.map(&:pid))

    release_row_lock(held_payer)
    held_payer = nil
    results = workers.map { |worker| finish_database_call(worker) }
    workers = []

    assert_equal [1, 1], results.map { |result| result[:settled] }.sort
    assert_equal [1, 1], results.map { |result| result[:charged] }.sort
    assert_equal BigDecimal("0.75"), @budget.reload.debited_amount
    assert_equal 2, @budget.last_entry_sequence
    assert_equal @receipts.map { |receipt| "settle:#{receipt.public_id}" }.sort,
      @budget.entries.where(kind: "charge").order(:operation_key).pluck(:operation_key)
    assert @receipts.all? { |receipt| receipt.reload.spend_settled_at.present? }
  ensure
    release_row_lock(held_payer) if held_payer
    workers&.each { |worker| stop_database_call(worker) }
  end

  private

    def build_receipt(sequence:, amount:)
      UsageRecord.create!(
        account: @account,
        idempotency_key: "settle-overlap:#{sequence}",
        model_invocation_public_id: SecureRandom.uuid_v7,
        attempt_ordinal: sequence,
        consumer_user_public_id: @payer.public_id,
        payer_user_public_id: @payer.public_id,
        provider_id: "dev",
        catalog_model_ref: "dev/text",
        wire_model_id: "text",
        workload: "text_generation",
        purpose: "one_shot_attempt",
        service_class: "interactive",
        admission_shape: "priced",
        status: "succeeded",
        recorded_at: Time.current,
        cost_amount: BigDecimal(amount),
        cost_unit: "USD"
      )
    end
end
