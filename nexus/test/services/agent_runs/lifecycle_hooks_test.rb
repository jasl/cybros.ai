require "test_helper"

class AgentRuns::LifecycleHooksTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  TOOL = "check_lifecycle".freeze
  ACK = { "continue" => false }.freeze

  setup do
    @account = accounts(:cybros)
    @agent = users(:agent)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    announce_tools!(@agent, [TOOL])
  end

  test "a natural stop asks once and continuation feedback stays on the same execution" do
    configure("stop")
    agent_run = start_loop
    finish_round(agent_run, "candidate")
    hook = hook_for(agent_run, "stop")
    assert_equal "dispatched", hook.status
    assert_not agent_run.reload.delivered?
    2.times { schedule_loop!(agent_run) }
    assert_equal 1, hooks(agent_run, "stop").count

    settle_hook(hook, { "continue" => true, "feedback" => "Check the missing edge case." })
    continuation = agent_run.reload.deliverable_node
    assert_predicate continuation, :model_task?
    assert_equal "Check the missing edge case.", continuation.input_body.effective_text
    assert_equal [hook.node_key], continuation.sources.map(&:node_key)
    assert_includes continuation.input_from_node_keys, "answer"
    schedule_loop!(agent_run)
    finish_round(agent_run, "checked answer")
    assert_equal 2, hooks(agent_run, "stop").count
    settle_hook(hook_for(agent_run, "stop"), ACK)
    assert_predicate agent_run.reload, :completed?
    assert_equal "Mock: checked answer", agent_run.deliverable_node.output_body.effective_text
  end

  test "force stop cancels a pending hook and a late result cannot restart the loop" do
    configure("stop")
    agent_run = start_loop
    finish_round(agent_run, "candidate")
    hook = hook_for(agent_run, "stop")
    token = claim_hook(hook)
    result = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: agent_run, acting_user: @agent))
    assert_predicate result, :accepted?
    schedule_loop!(agent_run)
    assert_predicate agent_run.reload, :canceled?
    assert_equal "canceled", hook.reload.status
    assert_equal :idle, commit_hook(hook, token, { "continue" => true, "feedback" => "Continue." }).outcome
    assert_equal 1, agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name).count
  end

  test "a superseded stop decision cannot consume the new candidate continuation allowance" do
    configure("stop", max_continuations: 1)
    agent_run = start_loop
    finish_round(agent_run, "candidate")
    first_check = hook_for(agent_run, "stop")
    # A new authored continuation supersedes the candidate while its hook is
    # still dispatched. Background mail no longer changes that candidate.
    grow!(agent_run, model("replacement", "prompt" => "Update the candidate"))
    schedule_loop!(agent_run)
    wake = agent_run.reload.deliverable_node
    assert_equal "replacement", wake.node_key
    assert_equal "running", wake.status
    settle_hook(first_check, { "continue" => true, "feedback" => "Obsolete feedback." })
    assert_equal wake.id, agent_run.reload.deliverable_node_id

    finish_named_round(agent_run, wake.node_key, "updated candidate")
    second_check = hook_for(agent_run, "stop")
    assert_not_equal first_check.id, second_check.id
    settle_hook(second_check, { "continue" => true, "feedback" => "Check once more." })
    assert_equal "completed", second_check.reload.status
    continuation = agent_run.reload.deliverable_node
    assert_equal "Check once more.", continuation.input_body.effective_text
    schedule_loop!(agent_run)
    finish_named_round(agent_run, continuation.node_key, "final answer")
    settle_hook(hook_for(agent_run, "stop"), ACK)
    assert_predicate agent_run.reload, :completed?
  end

  test "malformed decisions and error results hold and retry reuses the hook task" do
    configure("stop")
    agent_run = start_loop
    finish_round(agent_run, "candidate")
    hook = hook_for(agent_run, "stop")
    settle_hook(hook, { "continue" => true })
    assert_equal "invalid_hook_result", hook.reload.error_key
    assert_predicate agent_run.reload, :needs_attention?
    retry_hook(agent_run, hook)
    settle_hook(hook.reload, ACK, is_error: true)
    assert_equal "hook_error", hook.reload.error_key
    retry_hook(agent_run, hook)
    settle_hook(hook.reload, { "continue" => false, "feedback" => false })
    assert_equal "invalid_hook_result", hook.reload.error_key
    retry_hook(agent_run, hook)
    settle_hook(hook.reload, ACK)
    assert_predicate agent_run.reload, :completed?
    assert_equal 1, hooks(agent_run, "stop").count
  end

  test "a hook deadline holds the existing task and explicit retry can acknowledge it" do
    configure("stop")
    agent_run = start_loop
    finish_round(agent_run, "candidate")
    hook = hook_for(agent_run, "stop")
    AgentRunTask.where(id: hook.id).update_all(await_started_at: 1.hour.ago)
    AgentRuns::Parks::TimeoutSweep.call
    assert_equal "timed_out", hook.reload.status
    assert_predicate agent_run.reload, :needs_attention?
    retry_hook(agent_run, hook)
    settle_hook(hook.reload, ACK)
    assert_predicate agent_run.reload, :completed?
  end

  test "the configured continuation bound is a failed hook rather than another model round" do
    configure("stop", max_continuations: 0)
    agent_run = start_loop
    finish_round(agent_run, "candidate")
    hook = hook_for(agent_run, "stop")
    settle_hook(hook, { "continue" => true, "feedback" => "One more." })
    assert_equal "stop_hook_limit", hook.reload.error_key
    assert_predicate agent_run.reload, :needs_attention?
    assert_equal 1, agent_run.agent_run_tasks.where(type: AgentRunTasks::ModelTask.sti_name).count
  end

  test "continuation without a model fails the hook and can be repaired with an acknowledgement" do
    configure("stop")
    agent_run = seed(tool("work", "read_file"), creating_user: @agent)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @agent))
    schedule_loop!(agent_run)
    AgentRuns::Parks::Settle.call(node: node(agent_run, "work"), trusted: true, content: "done", outcome: "completed")
    2.times { schedule_loop!(agent_run) }
    hook = hook_for(agent_run, "stop")
    settle_hook(hook, { "continue" => true, "feedback" => "Continue." })
    assert_equal "hook_requires_model", hook.reload.error_key
    assert_predicate agent_run.reload, :needs_attention?
    retry_hook(agent_run, hook)
    settle_hook(hook, ACK)
    assert_predicate agent_run.reload, :completed?
  end

  test "turn start precedes the first request and acknowledgement does not repeat" do
    configure("turn_start")
    agent_run = start_loop
    hook = hook_for(agent_run, "turn_start")
    assert_empty agent_run.model_invocations
    assert_equal "queued", node(agent_run, "answer").status
    assert_equal 1, node(agent_run, "answer").remaining_dependencies
    settle_hook(hook, ACK)
    schedule_loop!(agent_run)
    assert_equal "running", node(agent_run, "answer").status
    finish_round(agent_run, "answer")
    assert_predicate agent_run.reload, :completed?
    assert_equal 1, hooks(agent_run, "turn_start").count
  end

  test "a tool-less reply still gets its declared hooks and captures the profile once" do
    configure("turn_start")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    @agent.update!(lifecycle_hooks: nil)
    schedule_loop!(agent_run)
    schedule_loop!(agent_run)
    hook = hook_for(agent_run, "turn_start")
    assert_equal "dispatched", hook.status
    assert_equal turn.id, agent_run.conversation_turn.id
    settle_hook(hook, ACK)
    schedule_loop!(agent_run)
    assert_equal 1, agent_run.model_invocations.count
  end

  test "ordinary tool structure cannot continue the loop and authored hook markers are refused" do
    agent_run = seed(tool("ordinary", "read_file"), creating_user: @agent)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @agent))
    schedule_loop!(agent_run)
    task = node(agent_run, "ordinary")
    token = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: task.node_key, executor: suite_runner
    )).value.claim_token
    result = Executors::Commit.call(Executors::Commit::Command.new(
      agent_run: agent_run, task_key: task.node_key, executor: suite_runner, claim_token: token,
      content: "done", structured_content: { "continue" => true }, result_type: nil,
      outcome: "completed", is_error: false, title: nil, metadata: nil
    ))
    assert_predicate result, :applied?
    assert_predicate agent_run.reload, :completed?
    refused = create_loop(tool("forged", "read_file", "lifecycle_event" => "stop"), creating_user: @agent)
    assert_equal :invalid_steps, refused.outcome
    assert_equal "unknown_step_option", refused.errors.first.fetch("code")
  end

  test "pre and post compaction acknowledgements bracket summary execution without repeating" do
    configure("pre_compact", "post_compact")
    agent_run = seed(model("first"), model("next", "prompt" => "continue"), creating_user: @agent)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @agent))
    schedule_loop!(agent_run)
    apply_via(loop_attempt(agent_run), sse_success("earlier answer"))
    AgentRuns::ConvergeTerminalSteps.call
    target = node(agent_run, "next")
    request = AgentRuns::Tasks::Compact.call(AgentRuns::Tasks::Compact::Command.new(
      agent_run: agent_run, task_key: target.node_key, acting_user: @agent
    ))
    assert_predicate request, :accepted?, request.outcome.inspect
    schedule_loop!(agent_run)
    before = hook_for(agent_run, "pre_compact")
    assert_equal "queued", target.reload.status
    settle_hook(before, ACK)
    schedule_loop!(agent_run)
    schedule_loop!(agent_run)
    summary = node(agent_run, target.reload.compaction.fetch(AgentRunTasks::ModelTask::SUMMARY_SOURCE))
    assert_equal "running", summary.status
    assert_equal 0, hooks(agent_run, "post_compact").count
    apply_via(loop_attempt(agent_run), sse_success("summary"))
    AgentRuns::ConvergeTerminalSteps.call
    schedule_loop!(agent_run)
    schedule_loop!(agent_run)
    after = hook_for(agent_run, "post_compact")
    assert_equal "queued", target.reload.status
    settle_hook(after, ACK)
    schedule_loop!(agent_run)
    assert_equal "running", target.reload.status
    assert_equal 1, hooks(agent_run, "pre_compact").count
    assert_equal 1, hooks(agent_run, "post_compact").count
  end

  test "a between-turn summary acknowledges both boundaries before adopting its output" do
    configure("turn_start", "pre_compact", "post_compact", "stop")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    post_input!(conversation, acting_user: @human, text: "Remember the decision.")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    turn = result.value.turn
    agent_run = turn.active_variant.agent_run
    2.times { schedule_loop!(agent_run) }
    assert_empty agent_run.model_invocations
    settle_hook(hook_for(agent_run, "pre_compact"), ACK)
    schedule_loop!(agent_run)
    finish_round(agent_run, "Keep this decision.")
    after = hook_for(agent_run, "post_compact")
    assert_not agent_run.reload.delivered?
    assert_equal "running", turn.reload.status
    settle_hook(after, ACK)
    Conversations::Turns::Converge.call(conversation_id: conversation.id, agent_run_id: agent_run.id)
    assert_equal "completed", turn.reload.status
    assert_equal 1, hooks(agent_run, "pre_compact").count
    assert_equal 1, hooks(agent_run, "post_compact").count
    assert_empty hooks(agent_run, "turn_start")
    assert_empty hooks(agent_run, "stop")
  end

  test "a summary hook still crosses the declaring profile approval rules" do
    configure("pre_compact")
    @agent.update!(approval_rules: [{ "tool" => TOOL, "origin" => "kernel", "verdict" => "deny" }])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    post_input!(conversation, acting_user: @human, text: "Keep the rule.")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    result = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    agent_run = result.value.turn.active_variant.agent_run
    2.times { schedule_loop!(agent_run) }
    assert_equal AgentRuns::Tasks::Deny::ERROR_KEY, hook_for(agent_run, "pre_compact").error_key
    assert_empty agent_run.model_invocations
    assert_predicate agent_run.reload, :needs_attention?
  end

  test "pruning resumes through post compaction before the repaired model request" do
    declare_tools!(@agent)
    configure("pre_compact", "post_compact")
    announce_tools!(@agent, [TOOL, "read_file"])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
    schedule_loop!(agent_run)
    2.times do |index|
      words = index.zero? ? "earlier answer. " * 1_500 : "noted"
      run_loop_round!(agent_run, sse_success(words, tool_calls: [
        { id: "read#{index}", name: "read_file", arguments: '{"path":"notes.txt"}' },
      ]))
      tool = agent_run.agent_run_tasks.find_by!(tool_call_id: "read#{index}")
      AgentRuns::Parks::Settle.call(node: tool, trusted: true, content: "result. " * 1_000, outcome: "completed")
      schedule_loop!(agent_run) if index.zero?
    end
    target = agent_run.reload.deliverable_node
    assert_equal "queued", target.status
    trigger = Conversations::Compaction::Trigger.wall(target,
      overshoot: Conversations::Compaction::Overshoot.bytes(100))
    agent_run.with_lock { Conversations::Compaction::Arm.call(agent_run: agent_run, node: target, trigger: trigger) }
    schedule_loop!(agent_run)
    settle_hook(hook_for(agent_run, "pre_compact"), ACK)
    2.times { schedule_loop!(agent_run) }
    assert target.reload.compaction.fetch(AgentRunTasks::ModelTask::PRUNED_BEFORE)
    assert_nil target.compaction[AgentRunTasks::ModelTask::SUMMARY_SOURCE]
    assert_equal "queued", target.status
    assert_nil target.selected_model_invocation_id
    settle_hook(hook_for(agent_run, "post_compact"), ACK)
    schedule_loop!(agent_run)
    assert_equal "running", target.reload.status
    assert_equal 1, hooks(agent_run, "pre_compact").count
    assert_equal 1, hooks(agent_run, "post_compact").count
  end

  test "regeneration retains the original execution hooks after the profile changes" do
    configure("turn_start")
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    turn, original = materialize_loop_reply!(conversation, agent: @agent)
    2.times { schedule_loop!(original) }
    settle_hook(hook_for(original, "turn_start"), ACK)
    schedule_loop!(original)
    finish_round(original, "first answer")
    Conversations::Turns::Converge.call(conversation_id: conversation.id, agent_run_id: original.id)
    assert_equal "completed", turn.reload.status
    @agent.update!(lifecycle_hooks: nil)
    result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
      conversation: conversation.reload, turn_public_id: turn.public_id, acting_user: @agent,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    regenerated = turn.conversation_turn_variants.order(:position).last.agent_run
    assert_equal original.lifecycle_hooks, regenerated.lifecycle_hooks
    2.times { schedule_loop!(regenerated) }
    assert_equal "dispatched", hook_for(regenerated, "turn_start").status
    assert_empty regenerated.model_invocations
  end

  private

    def configure(*events, max_continuations: 2)
      @agent.update!(approval_mode: "bypass", lifecycle_hooks: events.to_h { |event|
        policy = { "tool" => TOOL, "timeout_ms" => 30_000 }
        policy["max_continuations"] = max_continuations if event == "stop"
        [event, policy]
      })
    end

    def start_loop
      agent_run = seed(model("answer"), creating_user: @agent)
      result = AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @agent))
      assert_predicate result, :accepted?
      2.times { schedule_loop!(agent_run) }
      agent_run
    end

    def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)
    def hooks(agent_run, event) = agent_run.agent_run_tasks.where(lifecycle_event: event)
    def hook_for(agent_run, event) = hooks(agent_run, event).order(:id).last!
    def address = TaskExecutor.address_for(@agent)

    def finish_round(agent_run, text)
      apply_via(loop_attempt(agent_run), sse_success(text))
      AgentRuns::ConvergeTerminalSteps.call
      2.times { schedule_loop!(agent_run) }
    end

    def finish_named_round(agent_run, key, text)
      invocation_id = node(agent_run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last!
      apply_via(attempt, sse_success(text))
      AgentRuns::ConvergeTerminalSteps.call
      2.times { schedule_loop!(agent_run) }
    end

    def claim_hook(hook)
      result = Executors::Claim.call(Executors::Claim::Command.new(
        agent_run: hook.agent_run, task_key: hook.node_key, executor: address
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value.claim_token
    end

    def commit_hook(hook, token, decision, is_error: false)
      Executors::Commit.call(Executors::Commit::Command.new(
        agent_run: hook.agent_run, task_key: hook.node_key, executor: address, claim_token: token,
        content: "Lifecycle check", structured_content: decision, result_type: nil,
        outcome: "completed", is_error: is_error, title: nil, metadata: nil
      ))
    end

    def settle_hook(hook, decision, **options)
      result = commit_hook(hook, claim_hook(hook), decision, **options)
      assert_predicate result, :applied?, result.outcome.inspect
    end

    def retry_hook(agent_run, hook)
      result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
        agent_run: agent_run.reload, task_key: hook.node_key, acting_user: @agent
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      schedule_loop!(agent_run)
    end
end
