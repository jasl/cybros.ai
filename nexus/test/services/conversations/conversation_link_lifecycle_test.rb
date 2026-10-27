require "test_helper"

class Conversations::ConversationLinkLifecycleTest < ActiveSupport::TestCase
  setup do
    @human = users(:member)
    @sender = users(:agent)
    @recipient = create_agent_member(display_name: "Link peer", agent_identifier: "link-lifecycle-peer")
    @workspace = workspaces(:shared)
    @source = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @recipient)
    @target = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @recipient)
    outcome = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human)
    assert outcome.accepted?, outcome.outcome.inspect
    @link = outcome.value
  end

  test "endpoint access loss closes the grant and restoring access cannot reopen it" do
    outcome = set_access(@source, "none")
    assert outcome.accepted?, outcome.outcome.inspect
    assert @link.reload.closed?
    assert_equal "endpoint_access_lost", @link.close_reason
    closed_at = @link.closed_at
    assert set_access(@source, "full").accepted?
    assert_equal closed_at, @link.reload.closed_at
  end

  test "removing and restoring an endpoint Agent never revives its link" do
    assert_equal :removed, @sender.remove
    assert @link.reload.closed?
    assert_equal "principal_unavailable", @link.close_reason
    assert_equal :restored, @sender.restore
    assert @link.reload.closed?
  end

  test "losing access to the remote endpoint leaves an existing relation usable" do
    assert set_access(@target, "none").accepted?
    refute @link.reload.closed?
    refute @target.reload.writable_by?(@sender)
  end

  test "steward transfer closes the old grant even when both stewards keep access" do
    assert_equal :changed, @sender.change_steward(to: @human)
    assert @link.reload.closed?
    assert_equal "steward_changed", @link.close_reason
  end

  test "suspending a steward closes new grants and reactivation cannot revive them" do
    @sender.change_steward(to: @human)
    grant = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human).value
    assert_equal :suspended, @human.suspend
    assert_equal "principal_unavailable", grant.reload.close_reason
    assert_equal :reactivated, @human.reactivate
    assert grant.reload.closed?
  end

  test "private workspace narrowing preserves eligible endpoints but ownership transfer cuts them" do
    owner = @workspace.owner
    narrowed = Workspaces::UpdateAccessMode.call(workspace: @workspace, by: owner,
      to: "private", lock_version: @workspace.lock_version)
    assert_equal :updated, narrowed.outcome
    refute @link.reload.closed?
    transferred = Workspaces::TransferOwnership.call(workspace: @workspace, by: owner,
      to: @human, lock_version: @workspace.lock_version)
    assert_equal :transferred, transferred.outcome
    assert_equal "workspace_access_lost", @link.reload.close_reason
  end

  test "archive preserves a relation while tombstone closes it and forbids a fresh grant" do
    assert Conversations::Archive.call(conversation: @source).accepted?
    refute @link.reload.closed?
    assert Conversations::Tombstone.call(conversation: @source).accepted?
    assert_equal "endpoint_deleted", @link.reload.close_reason
    result = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human)
    refute result.accepted?
  end

  test "the default answerer is create-frozen and cannot retarget a relation" do
    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      Conversations::Update.call(conversation: @target, lock_version: @target.lock_version,
        changes: { answering_user: @sender })
    end
    assert_equal @recipient.id, @target.reload.answering_user_id
    assert_equal @recipient.id, @link.reload.second_agent_id
    refute @link.closed?
  end

  private

    def set_access(conversation, default)
      Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
        conversation: conversation, acting_user: @human, default: default, entries: []))
    end
end
