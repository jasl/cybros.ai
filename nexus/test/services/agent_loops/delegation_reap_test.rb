require "test_helper"

class AgentLoops::DelegationReapTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, READ_TOOL])
    @conversation = Conversation.create!(workspace: @workspace,
      creating_user: @human, answering_user: @agent)
  end

  test "a canceled publisher remains until its exact pending input is withdrawn" do
    parent, call, child = spawn_scoped
    input_id = call.spawn_delegation.delegated_input_public_id
    post_input!(child, acting_user: @agent, text: "independent follow up")
    parent.with_lock { AgentLoops::Stop.stop_now(parent) }
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(parent)
    age_loop(parent)

    pass = AgentLoops::Reap.call(batch: 1)
    assert_equal 1, pass[:scanned]
    assert_equal 0, pass[:reaped]
    assert pass.more?
    assert AgentLoop.exists?(parent.id)
    assert child.conversation_inputs.exists?(public_id: input_id)

    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_not child.conversation_inputs.exists?(public_id: input_id)
    assert_equal ["independent follow up"], child.conversation_inputs.map(&:text)
    assert_equal 1, AgentLoops::Reap.call(batch: 1)[:reaped]
    assert_not AgentLoop.exists?(parent.id)
    assert Conversation.exists?(child.id)
  end

  test "a published child input pins the child aggregate until ownership is settled" do
    _parent, call, child = spawn_scoped
    assert_empty child.conversation_turns
    input = child.conversation_inputs.sole
    assert_not child.with_lock { Conversations::Reap.destroy_aggregate(child) }
    assert ConversationInput.exists?(input.id)

    result = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: child, input_public_id: input.public_id, acting_user: @agent))
    assert result.accepted?, result.outcome.inspect
    assert_equal "failed", call.spawn_delegation.reload.status
    assert child.with_lock { Conversations::Reap.destroy_aggregate(child) }
    assert_not Conversation.exists?(child.id)
  end

  test "canceled ownership retains only the original child execution until cleanup stops it" do
    parent, call, child = spawn_scoped
    drained = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert drained.accepted?, drained.outcome.inspect
    turn = drained.value
    original = turn.active_variant.agent_loop
    schedule_loop!(original)
    run_loop_round!(original, json_response(400, { "error" => "held" }))
    Conversations::Turns::Converge.call(conversation_id: child.id)
    assert_equal "needs_attention", original.reload.status
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: child, turn_public_id: turn.public_id, acting_user: @agent,
      entries: [{ "text" => "replace the displayed answer" }]))
    assert edited.accepted?, edited.outcome.inspect
    _later_turn, later = materialize_loop_reply!(child, agent: @agent, text: "independent follow up")
    parent.with_lock { AgentLoops::Stop.stop_now(parent) }
    schedule_loop!(parent)
    age_loop(parent)

    assert_equal "canceled", call.spawn_delegation.reload.status
    assert_equal 0, AgentLoops::Reap.call(batch: 1)[:reaped]
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal "canceling", original.reload.status
    assert_equal 0, AgentLoops::Reap.call(batch: 1)[:reaped]
    schedule_loop!(original)
    assert_equal "canceled", original.reload.status
    assert_equal "running", later.reload.status
    assert_equal 1, AgentLoops::Reap.call(batch: 1)[:reaped]
    assert AgentLoop.exists?(later.id)
  end

  test "the original execution survives reap after an edit until its result belongs to the caller" do
    parent, call, child = spawn_scoped
    turn, original = complete_child(child)
    edit = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: child, turn_public_id: turn.public_id, acting_user: @agent,
      entries: [{ "text" => "edited display only" }]))
    assert edit.accepted?, edit.outcome.inspect
    age_loop(original)
    assert_equal 0, AgentLoops::Reap.call(batch: 1)[:reaped]
    assert AgentLoop.exists?(original.id)
    assert_equal "Mock: original report", original.deliverable.output_body.effective_text
    assert_not child.with_lock { Conversations::Reap.destroy_aggregate(child) }

    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal "completed", call.spawn_delegation.reload.status
    assert_equal "Mock: original report", call.spawn_delegation.output_body.effective_text
    assert_equal 1, AgentLoops::Reap.call(batch: 1)[:reaped]
    assert_not AgentLoop.exists?(original.id)
    assert child.with_lock { Conversations::Reap.destroy_aggregate(child) }
    assert_equal "Mock: original report", call.spawn_delegation.reload.output_body.effective_text
    assert AgentLoop.exists?(parent.id)
  end

  test "a retained first loop does not hide an eligible later tombstone" do
    _parent, _call, child = spawn_scoped
    _turn, retained = complete_child(child)
    at = (AgentLoop::RETENTION_PERIOD + 2.days).ago
    age_loop(retained, at: at)
    independent = seed(model("unrelated"))
    independent.update!(status: "completed", completed_at: Time.current,
      tombstoned_at: at + 1.minute)

    first = AgentLoops::Reap.call(batch: 1)
    assert_equal 0, first[:reaped]
    assert first.more?
    second = AgentLoops::Reap.call(batch: 1,
      after_tombstoned_at: first.cursor.first, after_id: first.cursor.last)
    assert_equal 1, second[:reaped]
    assert_not AgentLoop.exists?(independent.id)
    assert AgentLoop.exists?(retained.id)
  end

  test "a retained child does not hide the next conversation in a bounded sweep" do
    _parent, _call, child = spawn_scoped
    complete_child(child)
    at = (Conversation::RETENTION_PERIOD + 2.days).ago
    child.reload.update!(tombstoned_at: at)
    independent = Conversation.create!(workspace: @workspace, creating_user: @human,
      tombstoned_at: at + 1.minute)

    first = Conversations::Reap.call(batch: 1).value
    assert_equal 0, first[:reaped]
    assert first.more?
    second = Conversations::Reap.call(batch: 1,
      after_tombstoned_at: first.cursor.first, after_id: first.cursor.last).value
    assert_equal 1, second[:reaped]
    assert_not Conversation.exists?(independent.id)
    assert Conversation.exists?(child.id)
  end

  test "workspace collection shares child retention and releases it after owned completion" do
    parent, call, child = spawn_scoped
    _turn, original = complete_child(child)
    receipt = ConversationCommandReceipt.find_by!(host: child,
      idempotency_key: "spawn:#{parent.public_id}:#{call.node_key}")
    @workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    # A one-row budget visits the newest child first. Its original
    # execution is also the newest loop, so both shared teardown routes
    # must preserve the report even though the workspace is deleted. The
    # independent replay receipt can still consume the one unit of work.
    pass = nil
    assert_difference -> { ConversationCommandReceipt.where(workspace: @workspace).count }, -1 do
      pass = Workspaces::Collect.call(budget: 1)
    end
    assert_equal 1, pass[:processed]
    assert_not ConversationCommandReceipt.exists?(receipt.id)
    assert Conversation.exists?(child.id)
    assert AgentLoop.exists?(original.id)
    assert AgentLoop.exists?(parent.id)
    assert_equal "Mock: original report", original.deliverable.output_body.effective_text

    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal "completed", call.spawn_delegation.reload.status
    assert_equal 1, Workspaces::Collect.call(budget: 1)[:processed]
    assert_not Conversation.exists?(child.id)
    assert_equal "Mock: original report", call.spawn_delegation.reload.output_body.effective_text
  end

  test "workspace deletion drains a paused owner and held child before repeated bounded collection" do
    parent, _call, child = spawn_scoped
    drained = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert drained.accepted?, drained.outcome.inspect
    original = drained.value.active_variant.agent_loop
    schedule_loop!(original)
    run_loop_round!(original, json_response(400, { "error" => "held" }))
    Conversations::Turns::Converge.call(conversation_id: child.id)
    assert_equal "needs_attention", original.reload.status
    paused = AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(
      agent_loop: parent, acting_user: @agent))
    assert paused.accepted?, paused.outcome.inspect
    @workspace.with_lock do
      @workspace.accept_delete
      assert_equal :completed, @workspace.complete_transition
    end
    @workspace.update_columns(deleted_at: 31.days.ago)

    6.times do
      AgentLoops::ScheduleSweep.call
      AgentLoops::Spawn::Relay.call
      Workspaces::Collect.call(budget: 1)
    end

    assert_not Conversation.exists?(child.id), "revoked paused ownership must not pin the child forever"
    assert_not AgentLoop.exists?(original.id)
    assert_not AgentLoop.exists?(parent.id)
  end

  test "workspace collection stops a publisher before reaping while its input is still pending" do
    parent, call, child = spawn_scoped
    input_id = call.spawn_delegation.delegated_input_public_id
    receipt = ConversationCommandReceipt.find_by!(host: child,
      idempotency_key: "spawn:#{parent.public_id}:#{call.node_key}")
    @workspace.update_columns(state: "deleted", deleted_at: 31.days.ago)

    # The collector wins before the authority sweep has canceled this loop.
    # No child invocation exists yet, but its accepted request still needs
    # the source task to survive until exact cleanup removes the Input.
    pass = nil
    assert_difference -> { ConversationCommandReceipt.where(workspace: @workspace).count }, -1 do
      pass = Workspaces::Collect.call(budget: 1)
    end
    assert_equal 1, pass[:processed], "only the independent replay receipt was collected"
    assert_not ConversationCommandReceipt.exists?(receipt.id)
    assert AgentLoop.exists?(parent.id)
    assert_equal "canceled", call.spawn_delegation.reload.status
    assert child.reload.spawn_node_id
    assert child.conversation_inputs.exists?(public_id: input_id)

    AgentLoops::Spawn::Relay.call
    assert_not child.conversation_inputs.exists?(public_id: input_id)
    4.times { Workspaces::Collect.call(budget: 1) }
    assert_not AgentLoop.exists?(parent.id)
    assert_not Conversation.exists?(child.id)
  end

  test "completed ownership does not retain a later independent child execution" do
    parent, call, child = spawn_scoped
    complete_child(child)
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal "completed", call.spawn_delegation.reload.status
    _later_turn, later = materialize_loop_reply!(child, agent: @agent, text: "independent follow up")
    parent.with_lock { AgentLoops::Stop.stop_now(parent) }
    AgentLoops::ConvergeTerminalSteps.call
    schedule_loop!(parent)
    age_loop(parent)

    assert_equal 1, AgentLoops::Reap.call(batch: 1)[:reaped]
    assert_not AgentLoop.exists?(parent.id)
    assert_equal "running", later.reload.status
    assert Conversation.exists?(child.id)
  end

  private

    def spawn_scoped
      _turn, parent = materialize_loop_reply!(@conversation, agent: @agent, text: "delegate")
      schedule_loop!(parent)
      attempt = loop_attempt(parent)
      apply_via(attempt, sse_success("delegating", tool_calls: [
        { id: "spawn_once", name: "spawn", arguments: { prompt: "report", lifetime: "turn" }.to_json },
      ]))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::ConversationToolJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: parent.id)
      end
      call = loop_node(parent, "r2t0")
      assert_equal "completed", call.status
      assert_equal "running", call.spawn_delegation.status
      run_loop_round!(parent, sse_success("candidate answer"))
      assert_not parent.reload.delivered?
      [parent, call, call.spawned_conversation]
    end

    def complete_child(child)
      result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
      assert result.accepted?, result.outcome.inspect
      turn = result.value
      original = turn.active_variant.agent_loop
      schedule_loop!(original)
      run_loop_round!(original, sse_success("original report"))
      Conversations::Turns::Converge.call(conversation_id: child.id)
      assert_equal "completed", original.reload.status
      [turn.reload, original]
    end

    def age_loop(agent_loop, at: (AgentLoop::RETENTION_PERIOD + 1.day).ago)
      result = AgentLoops::Tombstone.call(agent_loop: agent_loop.reload)
      assert result.accepted?, result.outcome.inspect
      agent_loop.update!(tombstoned_at: at)
    end
end
