require "test_helper"

# The view-state writers over both sides of the fork boundary: local
# columns for local rows, the override facade for inherited rows, the
# variant deck's conceal/restore — each cause speaking its own code, the
# assembly-membership changes bumping the revision, everything narrated.
class Conversations::ViewStateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @actor = Speaker.create!(
      account: @account, kind: "member", user: @user,
      channel_key: "console", external_id: @user.public_id, display_name: "Member"
    )
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def build_turn(conversation: @conversation, position:, **overrides)
    ConversationTurn.create!(
      account: @account, conversation: conversation, position: position,
      kind: "message", role: "user", status: "completed",
      speaker: @actor, control_owner_user: @user, **overrides
    )
  end

  def set_view!(turn, conversation: @conversation, visibility: nil, concealed: nil)
    Conversations::Turns::SetViewState.call(
      Conversations::Turns::SetViewState::Command.new(
        conversation: conversation, turn_public_id: turn.public_id,
        acting_user: @user, visibility: visibility, concealed: concealed
      )
    )
  end

  test "a local turn's visibility and concealment write its own columns and bump context" do
    turn = build_turn(position: 0)
    build_turn(position: 1)

    result = set_view!(turn, visibility: "excluded_from_context")
    assert_predicate result, :accepted?
    assert_equal "excluded_from_context", turn.reload.visibility
    assert_equal 1, @conversation.reload.context_revision, "assembly membership changed"

    set_view!(turn, visibility: "visible")
    assert_equal 2, @conversation.reload.context_revision

    set_view!(turn, concealed: true)
    assert_not_nil turn.reload.deleted_at
    assert_equal 3, @conversation.reload.context_revision

    types = @conversation.conversation_event_items.order(:sequence).pluck(:item_type)
    assert_equal %w[visibility visibility soft_delete], types
  end

  test "the causes speak their own codes: apex, terminal, restore off the tail" do
    first = build_turn(position: 0)
    apex = build_turn(position: 1)

    assert_equal :apex_never_conceals, set_view!(apex, concealed: true).outcome
    assert_predicate set_view!(first, concealed: true), :accepted?

    running = build_turn(position: 2, status: "running")
    assert_equal :not_terminal, set_view!(running, concealed: true).outcome
    running.update!(status: "canceled")

    assert_equal :branch_required, set_view!(first, concealed: false).outcome,
      "restore lands only where the row would again be the tail"
  end

  test "the pin exception speaks through the service: truncate below a live branch" do
    build_turn(position: 0)
    pinned = build_turn(position: 1)
    apex = build_turn(position: 2)
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 1
    )
    apex.destroy!

    result = set_view!(pinned.reload, concealed: true)

    assert_predicate result, :accepted?,
      "where the pin refuses the hard delete, conceal opens — through the service too"
    assert_not_nil pinned.reload.deleted_at
  end

  test "a repeat of the standing state is a true no-op: no write, no event" do
    first = build_turn(position: 0)
    build_turn(position: 1)
    set_view!(first, concealed: true)
    stamped_at = first.reload.deleted_at
    events_before = @conversation.conversation_event_items.count

    repeat = set_view!(first, concealed: true)

    assert_predicate repeat, :accepted?
    assert_equal stamped_at, first.reload.deleted_at, "the timestamp never refreshes"
    assert_equal events_before, @conversation.conversation_event_items.count,
      "no duplicate narration for what already stood"
  end

  test "an inherited row takes the override facade; the shared row never moves" do
    kept = build_turn(position: 0)
    build_turn(position: 1)
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0
    )

    result = set_view!(kept, conversation: child, concealed: true)

    assert_predicate result, :accepted?
    assert_predicate result.value, :inherited?
    assert_nil kept.reload.deleted_at, "the shared row never moves"
    override = child.conversation_turn_overrides.sole
    assert_not_nil override.deleted_at
    assert_empty child.timeline.entries(surface: :timeline),
      "concealed for THIS child"
    assert_equal 1, child.reload.context_revision

    restore = set_view!(kept, conversation: child, concealed: false)
    assert_predicate restore, :accepted?
    assert_equal 1, child.timeline.entries(surface: :timeline).length,
      "the override is freely mutable both ways — inherited rows are mid-history by construction"
  end

  test "the variant deck: the active candidate refuses, the pointer moves, the slot rule holds" do
    turn = build_turn(position: 0)
    active = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    spare = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 1, status: "completed", source: "inference"
    )
    turn.update!(active_variant: active)

    conceal = lambda do |variant, concealed|
      Conversations::Variants::SetViewState.call(
        Conversations::Variants::SetViewState::Command.new(
          conversation: @conversation, turn_public_id: turn.public_id,
          variant_public_id: variant.public_id, acting_user: @user,
          concealed: concealed
        )
      )
    end

    assert_equal :variant_active, conceal.call(active, true).outcome

    turn.reload.update!(active_variant: spare)
    assert_predicate conceal.call(active, true), :accepted?

    usurper = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    assert_equal :slot_occupied, conceal.call(active, false).outcome

    usurper.update!(deleted_at: Time.current)
    assert_predicate conceal.call(active, false), :accepted?
    assert_equal "turn_variant",
      @conversation.conversation_event_items.order(:sequence).last.item_type
  end
end
