require "test_helper"

class Conversations::ReapLoopOwnershipTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace,
      creating_user: @human, answering_user: @agent, access_default: "none")
  end

  test "reaping a completed conversation never publishes its loop as a standalone host" do
    turn, agent_loop = completed_reply(@conversation)
    node_ids = agent_loop.agent_loop_nodes.pluck(:id)
    invocation_ids = agent_loop.model_invocations.pluck(:id)
    assert_not_empty invocation_ids, "the model lane created actual invocation history"
    assert_equal "completed", turn.reload.status

    condemn(@conversation)
    assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]
    assert_not Conversation.exists?(@conversation.id)
    assert_not AgentLoop.listable.exists?(agent_loop.id),
      "the deleted conversation's loop must not become a new workspace-readable host"

    # The conversation already spent its retention period: its engine
    # must be eligible now, without starting another thirty-day clock.
    AgentLoops::Reap.call(batch: 10)
    assert_not AgentLoop.exists?(agent_loop.id)
    assert_not AgentLoopNode.where(id: node_ids).exists?
    assert_not ModelInvocation.where(id: invocation_ids).exists?
    assert_not ContentBody.where(agent_loop_node_id: node_ids).exists?
    assert UsageRecord.exists?, "accepted usage survives physical reclamation"
  end

  test "immediate side deletion keeps its draining loop hidden and eventually reclaims it" do
    turn, = completed_reply(@conversation)
    side = fork_at(turn, side: true)
    _side_turn, agent_loop = materialize_loop_reply!(side, agent: @human, text: "side question")
    schedule_loop!(agent_loop)
    invocation = agent_loop.model_invocations.sole
    assert_equal "queued", invocation.status

    assert_predicate Conversations::Tombstone.call(conversation: side), :accepted?
    assert_not Conversation.exists?(side.id)
    assert_not AgentLoop.listable.exists?(agent_loop.id),
      "a canceled side's nullified seam must not publish its former engine"

    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(agent_loop)
    assert_equal "canceled", agent_loop.reload.status
    reclaim_loop(agent_loop)
    assert_not AgentLoop.exists?(agent_loop.id)
    assert_not ModelInvocation.exists?(invocation.id)
    assert Conversation.exists?(@conversation.id)
  end

  test "a fork pins its ancestor's loop history until the child is reaped" do
    turn, agent_loop = completed_reply(@conversation)
    child = fork_at(turn, side: false)
    body = agent_loop.agent_loop_nodes.sole.output_body
    expected = body.effective_text
    condemn(@conversation)

    assert_equal 0, Conversations::Reap.call(batch: 10).value[:reaped]
    assert_equal expected, body.reload.effective_text
    assert_equal agent_loop.id, turn.active_variant.reload.agent_loop.id

    condemn(child)
    2.times { Conversations::Reap.call(batch: 10) }
    assert_not Conversation.exists?(child.id)
    assert_not Conversation.exists?(@conversation.id)
    assert_not AgentLoop.listable.exists?(agent_loop.id)
    reclaim_loop(agent_loop)
    assert_not AgentLoop.exists?(agent_loop.id)
  end

  test "workspace collection retires loop ownership even without a conversation tombstone" do
    _turn, agent_loop = completed_reply(@conversation)
    assert_nil @conversation.reload.tombstoned_at
    invocation_ids = agent_loop.model_invocations.pluck(:id)
    @workspace.with_lock do
      @workspace.accept_delete
      assert_equal :completed, @workspace.complete_transition
    end
    @workspace.update_columns(deleted_at: 31.days.ago)

    # A single aggregate budget stops after the conversation stage. Its
    # former engine cannot become readable between collector passes.
    assert_equal 1, Workspaces::Collect.call(budget: 1)[:processed]
    assert_not Conversation.exists?(@conversation.id)
    assert_not AgentLoop.listable.exists?(agent_loop.id)
    Workspaces::Collect.call(budget: 20)

    assert_not AgentLoop.exists?(agent_loop.id)
    assert_not ModelInvocation.where(id: invocation_ids).exists?
    assert_not Workspace.exists?(@workspace.id)
    assert UsageRecord.exists?
  end

  private

    def completed_reply(conversation)
      turn, agent_loop = materialize_loop_reply!(conversation, agent: @human, text: "keep my history")
      schedule_loop!(agent_loop)
      run_loop_round!(agent_loop, sse_success("the accepted answer"))
      Conversations::Turns::Converge.call
      assert_equal "completed", agent_loop.reload.status
      [turn.reload, agent_loop]
    end

    def condemn(conversation)
      result = Conversations::Tombstone.call(conversation: conversation.reload)
      assert_predicate result, :accepted?, result.outcome.inspect
      Conversation.where(id: conversation.id).update_all(
        tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago
      )
    end

    def reclaim_loop(agent_loop)
      # Advance only a clock the writer actually installed. Setting a
      # missing stamp here would hide the orphan this regression guards.
      retained = AgentLoop.find_by(id: agent_loop.id)
      return if retained.nil?

      assert_predicate retained, :tombstoned?
      retained.update!(tombstoned_at: (AgentLoop::RETENTION_PERIOD + 1.day).ago)
      AgentLoops::Reap.call(batch: 10)
    end

    def fork_at(turn, side:)
      result = Conversations::Fork.call(Conversations::Fork::Command.new(
        conversation: @conversation.reload, turn_public_id: side ? nil : turn.public_id,
        variant_public_id: nil, acting_user: @human, title: nil, side: side
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end
end
