require "test_helper"
require_relative "../../test_helpers/inputs_apply_next_test_helper"

class Conversations::InputsApplyHoldTest < ActiveSupport::TestCase
  include InputsApplyNextTestHelper

  test "a row queued before the hold waits behind it, narrated once" do
    seam, queued = hold_settled_seam!(before: "typed while it ran")
    assert_equal "pending", queued.reload.state

    3.times do
      assert_equal :loop_held,
        Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    end
    assert ConversationInput.exists?(queued.id), "no state write: the head stays as it is"
    assert_equal "pending", queued.reload.state
    blocked = blocked_items.sole.payload
    assert_equal queued.public_id, blocked.fetch("input_public_id")
    assert_equal "loop_held", blocked.fetch("blocked_reason")
    assert_equal "needs_attention", seam.agent_loop.reload.status
    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    end
  end

  test "kernel mail waits behind the hold even when it arrives after the settle" do
    hold_settled_seam!
    mail = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 99,
      kind: "message", role: "user",
      speaker_actor: Actors::Resolve.member(account: @account, user: @user),
      authoring_user: @user, sender_conversation_public_id: SecureRandom.uuid
    )
    mail.save!

    assert_equal :loop_held,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert ConversationInput.exists?(mail.id)
  end

  test "a receipt through the real writer waits behind the hold, and wakes a loop-backed turn once it lifts" do
    answered_by!(@agent)
    seam, = hold_settled_seam!
    declare!(@agent)
    mail = kernel_mail!(acting_user: @agent, kind: "direct_reply", provider_id: "dev", model_ref: "mock-text")
    assert_equal %w[queue pending], [mail.delivery_mode, mail.state], "a receipt queues, never steers"

    assert_equal :loop_held, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal "loop_held", blocked_items.sole.payload.fetch("blocked_reason")

    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "completed", completed_at: Time.current,
      attention_reason: nil)
    Conversations::Turns::Converge.call
    assert_equal 1, drain!
    turn = @conversation.conversation_turns.order(:position).last
    assert_equal %w[direct_reply assistant running], [turn.kind, turn.role, turn.status]
    assert_equal "agent_loop", turn.active_variant.source, "the receipt WOKE the conversation"
    assert_equal "task_result", turn.origin
    assert_equal @conversation.public_id, turn.sender_conversation_public_id
    assert_equal turn.id, @conversation.reload.active_turn_id
    assert_equal ENVELOPE, input_entries(turn.active_variant.agent_loop.agent_loop_nodes.sole).last.dig("parts", 0, "text"),
      "the receipt is the woken round's trailing user message"
    assert_equal "task_result", AgentAPI::ConversationPresenter.turn_snapshot(turn).fetch(:origin)
  end

  test "the read order: a receipt posted after the person's word drains first" do
    person = accept!(text: "first, by arrival")
    mail = kernel_mail!
    assert_operator person.queue_position, :<, mail.queue_position

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal mail.public_id, materialized_items.sole.payload.fetch("input_public_id"),
      "kernel origin first"
    assert_equal "pending", person.reload.state
    assert_equal 1, drain!
    assert_equal [mail.public_id, person.public_id], materialized_items.map { |item| item.payload.fetch("input_public_id") }
  end

  # The hold's gate is per row in read order: a held receipt is always the head, so the one row that
  # can repair the hold — the person's post-settle word — must be let through ahead of it.
  test "a held receipt lets the person's post-settle word through, and drains at the repaired turn's end" do
    hold_settled_seam!
    mail = kernel_mail!
    assert_equal :loop_held, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal mail.public_id, blocked_items.sole.payload.fetch("input_public_id")

    repair = accept!(text: "never mind, do this instead")
    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal repair.public_id, materialized_items.sole.payload.fetch("input_public_id"),
      "the repair went ahead of the held receipt"
    assert_equal "pending", mail.reload.state
    assert_equal 1, blocked_items.count, "not narrated held twice"

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal mail.public_id, materialized_items.last.payload.fetch("input_public_id"),
      "the receipt drains once the repaired turn stands"
  end

  test "a blocked caller row stops the queue where it stands; a receipt ahead of it in read order still drains" do
    blocked = accept!(text: "policy-blocked")
    blocked.update!(state: "blocked", blocked_reason: "policy")
    mail = kernel_mail!

    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal mail.public_id, materialized_items.sole.payload.fetch("input_public_id")
    assert_equal :input_blocked, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert ConversationInput.exists?(blocked.id), "FIFO never skips a blocked caller row"
  end

  # The person cannot unblock or delete a kernel row, so a receipt the drain cannot serve lands as a
  # message turn when its execution surface is absent.
  test "a receipt with no model or approval surface degrades to a message turn instead of blocking" do
    declare!(@agent)
    mail = kernel_mail!(acting_user: @agent, kind: "direct_reply")

    assert_equal 1, drain!
    turn = @conversation.conversation_turns.sole
    assert_equal %w[message user completed], [turn.kind, turn.role, turn.status]
    assert_equal "task_result", turn.origin
    assert_equal ENVELOPE, turn.active_variant.content_bodies.sole.effective_text
    assert_nil turn.active_variant.content_bodies.find_by(role: "prompt"),
      "a message turn has no prompt: its content IS the envelope, the one copy a later history renders"
    assert_not ConversationInput.exists?(mail.id)
    assert_nil @conversation.reload.active_turn_id
    assert_empty blocked_items
    assert_equal 0, AgentLoop.count
  end

  # A PEER'S SEND THE DRAIN CANNOT SERVE BLOCKS like a person's word — its author can fix it, since
  # the edit surface is open on an `agent` row; only the kernel's set (`task_result`, `child`)
  # degrades.
  test "an agent's send with no resolvable model blocks; a child receipt degrades" do
    declare!(@agent)
    sender = Conversation.create!(workspace: @workspace, creating_user: @agent)
    sent = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
      host: @conversation, acting_user: @agent, kind: "direct_reply", entries: [{ "text" => "peer" }],
      sender_conversation_public_id: sender.public_id
    )).value
    assert_equal "agent", sent.origin

    assert_equal :input_blocked, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal %w[blocked model_selection_missing], [sent.reload.state, sent.blocked_reason]
    assert_equal "model_selection_missing", blocked_items.sole.payload.fetch("blocked_reason")
    assert_empty @conversation.conversation_turns

    sent.destroy!
    child = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: @agent, kind: "direct_reply", entries: [{ "text" => "child says" }],
      origin: ConversationInput::CHILD_ORIGIN, sender_conversation_public_id: sender.public_id
    )).value
    assert_equal 1, drain!
    turn = @conversation.conversation_turns.sole
    assert_equal %w[message user completed child], [turn.kind, turn.role, turn.status, turn.origin]
    assert_not ConversationInput.exists?(child.id)
  end

  test "a person's word typed after the settle materializes and wakes the converger" do
    seam, = hold_settled_seam!
    accept!(text: "never mind, do this instead")

    assert_enqueued_with(job: Conversations::Turns::ConvergeJob, args: [@conversation.id, { "agent_loop_id" => seam.agent_loop.id }]) do
      assert_equal 1, drain!
    end
    successor = @conversation.conversation_turns.order(:position).last
    assert_operator successor.position, :>, seam.turn.position
    assert_equal "completed", successor.status
    assert_empty blocked_items
    assert_equal "needs_attention", seam.agent_loop.reload.status,
      "the drain takes no loop lock; the REPLACE arm stops it"
  end

  # The gate reads the variant's ONE settle: an abandon that re-holds the
  # loop `deliverable_unresolved` in its own commit never re-settles the
  # terminal variant, so a word typed after it is post-settle and drains.
  test "a word typed after the single settle is not held behind a deliverable_unresolved re-hold" do
    seam, = hold_settled_seam!
    settled_at = seam.variant.reload.updated_at
    AgentLoops::Transition.agent_loop(seam.agent_loop, attention_reason: "deliverable_unresolved")
    Conversations::Turns::Converge.call
    assert_equal settled_at, seam.variant.reload.updated_at, "a terminal variant is never rewritten"
    accept!(text: "carry on")

    assert_equal 1, drain!
    assert_empty blocked_items
  end

  test "a settled loop gates nothing" do
    seam = create_loop_backed_turn(conversation: @conversation.reload, acting_user: @user)
    queued = accept!(text: "queued behind the run")
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "completed", completed_at: Time.current)
    Conversations::Turns::Converge.call

    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
      assert_equal 1, drain!
    end
    assert_not ConversationInput.exists?(queued.id)
  end

  # THE HELD CONJUNCT: a post-hold row addressed ELSEWHERE is held — it would otherwise materialize
  # B's turn and the REPLACE arm would kill A's repairable loop. Only the answerer's own post-settle
  # word repairs; the hold narrates on the first row in read order.
  test "a post-hold row addressed to another agent is held; A's needs_attention loop survives, and A's own word repairs" do
    seam, = hold_settled_seam!
    assert_equal @user, seam.agent_loop.answering_user, "A is the plain chat's Human here"
    to_b = accept!(text: "B, your view?", answering_user_public_id: @agent.public_id)

    assert_equal :loop_held, Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal "pending", to_b.reload.state
    assert_equal to_b.public_id, blocked_items.sole.payload.fetch("input_public_id")
    assert_equal "needs_attention", seam.agent_loop.reload.status, "no successor: the REPLACE arm never fired"
    assert_no_enqueued_jobs(only: Conversations::Turns::ConvergeJob) do
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
    end

    repair = accept!(text: "never mind, A: do this")
    assert_predicate Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id), :accepted?
    assert_equal repair.public_id, materialized_items.sole.payload.fetch("input_public_id"),
      "the answerer's own post-settle word is the head, ahead of the other agent's row"
    assert_equal "pending", to_b.reload.state
  end
end
