require "test_helper"

class AccountRetentionTest < ActiveSupport::TestCase
  test "execution details default to ninety days and can be retained indefinitely" do
    assert_equal 90, Account.new.execution_details_retention_days
    account = accounts(:cybros)
    assert account.update(execution_details_retention_days: nil)
    assert_nil account.reload.execution_details_retention_days
    assert account.update(execution_details_retention_days: 365)
    assert_equal 365, account.reload.execution_details_retention_days
  end

  test "retention requires a positive whole number when enabled" do
    account = accounts(:cybros)
    [0, -1, 1.5, "not days"].each do |invalid|
      refute account.update(execution_details_retention_days: invalid)
      assert_not_empty account.errors[:execution_details_retention_days]
      assert_equal 90, account.reload.execution_details_retention_days
    end
  end
end
