require "test_helper"

# C2-3 step-4 addendum: adjust appends and mutates the head in one
# transaction; revoke is the single-transition freeze. Both replay through
# their stored operation identities.
class UsageBudgets::AdjustRevokeTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    @budget = UsageBudgets::Open.call(
      actor: @owner, target: @owner, starts_at: Time.current,
      amount: BigDecimal("100"), operation_key: "open-1"
    ).budget
  end

  test "credit and debit adjustments append entries and move the head" do
    credit = adjust(kind: :credit, amount: BigDecimal("50"), operation_key: "adj-1")

    assert_predicate credit, :adjusted?
    assert_equal BigDecimal("150"), @budget.reload.credited_amount
    assert_equal 2, @budget.last_entry_sequence

    debit = adjust(kind: :debit, amount: BigDecimal("30"), operation_key: "adj-2")

    assert_predicate debit, :adjusted?
    assert_equal BigDecimal("30"), @budget.reload.debited_amount
  end

  test "a debit adjustment cannot push headroom below existing spend" do
    @budget.update_columns(debited_amount: BigDecimal("80"))

    result = adjust(kind: :debit, amount: BigDecimal("30"), operation_key: "adj-1")

    assert_predicate result, :insufficient_headroom?
    assert_equal 1, @budget.entries.count
  end

  test "adjustment replay returns the original entry and a changed payload conflicts" do
    first = adjust(kind: :credit, amount: BigDecimal("50"), operation_key: "adj-1")
    replay = adjust(kind: :credit, amount: BigDecimal("50"), operation_key: "adj-1")

    assert_predicate replay, :adjusted?
    assert_equal first.entry.id, replay.entry.id
    assert_equal BigDecimal("150"), @budget.reload.credited_amount

    conflicting = adjust(kind: :debit, amount: BigDecimal("50"), operation_key: "adj-1")
    assert_predicate conflicting, :conflict?
  end

  test "adjusting a revoked budget stays legal for deficit repair" do
    revoke(operation_key: "rev-1")

    result = adjust(kind: :credit, amount: BigDecimal("5"), operation_key: "adj-1")

    assert_predicate result, :adjusted?
  end

  test "only an admin or the steward may adjust" do
    refute_predicate adjust(actor: users(:member), kind: :credit,
      amount: BigDecimal("1"), operation_key: "adj-1"), :adjusted?
  end

  test "revoke freezes the whole evidence set once" do
    result = revoke(operation_key: "rev-1", reason: "policy change")

    assert_predicate result, :revoked?
    budget = @budget.reload
    assert_predicate budget, :revoked?
    assert_equal @owner.public_id, budget.revoked_by_public_id
    assert_equal "policy change", budget.revoke_reason
    assert_equal "rev-1", budget.revoke_operation_key
  end

  test "revoke replay honors the stored operation identity" do
    revoke(operation_key: "rev-1", reason: "policy change")

    assert_predicate revoke(operation_key: "rev-1", reason: "policy change"), :revoked?
    assert_predicate revoke(operation_key: "rev-1", reason: "different"), :conflict?
    assert_predicate revoke(operation_key: "rev-2", reason: "policy change"), :already_revoked?
  end

  private

    def adjust(actor: @owner, **args)
      UsageBudgets::Adjust.call(actor: actor, budget: @budget, **args)
    end

    def revoke(actor: @owner, operation_key:, reason: nil)
      UsageBudgets::Revoke.call(
        actor: actor, budget: @budget, operation_key: operation_key, reason: reason
      )
    end
end
