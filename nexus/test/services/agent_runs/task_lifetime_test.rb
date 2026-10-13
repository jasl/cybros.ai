require "test_helper"

class AgentRuns::TaskLifetimeTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::ASK, Nexus::ToolRegistry.function_definition("wait"), READ_TOOL])
  end

  test "asynchronous turn work permits foreground progress but joins and synthesizes before final" do
    turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "review", lifetime: "turn" })

    branch = loop_node(agent_run, "r2t0-model-1")
    assert_equal "turn", branch.lifetime
    assert_predicate branch, :detached?
    assert_equal "running", loop_node(agent_run, "r2").status
    assert_match(/incorporate the result before the final answer/, output(loop_node(agent_run, "r2t0")))

    finish_round(agent_run, "r2", "candidate before review")
    refute_predicate agent_run.reload, :delivered?
    Conversations::Turns::Converge.call
    assert_equal "running", turn.reload.status

    finish_round(agent_run, branch.node_key, "review complete")
    wake = loop_node(agent_run, "w1")
    assert_equal "conversation", wake.lifetime, "the wake inherits its mainline, not the result it consumes"
    assert_equal %w[r2 r2t0-model-1], wake.input_from_node_keys
    assert_equal 1, request_text(wake).scan(/Mock: review complete/).length
    refute_predicate agent_run.reload, :delivered?

    finish_round(agent_run, "w1", "synthesized answer")
    assert_predicate agent_run.reload, :delivered?
    assert_equal "completed", agent_run.status
    Conversations::Turns::Converge.call
    assert_equal "Mock: synthesized answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_empty @conversation.conversation_inputs.reload
    assert_empty AgentRuns::WakeContinuation.undelivered(agent_run)
  end

  test "mixed lifetimes join selected work while cross-turn work remains and later mails" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task",
      { prompt: "needed", lifetime: "turn" }, { prompt: "monitor", lifetime: "conversation" })
    finish_round(agent_run, "r2t1-model-1", "monitor result")
    finish_round(agent_run, "r2", "candidate")
    refute_predicate agent_run.reload, :delivered?

    stub_const(AgentRuns::Tasks::Compile, :KERNEL_MAX_DEPENDENCIES_PER_TASK, 1) do
      finish_round(agent_run, "r2t0-model-1", "needed result")
    end
    refute_includes request_text(loop_node(agent_run, "w1")), "Mock: monitor result"
    finish_round(agent_run, "w1", "final after needed result")
    assert_predicate agent_run.reload, :delivered?

    AgentRuns::ResultDeliveryJob.perform_now(agent_run.id)
    assert_equal 1, @conversation.conversation_inputs.count
    mail = @conversation.conversation_inputs.sole
    assert_match(/monitor result/, mail.content_bodies.find_by!(role: "input").effective_text)
    refute_match(/needed result/, mail.content_bodies.find_by!(role: "input").effective_text)
  end

  test "a nested turn-owned spawn reports to the mainline even when its waited caller is cross-turn" do
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, READ_TOOL])
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "background review", lifetime: "conversation" })
    call_round(agent_run, "r2t0-model-1", "spawn", { prompt: "required facts", lifetime: "turn", wait: true })
    call = loop_node(agent_run, "r3t0")
    child = call.spawned_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert materialized.accepted?, materialized.outcome.inspect
    child_loop = materialized.value.active_variant.agent_run
    schedule_loop!(child_loop)
    finish_round(agent_run, "r2", "candidate before the child report")
    refute_predicate agent_run.reload, :delivered?
    finish_round(child_loop, "r1", "nested child report")

    AgentRuns::Spawn::Relay.call(conversation_id: child.id)
    refute_predicate agent_run.reload, :delivered?
    background = loop_node(agent_run, "r3")
    assert_equal "queued", background.status, "delivery is still held before either consumer runs"
    assert_equal "conversation", background.lifetime
    assert_predicate background, :detached?
    assert_includes background.input_from_node_keys, call.spawn_delegation.node_key
    schedule_loop!(agent_run)
    assert_equal 1, request_text(background.reload).scan(/Mock: nested child report/).length
    assert_equal 1, request_text(loop_node(agent_run, "w1")).scan(/Mock: nested child report/).length
    AgentRuns::Spawn::Relay.call(conversation_id: child.id)
    assert_equal 1, agent_run.agent_run_tasks.where("node_key LIKE 'w%'").count

    finish_round(agent_run, "w1", "final with the nested report")
    assert_predicate agent_run.reload, :delivered?
    assert_equal "running", background.reload.status
    AgentRuns::ResultDeliveryJob.perform_now(agent_run.id)
    assert_empty @conversation.conversation_inputs.reload
    finish_round(agent_run, "r3", "the separate background review")
    AgentRuns::ResultDeliveryJob.perform_now(agent_run.id)
    mail = @conversation.conversation_inputs.reload.sole
    assert_includes mail.content_body.effective_text, "the separate background review"
    refute_includes mail.content_body.effective_text, "nested child report"
    assert_includes mail.content_body.effective_text, '<task_result task="r2t0"'
    assert_empty AgentRuns::WakeContinuation.undelivered(agent_run)
  end

  test "a cross-turn dependency consumer cannot discharge turn-owned result delivery" do
    _turn, agent_run = open_reply
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: agent_run, origin: "kernel",
      tip: AgentRuns::Tasks::Tip.seed("branch").with(detached: true),
      steps: [
        AgentRuns::Tasks::Step::Tool.new(key: "owned", name: "read_file", lifetime: "turn"),
        AgentRuns::Tasks::Step::Model.new(key: "background", prompt: "use the facts later",
          model: { "model" => "dev/mock-text" }, lifetime: "conversation", results: ["owned"]),
      ]))
    assert appended.applied?, appended.outcome.inspect
    schedule_loop!(agent_run)
    finish_round(agent_run, "r1", "candidate")
    refute_predicate agent_run.reload, :delivered?
    owned = loop_node(agent_run, "owned")
    assert_equal ["background"], owned.outgoing_edges.includes(:to_node).map { |edge| edge.to_node.node_key }

    AgentRuns::Parks::Settle.call(node: owned, trusted: true, content: "required edge report", outcome: "completed")
    refute_predicate agent_run.reload, :delivered?
    schedule_loop!(agent_run)
    background = loop_node(agent_run, "background")
    assert_equal "conversation", background.lifetime
    assert_predicate background, :detached?
    assert_equal 1, request_text(background).scan(/required edge report/).length
    assert_equal 1, request_text(loop_node(agent_run, "w1")).scan(/required edge report/).length
    finish_round(agent_run, "w1", "final incorporates the facts")
    assert_predicate agent_run.reload, :delivered?
    assert_equal "running", background.reload.status
    assert_empty AgentRuns::WakeContinuation.undelivered(agent_run)
  end

  test "canceling a nested spawn wait resumes its background caller and retains child completion" do
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, READ_TOOL])
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "background review", lifetime: "conversation" })
    call_round(agent_run, "r2t0-model-1", "spawn", { prompt: "required facts", lifetime: "turn", wait: true })
    call = loop_node(agent_run, "r3t0")
    await = call.spawn_await
    result = AgentRuns::CancelBranch.call(AgentRuns::CancelBranch::Command.new(
      agent_run: agent_run, task_key: await.node_key, acting_user: @agent))
    assert result.accepted?, result.outcome.inspect
    schedule_loop!(agent_run)
    assert_equal "canceled", await.reload.status
    assert_equal "running", call.spawn_delegation.reload.status
    assert_equal "running", loop_node(agent_run, "r3").status

    child = call.spawned_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert materialized.accepted?, materialized.outcome.inspect
    child_loop = materialized.value.active_variant.agent_run
    schedule_loop!(child_loop)
    finish_round(agent_run, "r2", "candidate still awaiting child completion")
    refute_predicate agent_run.reload, :delivered?
    finish_round(child_loop, "r1", "report after nested wait cancellation")
    AgentRuns::Spawn::Relay.call(conversation_id: child.id)
    schedule_loop!(agent_run)
    assert_equal 1, request_text(loop_node(agent_run, "w1")).scan(/report after nested wait cancellation/).length
    assert_equal "running", loop_node(agent_run, "r3").reload.status
    finish_round(agent_run, "w1", "final with required facts")
    assert_predicate agent_run.reload, :delivered?
  end

  test "synthesis may derive more turn work and the final frontier grows with it" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "first review", lifetime: "turn" })
    finish_round(agent_run, "r2", "candidate")
    finish_round(agent_run, "r2t0-model-1", "first result")
    call_round(agent_run, "w1", "delegate_task", { prompt: "follow-up review", lifetime: "turn" })
    finish_round(agent_run, "r3", "second candidate")
    refute_predicate agent_run.reload, :delivered?

    finish_round(agent_run, "r3t0-model-1", "follow-up result")
    assert_equal 1, request_text(loop_node(agent_run, "w2")).scan(/Mock: follow-up result/).length
    finish_round(agent_run, "w2", "final synthesis")
    assert_predicate agent_run.reload, :delivered?
  end

  test "a turn-owned question retains its virtual clock and expiry holds for repair" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "needs a choice", lifetime: "turn" })
    call_round(agent_run, "r2t0-model-1", "ask", { prompt: "Which choice?" })
    finish_round(agent_run, "r2", "candidate")
    question = loop_node(agent_run, "r3t0-ask-1")
    assert_equal "turn", question.lifetime
    assert_equal "awaiting_input", question.status
    refute_predicate agent_run.reload, :delivered?

    AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(agent_run: agent_run, acting_user: @human))
    AgentRunTask.where(id: question.id).update_all(await_started_at: (AgentRunTasks::AwaitTask::MAX_HOLD + 1.second).ago)
    assert_equal 0, AgentRuns::Parks::TimeoutSweep.call[:expired]
    assert_equal "awaiting_input", question.reload.status
    AgentRuns::Resume.call(AgentRuns::Resume::Command.new(agent_run: agent_run, acting_user: @human))
    assert_equal 1, AgentRuns::Parks::TimeoutSweep.call[:expired]
    assert_equal "timed_out", question.reload.status
    assert_equal "needs_attention", agent_run.reload.status
    refute_predicate agent_run, :delivered?
  end

  test "explicit branch cancel produces non-success material for the final synthesis" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "needs a choice", lifetime: "turn" })
    call_round(agent_run, "r2t0-model-1", "ask", { prompt: "Which choice?" })
    finish_round(agent_run, "r2", "candidate")
    canceled = AgentRuns::CancelBranch.call(AgentRuns::CancelBranch::Command.new(
      agent_run: agent_run, task_key: "r2t0", acting_user: @human
    ))
    assert_predicate canceled, :accepted?
    schedule_loop!(agent_run)
    refute_predicate agent_run.reload, :delivered?
    assert_match(/status=\\"canceled\\"/, request_text(loop_node(agent_run, "w1")))
    finish_round(agent_run, "w1", "explain the cancellation")
    assert_predicate agent_run.reload, :delivered?
  end

  test "wait and lifetime independently select dependencies and inherited expansion" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task",
      { prompt: "waited turn", wait: true, lifetime: "turn" },
      { prompt: "waited conversation", wait: true, lifetime: "conversation" })
    assert_equal "queued", loop_node(agent_run, "r2").status
    assert_equal %w[turn conversation], %w[r2t0-model-1 r2t1-model-1].map { |key| loop_node(agent_run, key).lifetime }
    assert %w[r2t0-model-1 r2t1-model-1].none? { |key| loop_node(agent_run, key).detached? }

    call_round(agent_run, "r2t0-model-1", "read_file", { path: "source.rb" })
    assert_equal "turn", loop_node(agent_run, "r3t0").lifetime
    assert_equal "turn", loop_node(agent_run, "r3").lifetime
    assert_equal "branch", loop_node(agent_run, "r3").continuation_source
    assert_equal "queued", loop_node(agent_run, "r2").status
  end

  test "explicit expansion lifetime overrides the caller and propagates to model tool and ask steps" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "read_file", { path: "source.rb" })
    append_branch!(loop_node(agent_run, "r2t0"), [parallel(
      model("model", "prompt" => "review"),
      tool("tool", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "input" => { "path" => "source.rb" }),
      ask("ask", "prompt" => "Which choice?"), "lifetime" => "turn"
    )])
    schedule_loop!(agent_run)

    assert_equal "conversation", loop_node(agent_run, "r2t0").lifetime
    assert_equal %w[turn turn turn], %w[model tool ask].map { |key| loop_node(agent_run, key).lifetime }
    assert %w[model tool ask].all? { |key| loop_node(agent_run, key).detached? }
    finish_round(agent_run, "r2", "candidate")
    refute_predicate agent_run.reload, :delivered?
    assert_equal "awaiting_human", agent_run.attention_reason
  end

  test "a turn context accepts an explicit cross-turn expansion without changing its siblings" do
    agent_run = seed(model("round1", "lifetime" => "turn", "tools" => [READ_TOOL]))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    schedule_loop!(agent_run)
    call_round(agent_run, "round1", "read_file", { path: "source.rb" })
    append_branch!(loop_node(agent_run, "r1t0"), [model("monitor", "lifetime" => "conversation")])
    schedule_loop!(agent_run)

    assert_equal "conversation", loop_node(agent_run, "monitor").lifetime
    assert_equal "turn", loop_node(agent_run, "r1").lifetime
    assert_equal "turn", loop_node(agent_run, "r1t0").lifetime
  end

  test "post-delivery append refuses turn work and replays an earlier accepted receipt" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "keep loop live" })
    append = grow!(agent_run, detached(tool("owed", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "lifetime" => "turn")),
      idempotency_key: "owed-work")
    finish_round(agent_run, "r2", "candidate")
    schedule_loop!(agent_run)
    AgentRuns::Parks::Settle.call(node: loop_node(agent_run, "owed"), trusted: true,
      content: "owed result", outcome: "completed")
    schedule_loop!(agent_run)
    finish_round(agent_run, "w1", "final")
    assert_predicate agent_run.reload, :delivered?
    stamp = agent_run.delivered_at
    answer = agent_run.deliverable_node_id
    count = agent_run.agent_run_tasks.count

    replay = grow(agent_run, detached(tool("owed", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "lifetime" => "turn")),
      idempotency_key: "owed-work")
    assert_predicate replay, :replayed?
    assert_equal append.receipt, replay.receipt
    refused = grow(agent_run, detached(tool("late", "read_file", "lifetime" => "turn")))
    assert_equal :turn_already_delivered, refused.outcome
    assert_equal count, agent_run.agent_run_tasks.count
    assert_equal [stamp, answer], [agent_run.reload.delivered_at, agent_run.deliverable_node_id]
    assert_predicate grow(agent_run, detached(tool("later", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "lifetime" => "conversation"))), :applied?
  end

  test "member append inherits the mainline context and retry retains its lifetime" do
    agent_run = seed(model("round1", "lifetime" => "turn"))
    AgentRunTask.where(id: agent_run.deliverable_node_id).update_all(status: "completed", completed_at: Time.current)
    agent_run.update!(status: "running")
    grow!(agent_run, model("repair"))
    repair = loop_node(agent_run, "repair")
    assert_equal "turn", repair.lifetime
    AgentRuns::Transition.node(repair, status: "failed", error_key: "failed", completed_at: Time.current)
    result = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "repair", acting_user: @human
    ))
    assert_predicate result, :accepted?
    assert_equal "turn", repair.reload.lifetime

    AgentRuns::Transition.node(repair, status: "failed", error_key: "failed", completed_at: Time.current)
    agent_run.update!(delivered_at: Time.current)
    refused = AgentRuns::Tasks::Retry.call(AgentRuns::Tasks::Retry::Command.new(
      agent_run: agent_run, task_key: "repair", acting_user: @human
    ))
    assert_equal :turn_already_delivered, refused.outcome
    assert_equal "failed", repair.reload.status
  end

  test "invalid tool lifetimes return error material without creating partial work" do
    _turn, agent_run = open_reply
    call_round(agent_run, "r1", "delegate_task", { prompt: "review", lifetime: "forever" })
    assert_match(/lifetime must be/, output(loop_node(agent_run, "r2t0")))
    assert_equal true, loop_node(agent_run, "r2t0").output_summary["is_error"]
    assert_nil agent_run.agent_run_tasks.find_by(node_key: "r2t0-model-1")
    call_round(agent_run, "r2", "delegate_task", { lifetime: "forever", prompt: "review", wait: true })
    assert_match(/lifetime must be/, output(loop_node(agent_run, "r3t0")))
    assert_equal true, loop_node(agent_run, "r3t0").output_summary["is_error"]
  end

  private

    def open_reply
      turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(agent_run)
      [turn, agent_run]
    end

    def attempt_for(agent_run, key)
      invocation_id = loop_node(agent_run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(agent_run, key, name, *arguments)
      calls = arguments.each_with_index.map do |fields, index|
        { id: "call_#{name}_#{index}", name: name, arguments: fields.to_json }
      end
      apply_via(attempt_for(agent_run, key), sse_success("delegating", tool_calls: calls))
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::AskJob,
      AgentRuns::ConversationToolJob, AgentRuns::ScheduleJob]) do
        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      end
      agent_run.reload
    end

    def finish_round(agent_run, key, text)
      apply_via(attempt_for(agent_run, key), sse_success(text))
      AgentRuns::ConvergeTerminalSteps.call
      schedule_loop!(agent_run)
    end

    def request_text(node) = round_request_entries(node).to_json
    def output(node) = node.content_bodies.find_by!(role: "output").effective_text
end
