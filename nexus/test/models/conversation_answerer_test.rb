require "test_helper"

# The answering profile as a stored fact: `answering_user_id` on the row — the creator by default
# whatever its kind, frozen at create, of the conversation's own account. `account` derives from the
# workspace through the house `belongs_to … default:` (B29), no callback.
class ConversationAnswererTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent = users(:agent)
  end

  test "the default answerer is the creator, of either kind" do
    by_human = Conversation.create!(workspace: @workspace, creating_user: @human)
    assert_equal @human, by_human.answering_user, "a Human's conversation is answered by the Human: the plain chat"
    assert_nil by_human.declaring_profile

    by_agent = Conversation.create!(workspace: @workspace, creating_user: @agent)
    assert_equal @agent, by_agent.answering_user, "an agent's conversation brings its engine"
    assert_equal @agent, by_agent.declaring_profile
  end

  test "a named answerer is the declaring profile whoever created the row" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)

    assert_equal @human, conversation.creating_user
    assert_equal @agent, conversation.answering_user
    assert_equal @agent, conversation.declaring_profile, "a Human's conversation, an agent's engine"
    assert_equal @agent, conversation.reload.answering_user, "stored, never derived"
  end

  test "the answerer never changes after create" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)

    assert_raises(ActiveRecord::ReadonlyAttributeError) { conversation.update!(answering_user: @human) }
    assert_equal @agent, conversation.reload.answering_user
  end

  # The cross-account half of answerer_must_share_the_account is unreachable
  # in a singleton-account install (index_accounts_singleton), like its
  # creator sibling: defense in depth, not bitten here.
  test "account derives from the workspace by default" do
    conversation = Conversation.new(workspace: @workspace, creating_user: @human)
    assert_nil conversation.account_id

    assert_predicate conversation, :valid?
    assert_equal @workspace.account_id, conversation.account_id
  end

  # THE TURN RECORDS WHO ANSWERED: one column on EVERY kind — the between-turn summary turn is
  # loop-backed and its loop derives from it — defaulting to the conversation's stored answerer at
  # creation and create-frozen; the loop behind a turn answers as the TURN does, so every
  # judged-for-the-answerer site follows the turn with no edit.
  def build_turn(conversation, **overrides)
    ConversationTurn.create!(**{
      account: conversation.account, conversation: conversation, position: conversation.timeline_position_head,
      kind: "direct_reply", role: "assistant", status: "completed",
      speaker_actor: Actors::Resolve.member(account: conversation.account, user: @human),
      control_owner_user: @human,
    }.merge(overrides))
  end

  test "a turn's answerer defaults to the conversation's, on every kind, and never changes" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)

    %w[message direct_reply compaction_summary].each_with_index do |kind, position|
      turn = build_turn(conversation, kind: kind, role: (kind == "direct_reply" ? "assistant" : "user"), position: position)
      assert_equal @agent, turn.reload.answering_user, "#{kind}: the conversation's answerer at creation"
    end
    named = build_turn(conversation, position: 3, answering_user: @human)
    assert_equal @human, named.reload.answering_user, "the input's addressee, written by the drain"
    assert_nil named.declaring_profile
    assert_equal @agent, build_turn(conversation, position: 4).declaring_profile

    assert_raises(ActiveRecord::ReadonlyAttributeError) { named.update!(answering_user: @agent) }
  end

  test "a loop-backed loop answers as its TURN does, whoever the conversation's default is" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    turn = build_turn(conversation, status: "running", answering_user: @agent)
    variant = ConversationTurnVariant.create!(account: conversation.account, conversation_turn: turn,
      position: 0, status: "running", source: "agent_loop")
    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @human, status: "running",
      conversation_turn_variant: variant, approval_mode: "bypass")

    assert_equal @human, conversation.answering_user, "the default stays the plain chat's"
    assert_equal @agent, agent_loop.answering_user, "the loop's answerer is the turn's"
    assert_equal @agent, agent_loop.declaring_profile
    assert_equal @human, agent_loop.creating_user, "the speaker stays the loop's creator"

    standalone = AgentLoop.create!(workspace: @workspace, creating_user: @agent, status: "running", approval_mode: "bypass")
    assert_equal @agent, standalone.answering_user, "a standalone loop answers as its creator"
  end
end
