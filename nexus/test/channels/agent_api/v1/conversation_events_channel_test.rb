require "test_helper"

# The realtime mirror's gate, tier by tier: token, feed, workspace,
# listable conversation — rejection before any resource detail could leak.
class AgentAPI::V1::ConversationEventsChannelTest < ActionCable::Channel::TestCase
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @token = create_access_token_fixture(user: @human, name: "Member").token
  end

  def subscribe_with(items: nil, conversation: @conversation, workspace: @workspace, user: @human, token: @token)
    stub_connection(current_user: user, current_access_token: token)
    payload = { workspace_id: workspace.public_id, conversation_id: conversation.public_id }
    payload[:items] = items if items
    subscribe(payload)
  end

  test "the default feed is the full stream; lifecycle and transcript narrow" do
    subscribe_with
    assert subscription.confirmed?
    assert_has_stream "agent_api:v1:conversation:#{@conversation.public_id}:events"

    unsubscribe
    subscribe_with(items: "lifecycle")
    assert_has_stream "agent_api:v1:conversation:#{@conversation.public_id}:lifecycle"

    # ⚑T4: what a turn SAID, on its own broadcasting — a console takes
    # `lifecycle`, a chat surface `transcript`, and neither decodes what
    # it will discard.
    unsubscribe
    subscribe_with(items: "transcript")
    assert_has_stream "agent_api:v1:conversation:#{@conversation.public_id}:transcript"

    # THE EPHEMERAL FEED: a `bash` tail under a claim, a process's output under this conversation's
    # binding.
    unsubscribe
    subscribe_with(items: "progress")
    assert_has_stream "agent_api:v1:conversation:#{@conversation.public_id}:progress"
  end

  test "an unknown feed and a tombstoned conversation both reject like absence" do
    subscribe_with(items: "everything")
    assert subscription.rejected?

    @conversation.update!(tombstoned_at: Time.current)
    subscribe_with
    assert subscription.rejected?
  end

  # The funnel is the same one the REST doors read: a principal the row conceals is rejected like
  # absence, before any detail leaks; a reader is confirmed on the same stream.
  test "a concealed principal is rejected like absence; a reader is confirmed" do
    reader = users(:owner)
    token = create_access_token_fixture(user: reader, name: "Owner").token
    @conversation.update!(access_default: "none")

    subscribe_with(user: reader, token: token)
    assert subscription.rejected?

    @conversation.conversation_access_entries.create!(user: reader, level: "read")
    subscribe_with(user: reader, token: token)
    assert subscription.confirmed?
    assert_has_stream "agent_api:v1:conversation:#{@conversation.public_id}:events"
  end
end
