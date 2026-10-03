require "test_helper"

# Completion is gated on the absence of nonterminal Workspace work. The acceptance transaction
# already first-stopped everything it could see (M5), while admission takes the same Workspace
# authority lock. The gate is therefore normally vacuous at checkpoint 1, but remains the single
# integrity seam later descendant kinds must extend.
class WorkspaceDescendantGateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  def workspace_with_work(state:)
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Gate #{SecureRandom.hex(3)}"
    )
    one_shot = OneShot.create!(
      account: @account, workspace: workspace, creating_user: @owner,
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    workspace.update_columns(state: state, archived_at: Time.current, deleted_at: Time.current)
    [workspace, invocation]
  end

  test "archiving waits for its last nonterminal invocation" do
    workspace, invocation = workspace_with_work(state: "archiving")

    assert_equal :descendants_pending,
      Workspaces::CompleteTransition.call(workspace: workspace).outcome
    assert_equal "archiving", workspace.reload.state

    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: invocation.id), reason: "workspace_archived"
    )

    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: workspace).outcome
    assert_equal "archived", workspace.reload.state
  end

  test "deleting waits on the same gate" do
    workspace, invocation = workspace_with_work(state: "deleting")

    assert_equal :descendants_pending,
      Workspaces::CompleteTransition.call(workspace: workspace).outcome

    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: invocation.id), reason: "workspace_deleted"
    )

    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: workspace).outcome
    assert_equal "deleted", workspace.reload.state
  end

  # Restoring reopens the Workspace; it has no destructive consequence and
  # nothing to wait for.
  test "restoring is not gated" do
    workspace, = workspace_with_work(state: "restoring")

    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: workspace).outcome
    assert_equal "active", workspace.reload.state
  end

  # Terminal work is not pending work. The gate reads the invocation's own
  # status, and after Stage 2 that is the only status there is — no second
  # row can hold a Workspace open after its work finished, or let one
  # through while work is still live.
  test "the gate reads invocation status, and only terminal work releases it" do
    workspace, invocation = workspace_with_work(state: "archiving")
    ModelInvocation.where(id: invocation.id).update_all(status: "completed", terminal_at: Time.current)

    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: workspace).outcome

    other, = workspace_with_work(state: "archiving")

    assert_equal :descendants_pending,
      Workspaces::CompleteTransition.call(workspace: other).outcome
  end

  test "a Workspace with no work at all completes immediately" do
    workspace = @account.workspaces.create!(
      creator: @owner, owner: @owner, name: "Empty #{SecureRandom.hex(3)}"
    )
    workspace.update_columns(state: "archiving", archived_at: Time.current)

    assert_equal :completed, Workspaces::CompleteTransition.call(workspace: workspace).outcome
  end
end
