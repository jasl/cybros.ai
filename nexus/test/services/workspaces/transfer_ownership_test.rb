require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class Workspaces::TransferOwnershipTest < ActiveSupport::TestCase
  include AgentMembershipTestHelper
  include RowLockTestHelper

  uses_transaction :test_transfer_to_a_target_and_target_removal_preserve_final_ownership_integrity

  setup do
    @workspace = workspaces(:personal)
  end

  test "the active Human owner transfers to another active same-account Human" do
    result = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: users(:owner),
      lock_version: @workspace.lock_version
    )

    assert_equal :transferred, result.outcome
    @workspace.reload
    assert_equal users(:owner), @workspace.owner
    # Creator attribution never follows the transfer.
    assert_equal users(:curator), @workspace.creator
  end

  test "only the current active owner may transfer" do
    not_owner = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:owner), to: users(:owner),
      lock_version: @workspace.lock_version
    )
    assert_equal :not_workspace_owner, not_owner.outcome

    assert_equal :suspended, users(:curator).suspend
    suspended_owner = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator).reload, to: users(:owner),
      lock_version: @workspace.lock_version
    )
    assert_equal :not_workspace_owner, suspended_owner.outcome
  end

  test "the target must be an active Human" do
    to_agent = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: users(:agent),
      lock_version: @workspace.lock_version
    )
    assert_equal :target_not_eligible, to_agent.outcome

    third = accounts(:cybros).create_direct_member(
      display_name: "Third", email: "third@example.com", role: :member,
      password: "correct horse battery", password_confirmation: "correct horse battery"
    ).member
    assert_equal :suspended, third.suspend
    to_suspended = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: third.reload,
      lock_version: @workspace.lock_version
    )
    assert_equal :target_not_eligible, to_suspended.outcome
  end

  test "self-transfer is rejected by the domain, not a rendering layer" do
    result = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: users(:curator),
      lock_version: @workspace.lock_version
    )

    assert_equal :target_not_eligible, result.outcome
    assert_equal users(:curator), @workspace.reload.owner
  end

  test "transfer requires the active state" do
    @workspace.update_columns(state: "archived", archived_at: Time.current)

    result = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: users(:owner),
      lock_version: @workspace.lock_version
    )

    assert_equal :workspace_not_active, result.outcome
  end

  test "a stale lock version loses without changing ownership" do
    assert @workspace.update(name: "Bumped")

    result = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: users(:owner),
      lock_version: 0
    )

    assert_equal :stale_object, result.outcome
    assert_equal users(:curator), @workspace.reload.owner
  end

  test "private access follows the transfer immediately, Agents included" do
    agent = users(:agent)
    dedicated = workspaces(:dedicated)
    assert dedicated.data_accessible_by?(agent)

    result = Workspaces::TransferOwnership.call(
      workspace: dedicated, by: users(:owner), to: users(:member),
      lock_version: dedicated.lock_version
    )

    assert_equal :transferred, result.outcome
    dedicated.reload
    assert_not dedicated.data_accessible_by?(users(:owner))
    assert_not dedicated.data_accessible_by?(agent)
    assert dedicated.data_accessible_by?(users(:member))
    # The dedication tag never follows ownership.
    assert_equal "fixture-agent-installation", dedicated.agent_identifier
  end

  test "transfer-versus-removal converges in both serial orders" do
    # Transfer first makes the target an owner, so its later removal waits for
    # another explicit transfer.
    target = users(:member)
    transfer_first = Workspaces::TransferOwnership.call(
      workspace: @workspace, by: users(:curator), to: target,
      lock_version: @workspace.lock_version
    )
    assert_equal :transferred, transfer_first.outcome
    assert_equal :workspace_ownership_transfer_required, target.remove
    assert_equal target, @workspace.reload.owner

    # Removal first uses a fresh Workspace and target, so the rejection is
    # caused by the target's state rather than the first scenario's transfer.
    fresh_workspace = Workspaces::Create.call(
      creator: users(:owner), name: "Removal first transfer"
    ).workspace
    removed_target = accounts(:cybros).create_direct_member(
      display_name: "Removed target", email: "removed-target@example.com", role: :member,
      password: "correct horse battery", password_confirmation: "correct horse battery"
    ).member
    assert_equal :removed, removed_target.remove
    removal_first = Workspaces::TransferOwnership.call(
      workspace: fresh_workspace, by: users(:owner), to: removed_target.reload,
      lock_version: fresh_workspace.lock_version
    )
    assert_equal :target_not_eligible, removal_first.outcome
    assert_equal users(:owner), fresh_workspace.reload.owner
  end

  test "transfer to a target and target removal preserve final ownership integrity" do
    source = accounts(:cybros).create_direct_member(
      display_name: "Transfer race Source",
      email: "transfer-source-#{SecureRandom.hex(8)}@example.com",
      role: :member,
      password: "correct horse battery",
      password_confirmation: "correct horse battery"
    ).member
    source_id = source.id
    source_identity_id = source.identity_id
    target = accounts(:cybros).create_direct_member(
      display_name: "Transfer race Target",
      email: "transfer-target-#{SecureRandom.hex(8)}@example.com",
      role: :member,
      password: "correct horse battery",
      password_confirmation: "correct horse battery"
    ).member
    target_id = target.id
    target_identity_id = target.identity_id
    workspace = Workspaces::Create.call(
      creator: source, name: "Transfer and target removal race"
    ).workspace
    workspace_id = workspace.id
    lock_version = workspace.lock_version
    held_target = hold_row_lock(User, target_id)
    transfer = start_database_call do
      Workspaces::TransferOwnership.call(
        workspace: Workspace.find(workspace_id),
        by: User.find(source_id),
        to: User.find(target_id),
        lock_version: lock_version
      )
    end

    wait_until_waiting_on_lock(transfer.pid)
    removal = start_database_call { User.find(target_id).remove }
    wait_until_waiting_on_lock(transfer.pid, removal.pid)

    release_row_lock(held_target)
    held_target = nil
    transfer_result = finish_database_call(transfer)
    transfer = nil
    removal_result = finish_database_call(removal)
    removal = nil

    assert_includes(
      [
        [:transferred, :workspace_ownership_transfer_required],
        [:target_not_eligible, :removed],
      ],
      [transfer_result.outcome, removal_result]
    )

    ApplicationRecord.uncached do
      workspace = Workspace.find(workspace_id)
      target = User.find(target_id)
      assert_not(
        target.removed? && workspace.non_tombstoned? && workspace.owner == target
      )
      if transfer_result.outcome == :transferred
        assert target.active?
        assert_equal target, workspace.owner
      else
        assert target.removed?
        assert_equal source_id, workspace.owner_id
      end
    end
  ensure
    begin
      release_row_lock(held_target) if held_target
    ensure
      stop_database_call(transfer) if transfer
      stop_database_call(removal) if removal
      if workspace_id
        StoreEntry.where(workspace_id: workspace_id).delete_all
        Workspace.where(id: workspace_id).delete_all
      end
      User.where(id: target_id).delete_all if target_id
      User.where(id: source_id).delete_all if source_id
      Identity.where(id: target_identity_id).delete_all if target_identity_id
      Identity.where(id: source_identity_id).delete_all if source_identity_id
    end
  end
end
