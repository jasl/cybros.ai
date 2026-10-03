require "test_helper"

# The conversation stage of Workspaces::Collect under the Reap protocol
# (the round review's find: the stage shipped with none of its siblings'
# defenses and zero coverage): lock-first per conversation, pins and
# obligations as level-triggered skips, and one fenced child never walling
# the whole daily pass off from its later stages.
class Workspaces::CollectConversationsTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:personal)
    @user = users(:curator)
  end

  def create_conversation
    Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def fork_child(of:)
    child = create_conversation
    ConversationAncestry.create!(
      account: @workspace.account, conversation: child,
      ancestor_conversation: of, depth: 1, boundary_position: -1
    )
    child
  end

  def tombstone(workspace, at:)
    workspace.update_columns(state: "deleted", deleted_at: at)
  end

  test "a fork tree drains leaves-first across level-triggered passes" do
    parent = create_conversation
    child = fork_child(of: parent)
    tombstone(@workspace, at: 31.days.ago)

    first = Workspaces::Collect.call(budget: 10)
    assert_not Conversation.exists?(child.id), "the unpinned leaf drains"
    assert Conversation.exists?(parent.id),
      "the pinned ancestor is excluded from the same window, never an error"
    assert first.more? || first[:processed].positive?

    Workspaces::Collect.call(budget: 10)
    assert_not Conversation.exists?(parent.id), "the next pass finds the freed ancestor"
    assert_nil Workspace.find_by(id: @workspace.id)
  end

  test "an obligation-fenced child skips without walling the pass" do
    parent = create_conversation
    child = fork_child(of: parent)
    holder = OneShot.create!(
      account: @workspace.account, workspace: workspaces(:shared),
      creating_user: users(:member), workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: holder)
    ModelInvocation.where(id: invocation.id)
      .update_all(status: "running", conversation_id: child.id)
    tombstone(@workspace, at: 31.days.ago)

    result = Workspaces::Collect.call(budget: 10)

    assert Conversation.exists?(child.id), "nonterminal work fences the child"
    assert Conversation.exists?(parent.id), "the pin fences the ancestor"
    assert Workspace.exists?(@workspace.id)
    assert_kind_of Sweeps::Pass, result, "the pass completed instead of aborting on the wall"

    ModelInvocation.where(id: invocation.id).update_all(status: "completed")
    Workspaces::Collect.call(budget: 10)
    Workspaces::Collect.call(budget: 10)
    assert_not Conversation.exists?(parent.id), "settlement releases the whole tree"
  end

  test "a settled reply history drains its invocations before the row" do
    conversation = create_conversation
    holder = OneShot.create!(
      account: @workspace.account, workspace: workspaces(:shared),
      creating_user: users(:member), workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: holder)
    ModelInvocation.where(id: invocation.id)
      .update_all(status: "completed", conversation_id: conversation.id, one_shot_id: nil)
    tombstone(@workspace, at: 31.days.ago)

    Workspaces::Collect.call(budget: 10)

    assert_not Conversation.exists?(conversation.id)
    assert_not ModelInvocation.exists?(invocation.id),
      "the explicit drain ran; the loud FK never fired"
  end
end
