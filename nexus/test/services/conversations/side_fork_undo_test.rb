require "test_helper"

class Conversations::SideForkUndoTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  test "a side after undo uses the remaining turn's answerer and fork point" do
    first = reply!
    last = message!
    head = @conversation.reload.timeline_position_head

    undo!(last)

    assert_equal head, @conversation.reload.timeline_position_head, "undo does not reuse a vacated position"
    side = fork!(side: true)
    assert_equal @agent, side.answering_user, "the remaining reply's agent, not the conversation's default"
    assert_equal first.public_id, side.forked_from_turn_public_id
    assert_equal first.active_variant.public_id, side.forked_from_variant_public_id
    assert_equal [first.id], side.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
  end

  test "a side after undoing every local turn finds the inherited predecessor" do
    first = reply!
    last = message!
    child = fork!(turn: last)
    undo!(child.conversation_turns.sole, conversation: child)
    assert_empty child.conversation_turns

    side = fork!(side: true, conversation: child)

    assert_equal @agent, side.answering_user
    assert_equal first.public_id, side.forked_from_turn_public_id
    assert_equal first.active_variant.public_id, side.forked_from_variant_public_id
    assert_equal [first.id], side.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
    assert_equal child.timeline_position_head, side.timeline_position_head
  end

  test "a side after undoing the entire history keeps the default answerer and an empty prefix" do
    first = reply!
    undo!(first)

    side = fork!(side: true)

    assert_equal @human, side.answering_user
    assert_nil side.forked_from_turn_public_id
    assert_nil side.forked_from_variant_public_id
    assert_empty side.timeline.entries(surface: :timeline)
    assert_equal @conversation.timeline_position_head, side.timeline_position_head
  end

  test "a side captures a running turn after an undone slot and keeps the running answerer" do
    first = reply!
    undo!(message!)
    post_input!(@conversation, acting_user: @human, text: "next reply", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    running = @conversation.reload.active_turn
    assert_equal "running", running.status
    assert_equal @human, running.answering_user

    side = fork!(side: true)

    assert_equal @human, side.answering_user
    assert_equal running.public_id, side.forked_from_turn_public_id
    reference = side.conversation_turns.sole
    assert_predicate reference, :reference?
    assert_equal [first.id, reference.id], side.timeline.entries(surface: :timeline).map { |entry| entry.turn.id }
    assert_equal running.position + 1, side.timeline_position_head
  end

  private

    def reply!
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @human,
        answering_user_public_id: @agent.public_id)
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("the agent's reply"))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      assert_equal @agent, turn.answering_user
      turn
    end

    def message!(conversation: @conversation)
      post_input!(conversation, acting_user: @human, text: "later message")
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
      conversation.conversation_turns.order(:position).last
    end

    def undo!(turn, conversation: @conversation)
      result = Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
        conversation: conversation, turn_public_id: turn.public_id, acting_user: @human
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      assert_not ConversationTurn.exists?(turn.id)
    end

    def fork!(turn: nil, side: false, conversation: @conversation)
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: conversation, turn_public_id: turn&.public_id,
        variant_public_id: nil, acting_user: @human, title: nil, side: side
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end
end
