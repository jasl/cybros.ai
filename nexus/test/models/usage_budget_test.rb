require "test_helper"

# Budget ownership follows the user's kind: the system user cannot own a budget. Model validation
# enforces the window shape; writers serialize changes under the owning user's lock.
class UsageBudgetTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:owner)
  end

  test "a human budget is virtual balance and an agent budget is allowance" do
    human_budget = build_budget
    assert_predicate human_budget, :valid?

    agent = create_agent_member(steward: @human)
    agent_budget = build_budget(user: agent, user_kind: "agent", user_public_id: agent.public_id)
    assert_predicate agent_budget, :valid?
  end

  test "the system user owns neither budget role" do
    system = users(:system)
    budget = build_budget(user: system, user_kind: "agent", user_public_id: system.public_id)

    refute_predicate budget, :valid?
    assert_includes budget.errors.full_messages.join, "system User"
  end

  test "the snapshots must derive from the live user" do
    refute_predicate build_budget(user_kind: "agent"), :valid?
    refute_predicate build_budget(user_public_id: SecureRandom.uuid_v7), :valid?
  end

  test "the window is half-open and ordered" do
    now = Time.current

    refute_predicate build_budget(starts_at: now, expires_at: now), :valid?
    assert_predicate build_budget(starts_at: now, expires_at: now + 1.second), :valid?
  end

  # At most one usable window may cover an instant. A revoked sibling stops constraining; disjoint
  # windows coexist.
  test "usable windows for one user never overlap" do
    now = Time.current
    build_budget(starts_at: now, expires_at: now + 1.day).save!

    refute_predicate build_budget(starts_at: now + 1.hour), :valid?
    assert_predicate build_budget(starts_at: now + 1.day, expires_at: now + 2.days), :valid?

    UsageBudget.sole.update_columns(revoked_at: now)
    assert_predicate build_budget(starts_at: now + 1.hour), :valid?
  end

  test "exact duplicate creation settles on identity uniqueness" do
    now = Time.current
    build_budget(starts_at: now, expires_at: now + 1.day).save!
    duplicate = build_budget(starts_at: now, expires_at: now + 1.day)

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "usable_at filters the live half-open window in the database" do
    now = Time.current
    build_budget(starts_at: now - 2.hours, expires_at: now).save!
    build_budget(
      starts_at: now - 1.hour,
      expires_at: now + 2.hours,
      revoked_at: now - 30.minutes,
      revoked_by_public_id: @human.public_id,
      revoke_operation_key: "usable-scope-revoked"
    ).save!
    current = build_budget(starts_at: now, expires_at: now + 1.hour)
    current.save!
    build_budget(starts_at: now + 1.hour, expires_at: now + 2.hours).save!

    relation = UsageBudget.usable_at(now)

    assert_kind_of ActiveRecord::Relation, relation
    assert_equal [current.id], relation.pluck(:id)
  end

  test "the head totals never go negative" do
    refute_predicate build_budget(credited_amount: -1), :valid?
    refute_predicate build_budget(debited_amount: -1), :valid?
  end

  test "revoke evidence freezes whole or not at all" do
    partial = build_budget(revoked_at: Time.current)

    refute_predicate partial, :valid?
    assert_includes partial.errors.full_messages.join, "never partially"

    whole = build_budget(
      revoked_at: Time.current, revoked_by_public_id: @human.public_id,
      revoke_operation_key: "revoke-1"
    )
    assert_predicate whole, :valid?
  end

  private

    def build_budget(**overrides)
      UsageBudget.new(
        account: @account, user: @human, user_public_id: @human.public_id,
        user_kind: "human", starts_at: Time.current,
        **overrides
      )
    end
end
