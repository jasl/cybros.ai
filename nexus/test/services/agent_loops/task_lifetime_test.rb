require "test_helper"

class AgentLoops::TaskLifetimeTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::ASK, Nexus::Compose::DEFINITION, READ_TOOL])
  end

  test "asynchronous turn work permits foreground progress but joins and synthesizes before final" do
    turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "review", lifetime: "turn" })

    branch = loop_node(agent_loop, "r2t0-model-1")
    assert_equal "turn", branch.lifetime
    assert_predicate branch, :detached?
    assert_equal "running", loop_node(agent_loop, "r2").status
    assert_match(/incorporate the result before the final answer/, output(loop_node(agent_loop, "r2t0")))

    finish_round(agent_loop, "r2", "candidate before review")
    refute_predicate agent_loop.reload, :delivered?
    Conversations::Turns::Converge.call
    assert_equal "running", turn.reload.status

    finish_round(agent_loop, branch.node_key, "review complete")
    wake = loop_node(agent_loop, "w1")
    assert_equal "conversation", wake.lifetime, "the wake inherits its spine, not the result it consumes"
    assert_equal %w[r2 r2t0-model-1], wake.input_from_node_keys
    assert_equal 1, request_text(wake).scan(/Mock: review complete/).length
    refute_predicate agent_loop.reload, :delivered?

    finish_round(agent_loop, "w1", "synthesized answer")
    assert_predicate agent_loop.reload, :delivered?
    assert_equal "completed", agent_loop.status
    Conversations::Turns::Converge.call
    assert_equal "Mock: synthesized answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_empty @conversation.conversation_inputs.reload
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop)
  end

  test "mixed lifetimes join selected work while cross-turn work remains and later mails" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task",
      { prompt: "needed", lifetime: "turn" }, { prompt: "monitor", lifetime: "conversation" })
    finish_round(agent_loop, "r2t1-model-1", "monitor result")
    finish_round(agent_loop, "r2", "candidate")
    refute_predicate agent_loop.reload, :delivered?

    stub_const(AgentLoops::Tasks::Compile, :KERNEL_MAX_DEPENDENCIES_PER_TASK, 1) do
      finish_round(agent_loop, "r2t0-model-1", "needed result")
    end
    refute_includes request_text(loop_node(agent_loop, "w1")), "Mock: monitor result"
    finish_round(agent_loop, "w1", "final after needed result")
    assert_predicate agent_loop.reload, :delivered?

    AgentLoops::MailJob.perform_now(agent_loop.id)
    assert_equal 1, @conversation.conversation_inputs.count
    mail = @conversation.conversation_inputs.sole
    assert_match(/monitor result/, mail.content_bodies.find_by!(role: "input").effective_text)
    refute_match(/needed result/, mail.content_bodies.find_by!(role: "input").effective_text)
  end

  test "a nested turn-owned spawn reports to the mainline even when its waited caller is cross-turn" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::SPAWN, READ_TOOL])
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "background review", lifetime: "conversation" })
    call_round(agent_loop, "r2t0-model-1", "spawn", { prompt: "required facts", lifetime: "turn", wait: true })
    call = loop_node(agent_loop, "r3t0")
    child = call.spawned_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert materialized.accepted?, materialized.outcome.inspect
    child_loop = materialized.value.active_variant.agent_loop
    schedule_loop!(child_loop)
    finish_round(agent_loop, "r2", "candidate before the child report")
    refute_predicate agent_loop.reload, :delivered?
    finish_round(child_loop, "r1", "nested child report")

    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    refute_predicate agent_loop.reload, :delivered?
    background = loop_node(agent_loop, "r3")
    assert_equal "queued", background.status, "delivery is still held before either consumer runs"
    assert_equal "conversation", background.lifetime
    assert_predicate background, :detached?
    assert_includes background.input_from_node_keys, call.spawn_delegation.node_key
    schedule_loop!(agent_loop)
    assert_equal 1, request_text(background.reload).scan(/Mock: nested child report/).length
    assert_equal 1, request_text(loop_node(agent_loop, "w1")).scan(/Mock: nested child report/).length
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    assert_equal 1, agent_loop.agent_loop_nodes.where("node_key LIKE 'w%'").count

    finish_round(agent_loop, "w1", "final with the nested report")
    assert_predicate agent_loop.reload, :delivered?
    assert_equal "running", background.reload.status
    AgentLoops::MailJob.perform_now(agent_loop.id)
    assert_empty @conversation.conversation_inputs.reload
    finish_round(agent_loop, "r3", "the separate background review")
    AgentLoops::MailJob.perform_now(agent_loop.id)
    mail = @conversation.conversation_inputs.reload.sole
    assert_includes mail.content_body.effective_text, "the separate background review"
    refute_includes mail.content_body.effective_text, "nested child report"
    assert_includes mail.content_body.effective_text, '<task_result task="r2t0"'
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop)
  end

  test "a cross-turn dependency consumer cannot discharge turn-owned result delivery" do
    _turn, agent_loop = open_reply
    appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
      agent_loop: agent_loop, origin: "kernel",
      tip: AgentLoops::Tasks::Tip.seed("branch").with(detached: true),
      steps: [
        AgentLoops::Tasks::Step::Tool.new(key: "owned", name: "read_file", lifetime: "turn"),
        AgentLoops::Tasks::Step::Model.new(key: "background", prompt: "use the facts later",
          model: { "model" => "dev/mock-text" }, lifetime: "conversation", results: ["owned"]),
      ]))
    assert appended.applied?, appended.outcome.inspect
    schedule_loop!(agent_loop)
    finish_round(agent_loop, "r1", "candidate")
    refute_predicate agent_loop.reload, :delivered?
    owned = loop_node(agent_loop, "owned")
    assert_equal ["background"], owned.outgoing_edges.includes(:to_node).map { |edge| edge.to_node.node_key }

    AgentLoops::Parks::Settle.call(node: owned, trusted: true, content: "required edge report", outcome: "completed")
    refute_predicate agent_loop.reload, :delivered?
    schedule_loop!(agent_loop)
    background = loop_node(agent_loop, "background")
    assert_equal "conversation", background.lifetime
    assert_predicate background, :detached?
    assert_equal 1, request_text(background).scan(/required edge report/).length
    assert_equal 1, request_text(loop_node(agent_loop, "w1")).scan(/required edge report/).length
    finish_round(agent_loop, "w1", "final incorporates the facts")
    assert_predicate agent_loop.reload, :delivered?
    assert_equal "running", background.reload.status
    assert_empty AgentLoops::WakeContinuation.undelivered(agent_loop)
  end

  test "canceling a nested spawn wait resumes its background caller and retains child completion" do
    declare_tools!(@agent, tools: [Nexus::Tools::TASK, Nexus::Tools::SPAWN, READ_TOOL])
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "background review", lifetime: "conversation" })
    call_round(agent_loop, "r2t0-model-1", "spawn", { prompt: "required facts", lifetime: "turn", wait: true })
    call = loop_node(agent_loop, "r3t0")
    await = call.spawn_await
    result = AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
      agent_loop: agent_loop, task_key: await.node_key, acting_user: @agent))
    assert result.accepted?, result.outcome.inspect
    schedule_loop!(agent_loop)
    assert_equal "canceled", await.reload.status
    assert_equal "running", call.spawn_delegation.reload.status
    assert_equal "running", loop_node(agent_loop, "r3").status

    child = call.spawned_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert materialized.accepted?, materialized.outcome.inspect
    child_loop = materialized.value.active_variant.agent_loop
    schedule_loop!(child_loop)
    finish_round(agent_loop, "r2", "candidate still awaiting child completion")
    refute_predicate agent_loop.reload, :delivered?
    finish_round(child_loop, "r1", "report after nested wait cancellation")
    AgentLoops::Spawn::Relay.call(conversation_id: child.id)
    schedule_loop!(agent_loop)
    assert_equal 1, request_text(loop_node(agent_loop, "w1")).scan(/report after nested wait cancellation/).length
    assert_equal "running", loop_node(agent_loop, "r3").reload.status
    finish_round(agent_loop, "w1", "final with required facts")
    assert_predicate agent_loop.reload, :delivered?
  end

  test "synthesis may derive more turn work and the final frontier grows with it" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "first review", lifetime: "turn" })
    finish_round(agent_loop, "r2", "candidate")
    finish_round(agent_loop, "r2t0-model-1", "first result")
    call_round(agent_loop, "w1", "task", { prompt: "follow-up review", lifetime: "turn" })
    finish_round(agent_loop, "r3", "second candidate")
    refute_predicate agent_loop.reload, :delivered?

    finish_round(agent_loop, "r3t0-model-1", "follow-up result")
    assert_equal 1, request_text(loop_node(agent_loop, "w2")).scan(/Mock: follow-up result/).length
    finish_round(agent_loop, "w2", "final synthesis")
    assert_predicate agent_loop.reload, :delivered?
  end

  test "a turn-owned question retains its virtual clock and expiry holds for repair" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "needs a choice", lifetime: "turn" })
    call_round(agent_loop, "r2t0-model-1", "ask", { prompt: "Which choice?" })
    finish_round(agent_loop, "r2", "candidate")
    question = loop_node(agent_loop, "r3t0-ask-1")
    assert_equal "turn", question.lifetime
    assert_equal "awaiting_input", question.status
    refute_predicate agent_loop.reload, :delivered?

    AgentLoops::Pause.call(AgentLoops::Pause::Command.graceful(agent_loop: agent_loop, acting_user: @human))
    AgentLoopNode.where(id: question.id).update_all(await_started_at: (AgentLoopNodes::AwaitTask::MAX_HOLD + 1.second).ago)
    assert_equal 0, AgentLoops::Parks::TimeoutSweep.call[:expired]
    assert_equal "awaiting_input", question.reload.status
    AgentLoops::Resume.call(AgentLoops::Resume::Command.new(agent_loop: agent_loop, acting_user: @human))
    assert_equal 1, AgentLoops::Parks::TimeoutSweep.call[:expired]
    assert_equal "timed_out", question.reload.status
    assert_equal "needs_attention", agent_loop.reload.status
    refute_predicate agent_loop, :delivered?
  end

  test "explicit branch cancel produces non-success material for the final synthesis" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "needs a choice", lifetime: "turn" })
    call_round(agent_loop, "r2t0-model-1", "ask", { prompt: "Which choice?" })
    finish_round(agent_loop, "r2", "candidate")
    canceled = AgentLoops::CancelBranch.call(AgentLoops::CancelBranch::Command.new(
      agent_loop: agent_loop, task_key: "r2t0", acting_user: @human
    ))
    assert_predicate canceled, :accepted?
    schedule_loop!(agent_loop)
    refute_predicate agent_loop.reload, :delivered?
    assert_match(/status=\\"canceled\\"/, request_text(loop_node(agent_loop, "w1")))
    finish_round(agent_loop, "w1", "explain the cancellation")
    assert_predicate agent_loop.reload, :delivered?
  end

  test "wait and lifetime independently select dependencies and inherited expansion" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task",
      { prompt: "waited turn", wait: true, lifetime: "turn" },
      { prompt: "waited conversation", wait: true, lifetime: "conversation" })
    assert_equal "queued", loop_node(agent_loop, "r2").status
    assert_equal %w[turn conversation], %w[r2t0-model-1 r2t1-model-1].map { |key| loop_node(agent_loop, key).lifetime }
    assert %w[r2t0-model-1 r2t1-model-1].none? { |key| loop_node(agent_loop, key).detached? }

    call_round(agent_loop, "r2t0-model-1", "read_file", { path: "source.rb" })
    assert_equal "turn", loop_node(agent_loop, "r3t0").lifetime
    assert_equal "turn", loop_node(agent_loop, "r3").lifetime
    assert_equal "branch", loop_node(agent_loop, "r3").continuation_source
    assert_equal "queued", loop_node(agent_loop, "r2").status
  end

  test "compose selection overrides the caller and propagates to model tool and ask steps" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "compose", { lifetime: "turn", script: <<~JS })
      g.parallel([
        g.model({ prompt: "review", key: "model" }),
        g.tool({ name: "read_file", input: { path: "source.rb" }, key: "tool" }),
        g.ask({ prompt: "Which choice?", key: "ask" }),
      ]);
    JS

    assert_equal "conversation", loop_node(agent_loop, "r2t0").lifetime
    assert_equal %w[turn turn turn], %w[r2t0-model r2t0-tool r2t0-ask].map { |key| loop_node(agent_loop, key).lifetime }
    assert %w[r2t0-model r2t0-tool r2t0-ask].all? { |key| loop_node(agent_loop, key).detached? }
    finish_round(agent_loop, "r2", "candidate")
    refute_predicate agent_loop.reload, :delivered?
    assert_equal "awaiting_human", agent_loop.attention_reason
  end

  test "a turn context accepts an explicit cross-turn compose override without changing its siblings" do
    agent_loop = seed(model("round1", "lifetime" => "turn",
      "tools" => [Nexus::Compose::DEFINITION, READ_TOOL]))
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
    schedule_loop!(agent_loop)
    call_round(agent_loop, "round1", "compose", { lifetime: "conversation", script: <<~JS })
      g.model({ prompt: "monitor", key: "monitor" });
    JS

    assert_equal "conversation", loop_node(agent_loop, "r1t0-monitor").lifetime
    assert_equal "turn", loop_node(agent_loop, "r1").lifetime
    assert_equal "turn", loop_node(agent_loop, "r1t0").lifetime
  end

  test "post-delivery append refuses turn work and replays an earlier accepted receipt" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "keep loop live" })
    append = grow!(agent_loop, detached(tool("owed", "read_file", "lifetime" => "turn")),
      idempotency_key: "owed-work")
    finish_round(agent_loop, "r2", "candidate")
    schedule_loop!(agent_loop)
    AgentLoops::Parks::Settle.call(node: loop_node(agent_loop, "owed"), trusted: true,
      content: "owed result", outcome: "completed")
    schedule_loop!(agent_loop)
    finish_round(agent_loop, "w1", "final")
    assert_predicate agent_loop.reload, :delivered?
    stamp = agent_loop.delivered_at
    answer = agent_loop.deliverable_node_id
    count = agent_loop.agent_loop_nodes.count

    replay = grow(agent_loop, detached(tool("owed", "read_file", "lifetime" => "turn")),
      idempotency_key: "owed-work")
    assert_predicate replay, :replayed?
    assert_equal append.receipt, replay.receipt
    refused = grow(agent_loop, detached(tool("late", "read_file", "lifetime" => "turn")))
    assert_equal :turn_already_delivered, refused.outcome
    assert_equal count, agent_loop.agent_loop_nodes.count
    assert_equal [stamp, answer], [agent_loop.reload.delivered_at, agent_loop.deliverable_node_id]
    assert_predicate grow(agent_loop, detached(tool("later", "read_file", "lifetime" => "conversation"))), :applied?
  end

  test "member append inherits the mainline context and retry retains its lifetime" do
    agent_loop = seed(model("round1", "lifetime" => "turn"))
    AgentLoopNode.where(id: agent_loop.deliverable_node_id).update_all(status: "completed", completed_at: Time.current)
    agent_loop.update!(status: "running")
    grow!(agent_loop, model("repair"))
    repair = loop_node(agent_loop, "repair")
    assert_equal "turn", repair.lifetime
    AgentLoops::Transition.node(repair, status: "failed", error_key: "failed", completed_at: Time.current)
    result = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "repair", acting_user: @human
    ))
    assert_predicate result, :accepted?
    assert_equal "turn", repair.reload.lifetime

    AgentLoops::Transition.node(repair, status: "failed", error_key: "failed", completed_at: Time.current)
    agent_loop.update!(delivered_at: Time.current)
    refused = AgentLoops::Tasks::Retry.call(AgentLoops::Tasks::Retry::Command.new(
      agent_loop: agent_loop, task_key: "repair", acting_user: @human
    ))
    assert_equal :turn_already_delivered, refused.outcome
    assert_equal "failed", repair.reload.status
  end

  test "invalid tool lifetimes return error material without creating partial work" do
    _turn, agent_loop = open_reply
    call_round(agent_loop, "r1", "task", { prompt: "review", lifetime: "forever" })
    assert_match(/lifetime must be/, output(loop_node(agent_loop, "r2t0")))
    assert_equal true, loop_node(agent_loop, "r2t0").output_summary["is_error"]
    assert_nil agent_loop.agent_loop_nodes.find_by(node_key: "r2t0-model-1")
    call_round(agent_loop, "r2", "compose", { lifetime: "forever", script: "g.model({ prompt: 'review' });" })
    assert_match(/lifetime must be/, output(loop_node(agent_loop, "r3t0")))
    assert_equal true, loop_node(agent_loop, "r3t0").output_summary["is_error"]
  end

  private

    def open_reply
      turn, agent_loop = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(agent_loop)
      [turn, agent_loop]
    end

    def attempt_for(agent_loop, key)
      invocation_id = loop_node(agent_loop, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(agent_loop, key, name, *arguments)
      calls = arguments.each_with_index.map do |fields, index|
        { id: "call_#{name}_#{index}", name: name, arguments: fields.to_json }
      end
      apply_via(attempt_for(agent_loop, key), sse_success("delegating", tool_calls: calls))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [AgentLoops::TaskToolJob, AgentLoops::ComposeJob, AgentLoops::AskJob,
      AgentLoops::ConversationToolJob, AgentLoops::ScheduleJob]) do
        AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
      end
      agent_loop.reload
    end

    def finish_round(agent_loop, key, text)
      apply_via(attempt_for(agent_loop, key), sse_success(text))
      AgentLoops::ConvergeTerminalSteps.call
      schedule_loop!(agent_loop)
    end

    def request_text(node) = round_request_entries(node).to_json
    def output(node) = node.content_bodies.find_by!(role: "output").effective_text
end
