require "test_helper"

class Runs::TaskLifetimeTest < ActiveJob::TestCase
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
    turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "review", lifetime: "turn" })

    branch = loop_node(run, "r2t0-model-1")
    assert_equal "turn", branch.lifetime
    assert_predicate branch, :detached?
    assert_equal "running", loop_node(run, "r2").status
    assert_match(/incorporate the result before the final answer/, output(loop_node(run, "r2t0")))

    finish_round(run, "r2", "candidate before review")
    refute_predicate run.reload, :delivered?
    Conversations::Turns::Converge.call
    assert_equal "running", turn.reload.status

    finish_round(run, branch.node_key, "review complete")
    wake = loop_node(run, "w1")
    assert_equal "conversation", wake.lifetime, "the wake inherits its mainline, not the result it consumes"
    assert_equal %w[r2 r2t0-model-1], wake.input_from_node_keys
    assert_equal 1, request_text(wake).scan(/Mock: review complete/).length
    refute_predicate run.reload, :delivered?

    finish_round(run, "w1", "synthesized answer")
    assert_predicate run.reload, :delivered?
    assert_equal "completed", run.status
    Conversations::Turns::Converge.call
    assert_equal "Mock: synthesized answer", turn.reload.active_variant.content_bodies.find_by!(role: "content").effective_text
    assert_empty @conversation.inputs.reload
    assert_empty Runs::WakeContinuation.undelivered(run)
  end

  test "mixed lifetimes join selected work while cross-turn work remains and later mails" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task",
      { prompt: "needed", lifetime: "turn" }, { prompt: "monitor", lifetime: "conversation" })
    finish_round(run, "r2t1-model-1", "monitor result")
    finish_round(run, "r2", "candidate")
    refute_predicate run.reload, :delivered?

    stub_const(Runs::Tasks::Compile, :KERNEL_MAX_DEPENDENCIES_PER_TASK, 1) do
      finish_round(run, "r2t0-model-1", "needed result")
    end
    refute_includes request_text(loop_node(run, "w1")), "Mock: monitor result"
    finish_round(run, "w1", "final after needed result")
    assert_predicate run.reload, :delivered?

    Runs::ResultDeliveryJob.perform_now(run.id)
    assert_equal 1, @conversation.inputs.count
    mail = @conversation.inputs.sole
    assert_match(/monitor result/, mail.content_bodies.find_by!(role: "input").effective_text)
    refute_match(/needed result/, mail.content_bodies.find_by!(role: "input").effective_text)
  end

  test "a nested turn-owned spawn reports to the mainline even when its waited caller is cross-turn" do
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, READ_TOOL])
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "background review", lifetime: "conversation" })
    call_round(run, "r2t0-model-1", "spawn", { prompt: "required facts", lifetime: "turn", wait: true })
    call = loop_node(run, "r3t0")
    child = call.spawned_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert materialized.accepted?, materialized.outcome.inspect
    child_loop = materialized.value.active_variant.run
    schedule_loop!(child_loop)
    finish_round(run, "r2", "candidate before the child report")
    refute_predicate run.reload, :delivered?
    finish_round(child_loop, "r1", "nested child report")

    Runs::Spawn::Relay.call(conversation_id: child.id)
    refute_predicate run.reload, :delivered?
    background = loop_node(run, "r3")
    assert_equal "queued", background.status, "delivery is still held before either consumer runs"
    assert_equal "conversation", background.lifetime
    assert_predicate background, :detached?
    assert_includes background.input_from_node_keys, call.spawn_delegation.node_key
    schedule_loop!(run)
    assert_equal 1, request_text(background.reload).scan(/Mock: nested child report/).length
    assert_equal 1, request_text(loop_node(run, "w1")).scan(/Mock: nested child report/).length
    Runs::Spawn::Relay.call(conversation_id: child.id)
    assert_equal 1, run.tasks.where("node_key LIKE 'w%'").count

    finish_round(run, "w1", "final with the nested report")
    assert_predicate run.reload, :delivered?
    assert_equal "running", background.reload.status
    Runs::ResultDeliveryJob.perform_now(run.id)
    assert_empty @conversation.inputs.reload
    finish_round(run, "r3", "the separate background review")
    Runs::ResultDeliveryJob.perform_now(run.id)
    mail = @conversation.inputs.reload.sole
    assert_includes mail.content_body.effective_text, "the separate background review"
    refute_includes mail.content_body.effective_text, "nested child report"
    assert_includes mail.content_body.effective_text, '<task_result task="r2t0"'
    assert_empty Runs::WakeContinuation.undelivered(run)
  end

  test "a cross-turn dependency consumer cannot discharge turn-owned result delivery" do
    _turn, run = open_reply
    appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, origin: "kernel",
      tip: Runs::Tasks::Tip.seed("branch").with(detached: true),
      steps: [
        Runs::Tasks::Step::Tool.new(key: "owned", name: "read_file", lifetime: "turn"),
        Runs::Tasks::Step::Model.new(key: "background", prompt: "use the facts later",
          model: { "model" => "dev/mock-text" }, lifetime: "conversation", results: ["owned"]),
      ]))
    assert appended.applied?, appended.outcome.inspect
    schedule_loop!(run)
    finish_round(run, "r1", "candidate")
    refute_predicate run.reload, :delivered?
    owned = loop_node(run, "owned")
    assert_equal ["background"], owned.outgoing_edges.includes(:to_node).map { |edge| edge.to_node.node_key }

    Runs::Parks::Settle.call(node: owned, trusted: true, content: "required edge report", outcome: "completed")
    refute_predicate run.reload, :delivered?
    schedule_loop!(run)
    background = loop_node(run, "background")
    assert_equal "conversation", background.lifetime
    assert_predicate background, :detached?
    assert_equal 1, request_text(background).scan(/required edge report/).length
    assert_equal 1, request_text(loop_node(run, "w1")).scan(/required edge report/).length
    finish_round(run, "w1", "final incorporates the facts")
    assert_predicate run.reload, :delivered?
    assert_equal "running", background.reload.status
    assert_empty Runs::WakeContinuation.undelivered(run)
  end

  test "canceling a nested spawn wait resumes its background caller and retains child completion" do
    declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::SPAWN, READ_TOOL])
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "background review", lifetime: "conversation" })
    call_round(run, "r2t0-model-1", "spawn", { prompt: "required facts", lifetime: "turn", wait: true })
    call = loop_node(run, "r3t0")
    await = call.spawn_await
    result = Runs::CancelBranch.call(Runs::CancelBranch::Command.new(
      run: run, task_key: await.node_key, acting_user: @agent))
    assert result.accepted?, result.outcome.inspect
    schedule_loop!(run)
    assert_equal "canceled", await.reload.status
    assert_equal "running", call.spawn_delegation.reload.status
    assert_equal "running", loop_node(run, "r3").status

    child = call.spawned_conversation
    materialized = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert materialized.accepted?, materialized.outcome.inspect
    child_loop = materialized.value.active_variant.run
    schedule_loop!(child_loop)
    finish_round(run, "r2", "candidate still awaiting child completion")
    refute_predicate run.reload, :delivered?
    finish_round(child_loop, "r1", "report after nested wait cancellation")
    Runs::Spawn::Relay.call(conversation_id: child.id)
    schedule_loop!(run)
    assert_equal 1, request_text(loop_node(run, "w1")).scan(/report after nested wait cancellation/).length
    assert_equal "running", loop_node(run, "r3").reload.status
    finish_round(run, "w1", "final with required facts")
    assert_predicate run.reload, :delivered?
  end

  test "synthesis may derive more turn work and the final frontier grows with it" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "first review", lifetime: "turn" })
    finish_round(run, "r2", "candidate")
    finish_round(run, "r2t0-model-1", "first result")
    call_round(run, "w1", "delegate_task", { prompt: "follow-up review", lifetime: "turn" })
    finish_round(run, "r3", "second candidate")
    refute_predicate run.reload, :delivered?

    finish_round(run, "r3t0-model-1", "follow-up result")
    assert_equal 1, request_text(loop_node(run, "w2")).scan(/Mock: follow-up result/).length
    finish_round(run, "w2", "final synthesis")
    assert_predicate run.reload, :delivered?
  end

  test "a turn-owned question retains its virtual clock and expiry holds for repair" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "needs a choice", lifetime: "turn" })
    call_round(run, "r2t0-model-1", "ask", { prompt: "Which choice?" })
    finish_round(run, "r2", "candidate")
    question = loop_node(run, "r3t0-ask-1")
    assert_equal "turn", question.lifetime
    assert_equal "awaiting_input", question.status
    refute_predicate run.reload, :delivered?

    Runs::Pause.call(Runs::Pause::Command.graceful(run: run, acting_user: @human))
    Task.where(id: question.id).update_all(await_started_at: (Tasks::AwaitTask::MAX_HOLD + 1.second).ago)
    assert_equal 0, Runs::Parks::TimeoutSweep.call[:expired]
    assert_equal "awaiting_input", question.reload.status
    Runs::Resume.call(Runs::Resume::Command.new(run: run, acting_user: @human))
    assert_equal 1, Runs::Parks::TimeoutSweep.call[:expired]
    assert_equal "timed_out", question.reload.status
    assert_equal "needs_attention", run.reload.status
    refute_predicate run, :delivered?
  end

  test "explicit branch cancel produces non-success material for the final synthesis" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "needs a choice", lifetime: "turn" })
    call_round(run, "r2t0-model-1", "ask", { prompt: "Which choice?" })
    finish_round(run, "r2", "candidate")
    canceled = Runs::CancelBranch.call(Runs::CancelBranch::Command.new(
      run: run, task_key: "r2t0", acting_user: @human
    ))
    assert_predicate canceled, :accepted?
    schedule_loop!(run)
    refute_predicate run.reload, :delivered?
    assert_match(/status=\\"canceled\\"/, request_text(loop_node(run, "w1")))
    finish_round(run, "w1", "explain the cancellation")
    assert_predicate run.reload, :delivered?
  end

  test "wait and lifetime independently select dependencies and inherited expansion" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task",
      { prompt: "waited turn", wait: true, lifetime: "turn" },
      { prompt: "waited conversation", wait: true, lifetime: "conversation" })
    assert_equal "queued", loop_node(run, "r2").status
    assert_equal %w[turn conversation], %w[r2t0-model-1 r2t1-model-1].map { |key| loop_node(run, key).lifetime }
    assert %w[r2t0-model-1 r2t1-model-1].none? { |key| loop_node(run, key).detached? }

    call_round(run, "r2t0-model-1", "read_file", { path: "source.rb" })
    assert_equal "turn", loop_node(run, "r3t0").lifetime
    assert_equal "turn", loop_node(run, "r3").lifetime
    assert_equal "branch", loop_node(run, "r3").continuation_source
    assert_equal "queued", loop_node(run, "r2").status
  end

  test "explicit expansion lifetime overrides the caller and propagates to model tool and ask steps" do
    _turn, run = open_reply
    call_round(run, "r1", "read_file", { path: "source.rb" })
    append_branch!(loop_node(run, "r2t0"), [parallel(
      model("model", "prompt" => "review"),
      tool("tool", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "input" => { "path" => "source.rb" }),
      ask("ask", "prompt" => "Which choice?"), "lifetime" => "turn"
    )])
    schedule_loop!(run)

    assert_equal "conversation", loop_node(run, "r2t0").lifetime
    assert_equal %w[turn turn turn], %w[model tool ask].map { |key| loop_node(run, key).lifetime }
    assert %w[model tool ask].all? { |key| loop_node(run, key).detached? }
    finish_round(run, "r2", "candidate")
    refute_predicate run.reload, :delivered?
    assert_equal "awaiting_human", run.attention_reason
  end

  test "a turn context accepts an explicit cross-turn expansion without changing its siblings" do
    run = seed(model("round1", "lifetime" => "turn", "tools" => [READ_TOOL]))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    schedule_loop!(run)
    call_round(run, "round1", "read_file", { path: "source.rb" })
    append_branch!(loop_node(run, "r1t0"), [model("monitor", "lifetime" => "conversation")])
    schedule_loop!(run)

    assert_equal "conversation", loop_node(run, "monitor").lifetime
    assert_equal "turn", loop_node(run, "r1").lifetime
    assert_equal "turn", loop_node(run, "r1t0").lifetime
  end

  test "post-delivery append refuses turn work and replays an earlier accepted receipt" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "keep loop live" })
    append = grow!(run, detached(tool("owed", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "lifetime" => "turn")),
      idempotency_key: "owed-work")
    finish_round(run, "r2", "candidate")
    schedule_loop!(run)
    Runs::Parks::Settle.call(node: loop_node(run, "owed"), trusted: true,
      content: "owed result", outcome: "completed")
    schedule_loop!(run)
    finish_round(run, "w1", "final")
    assert_predicate run.reload, :delivered?
    stamp = run.delivered_at
    answer = run.deliverable_node_id
    count = run.tasks.count

    replay = grow(run, detached(tool("owed", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "lifetime" => "turn")),
      idempotency_key: "owed-work")
    assert_predicate replay, :replayed?
    assert_equal append.receipt, replay.receipt
    refused = grow(run, detached(tool("late", "read_file", "lifetime" => "turn")))
    assert_equal :turn_already_delivered, refused.outcome
    assert_equal count, run.tasks.count
    assert_equal [stamp, answer], [run.reload.delivered_at, run.deliverable_node_id]
    assert_predicate grow(run, detached(tool("later", "read_file", "route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id }, "lifetime" => "conversation"))), :applied?
  end

  test "member append inherits the mainline context and retry retains its lifetime" do
    run = seed(model("round1", "lifetime" => "turn"))
    Task.where(id: run.deliverable_node_id).update_all(status: "completed", completed_at: Time.current)
    run.update!(status: "running")
    grow!(run, model("repair"))
    repair = loop_node(run, "repair")
    assert_equal "turn", repair.lifetime
    Runs::Transition.node(repair, status: "failed", error_key: "failed", completed_at: Time.current)
    result = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "repair", acting_user: @human
    ))
    assert_predicate result, :accepted?
    assert_equal "turn", repair.reload.lifetime

    Runs::Transition.node(repair, status: "failed", error_key: "failed", completed_at: Time.current)
    run.update!(delivered_at: Time.current)
    refused = Runs::Tasks::Retry.call(Runs::Tasks::Retry::Command.new(
      run: run, task_key: "repair", acting_user: @human
    ))
    assert_equal :turn_already_delivered, refused.outcome
    assert_equal "failed", repair.reload.status
  end

  test "invalid tool lifetimes return error material without creating partial work" do
    _turn, run = open_reply
    call_round(run, "r1", "delegate_task", { prompt: "review", lifetime: "forever" })
    assert_match(/lifetime must be/, output(loop_node(run, "r2t0")))
    assert_equal true, loop_node(run, "r2t0").output_summary["is_error"]
    assert_nil run.tasks.find_by(node_key: "r2t0-model-1")
    call_round(run, "r2", "delegate_task", { lifetime: "forever", prompt: "review", wait: true })
    assert_match(/lifetime must be/, output(loop_node(run, "r3t0")))
    assert_equal true, loop_node(run, "r3t0").output_summary["is_error"]
  end

  private

    def open_reply
      turn, run = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(run)
      [turn, run]
    end

    def attempt_for(run, key)
      invocation_id = loop_node(run, key).selected_model_invocation_id
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
    end

    def call_round(run, key, name, *arguments)
      calls = arguments.each_with_index.map do |fields, index|
        { id: "call_#{name}_#{index}", name: name, arguments: fields.to_json }
      end
      apply_via(attempt_for(run, key), sse_success("delegating", tool_calls: calls))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [Runs::DelegateTaskToolJob, Runs::AskJob,
      Runs::ConversationToolJob, Runs::ScheduleJob]) do
        Runs::ScheduleReady.call(run_id: run.id)
      end
      run.reload
    end

    def finish_round(run, key, text)
      apply_via(attempt_for(run, key), sse_success(text))
      Runs::ConvergeTerminalSteps.call
      schedule_loop!(run)
    end

    def request_text(node) = round_request_entries(node).to_json
    def output(node) = node.content_bodies.find_by!(role: "output").effective_text
end
