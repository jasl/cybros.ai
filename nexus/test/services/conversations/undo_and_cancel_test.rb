require "test_helper"

# The undo verb and the stop verb: apex-only hard delete with every cause spoken (steering mail
# never dies silently; the pin names its holder; a live loop refuses), and the cancellation —
# through the real chain, the converger settling what the cancel terminalized, on a reply's
# invocation or on the loop backing the turn.
class Conversations::UndoAndCancelTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def accept!(kind: "message", text: "hello", **overrides)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
      host: @conversation, acting_user: @human, kind: kind,
      role: "user", entries: [{ "text" => text }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil,
    }.merge(overrides)))
    assert_predicate result, :accepted?
    result.value
  end

  def drain! = Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

  def hard_delete!(turn)
    Conversations::Turns::HardDelete.call(Conversations::Turns::HardDelete::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human
    ))
  end

  test "the apex deletes, mid-history refuses, the pin names its holder" do
    accept!(text: "first")
    accept!(text: "second")
    drain!
    first, second = @conversation.conversation_turns.order(:position).to_a

    assert_equal :apex_only, hard_delete!(first).outcome

    child = Conversation.create!(workspace: @workspace, creating_user: @human)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 1
    )
    pinned = hard_delete!(second)
    assert_equal :descendant_pinned, pinned.outcome
    assert_equal child.public_id, pinned.value, "the answer names the pinning fork"

    child.destroy!
    result = hard_delete!(second)
    assert_predicate result, :accepted?
    assert_not ConversationTurn.exists?(second.id)
    assert_equal "turn_deleted",
      @conversation.conversation_event_items.order(:sequence).last.item_type
    assert first.reload.tail?, "the tail steps back"
  end

  test "held steering mail refuses the delete; canceling the steer clears the way" do
    accept!(text: "base")
    drain!
    actor = Actors::Resolve.member(account: @account, user: @human)
    running = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: 5,
      kind: "direct_reply", role: "assistant", status: "running",
      speaker_actor: actor, control_owner_user: @human
    )
    steer = accept!(delivery_mode: "steer", text: "aim")
    running.update!(status: "canceled")

    assert_equal :steering_holds, hard_delete!(running).outcome,
      "mail nobody agreed to lose"

    Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: @conversation, input_public_id: steer.public_id, acting_user: @human
    ))
    assert_predicate hard_delete!(running.reload), :accepted?
  end

  test "cancel stops the running reply through the real chain" do
    accept!(kind: "direct_reply", text: "long thought",
      provider_id: "dev", model_ref: "mock-text")
    drain!
    turn = @conversation.conversation_turns.sole
    assert_equal "running", turn.status

    result = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human
    ))
    assert_predicate result, :accepted?

    invocation = @conversation.model_invocations.sole
    assert_equal "canceled", invocation.reload.status
    assert_equal "creator_requested", invocation.failure_reason_key

    Conversations::Turns::Converge.call
    turn.reload
    assert_equal "canceled", turn.status
    assert_equal "canceled", turn.active_variant.status
    assert_nil @conversation.reload.active_turn_id, "the lane released"
    assert_equal 1, drain_ready_again

    repeat = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human
    ))
    assert_equal :not_running, repeat.outcome
  end

  def drain_ready_again
    accept!(text: "life goes on")
    drain!
  end

  def cancel!
    Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation.reload, acting_user: @human
    ))
  end

  def seam! = create_loop_backed_turn(conversation: @conversation.reload, acting_user: @human)

  test "cancel stops the loop backing the running turn, and the converger settles it canceled" do
    seam = seam!
    assert_predicate cancel!, :accepted?

    seam.agent_loop.reload
    assert_equal "canceling", seam.agent_loop.status, "the two-phase stop's first phase, forced"
    assert_nil seam.agent_loop.failure_reason
    assert_equal "running", seam.turn.reload.status, "the loop lock never writes the turn"

    AgentLoops::EvaluateQuiescence.call(seam.agent_loop)
    assert_equal "canceled", seam.agent_loop.reload.status
    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded]
    assert_equal "canceled", seam.turn.reload.status
    assert_equal "canceled", seam.variant.reload.status
    assert_nil @conversation.reload.active_turn_id, "the lane released"
    assert_equal 1, drain_ready_again
  end

  test "a hold-settled tail's live loop is cancelable and its variant records the final cancellation" do
    seam = seam!
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "needs_attention",
      attention_reason: "halt_failure")
    Conversations::Turns::Converge.call
    assert_equal "failed", seam.turn.reload.status
    assert_nil @conversation.reload.active_turn_id

    assert_predicate cancel!, :accepted?, "not `not_running`: the loop behind the tail is live"
    assert_equal "canceling", seam.agent_loop.reload.status
    AgentLoops::EvaluateQuiescence.call(seam.agent_loop)
    assert_equal "canceled", seam.agent_loop.reload.status

    assert_equal 1, Conversations::Turns::Converge.call.value[:recorded],
      "the held tail projects the loop's final cancellation"
    assert_equal "canceled", seam.variant.reload.status
    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded], "the final pair leaves the frontier"
    assert_equal :not_running, cancel!.outcome, "nothing live is left behind the tail"
  end

  test "the apex undo refuses over a live loop, then tombstones it before the cascade" do
    seam = seam!
    AgentLoops::Transition.agent_loop(seam.agent_loop, status: "needs_attention",
      attention_reason: "halt_failure")
    Conversations::Turns::Converge.call

    assert_equal :loop_live, hard_delete!(seam.turn).outcome,
      "a failed turn is terminal while its loop is adjudicable"

    cancel!
    AgentLoops::EvaluateQuiescence.call(seam.agent_loop.reload)
    assert_equal "canceled", seam.agent_loop.reload.status

    assert_predicate hard_delete!(seam.turn), :accepted?
    assert_not ConversationTurn.exists?(seam.turn.id)
    seam.agent_loop.reload
    assert_predicate seam.agent_loop, :tombstoned?, "tombstoned first, so a nil seam means a tombstoned loop"
    assert_nil seam.agent_loop.conversation_turn_variant_id, "the FK nullified behind it"
    assert_predicate seam.agent_loop, :standalone?
  end

  # A side's DELETE stops the loop behind its running turn through the kernel's own act and reaps
  # the row at once: the loop's seam nullifies, it drains standalone (the FK's design, as the apex
  # undo relies on), and the converger finds nothing of the side left.
  test "a side's tombstone stops its loop-backed turn, reaps at once, and the loop drains standalone" do
    accept!(text: "the settled message")
    drain!
    side = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: nil, variant_public_id: nil,
      acting_user: @human, title: nil, side: true
    )).value
    seam = create_loop_backed_turn(conversation: side, acting_user: @human)

    result = Conversations::Tombstone.call(conversation: side)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_not Conversation.exists?(side.id), "no conversation-owned work fences it: reaped at once"
    seam.agent_loop.reload
    assert_equal "canceling", seam.agent_loop.status, "the forced stop's first phase, by the kernel"
    assert_predicate seam.agent_loop, :standalone?, "the seam nullified under the reap"

    AgentLoops::EvaluateQuiescence.call(seam.agent_loop)
    assert_equal "canceled", seam.agent_loop.reload.status
    assert_equal 0, Conversations::Turns::Converge.call.value[:recorded], "nothing of the side is left to settle"
    assert Conversation.exists?(@conversation.id), "the parent stands, unpinned"
  end
end
