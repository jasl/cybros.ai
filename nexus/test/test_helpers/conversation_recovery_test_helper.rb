module ConversationRecoveryTestHelper
  include InvocationHarness
  include RunLaneTestHelper

  def prepare_recovery_conversation
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    @agent = connect_agent_session(steward: @human, agent_identifier: "recovery.trial",
      display_name: "Recovery Agent").access_token.user
    @account.update!(cost_unit: "USD")
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: users(:owner),
      answering_user: @agent, cost_limit: "0", title: "Cost recovery")
  end

  def cost_refused_reply
    post_input!(@conversation.reload, acting_user: @human, text: "Keep this question", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-priced")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    ModelInvocations::AdmitQueuedWork.call
    Conversations::Turns::Converge.call
    @turn = @conversation.turns.sole
    @original = @turn.active_variant
    assert_nil @original.run
    assert_equal Conversation::COST_LIMIT_REACHED, @original.model_invocation.failure_reason_key
    assert_equal "failed", @turn.status
  end

  def held_run_with_completed_tool
    @conversation.update!(cost_limit: nil)
    declare_tools!(@agent)
    post_input!(@conversation.reload, acting_user: @human, text: "Read once and continue", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-priced")
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    @turn = @conversation.turns.sole
    @original = @turn.active_variant
    @run = @original.run
    schedule_loop!(@run)
    run_loop_round!(@run, sse_success("Read", tool_calls: [
      { id: "read_once", name: "read_file", arguments: "{}" },
    ]))
    @tool = @run.tasks.where(type: Tasks::ToolTask.sti_name).sole
    result = Runs::Parks::Settle.call(node: @tool, trusted: true,
      content: "Already read", is_error: false, outcome: "completed")
    assert_predicate result, :applied?
    @conversation.reload.update!(cost_limit: "0")
    schedule_loop!(@run)
    ModelInvocations::AdmitQueuedWork.call
    Runs::ConvergeTerminalSteps.call
    schedule_loop!(@run)
    Conversations::Turns::Converge.call
    @failed_task = @run.tasks.cost_limit_failures.sole
    assert_equal "needs_attention", @run.reload.status
  end
end
