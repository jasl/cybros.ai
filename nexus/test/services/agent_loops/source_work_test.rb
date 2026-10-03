require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class AgentLoops::SourceWorkTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopSeamTestHelper
  include LoopLaneTestHelper
  include LockOrderTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
    @conversation = conversation
  end

  test "stopping a completed owner preserves its answer and permanently withdraws queued mail" do
    source = completed_source(@conversation)
    queued = receipt(source)
    assert_predicate queued, :accepted?
    assert_equal source.public_id, queued.value.sender_agent_loop_public_id
    assert_equal "background", queued.value.sender_task_key

    assert_predicate AgentLoops::Stop.stop_now(source), :accepted?
    first_cut = source.reload.stopped_at
    assert first_cut
    assert_equal "completed", source.status
    assert_equal :already_terminal, AgentLoops::Stop.stop_now(source).outcome
    assert_equal first_cut, source.reload.stopped_at
    assert_equal :source_stopped, receipt(source).outcome

    assert_ladder_order("stopped receipt drain") do
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    end
    assert_empty @conversation.conversation_inputs
    assert_equal 1, @conversation.conversation_turns.count
  end

  test "conversation stop cuts old delivered work while a later independent request remains runnable" do
    older = completed_source(@conversation)
    current = create_loop_backed_turn(conversation: @conversation, acting_user: @human)

    assert_ladder_order("conversation ownership cut") do
      result = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
        conversation: @conversation, acting_user: @human))
      assert_predicate result, :accepted?
    end
    assert_predicate older.reload, :stopped?
    assert_predicate current.agent_loop.reload, :stopped?
    assert_equal "completed", older.status
    assert_equal "canceling", current.agent_loop.status

    AgentLoops::ScheduleReady.call(agent_loop_id: current.agent_loop.id)
    Conversations::Turns::Converge.call
    post_input!(@conversation, acting_user: @human, text: "new independent request",
      kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
    result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    assert_predicate result, :accepted?
    assert_not AgentLoops::SourceWork.stopped_variant_source?(result.value.active_variant)
  end

  test "lost wakes recover a started supplementary reply without stopping independent child work" do
    source = completed_source(@conversation)
    child = conversation
    assert_predicate receipt(source, target: child), :accepted?
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert_predicate result, :accepted?
    derived = result.value.active_variant.agent_loop
    assert derived, result.value.attributes.inspect
    other = create_loop_backed_turn(conversation: conversation, acting_user: @human, loop_status: "paused")
    AgentLoops::Stop.stop_now(source)
    clear_enqueued_jobs

    assert_ladder_order("owned live loop recovery") { AgentLoops::ScheduleSweep.call }
    assert_predicate derived.reload, :stopped?
    assert_equal "canceled", derived.status
    assert_equal "paused", other.agent_loop.reload.status
  end

  test "immediate source hints cross a completed owner and spare an independent request in the same child" do
    source = completed_source(@conversation)
    child = conversation
    intermediate = materialized_receipt(source, child)
    intermediate.update!(status: "completed", delivered_at: Time.current, completed_at: Time.current)
    intermediate.conversation_turn_variant.update!(status: "completed")
    turn = intermediate.conversation_turn
    replacement = turn.conversation_turn_variants.create!(account: @account,
      position: 1, source: "manual", status: "completed")
    turn.reload.update!(status: "completed", active_variant: replacement)
    intermediate.conversation_turn_variant.update!(deleted_at: Time.current)
    child.reload.update!(active_turn: nil)
    independent = create_loop_backed_turn(conversation: child, acting_user: @human).agent_loop
    queued = receipt(intermediate, target: child).value
    descendant = materialized_receipt(intermediate, conversation)
    descendant.update!(status: "paused", paused_at: Time.current)
    held = descendant.agent_loop_nodes.create!(node_key: "wait", type: "AgentLoopNodes::AwaitTask", authored_by: "author")
    held.update_columns(status: "awaiting_input", started_at: Time.current, await_started_at: Time.current)
    clear_enqueued_jobs

    assert_ladder_order("precise source recovery crosses completed hidden owners") do
      perform_enqueued_jobs(only: AgentLoops::Spawn::RelayJob) { AgentLoops::Stop.stop_now(source) }
    end

    assert_equal "completed", intermediate.reload.status
    assert_equal "canceled", descendant.reload.status
    assert_equal "canceled", held.reload.status
    assert_not ConversationInput.exists?(id: queued.id)
    assert_equal "running", independent.reload.status
    assert_not independent.stopped?
  end

  test "replacement source hints ignore forked requests and human samples" do
    source = completed_source(@conversation)
    owned = materialized_receipt(source, conversation)
    forked = materialized_receipt(source, conversation)
    # Forge immutable fixture stamps to isolate reverse ownership selection.
    ConversationTurn.where(id: forked.conversation_turn.id)
      .update_all(forked_from_turn_public_id: owned.conversation_turn.public_id)
    human = replacement_sample(materialized_receipt(source, conversation))
    clear_enqueued_jobs

    perform_enqueued_jobs(only: AgentLoops::Spawn::RelayJob) { AgentLoops::Stop.mark_now(source) }

    assert_equal "canceled", owned.reload.status
    assert_equal "running", forked.reload.status
    assert_equal "running", human.reload.status
  end

  test "a source hint cancels the original request's direct-invocation fallback" do
    declare_tools!(@agent, tools: [], fallback_model: "dev/mock-unmetered")
    source = completed_source(@conversation)
    child = conversation
    sent = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: child, acting_user: @human, entries: [{ "text" => "child request" }],
      sender_conversation_public_id: source.conversation.public_id,
      agent_loop_public_id: source.public_id, task_key: "background", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text"))
    assert_predicate sent, :accepted?
    turn = Conversations::Inputs::ApplyNext.call(conversation_id: child.id).value
    invocation = turn.active_variant.model_invocation
    ModelInvocations::AdmitQueuedWork.call
    apply_via(invocation.attempts.order(:id).last, sse_refused("I cannot answer this request."))
    Conversations::Turns::Converge.call(conversation_id: child.id)
    fallback = turn.reload.conversation_turn_variants.find_by!(source: "fallback")
    assert_equal "queued", fallback.model_invocation.status
    AgentLoops::Stop.stop_now(source)
    clear_enqueued_jobs

    assert_ladder_order("source hint cancels the kernel fallback") do
      AgentLoops::SourceWork::Recovery.call(source_loop_public_id: source.public_id)
    end

    assert_equal "canceled", fallback.model_invocation.reload.status
    assert_equal "source_stopped", fallback.model_invocation.failure_reason_key
    assert_equal "canceled", fallback.reload.status
  end

  test "source hint pages charge retained requests independently of inputs and unrelated owners" do
    source = completed_source(@conversation)
    3.times do
      retained = completed_source(conversation)
      ConversationTurn.where(id: retained.conversation_turn.id).update_all(sender_agent_loop_public_id: source.public_id,
        forked_from_turn_public_id: source.conversation_turn.public_id)
    end
    derived = materialized_receipt(source, conversation)
    queued = 2.times.map { receipt(source, target: conversation).value }
    unrelated_source = completed_source(conversation)
    unrelated = materialized_receipt(unrelated_source, conversation)
    AgentLoops::Stop.stop_now(source)
    clear_enqueued_jobs
    cursor = { source_loop_public_id: source.public_id }
    scans = []

    loop do
      pass = AgentLoops::SourceWork::Recovery.call(**cursor.symbolize_keys, budget: 1)
      scans << pass[:scanned]
      break unless pass.more?

      cursor = pass.cursor
      assert_operator scans.length, :<, 10
    end

    assert_equal [2, 2, 1, 1, 0], scans
    assert_equal "canceled", derived.reload.status
    assert_equal "running", unrelated.reload.status
    assert_not ConversationInput.exists?(id: queued.map(&:id))
  end

  test "a graceful source hint cancels descendants while its own dispatched work drains" do
    source = create_loop_backed_turn(conversation: @conversation, acting_user: @human).agent_loop
    own = source.agent_loop_nodes.create!(node_key: "background", type: "AgentLoopNodes::ToolTask",
      tool_name: "read_file", tool_input: {}, authored_by: "author", detached: true, lifetime: "conversation")
    own.update_columns(status: "dispatched", started_at: Time.current, await_started_at: Time.current)
    derived = materialized_receipt(source, conversation)
    clear_enqueued_jobs

    perform_enqueued_jobs(only: [AgentLoops::Spawn::RelayJob, AgentLoops::ScheduleJob]) do
      assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
        agent_loop: source, acting_user: @human, force: false)), :accepted?
    end

    assert_equal "canceling", source.reload.status
    assert_nil source.stopped_at
    assert_equal "dispatched", own.reload.status
    assert_equal "canceled", derived.reload.status
  end

  test "one failed source request does not block other requests or the hint continuation" do
    source = completed_source(@conversation)
    queued = 2.times.map { receipt(source, target: conversation).value }
    derived = materialized_receipt(source, conversation)
    AgentLoops::Stop.stop_now(source)
    clear_enqueued_jobs
    errors = []
    recover_input = AgentLoops::SourceWork::Recovery.method(:input)
    interrupted = ->(id) do
      raise IOError, "input interrupted" if id == queued.first.id
      recover_input.call(id)
    end

    Rails.error.stub(:report, ->(error, **) { errors << error }) do
      AgentLoops::SourceWork::Recovery.stub(:input, interrupted) do
        pass = AgentLoops::SourceWork::Recovery.call(source_loop_public_id: source.public_id, budget: 2)
        assert_predicate pass, :more?
        assert_equal queued.last.id, pass.cursor.fetch("input_after_id")
        assert_equal 3, pass[:scanned]
      end
    end

    assert_equal ["input interrupted"], errors.map(&:message)
    assert_equal "canceled", derived.reload.status
    assert_not ConversationInput.exists?(id: queued.last.id)
    assert ConversationInput.exists?(id: queued.first.id)
    AgentLoops::Spawn::Relay.call
    assert_not ConversationInput.exists?(id: queued.first.id)
  end

  test "completed intermediate owners cannot publish or materialize a grandchild receipt after the source cut" do
    source = completed_source(@conversation)
    child = conversation
    receipt(source, target: child)
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert_predicate result, :accepted?
    intermediate = result.value.active_variant.agent_loop
    assert intermediate, result.value.attributes.inspect
    # A completed execution remains the source of its undelivered background
    # result. These are lifecycle facts, not a fresh authority grant.
    intermediate.update!(status: "completed", delivered_at: Time.current, completed_at: Time.current)
    result.value.active_variant.update!(status: "completed")
    result.value.update!(status: "completed")
    child.update!(active_turn: nil)
    queued = receipt(intermediate, target: child)
    assert_predicate queued, :accepted?

    AgentLoops::Stop.stop_now(source)
    assert AgentLoops::SourceWork.stopped_source?(intermediate)
    assert_equal :source_stopped, receipt(intermediate, target: child).outcome
    clear_enqueued_jobs
    AgentLoops::Spawn::Relay.call
    assert_not ConversationInput.exists?(id: queued.value.id)
    assert_equal 1, child.conversation_turns.count
  end

  test "recovery withdraws an old child request even behind independent active work" do
    source = completed_source(@conversation)
    child = conversation
    independent = create_loop_backed_turn(conversation: child, acting_user: @human)
    queued = receipt(source, target: child)
    AgentLoops::Stop.stop_now(source)

    assert_ladder_order("busy recipient cleanup") { AgentLoops::Spawn::Relay.call }
    assert_not ConversationInput.exists?(id: queued.value.id)
    assert_equal "running", independent.agent_loop.reload.status
    assert_not independent.agent_loop.stopped?
  end

  test "selecting away and back never revives the old owner's pending mail" do
    source = completed_source(@conversation)
    turn = source.conversation_turn
    alternative = turn.conversation_turn_variants.create!(account: @account,
      position: 1, source: "manual", status: "completed")
    receipt(source)

    assert_ladder_order("select away from completed owner") { assert_predicate activate(turn, alternative), :accepted? }
    assert_predicate source.reload, :stopped?
    assert_predicate activate(turn, source.conversation_turn_variant), :accepted?
    assert_predicate source.reload, :stopped?
    assert_equal :source_stopped, receipt(source).outcome
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal source.conversation_turn_variant_id, turn.reload.active_variant_id
  end

  test "a completed but unpublished supplementary result cannot settle after its source is stopped" do
    source = completed_source(@conversation)
    child = conversation
    receipt(source, target: child)
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    assert_predicate result, :accepted?
    derived = result.value.active_variant.agent_loop
    assert derived, result.value.attributes.inspect
    derived.update!(status: "completed", delivered_at: Time.current, completed_at: Time.current)
    AgentLoops::Stop.stop_now(source)

    Conversations::Turns::Converge.call(agent_loop_id: derived.id, conversation_id: child.id)
    assert_equal "canceled", result.value.reload.status
    assert_equal "canceled", result.value.active_variant.status
    assert_nil child.reload.active_turn_id
  end

  test "quiescence refuses late delivery before the stopped-source recovery wake runs" do
    source = completed_source(@conversation)
    child = conversation
    receipt(source, target: child)
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    derived = result.value.active_variant.agent_loop
    round = derived.agent_loop_nodes.find_by!(node_key: "r1")
    # The provider finished before the source cut; isolate the late quiescence
    # entry from its ordinary scheduler/converger prefix.
    round.update_columns(status: "completed", completed_at: Time.current)
    derived.update!(deliverable_node: round)
    AgentLoops::Stop.stop_now(source)
    clear_enqueued_jobs

    assert_ladder_order("late settle only wakes the upper stop owner") do
      derived.with_lock { AgentLoops::EvaluateQuiescence.call(derived) }
    end
    assert_nil derived.reload.delivered_at
    assert_equal "running", derived.status
    assert_enqueued_with(job: AgentLoops::ScheduleJob, args: [derived.id])
    AgentLoops::ScheduleReady.call(agent_loop_id: derived.id)
    assert_equal "canceled", derived.reload.status
  end

  test "each recovery frontier charges healthy inputs and variants and advances beyond them" do
    3.times do
      create_loop_backed_turn(conversation: conversation, acting_user: @human,
        turn_status: "failed", variant_status: "failed", loop_status: "completed")
    end
    live = completed_source(@conversation)
    child = conversation
    first = receipt(live, target: child).value
    stopped = completed_source(conversation)
    second = receipt(stopped, target: child).value
    AgentLoops::Stop.stop_now(stopped)
    cursor = {}
    passes = []
    loop do
      pass = AgentLoops::Spawn::Relay.call(budget: 1, **cursor.symbolize_keys)
      passes << pass
      break unless pass.more?

      cursor = pass.cursor
      assert_operator passes.length, :<, 20
    end
    assert ConversationInput.exists?(id: first.id)
    assert_not ConversationInput.exists?(id: second.id)
    assert_equal 5, passes.sum { |pass| pass[:scanned] }
  end

  test "a hosted graceful stop drains its own running task but an ancestor cut forces derived work" do
    source = completed_source(@conversation)
    child = conversation
    receipt(source, target: child)
    result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
    derived = result.value.active_variant.agent_loop
    held = derived.agent_loop_nodes.create!(node_key: "wait", type: "AgentLoopNodes::AwaitTask", authored_by: "author")
    held.update_columns(status: "awaiting_input", started_at: Time.current, await_started_at: Time.current)
    result = AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
      agent_loop: derived, acting_user: @human, force: false))
    assert_predicate result, :accepted?

    AgentLoops::ScheduleReady.call(agent_loop_id: derived.id)
    assert_equal "canceling", derived.reload.status
    assert_equal "awaiting_input", held.reload.status
    assert_not AgentLoops::SourceWork.execution_stopped?(derived)

    AgentLoops::Stop.stop_now(source)
    assert AgentLoops::SourceWork.execution_stopped?(derived)
    AgentLoops::ScheduleReady.call(agent_loop_id: derived.id)
    assert_equal "canceled", held.reload.status
    assert_equal "canceled", derived.reload.status
  end

  test "conversation force stop upgrades an older background loop already draining gracefully" do
    source, held = graceful_background
    completed_source(@conversation)

    result = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human))
    assert_predicate result, :accepted?
    assert_predicate source.reload, :stopped?
    AgentLoops::ScheduleSweep.call
    assert_equal "canceled", source.reload.status
    assert_equal "canceled", held.reload.status
  end

  test "activating another answer upgrades the old background owner's graceful stop" do
    source, held = graceful_background
    turn = source.conversation_turn
    alternative = turn.conversation_turn_variants.create!(account: @account,
      position: 1, source: "manual", status: "completed")

    assert_predicate activate(turn, alternative), :accepted?
    assert_predicate source.reload, :stopped?
    AgentLoops::ScheduleReady.call(agent_loop_id: source.id)
    assert_equal "canceled", held.reload.status
    assert_equal alternative.id, turn.reload.active_variant_id
  end

  test "regeneration upgrades a gracefully draining old owner while keeping the new sample independent" do
    source, held = graceful_background
    result = nil
    assert_ladder_order("regeneration force upgrade before new graph allocation") do
      result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation, turn_public_id: source.conversation_turn.public_id,
        acting_user: @human, provider_id: "dev", model_ref: "mock-text",
        reasoning_effort: nil, request_options: nil))
    end
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_predicate source.reload, :stopped?
    AgentLoops::ScheduleReady.call(agent_loop_id: source.id)
    assert_equal "canceled", held.reload.status
    assert_not result.value.agent_loop.stopped?
    assert_not AgentLoops::SourceWork.stopped_source?(result.value.agent_loop)
  end

  private

    def conversation
      Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    end

    def graceful_background
      seam = create_loop_backed_turn(conversation: @conversation, acting_user: @human,
        turn_status: "completed", variant_status: "completed", loop_status: "running")
      source = seam.agent_loop
      source.update!(delivered_at: Time.current)
      @conversation.update!(active_turn: nil)
      grow!(source, model("r1", "prompt" => "original request"))
      ContentBodies::Replace.call(owner: seam.variant, role: "prompt",
        entries: [{ "text" => "original request" }], seal: true)
      held = source.agent_loop_nodes.create!(node_key: "background", type: "AgentLoopNodes::AwaitTask",
        authored_by: "author", detached: true, lifetime: "conversation")
      held.update!(status: "awaiting_input", started_at: Time.current, await_started_at: Time.current)
      assert_predicate AgentLoops::Stop.call(AgentLoops::Stop::Command.new(
        agent_loop: source, acting_user: @human, force: false)), :accepted?
      assert_nil source.reload.stopped_at
      [source, held]
    end

    def completed_source(host)
      seam = create_loop_backed_turn(conversation: host, acting_user: @human,
        turn_status: "completed", variant_status: "completed", loop_status: "completed")
      seam.agent_loop.update!(delivered_at: Time.current, completed_at: Time.current)
      host.update!(active_turn: nil)
      seam.agent_loop
    end

    def receipt(source, target: @conversation)
      Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
        host: target, acting_user: @human, entries: [{ "text" => "background result" }],
        origin: "task_result", sender_conversation_public_id: source.conversation.public_id,
        agent_loop_public_id: source.public_id, task_key: "background", kind: "direct_reply",
        provider_id: "dev", model_ref: "mock-text"))
    end

    def materialized_receipt(source, target)
      assert_predicate receipt(source, target: target), :accepted?
      applied = Conversations::Inputs::ApplyNext.call(conversation_id: target.id)
      assert_predicate applied, :accepted?
      applied.value.active_variant.agent_loop
    end

    def replacement_sample(original)
      original.update!(status: "completed", completed_at: Time.current)
      original.conversation_turn_variant.update!(status: "completed")
      turn = original.conversation_turn
      variant = turn.conversation_turn_variants.create!(account: @account,
        position: 1, source: "agent_loop", status: "running", origin_variant: original.conversation_turn_variant)
      turn.reload.update!(active_variant: variant)
      AgentLoop.create!(workspace: @workspace, creating_user: @human,
        conversation_turn_variant: variant, status: "running", approval_mode: "bypass")
    end

    def activate(turn, variant)
      Conversations::Variants::Activate.call(Conversations::Variants::Activate::Command.new(
        conversation: @conversation, turn_public_id: turn.public_id,
        variant_public_id: variant.public_id, acting_user: @human))
    end
end
