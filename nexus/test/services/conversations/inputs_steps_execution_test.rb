require "test_helper"

class Conversations::InputsStepsExecutionTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @steps = [
      { "tool" => { "key" => "check", "name" => "read_file", "input" => { "path" => "result.txt" } } },
      { "ask" => { "key" => "hold", "prompt" => "Check the result" } },
    ]
  end

  test "an immediate model answer cannot complete before the authored check and hold" do
    declare_tools!(@agent, approval_mode: "ask")
    run = materialize_steps
    assert_equal %w[r1 check hold], run.agent_run_tasks.order(:id).pluck(:node_key)
    schedule_loop!(run)
    run_loop_round!(run, sse_success("finished without a tool call"))

    assert_equal "completed", loop_node(run, "r1").status
    check = loop_node(run, "check")
    assert_equal ["dispatched", "author", "author"], [check.status, check.authored_by, check.approval_origin]
    assert_equal "queued", loop_node(run, "hold").status
    assert_not run.reload.completed?
    assert_not run.delivered?

    settle_tool(check)
    schedule_loop!(run)
    assert_equal "dispatched", loop_node(run, "hold").status
    assert_not run.reload.completed?
    resolve_hold(run)
    assert_predicate run.reload, :completed?
  end

  test "the check follows the expanded round through its tool and continuation" do
    run = materialize_steps
    schedule_loop!(run)
    run_loop_round!(run, sse_success("reading first", tool_calls: [
      { id: "call_read", name: "read_file", arguments: '{"path":"source.txt"}' },
    ]))

    generated = run.agent_run_tasks.where(type: AgentRunTasks::ToolTask.sti_name, authored_by: "model").sole
    assert_equal "dispatched", generated.status
    assert_equal "queued", loop_node(run, "check").status
    settle_tool(generated)
    schedule_loop!(run)
    assert_equal "queued", loop_node(run, "check").status
    run_loop_round!(run, sse_success("the tool work is finished"))
    assert_equal "dispatched", loop_node(run, "check").status
    assert_equal "queued", loop_node(run, "hold").status
    assert_not run.reload.completed?
  end

  test "the input answerer keeps its hooks and model declaration beside authored steps" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @agent.update!(lifecycle_hooks: { "turn_start" => { "tool" => "check_lifecycle", "timeout_ms" => 30_000 } })
    announce_tools!(@agent, %w[read_file check_lifecycle])
    run = materialize_steps(answering_user_public_id: @agent.public_id)
    assert_equal @human, run.creating_user
    assert_equal @agent, run.answering_user
    assert_equal [READ_TOOL], loop_node(run, "r1").tool_definitions
    assert_equal @agent.lifecycle_hooks, run.lifecycle_hooks
    @agent.update!(lifecycle_hooks: nil)

    2.times { schedule_loop!(run) }
    hook = run.agent_run_tasks.where(lifecycle_event: "turn_start").sole
    assert_equal "dispatched", hook.status
    assert_empty run.model_invocations
    assert_equal "queued", loop_node(run, "check").status
    settle_tool(hook, structured_content: { "continue" => false })
    schedule_loop!(run)
    run_loop_round!(run, sse_success("finished after the original hook"))
    assert_equal "dispatched", loop_node(run, "check").status
    assert_equal 1, run.agent_run_tasks.where(lifecycle_event: "turn_start").count
  end

  test "regeneration and the next input do not replay original trailing work" do
    original = materialize_steps
    schedule_loop!(original)
    run_loop_round!(original, sse_success("first answer"))
    settle_tool(loop_node(original, "check"))
    schedule_loop!(original)
    resolve_hold(original)
    Conversations::Turns::Converge.call
    turn = @conversation.conversation_turns.sole
    assert_equal "completed", turn.status

    regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate regenerated, :accepted?, regenerated.outcome.to_s
    replacement = regenerated.value.agent_run
    assert_equal ["r1"], replacement.agent_run_tasks.pluck(:node_key)
    assert_empty replacement.agent_run_append_receipts
    schedule_loop!(replacement)
    run_loop_round!(replacement, sse_success("regenerated answer"))
    Conversations::Turns::Converge.call

    later = materialize_steps(steps: nil)
    assert_equal ["r1"], later.agent_run_tasks.pluck(:node_key)
    assert_empty later.agent_run_append_receipts
    assert_equal [original.id], AgentRunAppendReceipt.distinct.pluck(:agent_run_id)
  end

  test "empty or absent steps keep the ordinary engine and task count" do
    [nil, []].each do |steps|
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      run = materialize_steps(steps: steps)
      assert_equal ["r1"], run.agent_run_tasks.pluck(:node_key)
      assert_empty run.agent_run_append_receipts
    end
    declare_tools!(@agent, tools: [], approval_mode: nil)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    input = accept_steps(steps: [])
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    assert_predicate applied, :accepted?
    assert_equal "inference", applied.value.active_variant.source
    assert_nil applied.value.active_variant.agent_run
    assert_not ConversationInput.exists?(input.id)
  end

  test "nonempty steps require the existing run approval mode even for a tool-less profile" do
    declare_tools!(@agent, tools: [], approval_mode: nil)
    input = accept_steps
    assert_no_difference ["AgentRun.count", "ConversationTurn.count", "ModelInvocation.count"] do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_equal :input_blocked, result.outcome
    end
    assert_equal "approval_mode_required", input.reload.blocked_reason
  end

  test "existing live-mainline and compiler guards block the whole candidate" do
    [
      [{ "model" => { "key" => "later", "model" => { "model" => "dev/mock-text" }, "prompt" => "continue" } }, "tip_live"],
      [{ "unknown" => {} }, "invalid_steps"],
    ].each do |step, reason|
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      input = accept_steps(steps: [step])
      assert_no_difference ["AgentRun.count", "ConversationTurn.count", "AgentRunTask.count"] do
        result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
        assert_equal :input_blocked, result.outcome
      end
      assert_equal reason, input.reload.blocked_reason
    end
  end

  private

    def accept_steps(steps: @steps, **options)
      post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "Produce a result",
        provider_id: "dev", model_ref: "mock-text", steps: steps, **options)
    end

    def materialize_steps(**options)
      accept_steps(**options)
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_predicate applied, :accepted?, applied.outcome.to_s
      applied.value.active_variant.agent_run
    end

    def settle_tool(node, structured_content: nil)
      executor = TaskExecutor.address_for(@agent)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: node.agent_run, task_key: node.node_key, executor: executor
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.to_s
      committed = Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: node.agent_run, task_key: node.node_key, executor: executor, claim_token: claimed.value.claim_token,
        content: "Checked", structured_content: structured_content, result_type: nil,
        outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate committed, :applied?, committed.outcome.to_s
    end

    def resolve_hold(run)
      resolved = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.authored(
        agent_run: run.reload, steps: [], resolves: [{ "task" => "hold", "content" => "Accepted" }], creator: @human
      ))
      assert_predicate resolved, :applied?, resolved.outcome.to_s
      schedule_loop!(run)
    end
end
