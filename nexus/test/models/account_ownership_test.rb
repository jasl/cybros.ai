require "test_helper"

class AccountOwnershipTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @member = users(:member)
  end

  test "transfer swaps both roles in one accepted outcome" do
    @member.change_role(to: :admin)

    assert_equal :transferred, @account.transfer_ownership(to: @member.reload, by: @owner)

    assert_equal "owner", @member.reload.role
    assert_equal "admin", @owner.reload.role
    assert_equal @member, @account.owner
  end

  test "transfer advances no authority generation and fences no session" do
    @member.change_role(to: :admin)
    owner_session = create_browser_session(identities(:owner))

    assert_no_changes -> { [@owner.reload.authority_generation, @member.reload.authority_generation] } do
      assert_equal :transferred, @account.transfer_ownership(to: @member.reload, by: @owner)
    end
    assert owner_session.reload.usable?
  end

  test "only the current owner can transfer" do
    @member.change_role(to: :admin)

    assert_equal :owner_required, @account.transfer_ownership(to: @owner, by: @member.reload)
    assert_equal "owner", @owner.reload.role
  end

  test "the target must be an active human admin" do
    assert_equal :target_not_eligible, @account.transfer_ownership(to: @member, by: @owner)

    @member.change_role(to: :admin)
    @member.reload.suspend
    assert_equal :target_not_eligible, @account.transfer_ownership(to: @member.reload, by: @owner)

    assert_equal "owner", @owner.reload.role
  end

  test "a transfer accepted first defeats a stale demotion of the new owner" do
    @member.change_role(to: :admin)
    assert_equal :transferred, @account.transfer_ownership(to: @member.reload, by: @owner)

    # The demotion re-checks under the row lock and finds an owner.
    assert_equal :owner_protected, @member.reload.change_role(to: :member)
  end

  test "a demotion accepted first defeats a stale transfer" do
    @member.change_role(to: :admin)
    target = @member.reload
    assert_equal :role_changed, target.change_role(to: :member)

    # The transfer re-checks under the locks and rejects the non-admin target.
    assert_equal :target_not_eligible, @account.transfer_ownership(to: target, by: @owner)
    assert_equal "owner", @owner.reload.role
  end
end
