require "test_helper"

class Conversations::ReapRunOwnershipTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

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
    turn, agent_run = completed_reply(@conversation)
    node_ids = agent_run.agent_run_tasks.pluck(:id)
    invocation_ids = agent_run.model_invocations.pluck(:id)
    assert_not_empty invocation_ids, "the model lane created actual invocation history"
    assert_equal "completed", turn.reload.status

    condemn(@conversation)
    assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]
    assert_not Conversation.exists?(@conversation.id)
    assert_not AgentRun.listable.exists?(agent_run.id),
      "the deleted conversation's loop must not become a new workspace-readable host"

    # The conversation already spent its retention period: its engine
    # must be eligible now, without starting another thirty-day clock.
    AgentRuns::Reap.call(batch: 10)
    assert_not AgentRun.exists?(agent_run.id)
    assert_not AgentRunTask.where(id: node_ids).exists?
    assert_not ModelInvocation.where(id: invocation_ids).exists?
    assert_not ContentBody.where(agent_run_task_id: node_ids).exists?
    assert UsageRecord.exists?, "accepted usage survives physical reclamation"
  end

  test "immediate side deletion keeps its draining loop hidden and eventually reclaims it" do
    turn, = completed_reply(@conversation)
    side = fork_at(turn, side: true)
    _side_turn, agent_run = materialize_loop_reply!(side, agent: @human, text: "side question")
    schedule_loop!(agent_run)
    invocation = agent_run.model_invocations.sole
    assert_equal "queued", invocation.status

    assert_predicate Conversations::Tombstone.call(conversation: side), :accepted?
    assert_not Conversation.exists?(side.id)
    assert_not AgentRun.listable.exists?(agent_run.id),
      "a canceled side's nullified seam must not publish its former engine"

    AgentRuns::ConvergeTerminalSteps.call
    schedule_loop!(agent_run)
    assert_equal "canceled", agent_run.reload.status
    reclaim_loop(agent_run)
    assert_not AgentRun.exists?(agent_run.id)
    assert_not ModelInvocation.exists?(invocation.id)
    assert Conversation.exists?(@conversation.id)
  end

  test "a fork pins its ancestor's loop history until the child is reaped" do
    turn, agent_run = completed_reply(@conversation)
    child = fork_at(turn, side: false)
    body = agent_run.agent_run_tasks.sole.output_body
    expected = body.effective_text
    condemn(@conversation)

    assert_equal 0, Conversations::Reap.call(batch: 10).value[:reaped]
    assert_equal expected, body.reload.effective_text
    assert_equal agent_run.id, turn.active_variant.reload.agent_run.id

    condemn(child)
    2.times { Conversations::Reap.call(batch: 10) }
    assert_not Conversation.exists?(child.id)
    assert_not Conversation.exists?(@conversation.id)
    assert_not AgentRun.listable.exists?(agent_run.id)
    reclaim_loop(agent_run)
    assert_not AgentRun.exists?(agent_run.id)
  end

  test "workspace collection retires loop ownership even without a conversation tombstone" do
    _turn, agent_run = completed_reply(@conversation)
    assert_nil @conversation.reload.tombstoned_at
    invocation_ids = agent_run.model_invocations.pluck(:id)
    @workspace.with_lock do
      @workspace.accept_delete
      assert_equal :completed, @workspace.complete_transition
    end
    @workspace.update_columns(deleted_at: 31.days.ago)

    # A single aggregate budget stops after the conversation stage. Its
    # former engine cannot become readable between collector passes.
    assert_equal 1, Workspaces::Collect.call(budget: 1)[:processed]
    assert_not Conversation.exists?(@conversation.id)
    assert_not AgentRun.listable.exists?(agent_run.id)
    Workspaces::Collect.call(budget: 20)

    assert_not AgentRun.exists?(agent_run.id)
    assert_not ModelInvocation.where(id: invocation_ids).exists?
    assert_not Workspace.exists?(@workspace.id)
    assert UsageRecord.exists?
  end

  private

    def completed_reply(conversation)
      turn, agent_run = materialize_loop_reply!(conversation, agent: @human, text: "keep my history")
      schedule_loop!(agent_run)
      run_loop_round!(agent_run, sse_success("the accepted answer"))
      Conversations::Turns::Converge.call
      assert_equal "completed", agent_run.reload.status
      [turn.reload, agent_run]
    end

    def condemn(conversation)
      result = Conversations::Tombstone.call(conversation: conversation.reload)
      assert_predicate result, :accepted?, result.outcome.inspect
      Conversation.where(id: conversation.id).update_all(
        tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago
      )
    end

    def reclaim_loop(agent_run)
      # Advance only a clock the writer actually installed. Setting a
      # missing stamp here would hide the orphan this regression guards.
      retained = AgentRun.find_by(id: agent_run.id)
      return if retained.nil?

      assert_predicate retained, :tombstoned?
      retained.update!(tombstoned_at: (AgentRun::RETENTION_PERIOD + 1.day).ago)
      AgentRuns::Reap.call(batch: 10)
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
