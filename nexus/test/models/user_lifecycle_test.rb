require "test_helper"

class UserLifecycleTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
    @owner = users(:owner)
  end

  test "suspend fences the member and advances the authority generation" do
    session = create_browser_session(identities(:member))

    assert_no_changes -> { @member.reload.managed_resource_shutdown_generation } do
      assert_changes -> { @member.reload.authority_generation }, from: 0, to: 1 do
        assert_equal :suspended, @member.suspend
      end
    end

    assert @member.reload.suspended?
    assert_not session.reload.usable?
  end

  test "reactivate restores access without reviving old credentials" do
    session = create_browser_session(identities(:member))
    @member.suspend

    assert_no_changes -> { @member.reload.authority_generation } do
      assert_equal :reactivated, @member.reactivate
    end

    assert @member.reload.active?
    assert_not session.reload.usable?

    fresh = create_browser_session(identities(:member))
    assert fresh.usable?
  end

  test "reactivate refuses a member who is not suspended" do
    assert_equal :not_suspended, @member.reactivate
  end

  test "suspend refuses a member who is not active" do
    @member.suspend
    assert_equal :not_active, @member.reload.suspend
  end

  test "remove keeps the identity link, fences credentials, and reserves the email" do
    session = create_browser_session(identities(:member))

    assert_changes(
      -> { @member.reload.managed_resource_shutdown_generation },
      from: 0,
      to: 1
    ) do
      assert_equal :removed, @member.remove
    end

    @member.reload
    assert @member.removed?
    # Recoverable soft delete: attribution and the sign-in survive; the
    # status check is what blocks access.
    assert_equal identities(:member), @member.identity
    assert_equal 1, @member.authority_generation
    assert_not session.reload.usable?
    assert_equal "member@example.com", @member.identity.email
    assert_not @member.identity.password_resettable?
  end

  test "remove accepts a suspended member" do
    @member.suspend

    assert_equal :removed, @member.reload.remove
    assert_equal 2, @member.reload.authority_generation
    assert_equal 1, @member.managed_resource_shutdown_generation
  end

  test "a removed membership refuses every transition except restore" do
    @member.remove
    @member.reload

    assert_equal :not_active, @member.suspend
    assert_equal :not_suspended, @member.reactivate
    assert_no_changes -> { @member.reload.managed_resource_shutdown_generation } do
      assert_equal :not_active, @member.remove
    end
  end

  test "restore reopens access without reviving old credentials" do
    session = create_browser_session(identities(:member))
    @member.remove

    assert_no_changes -> { @member.reload.managed_resource_shutdown_generation } do
      assert_no_changes -> { @member.reload.authority_generation } do
        assert_equal :restored, @member.reload.restore
      end
    end

    assert @member.reload.active?
    assert_not session.reload.usable?

    fresh = create_browser_session(identities(:member))
    assert fresh.usable?
  end

  test "restore refuses a member who is not removed" do
    assert_equal :not_removed, @member.restore

    @member.suspend
    assert_equal :not_removed, @member.reload.restore
  end

  test "the owner is protected from suspend and remove" do
    assert_equal :owner_protected, @owner.suspend
    assert_no_changes -> { @owner.reload.managed_resource_shutdown_generation } do
      assert_equal :owner_protected, @owner.remove
    end
    assert @owner.reload.active?
  end

  test "a former owner is an ordinary administrable admin after transfer" do
    # While an active owner exists the active-admin set can never empty, so
    # the last-admin guard stays quiet and the former owner is suspendable.
    @member.change_role(to: :admin)
    assert_equal :transferred, @account.transfer_ownership(to: @member.reload, by: @owner)

    former = @owner.reload
    assert_equal "admin", former.role
    assert_equal :suspended, former.suspend
  end

  test "remove is refused while the Human owns a non-tombstoned Workspace" do
    curator = users(:curator)

    assert_no_changes -> { curator.reload.status } do
      assert_equal :workspace_ownership_transfer_required, curator.remove
    end
    assert_equal 0, curator.reload.managed_resource_shutdown_generation
  end

  test "suspend never consults Workspace ownership" do
    assert_equal :suspended, users(:curator).suspend
    assert users(:curator).reload.suspended?
  end

  test "remove proceeds after explicit transfer releases every ownership" do
    curator = users(:curator)
    personal = workspaces(:personal)

    result = Workspaces::TransferOwnership.call(
      workspace: personal, by: curator, to: @owner, lock_version: personal.lock_version
    )
    assert_equal :transferred, result.outcome

    assert_equal :removed, curator.remove
  end

  test "remove proceeds over tombstoned ownership without clearing the anchor" do
    curator = users(:curator)
    personal = workspaces(:personal)
    accepted = Workspaces::Delete.call(
      workspace: personal, by: curator, lock_version: personal.lock_version
    )
    assert_equal :accepted, accepted.outcome

    assert_equal :removed, curator.remove
    # The tombstone keeps its Human owner as a durable ownership/attribution anchor until physical
    # collection.
    assert_equal curator.id, personal.reload.owner_id
  end

  test "an archived Workspace still blocks its owner's removal" do
    workspaces(:personal).update_columns(state: "archived", archived_at: Time.current)

    assert_equal :workspace_ownership_transfer_required, users(:curator).remove
  end
end

# THE NAMED DEFINITIONS GO WITH THEIR DECLARER: a parent's removal flips its instance-scoped rows to
# removed under its lock; a published row survives; restore restores none.
class UserLifecycleNamedDefinitionsTest < ActiveSupport::TestCase
  include LoopLaneTestHelper

  CONFIGURATION = {
    tool_definitions: [], approval_mode: nil, approval_rules: nil, prompt_mechanism: "default",
    prompt_template: nil, compaction_policy: nil, default_model: nil,
  }.freeze

  def declare(caller, name, scope)
    Users::DeclareNamedDefinition.call(caller: caller, name: name, scope: scope, description: "#{name}.",
      configuration: CONFIGURATION).user
  end

  test "remove cascades the instance rows, keeps the published one, and restore restores none" do
    parent = create_agent_member(display_name: "Parent", agent_identifier: "rho.parent")
    reviewer = declare(parent, "reviewer", "instance")
    docs = declare(parent, "docs", "instance")
    published = declare(parent, "shared", "steward")

    assert_equal :removed, parent.remove
    assert_predicate reviewer.reload, :removed?
    assert_predicate docs.reload, :removed?
    assert_predicate published.reload, :active?
    assert_equal 1, reviewer.authority_generation, "each through its own remove"
    assert_equal "reviewer", reviewer.handle, "removal keeps the handle"

    assert_equal :restored, parent.restore
    assert_predicate reviewer.reload, :removed?, "the next boot's declare edge re-declares from the files"
    assert_predicate docs.reload, :removed?
  end

  test "a named row's own removal is ordinary and reversible" do
    parent = create_agent_member(display_name: "Parent", agent_identifier: "rho.parent")
    reviewer = declare(parent, "reviewer", "instance")

    assert_equal :removed, reviewer.remove
    assert_predicate parent.reload, :active?
    assert_equal :restored, reviewer.restore
    assert_predicate reviewer.reload, :active?
  end
end
