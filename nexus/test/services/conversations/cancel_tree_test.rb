require "test_helper"

# Cancellation follows source requests, not reusable child-container grouping.
# Fixture sender stamps reproduce the immutable ownership written by Inputs.
class Conversations::CancelTreeTest < ActiveJob::TestCase
  include LoopSeamTestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:member)
    @agent = users(:agent)
    @root = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @child = spawned(@root)
    @grandchild = spawned(@child)
    @other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  def spawned(parent)
    Conversation.create!(
      workspace: @workspace, creating_user: @agent, answering_user: @agent,
      parent_conversation: parent, parent_conversation_public_id: parent.public_id
    )
  end

  def cancel!(conversation)
    Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: conversation, acting_user: @human
    ))
  end

  test "a stop reaches owned descendants through recovery without stopping unrelated work" do
    root_seam = create_loop_backed_turn(conversation: @root, acting_user: @human)
    child_seam = create_loop_backed_turn(conversation: @child, acting_user: @agent)
    grandchild_seam = create_loop_backed_turn(conversation: @grandchild, acting_user: @agent)
    other_seam = create_loop_backed_turn(conversation: @other, acting_user: @human, loop_status: "paused")
    bind_request(child_seam, root_seam)
    bind_request(grandchild_seam, child_seam)

    assert_enqueued_with(job: Conversations::Turns::ConvergeJob) do
      assert_predicate cancel!(@root), :accepted?
    end

    assert_equal "canceling", root_seam.agent_loop.reload.status
    clear_enqueued_jobs
    AgentLoops::ScheduleSweep.call
    assert_equal %w[canceled canceled canceled],
      [root_seam, child_seam, grandchild_seam].map { |seam| seam.agent_loop.reload.status }
    assert_equal "paused", other_seam.agent_loop.reload.status, "an unrelated conversation is untouched"
  end

  test "a completed root owner still stops its unfinished child request" do
    root_seam = completed_owner(@root)
    child_seam = create_loop_backed_turn(conversation: @child, acting_user: @agent)
    bind_request(child_seam, root_seam)

    assert_predicate cancel!(@root), :accepted?
    AgentLoops::ScheduleSweep.call
    assert_equal "canceled", child_seam.agent_loop.reload.status

    AgentLoops::EvaluateQuiescence.call(child_seam.agent_loop.reload)
    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal "canceled", child_seam.turn.reload.status
    assert_equal :not_running, cancel!(@root).outcome, "the whole tree idle is the one refusal"
  end

  test "a stop on a child reaches its own subtree only" do
    root_seam = create_loop_backed_turn(conversation: @root, acting_user: @human, loop_status: "paused")
    child_seam = completed_owner(@child)
    grandchild_seam = create_loop_backed_turn(conversation: @grandchild, acting_user: @agent)
    bind_request(grandchild_seam, child_seam)

    assert_predicate cancel!(@child), :accepted?
    AgentLoops::ScheduleSweep.call
    assert_equal "canceled", grandchild_seam.agent_loop.reload.status
    assert_equal "paused", root_seam.agent_loop.reload.status, "the parent is above the stop, not below it"
  end

  test "child grouping alone never grants cancellation of a later independent request" do
    root_seam = create_loop_backed_turn(conversation: @root, acting_user: @human)
    child_seam = create_loop_backed_turn(conversation: @child, acting_user: @agent, loop_status: "paused")
    assert_predicate cancel!(@root), :accepted?
    AgentLoops::ScheduleSweep.call
    assert_predicate root_seam.agent_loop.reload, :stopped?
    assert_equal "paused", child_seam.agent_loop.reload.status
    assert_not child_seam.agent_loop.stopped?
  end

  test "a read principal is refused before any member is touched" do
    child_seam = create_loop_backed_turn(conversation: @child, acting_user: @agent)
    reader = users(:owner)
    Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
      conversation: @root, acting_user: @human, default: "read", entries: []
    ))

    assert_equal :not_authorized, Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @root.reload, acting_user: reader
    )).outcome
    assert_equal "running", child_seam.agent_loop.reload.status
  end

  test "the ancestor predicate: above is true, self, below and beside are false" do
    assert Conversations::SubagentTree.ancestor?(@root, @child)
    assert Conversations::SubagentTree.ancestor?(@root, @grandchild)
    assert Conversations::SubagentTree.ancestor?(@child, @grandchild)
    assert_not Conversations::SubagentTree.ancestor?(@child, @child), "a conversation is not its own ancestor"
    assert_not Conversations::SubagentTree.ancestor?(@child, @root), "below is not above"
    assert_not Conversations::SubagentTree.ancestor?(@other, @child), "beside is nothing"
  end

  private

    def bind_request(child, source)
      ConversationTurn.where(id: child.turn.id).update_all(
        sender_conversation_public_id: source.turn.conversation.public_id,
        sender_agent_loop_public_id: source.agent_loop.public_id, sender_task_key: "spawn")
    end

    def completed_owner(conversation)
      seam = create_loop_backed_turn(conversation: conversation, acting_user: @human,
        turn_status: "completed", variant_status: "completed", loop_status: "completed")
      seam.agent_loop.update!(delivered_at: Time.current, completed_at: Time.current)
      conversation.update!(active_turn: nil)
      seam
    end
end
