require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class Runs::ConversationCommunicationTest < ActiveJob::TestCase
  include LockOrderTestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @sender = users(:agent)
    @recipient = create_agent_member(display_name: "Recipient", agent_identifier: "communication-recipient")
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    [@sender, @recipient].each do |agent|
      declare_tools!(agent, tools: [Nexus::Tools::SEND, Nexus::Tools::REQUEST, Nexus::Tools::SPAWN, Nexus::Tools::LINKS, READ_TOOL], default_model: "dev/mock-text")
    end
    @source = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @sender)
    @target = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @recipient)
  end

  test "consumed ordinary message belongs to the recipient after its sender stops" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call_tool(source, "send", to: @target.public_id, message: "Please consider this question")
    input = @target.inputs.sole
    assert_equal @sender, input.authoring_user
    input_public_id = input.public_id

    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id)
    assert applied.accepted?, applied.outcome.inspect
    turn = applied.value
    receiving = turn.active_variant.run
    assert_equal input_public_id, turn.input_public_id
    assert_equal source.public_id, turn.sender_run_public_id
    assert_equal @recipient, receiving.creating_user
    assert_equal @recipient, turn.control_owner_user

    assert Conversations::Turns::Cancel.stop_tree(@source).accepted?
    assert source.reload.stopped?
    refute Runs::SourceWork.execution_stopped?(receiving.reload)
    schedule_loop!(receiving)
    run_loop_round!(receiving, sse_success("Recipient answer"))
    assert receiving.reload.delivered?
  end

  test "unconsumed ordinary message is discarded when its sender stops" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call_tool(source, "send", to: @target.public_id, message: "This has not been consumed")
    input_public_id = @target.inputs.sole.public_id
    assert Conversations::Turns::Cancel.stop_tree(@source).accepted?
    Conversations::Inputs::ApplyNext.drain(conversation_id: @target.id)
    refute @target.inputs.exists?(public_id: input_public_id)
    refute @target.turns.exists?(input_public_id: input_public_id)
  end

  test "request completion observes the original execution" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", to: @target.public_id, prompt: "First request", lifetime: "conversation")
    completion = Runs::Delegations.for_call(call)
    assert_equal "conversation", completion.lifetime
    original_id = completion.delegated_input_public_id
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id)
    assert applied.accepted?, applied.outcome.inspect
    worker = applied.value.active_variant.run
    schedule_loop!(worker)
    run_loop_round!(worker, sse_success("Original result"))
    Runs::Delegations.converge(node: completion.reload)
    assert_equal "completed", completion.reload.status
    assert_equal original_id, Runs::TaskResultProjection.call(completion).dig("structured_content", "input_public_id")
  end

  test "closing a link before consumption discards its pending message" do
    link = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human)
    assert link.accepted?, link.outcome.inspect
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call_tool(source, "send", link_public_id: link.value.public_id, message: "Pending question")
    input_id = @target.inputs.sole.public_id
    link.value.close
    Conversations::Inputs::ApplyNext.drain(conversation_id: @target.id)
    refute @target.inputs.exists?(public_id: input_id)
    refute @target.turns.exists?(input_public_id: input_id)
  end

  test "closing a link after consumption preserves recipient work" do
    link = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human).value
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call_tool(source, "send", link_public_id: link.public_id, message: "Consumed question")
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id)
    assert applied.accepted?, applied.outcome.inspect
    worker = applied.value.active_variant.run
    link.close
    schedule_loop!(worker)
    run_loop_round!(worker, sse_success("Independent answer"))
    assert worker.reload.delivered?
    Runs::Spawn::Relay.call(conversation_id: @target.id)
    assert_empty @source.inputs.reload
    assert_empty source.tasks.where(type: Tasks::DelegationTask.sti_name)
  end

  test "detached request survives P1 reply and a worker question wakes independent P2" do
    link = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human).value
    _turn, p1 = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(p1)
    request = call_tool(p1, "request", to: @target.public_id, prompt: "Work on R1", lifetime: "conversation")
    run_loop_round!(p1, sse_success("I have started the worker"))
    assert p1.reload.delivered?
    Conversations::Turns::Converge.call(conversation_id: @source.id)

    worker_turn = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value
    worker = worker_turn.active_variant.run
    schedule_loop!(worker)
    call_tool(worker, "send", link_public_id: link.public_id, message: "Which acceptance criterion?")
    question = @source.inputs.sole
    assert_equal worker.public_id, question.sender_run_public_id
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @source.id)
    assert applied.accepted?, applied.outcome.inspect
    p2 = applied.value.active_variant.run
    refute_equal p1.id, p2.id
    schedule_loop!(p2)
    call_tool(p2, "send", link_public_id: link.public_id, message: "Use the focused contract test")
    assert_equal "Use the focused contract test", @target.inputs.sole.content_body.effective_text
    assert_equal p2.public_id, @target.inputs.sole.sender_run_public_id
    assert_equal "running", Runs::Delegations.for_call(request).reload.status
    run_loop_round!(p2, sse_success("Criterion sent"))
    assert p2.reload.delivered?
    refute worker.reload.stopped?
  end

  test "stopping the worker reports canceled without stopping its requester" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", to: @target.public_id, prompt: "Cancelable request", wait: true)
    completion = Runs::Delegations.for_call(call)
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id)
    assert applied.accepted?, applied.outcome.inspect
    worker = applied.value.active_variant.run
    schedule_loop!(worker)
    assert Conversations::Turns::Cancel.stop_tree(@target).accepted?
    Runs::ConvergeTerminalSteps.call
    schedule_loop!(worker)
    Runs::Delegations.converge(node: completion)
    assert_equal "failed", completion.reload.status
    assert_equal "canceled", Runs::TaskResultProjection.call(completion).dig("structured_content", "status")
    assert call.spawn_await.reload.terminal?
    refute source.reload.stopped?
    schedule_loop!(source)
    run_loop_round!(source, sse_success("The worker was canceled; I can continue"))
    assert source.reload.delivered?
  end

  test "late R1 completion cannot settle R2 on the same worker conversation" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    first = call_tool(source, "request", to: @target.public_id, prompt: "R1", lifetime: "conversation")
    original = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value.active_variant.run
    schedule_loop!(original)
    run_loop_round!(original, sse_success("R1 exact answer"))
    Conversations::Turns::Converge.call(conversation_id: @target.id)
    second = call_tool(source, "request", to: @target.public_id, prompt: "R2", lifetime: "conversation")
    current = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value.active_variant.run
    schedule_loop!(current)
    first_completion, second_completion = [first, second].map { Runs::Delegations.for_call(_1) }
    Runs::Delegations.converge(node: first_completion)
    result = Runs::TaskResultProjection.call(first_completion.reload)
    assert_equal original.public_id, result.dig("structured_content", "run_public_id")
    assert_equal "completed", first_completion.status
    assert_equal "running", second_completion.reload.status
    assert_equal current.id, @target.turns.active.sole.active_variant.run.id
    refute current.reload.stopped?
  end

  test "send request and linked spawn atomically publish along the lock ladder" do
    %w[send request spawn].each do |name|
      source = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @sender)
      _turn, run = materialize_loop_reply!(source, agent: @sender)
      schedule_loop!(run)
      input = name == "spawn" ? { prompt: "Atomic spawn", agent: @recipient.public_id, establish_link: true } :
        { to: @target.public_id, name == "send" ? :message : :prompt => "Atomic dispatch" }
      apply_via(loop_attempt(run), sse_success("working", tool_calls: [
        { id: "locked_call", name: name, arguments: input.to_json },
      ]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      Runs::ScheduleReady.call(run_id: run.id)
      call = run.tasks.find_by!(tool_name: name)
      assert_ladder_order("#{name} publication") do
        Nexus::ToolRegistry.executor_for(name).call(node: call)
      end
      assert_equal "completed", call.reload.status
      assert call.output_body
    end
  end

  test "ordinary message processing uses receiver memory while preserving sender attribution" do
    [@sender, @recipient].each do |agent|
      MemoryCollection.default_for(agent)
      anchor = memory_anchor(path: "agent/private.md", user: agent, agent: agent)
      written = MemoryDocuments::Write.call(anchor: anchor, content: "private-#{agent.public_id}", expected: nil)
      assert written.written?
    end
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call_tool(source, "send", to: @target.public_id, message: "A public question")
    applied = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id)
    assert applied.accepted?, applied.outcome.inspect
    turn = applied.value
    worker = turn.active_variant.run
    seed = worker.tasks.find_by!(node_key: "r1").content_bodies.find_by!(role: "input")
      .content_body_entries.map { _1.content_fragment.payload.to_json }.join
    assert_includes seed, "private-#{@recipient.public_id}"
    refute_includes seed, "private-#{@sender.public_id}"
    assert_equal @recipient, turn.speaker.user
    assert_equal source.public_id, turn.sender_run_public_id
    assert_equal @source.public_id, turn.sender_conversation_public_id
  end

  test "strict communication steer binds the named run and explicit fallback keeps the original input" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    _target_turn, target = materialize_loop_reply!(@target, agent: @recipient)
    schedule_loop!(source)
    schedule_loop!(target)
    call_tool(source, "send", to: @target.public_id, message: "Correct this execution",
      delivery_mode: "steer", expected_steering_run_public_id: target.public_id, on_target_end: "queue")
    input = @target.inputs.sole
    assert_equal "steering", input.state
    assert_equal target.public_id, input.expected_steering_run_public_id
    target.with_lock { Runs::Transition.run(target, status: "completed", completed_at: Time.current) }
    assert Input.exists?(input.id)
    input.reload
    assert_equal "pending", input.state
    assert_equal "queue", input.delivery_mode
    assert_equal "steer", input.requested_delivery_mode
    assert_equal "steer_target_settled", input.fallback_reason
    assert_equal target.public_id, input.expected_steering_run_public_id
  end

  test "an already ended strict target uses queue only when explicitly requested" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    original = SecureRandom.uuid_v7
    call_tool(source, "send", to: @target.public_id, message: "Fallback question",
      delivery_mode: "steer_now", expected_steering_run_public_id: original, on_target_end: "queue")
    input = @target.inputs.sole
    assert_equal "pending", input.state
    assert_equal "queue", input.delivery_mode
    assert_equal "steer_now", input.requested_delivery_mode
    assert_equal "steering_target_changed", input.fallback_reason
    assert_equal original, input.expected_steering_run_public_id
  end

  test "linked spawn publishes its first request and an independent conversation lifetime completion" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "spawn", prompt: "Initial job", agent: @recipient.public_id, establish_link: true)
    child = call.spawned_conversation
    receipt = Runs::TaskResultProjection.call(call).fetch("structured_content")
    completion = Runs::Delegations.for_call(call)
    assert_equal "conversation", completion.lifetime
    assert_equal child.inputs.sole.public_id, completion.delegated_input_public_id
    assert_equal completion.delegated_input_public_id, receipt.fetch("input_public_id")
    link = ConversationLink.find_by!(public_id: receipt.fetch("link_public_id"))
    assert_equal [child, @recipient], link.peer(conversation: @source, agent: @sender)
    assert_equal "request", child.inputs.sole.communication_kind
    refute child.inputs.sole.conversation_link_id
    [@source, child].each do |endpoint|
      event = endpoint.event_items.where(item_type: "conversation_link_changed").sole.payload
      assert_equal [link.public_id, "active", @sender.public_id, "agent"],
        event.values_at("link_public_id", "state", "by", "kind")
    end
  end

  test "link discovery is scoped to the exact calling endpoint and exposes no peer history" do
    link = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human).value
    Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
      conversation: @target, acting_user: @human, default: "none", entries: []))
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "links")
    result = Runs::TaskResultProjection.call(call).fetch("structured_content")
    assert_equal [link.public_id], result.fetch("links").map { |row| row.fetch("public_id") }
    peer = result.fetch("links").sole.fetch("peer")
    assert_equal %w[agent_public_id conversation_public_id], peer.keys.sort
    assert_equal @target.public_id, peer.fetch("conversation_public_id")
    refute @target.reload.visible_to?(@sender)
  end

  test "canceling the exact completion releases its wait and never rewrites a final outcome" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", to: @target.public_id, prompt: "Cancel this request", wait: true)
    completion = Runs::Delegations.for_call(call)
    accepted_id = completion.delegated_input_public_id
    canceled = Runs::CancelBranch.call(Runs::CancelBranch::Command.new(
      run: source, task_key: completion.node_key, acting_user: @sender))
    assert canceled.accepted?, canceled.outcome.inspect
    assert_equal "canceled", completion.reload.status
    assert call.spawn_await.reload.terminal?
    receipt = Runs::TaskResultProjection.call(completion).fetch("structured_content")
    assert_equal "canceled", receipt.fetch("status")
    assert_equal accepted_id, receipt.fetch("input_public_id")
    assert_nil receipt.fetch("run_public_id")
    shared = Nexus::Contract.pack.fetch("communication.json").fetch("cases")
      .find { |example| example.fetch("name") == "request_canceled_before_materialization" }.dig("body", "task")
    assert_equal shared.fetch("status"), completion.status
    assert_equal shared.fetch("structured_content").keys.sort, receipt.keys.sort
    %w[status turn_public_id variant_public_id run_public_id].each do |field|
      assert_equal [shared.dig("structured_content", field)], [receipt.fetch(field)]
    end
    Runs::Delegations.converge(node: completion)
    refute Input.exists?(public_id: accepted_id)
    again = Runs::CancelBranch.call(Runs::CancelBranch::Command.new(
      run: source, task_key: completion.node_key, acting_user: @sender))
    assert_equal :already_terminal, again.outcome
    assert_equal receipt, Runs::TaskResultProjection.call(completion.reload).fetch("structured_content")
    refute source.reload.stopped?
  end

  test "communication steers require an exact target and queue rejects the guard" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call_tool(source, "send", to: @target.public_id, message: "No target", delivery_mode: "steer",
      expected_error: "steering_target_required")
    call_tool(source, "send", to: @target.public_id, message: "Wrong target", delivery_mode: "steer_now",
      expected_steering_run_public_id: source.public_id, expected_error: "steering_target_changed")
    call_tool(source, "send", to: @target.public_id, message: "Invalid queue", delivery_mode: "queue",
      expected_steering_run_public_id: source.public_id, expected_error: "steering_guard_requires_steer")
    assert_empty @target.inputs
  end

  test "an archived endpoint accepts its accurate in-flight steer but refuses new fallback work" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    _target_turn, target = materialize_loop_reply!(@target, agent: @recipient)
    schedule_loop!(source)
    schedule_loop!(target)
    assert Conversations::Archive.call(conversation: @target).accepted?
    call_tool(source, "send", to: @target.public_id, message: "Accurate correction", delivery_mode: "steer",
      expected_steering_run_public_id: target.public_id)
    call_tool(source, "send", to: @target.public_id, message: "New work", delivery_mode: "steer",
      expected_steering_run_public_id: SecureRandom.uuid_v7, on_target_end: "queue",
      expected_error: "conversation_archived")
    assert_equal ["Accurate correction"], @target.inputs.map(&:text)
  end

  test "linked spawn refusal rolls back both child and relation while unlinked spawn remains available" do
    @workspace.update!(messaging_policy: { agents: [
      { agent_public_id: @sender.public_id, mode: "private", allowed_sender_public_ids: [] },
    ] })
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    rejected = nil
    assert_no_difference ["Conversation.count", "ConversationLink.count"] do
      rejected = call_tool(source, "spawn", prompt: "No reverse permission", agent: @recipient.public_id,
        establish_link: true, expected_error: "messaging_not_allowed")
    end
    assert_nil rejected.reload.spawned_conversation
    assert_nil Runs::Delegations.for_call(rejected).delegated_input_public_id
    accepted = call_tool(source, "spawn", prompt: "One request only", agent: @recipient.public_id)
    assert accepted.spawned_conversation
    assert_nil Runs::TaskResultProjection.call(accepted).dig("structured_content", "link_public_id")
  end

  test "bounded recovery discards closed-link messages even when delayed blocked or steering" do
    link = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human).value
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    _target_turn, target = materialize_loop_reply!(@target, agent: @recipient)
    schedule_loop!(source)
    schedule_loop!(target)
    call_tool(source, "send", link_public_id: link.public_id, message: "Delayed", deliver_in: "1d")
    call_tool(source, "send", link_public_id: link.public_id, message: "Blocked")
    @target.inputs.order(:id).last.update!(state: "blocked", blocked_reason: "author_not_authorized")
    call_tool(source, "send", link_public_id: link.public_id, message: "Held correction", delivery_mode: "steer",
      expected_steering_run_public_id: target.public_id, on_target_end: "queue")
    ids = @target.inputs.pluck(:public_id)
    assert_equal 3, ids.length
    link.close
    clear_enqueued_jobs
    pass = Runs::Spawn::Relay.call(budget: 1)
    20.times do
      assert_operator pass[:scanned], :<=, 4
      break unless pass.more?
      pass = Runs::Spawn::Relay.call(budget: 1, **pass.cursor.symbolize_keys)
    end
    refute pass.more?
    assert_empty Input.where(public_id: ids)
    refute @target.turns.where(input_public_id: ids).exists?
  end

  test "a single formal result starts a requester-owned supplementary reply and Stop cuts that reply" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", to: @target.public_id, prompt: "Background result", lifetime: "conversation")
    run_loop_round!(source, sse_success("Started"))
    Conversations::Turns::Converge.call(conversation_id: @source.id)
    worker = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value.active_variant.run
    schedule_loop!(worker)
    run_loop_round!(worker, sse_success("Exact report"))
    completion = Runs::Delegations.for_call(call)
    Runs::Delegations.converge(node: completion)
    assert_equal [:delivered], Runs::ResultDelivery.call(source.reload)
    mail = @source.inputs.sole
    assert_equal source.public_id, mail.sender_run_public_id
    supplementary = Conversations::Inputs::ApplyNext.call(conversation_id: @source.id).value.active_variant.run
    assert_equal source.public_id, supplementary.turn.sender_run_public_id
    assert Runs::Stop.stop_now(source).accepted?
    schedule_loop!(supplementary)
    assert supplementary.reload.stopped?
    assert_empty Runs::ResultDelivery.call(source.reload)
    assert_equal "completed", completion.reload.status
    assert_equal "completed", Runs::TaskResultProjection.call(completion).dig("structured_content", "status")
  end

  test "a worker strict steer_now question preserves the requester await and exact result" do
    link = Conversations::Links::Create.call(conversation: @source, agent: @sender,
      peer_conversation: @target, peer_agent: @recipient, acting_user: @human).value
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    request = call_tool(source, "request", to: @target.public_id, prompt: "Waited work", wait: true)
    completion = Runs::Delegations.for_call(request)
    waiting = request.spawn_await
    worker = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value.active_variant.run
    schedule_loop!(worker)
    call_tool(worker, "send", link_public_id: link.public_id, message: "Which criterion?",
      delivery_mode: "steer_now", expected_steering_run_public_id: source.public_id)
    schedule_loop!(source)
    assert_equal "running", source.tasks.find_by!(node_key: "steer1").status
    assert_equal "dispatched", waiting.reload.status
    assert_equal "running", completion.reload.status
    assert_empty @source.inputs.reload
    run_loop_round!(source, sse_success("Use the focused test"))
    assert_equal "dispatched", waiting.reload.status
    refute source.reload.delivered?
    run_loop_round!(worker, sse_success("Verified exact report"))
    Runs::Delegations.converge(node: completion)
    assert waiting.reload.terminal?
    schedule_loop!(source)
    run_loop_round!(source, sse_success("Report received"))
    assert source.reload.delivered?
    assert_empty Runs::ResultDelivery.call(source)
    assert_empty @source.inputs.reload
  end

  test "a durable completion still mails the exact result after its original Turn is deleted" do
    _turn, source = materialize_loop_reply!(@source, agent: @sender)
    schedule_loop!(source)
    call = call_tool(source, "request", to: @target.public_id, prompt: "Retained result", lifetime: "conversation")
    run_loop_round!(source, sse_success("Started"))
    Conversations::Turns::Converge.call(conversation_id: @source.id)
    turn = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id).value
    worker = turn.active_variant.run
    original = [turn.public_id, turn.active_variant.public_id, worker.public_id]
    schedule_loop!(worker)
    run_loop_round!(worker, sse_success("Durable exact result"))
    Conversations::Turns::Converge.call(conversation_id: @target.id)
    completion = Runs::Delegations.for_call(call)
    command = Conversations::Turns::HardDelete::Command.new(
      conversation: @target, turn_public_id: turn.public_id, acting_user: @human)
    assert_equal :delegation_pending, Conversations::Turns::HardDelete.call(command).outcome
    Runs::Delegations.converge(node: completion)
    assert Conversations::Turns::HardDelete.call(command).accepted?
    refute Turn.exists?(turn.id)
    assert_equal [:delivered], Runs::ResultDelivery.call(source.reload)
    input = @source.inputs.sole
    assert_includes input.text, "Durable exact result"
    assert_equal original, input.callback_result.values_at("turn_public_id", "variant_public_id", "run_public_id")
    assert_equal @target.public_id, input.sender_conversation_public_id
    assert_empty Runs::ResultDelivery.call(source.reload)
  end

  private

    def loop_attempt(run)
      running = ModelInvocationAttempt.active.joins(:model_invocation).find_by(model_invocations: { run_id: run.id })
      running || super
    end

    def call_tool(run, name, expected_error: nil, **input)
      apply_via(loop_attempt(run), sse_success("working", tool_calls: [
        { id: "communication_call", name: name, arguments: input.to_json },
      ]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
        Runs::ScheduleReady.call(run_id: run.id)
      end
      call = run.tasks.where(tool_name: name).order(:id).last
      assert_equal "completed", call.status, [call.error_key, call.error_detail, call.output_body&.effective_text].inspect
      if expected_error
        assert call.output_summary["is_error"]
        assert_includes call.output_body.effective_text, expected_error
      else
        refute call.output_summary["is_error"], call.output_body&.effective_text
      end
      call
    end
end
