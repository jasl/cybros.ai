require "test_helper"

# The append-only ledger entry — kind determines authorship,
# every duplicate-effect fence is an ordinary unique index, and nothing
# persisted can change.
class UsageBudgetEntryTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @budget = UsageBudget.create!(
      account: @account, user: users(:owner), user_public_id: users(:owner).public_id,
      user_kind: "human", starts_at: Time.current
    )
  end

  test "an entry is immutable after insert" do
    entry = build_entry.tap(&:save!)

    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(amount: 2) }
  end

  test "human-authored kinds carry their actor and no kernel identity" do
    refute_predicate build_entry(actor_public_id: nil), :valid?
    refute_predicate build_entry(usage_record_public_id: SecureRandom.uuid_v7), :valid?
  end

  test "kernel kinds derive from the receipt they charge" do
    charge = build_entry(
      kind: "charge", actor_public_id: nil,
      usage_record_public_id: SecureRandom.uuid_v7
    )
    assert_predicate charge, :valid?

    refute_predicate build_entry(kind: "charge", actor_public_id: nil), :valid?
  end

  test "sequence and operation key are each unique per budget" do
    build_entry.save!

    assert_raises(ActiveRecord::RecordNotUnique) { build_entry(operation_key: "other").save! }
    assert_raises(ActiveRecord::RecordNotUnique) { build_entry(entry_sequence: 2).save! }
  end

  test "the amount is exact and nonnegative and the kind closed" do
    refute_predicate build_entry(amount: -1), :valid?
    refute_predicate build_entry(kind: "gift"), :valid?
    refute_predicate build_entry(cost_unit: nil), :valid?
  end

  private

    def build_entry(**overrides)
      UsageBudgetEntry.new(
        usage_budget: @budget, account_public_id: @account.public_id,
        user_public_id: users(:owner).public_id, entry_sequence: 1,
        kind: "initial_grant", amount: BigDecimal("100"), cost_unit: "USD",
        actor_public_id: users(:owner).public_id, operation_key: "open-1",
        **overrides
      )
    end
end
