require "test_helper"

# THE ONE ADDRESS RESOLVER of the conversation verbs: what `send`/`status`/`cancel` address — a
# child's LABEL among the sender conversation's own children, or a conversation's public id — read
# through `Conversation.visible_to` (the same access funnel), so the tool plane can never see what
# the member plane conceals. Three refusals by name: `unknown_conversation` (absent, concealed,
# tombstoned, another workspace, another parent's label), `side_conversation` (a side is never an
# addressee), and `ancestor_conversation` (a subagent may not send to or cancel a conversation above
# it in its own tree — it would stop or steer the turn it answers to; `status` reads an ancestor
# freely).
class Conversations::ConversationAddressTest < ActiveSupport::TestCase
  Address = Conversations::ConversationAddress

  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent = users(:agent)
    @root = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @child = spawn!(@root, label: "reviewer")
    @grandchild = spawn!(@child, label: "linter")
    @sibling = spawn!(@root, label: "tester")
  end

  def spawn!(parent, label: nil, **over)
    Conversation.create!(workspace: parent.workspace, creating_user: @agent, answering_user: @agent,
      parent_conversation: parent, parent_conversation_public_id: parent.public_id, spawn_label: label, **over)
  end

  def resolve(address, from: @root, sender: @agent, **over)
    Address.resolve(sender_conversation: from, sender: sender, address: address, **over)
  end

  test "a child is addressed by the label its spawn gave it — normalized — or by its public id" do
    assert_equal @child, resolve("reviewer").conversation
    assert_equal @child, resolve(" Reviewer ").conversation, "the label is normalized as the door normalized it"
    assert_equal @child, resolve(@child.public_id).conversation
    assert_equal @grandchild, resolve(@grandchild.public_id).conversation, "any readable id, not only a child's"
    assert_nil resolve("reviewer").refusal
  end

  test "a label is one parent's: a grandchild's label from the root, or a sibling's from a child, is unknown" do
    assert_equal :unknown_conversation, resolve("linter").refusal
    assert_equal :unknown_conversation, resolve("tester", from: @child).refusal
    assert_equal @grandchild, resolve("linter", from: @child).conversation
  end

  test "absent, blank, concealed, tombstoned and another workspace's conversations are unknown_conversation" do
    assert_equal :unknown_conversation, resolve("nobody").refusal
    assert_equal :unknown_conversation, resolve("").refusal
    assert_equal :unknown_conversation, resolve(nil).refusal
    assert_equal :unknown_conversation, resolve(SecureRandom.uuid_v7).refusal
    assert_equal :unknown_conversation, resolve("not a label!").refusal

    concealed = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @human,
      access_default: "none")
    assert_equal :unknown_conversation, resolve(concealed.public_id).refusal, "`none` reads as absence"
    assert_equal concealed, resolve(concealed.public_id, sender: @human).conversation, "the creator reads it"

    gone = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      tombstoned_at: Time.current)
    assert_equal :unknown_conversation, resolve(gone.public_id).refusal

    elsewhere = Conversation.create!(workspace: workspaces(:personal), creating_user: @human, answering_user: @agent)
    assert_equal :unknown_conversation, resolve(elsewhere.public_id).refusal
  end

  test "a side is never an addressee" do
    side = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent, side: true)
    assert_equal :side_conversation, resolve(side.public_id).refusal
  end

  test "an ancestor is refused for a send or a cancel, admitted for a read; a sibling and one's own conversation resolve" do
    assert_equal :ancestor_conversation, resolve(@root.public_id, from: @child).refusal
    assert_equal :ancestor_conversation, resolve(@root.public_id, from: @grandchild).refusal, "any ancestor, not only the parent"
    assert_equal :ancestor_conversation, resolve(@child.public_id, from: @grandchild).refusal
    assert_equal @root, resolve(@root.public_id, from: @child, admit_ancestors: true).conversation
    assert_equal @sibling, resolve(@sibling.public_id, from: @child).conversation, "a sibling is not above"
    assert_equal @root, resolve(@root.public_id, from: @root).conversation, "one's own conversation is not above itself"
    assert_equal @child, resolve(@child.public_id, from: @root).conversation, "a child is below"
  end

  test "the funnel is the member plane's: the resolver reads through Conversation.visible_to" do
    read_only = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @human,
      access_default: "read")
    assert_equal read_only, resolve(read_only.public_id).conversation, "`read` is visible; the door judges the write"
    assert_includes Conversation.visible_to(@agent, workspace: @workspace), read_only
  end
end
