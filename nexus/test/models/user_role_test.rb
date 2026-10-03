require "test_helper"

class UserRoleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
    @owner = users(:owner)
  end

  test "change_role promotes and demotes between member and admin" do
    assert_equal :role_changed, @member.change_role(to: :admin)
    assert_equal "admin", @member.reload.role

    assert_equal :role_changed, @member.change_role(to: :member)
    assert_equal "member", @member.reload.role
  end

  test "change_role rejects roles outside the assignable vocabulary" do
    assert_equal :invalid_role, @member.change_role(to: :owner)
    assert_equal :invalid_role, @member.change_role(to: :system)
    assert_equal "member", @member.reload.role
  end

  test "an agent member cannot be promoted through human membership administration" do
    agent = users(:agent)

    assert_equal :not_administrable, agent.change_role(to: :admin)
    assert_equal "member", agent.reload.role
  end

  test "role changes advance no authority generation and fence no session" do
    session = create_browser_session(identities(:member))

    assert_no_changes -> { @member.reload.authority_generation } do
      @member.change_role(to: :admin)
    end
    assert session.reload.usable?
  end

  test "a removed membership refuses role changes" do
    @member.remove
    assert_equal :not_active, @member.reload.change_role(to: :admin)
    assert_equal "member", @member.reload.role
  end

  test "the owner cannot be demoted through change_role" do
    assert_equal :owner_protected, @owner.change_role(to: :member)
    assert_equal "owner", @owner.reload.role
  end

  test "administrable_by? requires an administrator and excludes owner and self" do
    assert @member.administrable_by?(@owner)
    assert_not @owner.administrable_by?(@owner)
    assert_not @member.administrable_by?(@member)

    @member.change_role(to: :admin)
    assert_not @owner.administrable_by?(@member.reload)
  end

  test "device-flow presence accepts every active human member" do
    assert @member.active_human_member?
    assert @owner.active_human_member?

    # Agent principals and inactive humans are excluded from the surface.
    assert_not users(:agent).active_human_member?
    @member.update!(status: :suspended)
    assert_not @member.active_human_member?
  end
end
