require "test_helper"

# The seam and the turn shape: one pure function over the loop's own row — every row of the mapping
# — plus the seam's owning-side validation, its two derivations, and the one finder with two
# associations.
class AgentLoopTurnShapeTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  # Every row below is an UNDELIVERED loop; a delivered one has one row.
  def shape(delivered_at: nil, **attributes)
    AgentLoop.new(workspace: @workspace, creating_user: @user, delivered_at: delivered_at, **attributes).turn_shape
  end

  test "every row of the mapping, in the frozen turn algebra" do
    assert_equal ["pending", nil], shape(status: "pending").to_h.values
    assert_equal ["running", nil], shape(status: "running").to_h.values
    assert_equal ["running", nil],
      shape(status: "running", attention_reason: "awaiting_human").to_h.values,
      "a park is waiting, not halting"
    assert_equal ["running", nil], shape(status: "paused").to_h.values
    assert_equal ["running", nil], shape(status: "canceling").to_h.values
    assert_equal %w[failed halt_failure],
      shape(status: "needs_attention", attention_reason: "halt_failure").to_h.values
    assert_equal ["completed", nil], shape(status: "completed").to_h.values
    assert_equal %w[failed authority_lost],
      shape(status: "canceled", failure_reason: "authority_lost").to_h.values,
      "a reasoned cancel IS the loop failing"
    assert_equal ["canceled", nil], shape(status: "canceled").to_h.values
  end

  # THE LOOP HAS NO `failed` (review 2026-09-08 change 7): the engine never
  # wrote it — a reasoned cancel IS the loop failing, and the turn shape
  # derives its `failed` from a hold or that cancel. A word declared,
  # published and never written was a promise to every client for nothing.
  test "failed is not a loop status" do
    assert_not_includes AgentLoop::STATUSES, "failed"
    assert_equal %w[completed canceled], AgentLoop::TERMINAL_STATUSES
    assert_not AgentLoop.new(workspace: @workspace, creating_user: @user, status: "failed").valid?
  end

  # THE REPLY IS FINAL: a delivered loop reads `completed` whatever its own status — a hold or a
  # cancel of the background work later is the loop's alone, never the turn's.
  test "a delivered loop is completed whatever its status" do
    now = Time.current
    assert_equal ["completed", nil], shape(status: "running", delivered_at: now).to_h.values
    assert_equal ["completed", nil],
      shape(status: "needs_attention", attention_reason: "halt_failure", delivered_at: now).to_h.values
    assert_equal ["completed", nil],
      shape(status: "canceled", failure_reason: "replaced", delivered_at: now).to_h.values
    assert_equal ["completed", nil], shape(status: "completed", delivered_at: now).to_h.values
  end

  test "the seam is nullable and admits only a loop-backed variant" do
    standalone = AgentLoop.new(workspace: @workspace, creating_user: @user, approval_mode: "bypass")
    assert_predicate standalone, :valid?
    assert_predicate standalone, :standalone?

    hosted = create_loop_backed_turn(conversation: @conversation, acting_user: @user)
    assert_not hosted.agent_loop.standalone?

    manual = ConversationTurnVariant.create!(
      account: @account, conversation_turn: hosted.turn,
      position: 1, status: "completed", source: "manual"
    )
    wrong = AgentLoop.new(workspace: @workspace, creating_user: @user, conversation_turn_variant: manual)
    assert_not wrong.valid?, "a manual or edit variant never acquires a loop"
    assert wrong.errors.of_kind?(:conversation_turn_variant, :invalid)
  end

  test "the seam is creation-frozen and one loop per variant" do
    hosted = create_loop_backed_turn(conversation: @conversation, acting_user: @user)

    assert_raises(ActiveRecord::ReadonlyAttributeError) do
      hosted.agent_loop.update!(conversation_turn_variant: nil)
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      AgentLoop.create!(workspace: @workspace, creating_user: @user,
        status: "running", conversation_turn_variant: hosted.variant, approval_mode: "bypass")
    end
  end

  test "the host is the conversation through the seam, or the loop itself" do
    standalone = AgentLoop.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass")
    assert_equal standalone, standalone.host
    assert_nil standalone.conversation
    assert_nil standalone.conversation_turn

    hosted = create_loop_backed_turn(conversation: @conversation, acting_user: @user)
    assert_equal @conversation, hosted.agent_loop.host
    assert_equal hosted.turn, hosted.agent_loop.conversation_turn
    assert_equal @conversation, hosted.agent_loop.conversation
  end

  test "one steering finder reads the turn's rows or the hosted rows" do
    hosted = create_loop_backed_turn(conversation: @conversation, acting_user: @user)
    steer = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @user, kind: "message", role: "user",
      entries: [{ "text" => "aim" }], visible_in_context: nil, delivery_mode: "steer",
      context_mode: nil, context_options: nil, expected_context_revision: nil,
      expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
      reasoning_effort: nil, request_options: nil
    ))
    assert_predicate steer, :accepted?
    assert_equal hosted.turn.id, steer.value.steering_target_turn_id

    assert_equal [steer.value], hosted.agent_loop.steering_inputs.to_a
    assert_empty hosted.agent_loop.follow_up_inputs,
      "a loop-backed loop's queue is its conversation's next turns"

    standalone = AgentLoop.create!(workspace: @workspace, creating_user: @user, status: "running", approval_mode: "bypass")
    actor = Actors::Resolve.member(account: @account, user: @user)
    bound = standalone.conversation_inputs.create!(
      account: @account, queue_position: 0, kind: "message", state: "steering",
      speaker_actor: actor, authoring_user: @user
    )
    queued = standalone.conversation_inputs.create!(
      account: @account, queue_position: 1, kind: "message",
      speaker_actor: actor, authoring_user: @user
    )
    assert_equal [bound], standalone.steering_inputs.to_a
    assert_equal [queued], standalone.follow_up_inputs.to_a
  end

  test "a loop-backed loop's door and a standalone loop's door answer differently" do
    hosted = create_loop_backed_turn(conversation: @conversation, acting_user: @user)
    assert_equal :conversation_hosted, hosted.agent_loop.input_refusal

    standalone = AgentLoop.create!(workspace: @workspace, creating_user: @user, status: "running", approval_mode: "bypass")
    assert_nil standalone.input_refusal
    assert_equal :self, standalone.steer_binding
    assert_not standalone.hosts_turns?
    assert_equal AgentLoop::INPUT_QUEUE_LIMIT, standalone.input_queue_limit
  end
end
