require "test_helper"

class Workspaces::UpdateAccessModeTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper

  test "account_wide to private cuts every non-owner immediately" do
    shared = workspaces(:shared)
    agent = create_agent_member(steward: users(:member), agent_identifier: "w3-mode-cut")
    assert shared.data_accessible_by?(users(:member))
    assert shared.data_accessible_by?(agent)

    result = Workspaces::UpdateAccessMode.call(
      workspace: shared, by: users(:owner), to: :private,
      lock_version: shared.lock_version
    )

    assert_equal :updated, result.outcome
    shared.reload
    assert_not shared.data_accessible_by?(users(:member))
    assert_not shared.data_accessible_by?(agent)
    assert shared.data_accessible_by?(users(:owner))
  end

  test "private to account_wide authorizes future access" do
    personal = workspaces(:personal)
    assert_not personal.data_accessible_by?(users(:owner))

    result = Workspaces::UpdateAccessMode.call(
      workspace: personal, by: users(:curator), to: :account_wide,
      lock_version: personal.lock_version
    )

    assert_equal :updated, result.outcome
    assert personal.reload.data_accessible_by?(users(:owner))
  end

  test "only the active owner changes the mode and only while active" do
    shared = workspaces(:shared)

    not_owner = Workspaces::UpdateAccessMode.call(
      workspace: shared, by: users(:member), to: :private,
      lock_version: shared.lock_version
    )
    assert_equal :not_workspace_owner, not_owner.outcome

    shared.update_columns(state: "archived", archived_at: Time.current)
    archived = Workspaces::UpdateAccessMode.call(
      workspace: shared, by: users(:owner), to: :private,
      lock_version: shared.reload.lock_version
    )
    assert_equal :workspace_not_active, archived.outcome
  end

  test "a stale lock version loses and an unknown mode is invalid" do
    shared = workspaces(:shared)

    stale = Workspaces::UpdateAccessMode.call(
      workspace: shared, by: users(:owner), to: :private, lock_version: 99
    )
    assert_equal :stale_object, stale.outcome
    assert shared.reload.account_wide?

    invalid = Workspaces::UpdateAccessMode.call(
      workspace: shared, by: users(:owner), to: :public, lock_version: shared.lock_version
    )
    assert_equal :invalid_access_mode, invalid.outcome
    assert shared.reload.account_wide?
  end
end
