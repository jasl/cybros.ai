require "test_helper"

# Opening a usage budget atomically establishes its usable window and initial ledger state. A caller
# must never observe a partially opened budget.
class UsageBudgets::OpenTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
  end

  test "an admin opens a human budget with its initial grant atomically" do
    result = open_budget

    assert_predicate result, :opened?
    budget = result.budget
    assert_equal "human", budget.user_kind
    assert_equal BigDecimal("100"), budget.credited_amount
    assert_equal 1, budget.last_entry_sequence

    grant = budget.entries.sole
    assert_equal "initial_grant", grant.kind
    assert_equal "USD", grant.cost_unit
    assert_equal @owner.public_id, grant.actor_public_id
  end

  test "a steward alone opens their agent's allowance" do
    agent = create_agent_member(steward: users(:member))

    refused = open_budget(target: agent)
    assert_predicate refused, :not_authorized?

    result = open_budget(actor: users(:member), target: agent)
    assert_predicate result, :opened?
    assert_equal "agent", result.budget.user_kind
  end

  test "a member cannot self-grant and a suspended actor cannot act" do
    refute_predicate open_budget(actor: users(:member), target: users(:member)), :opened?

    users(:owner).update_columns(status: "suspended")
    assert_predicate open_budget, :not_authorized?
  end

  test "an unset account unit refuses before any write" do
    Account.where(id: @account.id).update_all(cost_unit: nil)

    result = open_budget

    assert_predicate result, :unit_unconfigured?
    assert_equal 0, UsageBudget.count
  end

  test "exact replay returns the original outcome and a changed payload conflicts" do
    first = open_budget
    replay = open_budget

    assert_predicate replay, :opened?
    assert_equal first.budget.id, replay.budget.id
    assert_equal 1, UsageBudget.count

    conflicting = open_budget(amount: BigDecimal("200"))
    assert_predicate conflicting, :conflict?
    assert_equal 1, UsageBudget.count
  end

  test "an overlapping usable window refuses without writing" do
    open_budget

    overlapping = open_budget(operation_key: "open-2", starts_at: @starts_at + 1.hour)

    assert_predicate overlapping, :overlap?
    assert_equal 1, UsageBudget.count
  end

  test "a refusal consumes no key" do
    Account.where(id: @account.id).update_all(cost_unit: nil)
    open_budget
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")

    assert_predicate open_budget, :opened?
  end

  private

    def open_budget(actor: @owner, target: @owner, amount: BigDecimal("100"),
                    operation_key: "open-1", starts_at: nil, expires_at: nil)
      @starts_at ||= Time.current
      UsageBudgets::Open.call(
        actor: actor, target: target, starts_at: starts_at || @starts_at,
        expires_at: expires_at, amount: amount, operation_key: operation_key
      )
    end
end
