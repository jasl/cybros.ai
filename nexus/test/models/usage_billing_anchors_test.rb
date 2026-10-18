require "test_helper"

# C2-3 start-shape: the ledger head and the grouping identity — the two small
# anchors beside the receipt.
class UsageBillingAnchorsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "a billing subject is key plus ownership and nothing else" do
    subject = BillingSubject.create!(
      account: @account, owning_user: users(:owner), key: "team-alpha"
    )

    assert_predicate subject.public_id, :present?
    # Grouping only: the row carries NO status, balance, limit, quota, payer,
    # reservation, cost-unit, or projection column. Pinned on the column set
    # so a later "just one flag" has to argue with this test.
    assert_equal %w[
      account_id created_at id key owning_user_id public_id updated_at
    ], BillingSubject.column_names.sort
  end

  test "the key is unique per account and frozen" do
    BillingSubject.create!(account: @account, owning_user: users(:owner), key: "team-alpha")

    assert_raises(ActiveRecord::RecordNotUnique) do
      BillingSubject.create!(account: @account, owning_user: users(:member), key: "team-alpha")
    end
  end

  test "the owner must share the account" do
    # An unsaved User carries the foreign account_id; mutating a persisted
    # fixture would trip its own readonly guard before this validation runs.
    foreign = BillingSubject.new(
      account: @account, owning_user: User.new(account_id: @account.id + 1), key: "x"
    )

    refute_predicate foreign, :valid?
    assert_includes foreign.errors.full_messages.join, "same Account"
  end
end
