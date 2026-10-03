require "test_helper"

# Fork without copy: closure + adopted boundary turn + sparse overlay +
# digest-shared fragments. The walk asserts the O(10+D+K+S) shape directly:
# zero content bytes move — the adopted variant's bodies point at the SAME
# fragment rows the source sealed.
class Conversations::ForkTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @actor = Actor.create!(
      account: @account, kind: "member", user: @user,
      channel_key: "console", external_id: @user.public_id, display_name: "Member"
    )
    @source = create_conversation
  end

  def create_conversation
    Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def build_turn(conversation:, position:, **overrides)
    ConversationTurn.create!(
      account: @account, conversation: conversation, position: position,
      kind: "message", role: "user", status: "completed",
      speaker_actor: @actor, control_owner_user: @user, **overrides
    )
  end

  def build_variant(turn:, text: "hello from #{turn.position}", activate: true)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: turn.conversation_turn_variants.count, status: "completed",
      source: "inference", content_preview: text[0, 140]
    )
    ContentBodies::Replace.call(
      owner: variant, role: "content", entries: [{ "text" => text }], seal: true
    )
    turn.update!(active_variant: variant) if activate
    variant
  end

  def fork!(turn:, variant: nil, source: @source, title: nil, by: @user)
    Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: source, turn_public_id: turn.public_id,
      variant_public_id: variant&.public_id, acting_user: by, title: title
    ))
  end

  # The side fork names no turn: the fork point is the parent's newest SETTLED turn, whatever runs
  # above it.
  def side_fork!(source: @source, title: nil, by: @user)
    Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: source, turn_public_id: nil, variant_public_id: nil,
      acting_user: by, title: title, side: true
    ))
  end

  # A reply turn left RUNNING at the head, its variant unsettled — the
  # shape a side fork is taken under.
  def build_running_head!(conversation:, position:, **overrides)
    turn = build_turn(conversation: conversation, position: position,
      kind: "direct_reply", role: "assistant", status: "running", **overrides)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "running", source: "inference"
    )
    turn.update!(active_variant: variant)
    conversation.update!(active_turn: turn, timeline_position_head: position + 1)
    [turn, variant]
  end

  # A fork copies the CONVERSATION rung only: `user/` belongs to the person, `workspace/` to the
  # room, and neither is the conversation's.
  test "a fork copies no user/ rows — they are the person's, not the conversation's" do
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)
    Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @source, path: "conversation/plan.md", by: @user),
      conversation: @source, path: "conversation/plan.md", content: "ours", by: @user
    ).then { |result| assert_predicate result, :accepted?, result.outcome.inspect }
    Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @source, path: "user/notes.md", by: @user),
      conversation: @source, path: "user/notes.md", content: "mine", by: @user
    ).then { |result| assert_predicate result, :accepted?, result.outcome.inspect }
    user_rows = MemoryDocument.for_user(@user.id).count

    result = fork!(turn: target)

    assert_predicate result, :accepted?
    child = result.value
    assert_equal ["conversation/plan.md"],
      MemoryDocument.for_conversation(child.id).map(&:path)
    assert_equal user_rows, MemoryDocument.for_user(@user.id).count
  end

  # A store row is MUTABLE, so it is copied as a current value with a fresh lock_version, never
  # shared by pointer: CoW-by-pointer would let the parent's next PATCH rewrite the child's value.
  test "a fork copies conversation-scope store entries as fresh current values, and nothing else" do
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)
    plan = @source.store_entries.create!(namespace: "ui", key: "plan", value: { "step" => 1 })
    @source.store_entries.create!(namespace: "ui", key: "cursor", value: 7)
    plan.update!(value: { "step" => 2 })
    @workspace.store_entries.create!(namespace: "ui", key: "plan", value: "room")
    @user.store_entries.create!(namespace: "ui", key: "plan", value: "mine")
    workspace_rows = StoreEntry.for_workspace(@workspace.id).count
    user_rows = StoreEntry.for_user(@user.id).count

    result = fork!(turn: target)

    assert_predicate result, :accepted?
    child = result.value
    copied = StoreEntry.for_conversation(child.id).order(:key).to_a
    assert_equal %w[cursor plan], copied.map(&:key)
    assert_equal [7, { "step" => 2 }], copied.map(&:value)
    assert_equal [0, 0], copied.map(&:lock_version)
    assert_empty copied.map(&:public_id) & StoreEntry.for_conversation(@source.id).pluck(:public_id)
    assert_equal workspace_rows, StoreEntry.for_workspace(@workspace.id).count
    assert_equal user_rows, StoreEntry.for_user(@user.id).count

    assert_equal :updated, StoreEntries::Update.call(
      entry: plan, by: @user, lock_version: plan.reload.lock_version, value: { "step" => 3 }
    ).outcome
    assert_equal({ "step" => 2 }, copied.find { |row| row.key == "plan" }.reload.value)
  end

  test "a fork adopts the boundary as its own editable latest, sharing every byte" do
    build_turn(conversation: @source, position: 0)
    stamp = SecureRandom.uuid
    sending_loop = SecureRandom.uuid_v7
    target = build_turn(conversation: @source, position: 1, origin: "agent", sender_conversation_public_id: stamp,
      sender_agent_loop_public_id: sending_loop, sender_task_key: "r2t1")
    chosen = build_variant(turn: target)
    build_turn(conversation: @source, position: 2)

    result = fork!(turn: target)

    assert_predicate result, :accepted?
    child = result.value
    assert_equal target.public_id, child.forked_from_turn_public_id
    assert_equal 2, child.timeline_position_head, "the head sits above the adopted slot"

    pin = child.conversation_ancestries.sole
    assert_equal @source.id, pin.ancestor_conversation_id
    assert_equal 0, pin.boundary_position, "fork at P bounds the closure at P-1"

    adopted = child.conversation_turns.sole
    assert_equal 1, adopted.position
    assert_equal target.public_id, adopted.forked_from_turn_public_id
    assert_equal chosen.public_id, adopted.forked_from_variant_public_id
    assert_equal @actor.id, adopted.speaker_actor_id, "attribution stays the original's"
    assert_equal ["agent", stamp, sending_loop, "r2t1"],
      [adopted.origin, adopted.sender_conversation_public_id, adopted.sender_agent_loop_public_id, adopted.sender_task_key],
      "the speaker's kind and sender ride the adopted words; control alone passes to the forker"

    adopted_variant = adopted.active_variant
    assert_equal "fork", adopted_variant.source
    assert_equal chosen.content_bodies.sole.content_body_entries.pluck(:content_fragment_id),
      adopted_variant.content_bodies.sole.content_body_entries.pluck(:content_fragment_id),
      "the clone points at the SAME fragments — zero content bytes moved"

    assert_equal [0, 1], child.timeline.entries(surface: :timeline).map(&:position)
    assert_predicate adopted.reload, :tail?, "immediately editable and regenerable"
    ConversationTurnVariant.create!(
      account: @account, conversation_turn: adopted,
      position: 1, status: "completed", source: "inference"
    )

    narration = @source.conversation_event_items.sole
    assert_equal "fork_created", narration.item_type
    assert_equal child.public_id, narration.payload.fetch("child_conversation_public_id"),
      "the fork narrates in the SOURCE's stream"
    assert_equal 0, child.conversation_event_items.count, "a child starts an empty stream"
  end

  test "a fork names its original turn without fabricating input consumption or callback delivery" do
    receipt_id = SecureRandom.uuid_v7
    source = { "input_public_id" => receipt_id, "origin" => "child",
      "sender_conversation_public_id" => SecureRandom.uuid_v7, "sender_agent_loop_public_id" => SecureRandom.uuid_v7,
      "sender_task_key" => "r2t0", "result" => {
        "conversation_public_id" => SecureRandom.uuid_v7, "input_public_id" => SecureRandom.uuid_v7,
        "turn_public_id" => SecureRandom.uuid_v7, "variant_public_id" => SecureRandom.uuid_v7,
        "requester_actor_public_id" => @actor.public_id,
      } }
    target = build_turn(conversation: @source, position: 0, origin: "child", input_public_id: receipt_id,
      callback_sources: [source], sender_agent_loop_public_id: source.fetch("sender_agent_loop_public_id"))
    build_variant(turn: target)

    result = fork!(turn: target)
    assert_predicate result, :accepted?
    adopted = result.value.conversation_turns.sole
    assert_nil adopted.input_public_id
    assert_empty adopted.callback_sources
    assert_equal target.public_id, adopted.forked_from_turn_public_id
    assert_equal [source], target.reload.callback_sources
    assert_nil AgentLoops::SourceWork.source_of(adopted.active_variant)
  end

  test "forking a fork caps every inherited bound at the new edge and copies the root's billing and answerer" do
    BillingSubject.create!(account: @account, owning_user: @user, key: "root-team")
    root = Conversations::Create.call(Conversations::Create::Command.new(
      workspace: @workspace, creating_user: @user, title: nil,
      metadata: {}, billing_subject: "root-team", answering_user_public_id: users(:agent).public_id
    )).value
    runner = @account.task_executors.create!(
      executor_kind: :runner, display_name: "Bound", runner_identifier: "bound",
      manager: users(:owner), assignment_scope: :account_wide
    )
    root.update!(runner_executor: runner)
    build_turn(conversation: root, position: 0)
    t1 = build_turn(conversation: root, position: 1)
    build_variant(turn: t1)
    middle = fork!(turn: t1, source: root).value
    m2 = build_turn(conversation: middle, position: 2)
    build_variant(turn: m2)
    build_turn(conversation: middle, position: 3)

    result = fork!(turn: m2, source: middle)

    assert_predicate result, :accepted?
    leaf = result.value
    bounds = leaf.conversation_ancestries.order(:depth)
      .pluck(:depth, :ancestor_conversation_id, :boundary_position)
    assert_equal [[1, middle.id, 1], [2, root.id, 0]], bounds,
      "the direct edge at P-1; the inherited edge capped at min(bound, P-1)"
    assert_equal runner.id, middle.runner_executor_id, "a fork COPIES its source's binding"
    assert_equal runner.id, leaf.runner_executor_id
    assert_equal users(:agent), middle.answering_user, "a fork COPIES its source's answerer"
    assert_equal users(:agent), leaf.answering_user, "the forker is never the answerer"
    assert_equal @user, leaf.creating_user
    assert_equal "root-team", leaf.billing_subject_key,
      "the BRANCH ROOT's frozen pair, never re-verified"
    assert_equal [0, 1, 2], leaf.timeline.entries(surface: :timeline).map(&:position)
  end

  test "the overlay freezes the source's effective view at the fork" do
    hidden = build_turn(conversation: @source, position: 0, visibility: "hidden")
    build_turn(conversation: @source, position: 1)
    target = build_turn(conversation: @source, position: 2)
    build_variant(turn: target)

    child = fork!(turn: target).value

    override = child.conversation_turn_overrides.sole
    assert_equal hidden.id, override.conversation_turn_id
    assert_equal "hidden", override.visibility
    assert_equal [1, 2], child.timeline.entries(surface: :timeline).map(&:position),
      "the child sees what the source saw"

    hidden.update!(visibility: "visible")
    assert_equal [1, 2], child.reload.timeline.entries(surface: :timeline).map(&:position),
      "frozen AT fork: the source's later change does not bleed through"
  end

  test "source-state gates: archived forks freely, tombstoned answers as absence" do
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)

    Conversations::Archive.call(conversation: @source)
    assert_predicate fork!(turn: target, source: @source.reload), :accepted?,
      "a fork is a pure read-derivation of the bin"

    Conversations::Tombstone.call(conversation: @source)
    assert_equal :not_found, fork!(turn: target, source: @source.reload).outcome
  end

  test "a concealed target answers as absence" do
    build_turn(conversation: @source, position: 0)
    target = build_turn(conversation: @source, position: 1)
    build_variant(turn: target)
    build_turn(conversation: @source, position: 2)
    target.update!(deleted_at: Time.current)

    assert_equal :not_found, fork!(turn: target).outcome,
      "a concealed-turn fork would resurrect removed content"
  end

  test "a concealed chosen variant answers as absence; its live sibling forks" do
    target = build_turn(conversation: @source, position: 0)
    chosen = build_variant(turn: target)
    replacement = build_variant(turn: target, text: "replacement")
    chosen.reload.update!(deleted_at: Time.current)

    assert_equal :not_found, fork!(turn: target, variant: chosen).outcome
    assert_predicate fork!(turn: target, variant: replacement.reload), :accepted?
  end

  test "an unsettled chosen variant refuses; absence swallows an unreachable turn" do
    target = build_turn(conversation: @source, position: 0, status: "running")
    running = ConversationTurnVariant.create!(
      account: @account, conversation_turn: target,
      position: 0, status: "running", source: "inference"
    )

    assert_equal :variant_not_forkable, fork!(turn: target, variant: running).outcome

    stranger = build_turn(conversation: create_conversation, position: 0)
    assert_equal :not_found, fork!(turn: stranger).outcome,
      "a turn outside the source's reach reads as absence"
  end

  # ── The side fork ────────────────────────────

  test "a side fork from a running head takes the last settled turn, bounds the closure there and adopts nothing" do
    runner = @account.task_executors.create!(
      executor_kind: :runner, display_name: "Bound", runner_identifier: "bound-side",
      manager: users(:owner), assignment_scope: :account_wide
    )
    @source = Conversation.create!(workspace: @workspace, creating_user: @user,
      answering_user: users(:agent), runner_executor: runner)
    build_variant(turn: build_turn(conversation: @source, position: 0))
    settled = build_turn(conversation: @source, position: 1, kind: "direct_reply", role: "assistant")
    settled_variant = build_variant(turn: settled)
    _running, running_variant = build_running_head!(conversation: @source, position: 2)
    Conversations::Memory::Apply.write(expected: memory_expectation_for(conversation: @source, path: "conversation/plan.md", by: @user),
      conversation: @source, path: "conversation/plan.md", content: "ours", by: @user
    ).then { |result| assert_predicate result, :accepted?, result.outcome.inspect }
    @source.store_entries.create!(namespace: "ui", key: "plan", value: { "step" => 1 })

    result = side_fork!(source: @source.reload)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "running", running_variant.reload.status, "nothing running was forked or touched"
    child = result.value
    assert_predicate child, :side?
    assert_equal settled.public_id, child.forked_from_turn_public_id, "the fork point is P = the running turn's position - 1"
    assert_equal settled_variant.public_id, child.forked_from_variant_public_id
    assert_equal 2, child.timeline_position_head, "the side's own turns start above P"
    pin = child.conversation_ancestries.sole
    assert_equal [@source.id, 1], [pin.ancestor_conversation_id, pin.boundary_position],
      "the closure bounds the parent at P INCLUSIVE"
    assert_equal 0, child.conversation_turns.count, "a side adopts nothing: only the closure keeps the bytes"
    assert_equal [0, 1], child.timeline.entries(surface: :timeline).map(&:position),
      "the running turn is never inherited"
    assert_equal users(:agent), child.answering_user, "the stored answerer, never the derivation (Q6)"
    assert_equal runner.id, child.runner_executor_id
    assert_equal ["conversation/plan.md"], MemoryDocument.for_conversation(child.id).map(&:path)
    assert_equal [{ "step" => 1 }], StoreEntry.for_conversation(child.id).pluck(:value)
    narration = @source.conversation_event_items.sole
    assert_equal "fork_created", narration.item_type
    assert_equal child.public_id, narration.payload.fetch("child_conversation_public_id"),
      "the fork narrates in the parent's stream; a UI may hide the child"
  end

  test "a side of a first-turn conversation inherits nothing and is allowed" do
    build_running_head!(conversation: @source, position: 0)

    result = side_fork!(source: @source.reload)

    assert_predicate result, :accepted?, result.outcome.inspect
    child = result.value
    assert_equal(-1, child.conversation_ancestries.sole.boundary_position)
    assert_nil child.forked_from_turn_public_id
    assert_nil child.forked_from_variant_public_id
    assert_equal 0, child.timeline_position_head
    assert_empty child.timeline.entries(surface: :timeline)
  end

  test "a side is never forked: plain and side alike refuse side_of_side" do
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)
    @source.update!(timeline_position_head: 1)
    side = side_fork!(source: @source.reload).value
    assert_equal target.public_id, side.forked_from_turn_public_id,
      "an idle parent's fork point is its head - 1"

    assert_equal :side_of_side, side_fork!(source: side).outcome
    assert_equal :side_of_side, fork!(turn: target, source: side).outcome,
      "a plain fork of a side would inherit a boundary item"
    assert_equal 2, Conversation.count
  end

  test "a side fork under a running variant does not meet variant_not_forkable" do
    build_variant(turn: build_turn(conversation: @source, position: 0))
    _running, running_variant = build_running_head!(conversation: @source, position: 1)
    assert_equal "running", running_variant.status

    assert_predicate side_fork!(source: @source.reload), :accepted?
  end

  test "a non-writer's side fork is not_authorized" do
    build_variant(turn: build_turn(conversation: @source, position: 0))
    @workspace.update!(state: :archiving)

    assert_equal :not_authorized, side_fork!(source: @source.reload).outcome
    assert_equal 1, Conversation.count
  end

  test "fork replays through its receipt without a second child" do
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)
    digest = SecureRandom.hex(32)

    run = lambda do
      ConversationCommandReceipt::Idempotent.call(
        account: @account, workspace: @workspace, acting_user: @user,
        operation: "fork", idempotency_key: "fork-1", request_digest: digest,
        host: @source
      ) do
        result = fork!(turn: target)
        ConversationCommandReceipt::Idempotent::Success.new(
          status: 201,
          body: { "public_id" => result.value.public_id },
          host: result.value
        )
      end
    end

    first = run.call
    replay = run.call

    assert_equal :executed, first.outcome
    assert_equal :replayed, replay.outcome
    assert_equal 2, Conversation.count, "source plus exactly one child"
  end

  # ── The access carrier forks with the conversation ───────

  # Every principal's effective level on the child equals its level on the
  # source, except the forker, who becomes the creator: the rows are copied
  # at the fork instant, and the source's DERIVED-full principals (creator,
  # answerer) are MATERIALIZED as `full` entries when they are not the
  # child's own creator or answerer — a source creator with no row would
  # otherwise fall to the child's default and lose its own conversation.
  def access_source!(default: "none", entries: { curator: "full", owner: "read" })
    @source.update!(access_default: default)
    entries.each { |name, level| @source.conversation_access_entries.create!(user: users(name), level: level) }
    @source
  end

  def levels_on(conversation)
    %i[member agent curator owner system].to_h { |name| [name, conversation.access_level_for(users(name))] }
  end

  test "a fork by a non-creator full entry copies the levels and materializes the source's creator" do
    @source = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    access_source!
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)

    result = nil
    assert_difference -> { ConversationAccessEntry.count }, 2 do
      result = fork!(turn: target, by: users(:curator))
    end

    assert_predicate result, :accepted?, result.outcome.inspect
    child = result.value
    assert_equal users(:curator), child.creating_user
    assert_equal users(:agent), child.answering_user
    assert_equal "none", child.access_default, "the default is copied, never re-derived"
    assert_equal levels_on(@source), levels_on(child), "every principal keeps its level on the child"
    assert_equal({ member: "full", owner: "read" },
      child.conversation_access_entries.joins(:user).order(:id)
        .pluck("users.display_name", :level).to_h { |name, level| [name.downcase.to_sym, level] },
      "the source's creator is a materialized full row; the forker's own row is not carried; the answerer stays derived")
    assert_equal "full", child.access_level_for(@user), "the source's creator reads its own conversation's fork"
  end

  # The failing sequence the rule was cut for: Human H opens `default: none`
  # answered by rho; rho's `btw` side (creator = rho) must still be readable
  # by H — H's level on the side equals H's level on the source.
  test "a side fork by the answerer materializes the Human creator as full on the side" do
    @source = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    access_source!(entries: { owner: "read" })
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)
    @source.update!(timeline_position_head: 1)

    result = nil
    assert_difference -> { ConversationAccessEntry.count }, 2 do
      result = side_fork!(source: @source.reload, by: users(:agent))
    end

    assert_predicate result, :accepted?, result.outcome.inspect
    side = result.value
    assert_predicate side, :side?
    assert_equal users(:agent), side.creating_user
    assert_equal users(:agent), side.answering_user
    assert_equal "none", side.access_default
    assert_equal levels_on(@source), levels_on(side)
    assert_equal "full", side.access_level_for(@user), "H reads rho's side of H's own conversation"
    assert_equal "none", side.access_level_for(users(:curator))
    assert_equal "read", side.access_level_for(users(:owner)), "the steward's read level rides along"
  end

  test "a fork by the creator copies the entries verbatim and materializes nothing" do
    access_source!(entries: { curator: "full", owner: "read", agent: "none" })
    target = build_turn(conversation: @source, position: 0)
    build_variant(turn: target)

    result = nil
    assert_difference -> { ConversationAccessEntry.count }, 3 do
      result = fork!(turn: target)
    end

    child = result.value
    assert_equal levels_on(@source), levels_on(child)
    assert_equal @source.conversation_access_entries.order(:user_id).pluck(:user_id, :level),
      child.conversation_access_entries.order(:user_id).pluck(:user_id, :level)
  end

  # THE TURN COLUMN THROUGH THE FORK: the adopted boundary carries the target turn's own answerer
  # (never the forker's); a plain fork keeps the source's default; a SIDE copies the fork-point
  # turn's — the running one when a turn runs — so a `btw` taken during B's turn renders under B's
  # system_prompt (the side-conversation prefix).
  test "a fork's boundary carries the turn's answerer; a side copies the fork-point turn's" do
    @source = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    peer = create_agent_member(display_name: "Peer", agent_identifier: "peer-agent")
    target = build_turn(conversation: @source, position: 0, kind: "direct_reply", role: "assistant",
      answering_user: peer)
    build_variant(turn: target)
    @source.update!(timeline_position_head: 1)

    child = fork!(turn: target, by: users(:curator)).value
    assert_equal users(:agent), child.answering_user, "a plain fork keeps the source's default"
    assert_equal peer, child.conversation_turns.sole.answering_user, "the boundary is the turn's own answerer"
    assert_equal users(:curator), child.conversation_turns.sole.control_owner_user

    idle_side = side_fork!(source: @source.reload).value
    assert_equal peer, idle_side.answering_user, "idle: the last settled turn's answerer"

    build_running_head!(conversation: @source.reload, position: 1, answering_user: peer)
    running_side = side_fork!(source: @source.reload).value
    assert_equal peer, running_side.answering_user, "running: the running turn's answerer"
    assert_equal peer, running_side.declaring_profile
  end
end
