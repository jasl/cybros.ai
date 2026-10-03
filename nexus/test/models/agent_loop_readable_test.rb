require "test_helper"

# THE LOOP DOOR onto the conversation's rows: a loop-backed loop is readable and writable exactly as
# its conversation is; a standalone loop is the caller's own object and keeps the workspace rule —
# the access-control list is the conversation's, and a loop has none of its own.
class AgentLoopReadableTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @creator = users(:member)
    @reader = users(:curator)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @creator,
      access_default: "none")
    @hosted = create_loop_backed_turn(conversation: @conversation, acting_user: @creator).agent_loop
    @standalone = AgentLoop.create!(workspace: @workspace, creating_user: @creator, approval_mode: "bypass")
  end

  test "a loop-backed loop follows its conversation's level; a standalone loop is unaffected" do
    assert_includes AgentLoop.readable_by(@creator), @hosted
    assert_not_includes AgentLoop.readable_by(@reader), @hosted, "`none` conceals the loop with the row"
    assert_includes AgentLoop.readable_by(@reader), @standalone

    @conversation.conversation_access_entries.create!(user: @reader, level: "read")
    assert_includes AgentLoop.readable_by(@reader), @hosted

    @conversation.update!(access_default: "read")
    assert_includes AgentLoop.readable_by(users(:owner)), @hosted
    assert_includes AgentLoop.where(workspace_id: @workspace.id).listable.readable_by(@reader), @hosted,
      "composes under the workspace filter and the tombstone"
  end

  test "writable_by? is the conversation's full for a loop-backed loop, the workspace's rule standalone" do
    @conversation.update!(access_default: "read")

    assert @hosted.writable_by?(@creator), "the creator is full by derivation"
    assert_not @hosted.writable_by?(@reader), "read cannot write"
    assert @standalone.writable_by?(@reader), "a standalone loop has no level: the workspace decides"

    @conversation.conversation_access_entries.create!(user: @reader, level: "full")
    assert @hosted.writable_by?(@reader)

    @workspace.update_column(:state, "archived")
    assert_not @hosted.reload.writable_by?(@creator), "full on the row is still conjunct with the workspace"
    assert_not @standalone.reload.writable_by?(@creator)
  ensure
    @workspace.update_column(:state, "active")
  end
end
