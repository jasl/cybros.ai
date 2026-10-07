require "test_helper"

# The read-path funnel: one shared filter for timeline and assembly. Local
# rows read their own columns; inherited rows read COALESCE(override,
# (visible, not-deleted)) and NEVER the shared row's own view columns.
class ConversationTimelineTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @actor = Speaker.create!(
      account: @account, kind: "member", user: @user,
      channel_key: "console", external_id: @user.public_id, display_name: "Member"
    )
    @parent = create_conversation
  end

  def create_conversation
    Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def build_turn(conversation:, position:, **overrides)
    ConversationTurn.create!(
      account: @account, conversation: conversation, position: position,
      kind: "message", role: "user", status: "completed",
      speaker: @actor, control_owner_user: @user, **overrides
    )
  end

  def fork_child(of:, bound:)
    child = create_conversation
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: of, depth: 1, boundary_position: bound
    )
    child
  end

  def positions(conversation, surface:, **window)
    conversation.timeline.entries(surface: surface, **window).map(&:position)
  end

  test "an assembled read merges the inherited prefix below the local rows, by position" do
    build_turn(conversation: @parent, position: 0)
    build_turn(conversation: @parent, position: 1)
    build_turn(conversation: @parent, position: 2)
    child = fork_child(of: @parent, bound: 1)
    build_turn(conversation: child, position: 2)

    entries = child.timeline.entries(surface: :timeline)

    assert_equal [0, 1, 2], entries.map(&:position)
    assert_equal [true, true, false], entries.map(&:inherited),
      "positions 0-1 are the ancestor's rows; 2 is local — the row above the bound is unreachable"
  end

  test "the empty-prefix pin reads nothing and costs nothing" do
    build_turn(conversation: @parent, position: 0)
    child = fork_child(of: @parent, bound: -1)

    assert_empty child.timeline.entries(surface: :timeline)
  end

  test "local concealment: deleted and hidden leave the timeline, excluded leaves assembly only" do
    build_turn(conversation: @parent, position: 0)
    concealed = build_turn(conversation: @parent, position: 1)
    excluded = build_turn(conversation: @parent, position: 2, visibility: "excluded_from_context")
    build_turn(conversation: @parent, position: 3, visibility: "hidden")
    build_turn(conversation: @parent, position: 4)
    concealed.update!(deleted_at: Time.current)

    assert_equal [0, 2, 4], positions(@parent, surface: :timeline)
    assert_equal [0, 4], positions(@parent, surface: :assembly)
    assert_equal "excluded_from_context",
      @parent.timeline.entries(surface: :timeline)[1].visibility
    assert_equal excluded.id, @parent.timeline.entries(surface: :timeline)[1].turn.id
  end

  test "an inherited row ignores the shared row's own view columns" do
    kept = build_turn(conversation: @parent, position: 0)
    build_turn(conversation: @parent, position: 1)
    child = fork_child(of: @parent, bound: 0)
    kept.update!(visibility: "hidden")

    assert_equal [0], positions(child, surface: :timeline),
      "the ancestor's own hide is its own view-state; the child seeded no override"
    assert_empty positions(@parent, surface: :timeline).select { |p| p == 0 },
      "while the ancestor's own surface honors it"
  end

  test "an override row is the child's whole view-state for an inherited turn" do
    build_turn(conversation: @parent, position: 0)
    target = build_turn(conversation: @parent, position: 1)
    build_turn(conversation: @parent, position: 2)
    child = fork_child(of: @parent, bound: 2)
    override = ConversationTurnOverride.create!(
      account: @account, conversation: child, conversation_turn: target,
      visibility: "excluded_from_context"
    )

    assert_equal [0, 1, 2], positions(child, surface: :timeline)
    assert_equal [0, 2], positions(child, surface: :assembly),
      "excluded rides the timeline and leaves assembly"

    override.update!(deleted_at: Time.current)
    assert_equal [0, 2], positions(child, surface: :timeline),
      "the overlay conceal hides it for THIS child"
    assert_equal [0, 1, 2], positions(@parent, surface: :timeline),
      "and touches nobody else"
  end

  test "a deep chain reads every ancestor's range through its own bound" do
    build_turn(conversation: @parent, position: 0)
    build_turn(conversation: @parent, position: 1)
    middle = fork_child(of: @parent, bound: 0)
    build_turn(conversation: middle, position: 1)
    build_turn(conversation: middle, position: 2)
    leaf = create_conversation
    ConversationAncestry.create!(
      account: @account, conversation: leaf,
      ancestor_conversation: @parent, depth: 2, boundary_position: 0
    )
    ConversationAncestry.create!(
      account: @account, conversation: leaf,
      ancestor_conversation: middle, depth: 1, boundary_position: 2
    )
    build_turn(conversation: leaf, position: 3)

    entries = leaf.timeline.entries(surface: :timeline)

    assert_equal [0, 1, 2, 3], entries.map(&:position)
    assert_equal [@parent.id, middle.id, middle.id, leaf.id],
      entries.map { |e| e.turn.conversation_id },
      "one disjoint range per ancestor, merged purely by position"
  end

  test "windows page by exclusive position cursors in both directions" do
    4.times { |i| build_turn(conversation: @parent, position: i) }

    assert_equal [2, 3], positions(@parent, surface: :timeline, after_position: 1)
    assert_equal [0, 1], positions(@parent, surface: :timeline, before_position: 2)
    assert_equal [1, 2], positions(@parent, surface: :timeline, before_position: 3, limit: 2),
      "a before-window takes the rows immediately below the cursor, ascending"
    assert_equal [0], positions(@parent, surface: :timeline, limit: 1)
  end
end
