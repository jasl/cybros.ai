require "test_helper"

# The conversation plane's substrate invariants — each rule the 2026-08-28
# schema design assigns to an INDEX or a MODEL VALIDATION, bitten here so a
# mutation deleting any one of them fails a test rather than shipping.
class ConversationSubstrateTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @actor = Speaker.create!(
      account: @account, kind: "member", user: @user,
      channel_key: "console", external_id: @user.public_id, display_name: "Member"
    )
    @conversation = Conversation.create!(
      workspace: @workspace, creating_user: @user
    )
  end

  def build_turn(conversation: @conversation, position:, status: "completed", **overrides)
    ConversationTurn.create!(
      account: conversation.account, conversation: conversation,
      position: position, kind: "message", role: "user", status: status,
      speaker: @actor, control_owner_user: @user, **overrides
    )
  end

  # Bypasses validations to construct states the create backstop refuses,
  # so the INDEX-level rules keep their own biting tests. The answerer is
  # spelled out: skipping validation skips the column's default too.
  def force_turn(conversation: @conversation, position:, status: "completed", **overrides)
    turn = ConversationTurn.new(
      account: conversation.account, conversation: conversation,
      position: position, kind: "message", role: "user", status: status,
      speaker: @actor, control_owner_user: @user, answering_user: conversation.answering_user,
      **overrides
    )
    turn.save!(validate: false)
    turn
  end

  test "an actor of kind member names its controlling user" do
    orphan = Speaker.new(
      account: @account, kind: "member",
      channel_key: "console", external_id: "nobody", display_name: "Nobody"
    )
    assert_not orphan.valid?

    speaker = Speaker.new(
      account: @account, kind: "persona",
      channel_key: "roleplay", external_id: "villager", display_name: "Villager"
    )
    assert_predicate speaker, :valid?, "every other kind may stand alone"
    assert_equal %w[member persona ingress system], Speaker::KINDS,
      "a bare speaker's whole identity is its own row: no User, no bridge, not the kernel"
  end

  test "one active turn per conversation is an index, not a promise" do
    build_turn(position: 0, status: "running")

    assert_raises(ActiveRecord::RecordNotUnique) do
      force_turn(position: 1, status: "pending")
    end
  end

  # A soft-deleted turn keeps its slot forever, so the timeline never
  # renumbers — the predecessor's discipline, adopted deliberately.
  test "a position slot is never reused, even by a soft delete" do
    concealed = build_turn(position: 0)
    build_turn(position: 1)
    concealed.update!(deleted_at: Time.current)

    assert_raises(ActiveRecord::RecordNotUnique) { force_turn(position: 0) }
  end

  test "one active candidate per turn is the predecessor's index, verbatim" do
    turn = build_turn(position: 0, status: "running")
    ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "running", source: "inference"
    )

    assert_raises(ActiveRecord::RecordNotUnique) do
      ConversationTurnVariant.create!(
        account: @account, conversation_turn: turn,
        position: 1, status: "pending", source: "inference"
      )
    end
  end

  test "a deleted variant frees its position slot; a live one holds it" do
    turn = build_turn(position: 0)
    ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "manual",
      deleted_at: Time.current
    )

    assert ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "edit"
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      ConversationTurnVariant.create!(
        account: @account, conversation_turn: turn,
        position: 0, status: "completed", source: "manual"
      )
    end
  end

  # THE MODEL-LEVEL BACKSTOP behind the tail rule (the schema attack's
  # must-fix): whatever service forgets the guard, a turn with a local
  # successor — live or concealed — refuses status and active-variant
  # mutation here.
  test "a turn with a successor is frozen against status and variant flips" do
    first = build_turn(position: 0)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: first,
      position: 0, status: "completed", source: "manual"
    )
    build_turn(position: 1)

    first.status = "running"
    assert_not first.valid?
    assert_includes first.errors[:base], "a turn with a successor is frozen"

    first.reload.active_variant = variant
    assert_not first.valid?

    # And the tail itself reopens freely — regenerate's terminal-to-running
    # is the recorded deliberate exception, possible only where no successor
    # exists.
    tail = @conversation.conversation_turns.live.order(:position).last
    tail.status = "running"
    assert_predicate tail, :valid?
  end

  test "tail? is the shared test every content verb composes" do
    first = build_turn(position: 0)
    second = build_turn(position: 1)

    assert_not first.tail?
    assert second.tail?

    # The newest message leaves by HARD delete, and the tail steps back over the vacated position.
    second.destroy!
    assert first.reload.tail?

    # A CONCEALED successor still pins: mid-history concealment followed by
    # the apex's hard delete leaves a hidden row above the live one, and
    # verbs must aim at that row (restore or hard-delete it), not below it.
    middle = build_turn(position: 2)
    apex = build_turn(position: 3)
    middle.update!(deleted_at: Time.current)
    apex.destroy!
    assert_not first.reload.tail?, "the concealed row above still freezes below"
    assert_not middle.reload.tail?, "a concealed row is never the tail itself"
  end

  # THE LOCALITY GUARD: an override describes an INHERITED turn only — a
  # local turn's view-state lives on its own row, and an out-of-bounds
  # ancestor turn was never part of this child's prefix.
  test "an override refuses local turns and out-of-bounds ancestors" do
    parent_turn = build_turn(position: 0)
    beyond = build_turn(position: 5)
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 3
    )

    # Above the boundary, as the position guard now demands of local rows.
    local = build_turn(conversation: child, position: 4)
    override = ConversationTurnOverride.new(
      account: @account, conversation: child,
      conversation_turn: local, visibility: "hidden"
    )
    assert_not override.valid?, "a local turn's view-state lives on its own row"

    in_bounds = ConversationTurnOverride.new(
      account: @account, conversation: child,
      conversation_turn: parent_turn, visibility: "excluded_from_context"
    )
    assert_predicate in_bounds, :valid?

    past_boundary = ConversationTurnOverride.new(
      account: @account, conversation: child,
      conversation_turn: beyond, visibility: "hidden"
    )
    assert_not past_boundary.valid?, "position 5 was never part of a prefix cut at 3"
  end

  # THE LIVENESS PIN: the database itself enforces leaves-first reap. The
  # refusal is SQLSTATE 23001 — explicit RESTRICT, not NO ACTION's 23503 —
  # so the future root reaper's per-row rescue matches PG::RestrictViolation
  # BY CAUSE, exactly as ContentFragment.reap documents for the identical FK
  # shape. Rails maps only 23503 onto InvalidForeignKey; asserting the cause
  # here is what keeps the wrong rescue from ever being copied.
  test "a pinned ancestor cannot be destroyed while a descendant lives" do
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0
    )

    error = assert_raises(ActiveRecord::StatementInvalid) { @conversation.destroy }
    assert_kind_of PG::RestrictViolation, error.cause,
      "the pin speaks 23001, the SQLSTATE the house per-row rescue matches"

    child.destroy!
    assert @conversation.reload.destroy, "the leaf's death releases the pin"
  end

  # A variant cannot hard-delete alone, and a mid-history turn cannot hard-delete either: nullified
  # lineage pointers would lose history for the owner and descendants. Guards run before dependent
  # deletion; a whole-conversation cascade may proceed.
  test "mid-history and variant hard deletes are refused with children intact" do
    turn = build_turn(position: 0)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    turn.update!(active_variant: variant)
    build_turn(position: 1)

    # `destroy` swallows the guard's exception into a false return (the
    # callbacks-layer rescue); `destroy!` re-raises it with our message.
    assert_not variant.destroy, "a bare variant destroy is refused"
    assert_raises(ActiveRecord::RecordNotDestroyed) { turn.destroy! }
    assert ConversationTurnVariant.exists?(variant.id),
      "the refusal ran before the cascade: nothing died"
    assert_equal variant.id, turn.reload.active_variant_id

    assert @conversation.destroy,
      "the conversation's own cascade is the sanctioned path through both guards"
    assert_not ConversationTurn.exists?(turn.id)
    assert_not ConversationTurnVariant.exists?(variant.id)
  end

  # A turn with no successor may hard-delete; a mid-history turn is concealed so inherited history
  # remains intact.
  test "the apex hard-deletes and never conceals; mid-history is the reverse" do
    first = build_turn(position: 0)
    apex = build_turn(position: 1)

    apex.deleted_at = Time.current
    assert_not apex.valid?, "the apex never conceals; removing it is hard delete"
    apex.deleted_at = nil

    first.deleted_at = Time.current
    assert_predicate first, :valid?, "mid-history conceals freely"
    first.deleted_at = nil

    assert apex.destroy, "the apex hard-deletes"
    assert first.reload.tail?, "and the tail steps back over the vacated slot"
  end

  # THE CREATE BACKSTOP (the verification round's find): creation was the
  # one verb without one. Above a running turn it wedges the runner against
  # its own terminal write; into a below-live gap it rewrites the frozen
  # row-set restore-coherence depends on. Arrivals wait in the queue;
  # positions come from the head.
  test "a new turn refuses to land above a running one or below the top" do
    build_turn(position: 0, status: "running")

    above_running = ConversationTurn.new(
      account: @account, conversation: @conversation, position: 1,
      kind: "message", role: "user", status: "completed",
      speaker: @actor, control_owner_user: @user
    )
    assert_not above_running.valid?, "the queue holds mid-run arrivals"

    done = Conversation.create!(workspace: @workspace, creating_user: @user)
    build_turn(conversation: done, position: 0)
    gap = build_turn(conversation: done, position: 1)
    gap.destroy!
    build_turn(conversation: done, position: 2)

    into_the_gap = ConversationTurn.new(
      account: @account, conversation: done, position: 1,
      kind: "message", role: "user", status: "completed",
      speaker: @actor, control_owner_user: @user
    )
    assert_not into_the_gap.valid?,
      "a vacated slot below the top never refills; the head allocates above"
  end

  # The pinned-top corridor under the PIN-SCOPED CONCEAL EXCEPTION (ruled
  # 2026-08-28): fork at P+1 bounds the child at P; hard-deleting P+1
  # leaves an apex the bound covers. Delete refuses — a descendant reads
  # the row — and exactly there conceal OPENS, so truncate-below-a-live-
  # branch works to any depth while the checkpoint fork's reads stay
  # untouched (descendants never consult the shared row's view columns).
  test "a bound-covered apex conceals exactly where it cannot hard-delete" do
    prefix = build_turn(position: 0)
    pinned = build_turn(position: 1)
    apex = build_turn(position: 2)
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 1
    )
    apex.destroy!

    assert_raises(ActiveRecord::RecordNotDestroyed) { pinned.reload.destroy! }
    assert pinned.reload.update(deleted_at: Time.current),
      "the one verb pair that would otherwise both refuse"
    assert prefix.reload.update(deleted_at: Time.current),
      "and everything below is ordinary mid-history"

    assert_equal [0, 1], child.timeline.entries(surface: :timeline).map(&:position),
      "the checkpoint fork still reads its whole prefix"

    assert prefix.reload.update(deleted_at: nil), "restore climbs bottom-up"
    assert pinned.reload.update(deleted_at: nil)
  end

  test "a running apex refuses hard delete until the work ends" do
    build_turn(position: 0)
    running = build_turn(position: 1, status: "running")

    assert_raises(ActiveRecord::RecordNotDestroyed) { running.destroy! }

    running.update!(status: "canceled")
    assert running.destroy, "terminal now; the undo verb proceeds"
  end

  # A fork at P adopts P as the child's own copy and bounds the closure at
  # P-1 — so the source's apex stays free to die, and the bound pins exactly
  # the rows the child actually reads.
  test "the closure bound pins exactly the rows a descendant reads" do
    prefix = build_turn(position: 0)
    apex = build_turn(position: 1)
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0
    )

    assert apex.destroy, "above the bound: the child reads its own adopted copy"
    assert_raises(ActiveRecord::RecordNotDestroyed) { prefix.reload.destroy! }
  end

  # Concealment ordering: the turn-side "active variant is live" rule runs
  # only on TURN saves, so without this refusal a variant-side deleted_at
  # write would violate that invariant at rest. The pointer moves first.
  test "the active variant refuses concealment until the pointer moves" do
    turn = build_turn(position: 0)
    kept = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    turn.update!(active_variant: kept)

    kept.deleted_at = Time.current
    assert_not kept.valid?, "the pointer still names this row"
    kept.deleted_at = nil

    replacement = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 1, status: "completed", source: "inference"
    )
    turn.update!(active_variant: replacement)
    assert kept.reload.update(deleted_at: Time.current),
      "once the pointer moved, the old candidate may hide"
  end

  # Replay evidence ages out on the DB clock; a receipt inside its window is
  # untouchable. The recurring wiring rides the storage-reaper test.
  test "conversation command receipts reap strictly behind the replay window" do
    stale, fresh = [25.hours.ago, 1.minute.ago].map do |created_at|
      receipt = ConversationCommandReceipt.create!(
        account: @account, workspace: @workspace, host: @conversation,
        acting_user: @user, operation: "conversation_create",
        idempotency_key: SecureRandom.uuid, request_digest: SecureRandom.hex(32),
        response_status: 201, response_body: { "public_id" => SecureRandom.uuid }
      )
      receipt.update_column(:created_at, created_at)
      receipt
    end

    assert_equal 1, ConversationCommandReceipt.reap
    assert_not ConversationCommandReceipt.exists?(stale.id)
    assert ConversationCommandReceipt.exists?(fresh.id)
  end

  test "a conversation never appears in its own closure" do
    loop_row = ConversationAncestry.new(
      account: @account, conversation: @conversation,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 0
    )
    assert_not loop_row.valid?
  end

  test "an input pairs steering state with its target and blocked with its reason" do
    turn = build_turn(position: 0, status: "running")
    base = {
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user,
    }

    steering = ConversationInput.new(**base, state: "steering")
    assert_not steering.valid?, "steering names its target"

    steered = ConversationInput.new(**base, state: "steering", steering_target_turn: turn)
    assert_predicate steered, :valid?

    pending_with_target = ConversationInput.new(
      **base, state: "pending", steering_target_turn: turn
    )
    assert_not pending_with_target.valid?, "a pending row carries no target"

    blocked = ConversationInput.new(**base, state: "blocked")
    assert_not blocked.valid?, "blocked names its reason"
  end

  test "the input queue's FIFO order is an index" do
    base = {
      account: @account, host: @conversation,
      kind: "message", speaker: @actor, authoring_user: @user,
    }
    ConversationInput.create!(**base, queue_position: 0)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ConversationInput.create!(**base, queue_position: 0)
    end
  end

  # Regression coverage for content and lineage integrity guards.

  test "destroying a conversation clears its active pointer instead of raising" do
    turn = build_turn(position: 0)
    @conversation.update!(active_turn: turn)

    assert @conversation.destroy, "the nullify FK is what makes teardown possible at all"
  end

  # Variant hard delete only rides a cascade, so the proof rides the
  # conversation: the origin chain's nullify FK must not turn teardown into
  # an ordering puzzle at any grain.
  test "a regeneration chain does not block the conversation cascade" do
    turn = build_turn(position: 0)
    v1 = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 1, status: "completed", source: "inference", origin_variant: v1
    )

    assert @conversation.destroy,
      "the origin chain is weak provenance, not a destroy order puzzle"
    assert_not ConversationTurn.exists?(turn.id)
  end

  test "a steering input dies with the turn it aims at" do
    turn = build_turn(position: 0, status: "running")
    ConversationInput.create!(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user,
      state: "steering", steering_target_turn: turn
    )

    assert @conversation.destroy,
      "the RESTRICT FK stays as the DB backstop; the association clears it first"
  end

  test "the account teardown takes a fork tree and its speakers, descendants first" do
    parent_turn = build_turn(position: 0)
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: -1
    )
    ConversationCommandReceipt.create!(
      account: @account, workspace: @workspace, host: child,
      acting_user: @user, operation: "fork", idempotency_key: "k",
      request_digest: "a" * 64, response_status: 201
    )

    assert parent_turn.persisted?
    assert @account.destroy,
      "descending id is the fork trees' topological order; receipts and speakers ride along"
  end

  test "a restore is refused where the turn would not again be the tail" do
    first = build_turn(position: 0)
    successor = build_turn(position: 1)
    first.update!(deleted_at: Time.current)

    first.deleted_at = nil
    assert_not first.valid?,
      "restoring under a live successor renders a context nobody generated against"

    successor.destroy!
    first.deleted_at = nil
    assert_predicate first, :valid?,
      "with the successor physically gone, the restore lands back on the tail"
  end

  # The permissive half of the restore rule, bitten: only LIVE rows above
  # block a restore, so stacked concealed rows come back bottom-up.
  test "restore chains climb bottom-up through stacked concealed rows" do
    build_turn(position: 0)
    lower = build_turn(position: 1)
    upper = build_turn(position: 2)
    apex = build_turn(position: 3)
    lower.update!(deleted_at: Time.current)
    upper.update!(deleted_at: Time.current)
    apex.destroy!

    assert lower.reload.update(deleted_at: nil),
      "a concealed row above does not block the restore — live-above only"
    assert upper.reload.update(deleted_at: nil), "then the next climbs"
  end

  # The freeze counts concealed successors too — restore is only coherent
  # because nothing below a hidden row may move while it hides.
  test "a concealed successor still freezes the turn below it" do
    first = build_turn(position: 0)
    middle = build_turn(position: 1)
    apex = build_turn(position: 2)
    middle.update!(deleted_at: Time.current)
    apex.destroy!

    frozen = first.reload
    frozen.status = "running"
    assert_not frozen.valid?, "only physical removal unfreezes"

    minted = ConversationTurnVariant.new(
      account: @account, conversation_turn: first,
      position: 0, status: "completed", source: "inference"
    )
    assert_not minted.valid?, "no new variant work under a concealed successor either"

    middle.reload.destroy!
    thawed = first.reload
    thawed.status = "running"
    assert_predicate thawed, :valid?, "the concealed pin is gone; the tail reopens"
  end

  test "an active turn cannot be soft-deleted and a running variant cannot either" do
    turn = build_turn(position: 0, status: "running")
    force_turn(position: 1)
    turn.deleted_at = Time.current
    assert_not turn.valid?, "the one-active index counts deleted rows; end the work first"

    done = Conversation.create!(workspace: @workspace, creating_user: @user)
    t = build_turn(conversation: done, position: 0)
    running = ConversationTurnVariant.create!(
      account: @account, conversation_turn: t,
      position: 0, status: "running", source: "inference"
    )
    running.deleted_at = Time.current
    assert_not running.valid?, "the one-active-candidate index EXCLUDES deleted rows"
  end

  test "a fork child's local turns live strictly above the inherited range" do
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    ConversationAncestry.create!(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: 3
    )

    inside = ConversationTurn.new(
      account: @account, conversation: child, position: 2, kind: "message",
      role: "user", status: "completed",
      speaker: @actor, control_owner_user: @user
    )
    assert_not inside.valid?, "a local row inside the prefix collides in every assembled read"

    above = ConversationTurn.new(
      account: @account, conversation: child, position: 4, kind: "message",
      role: "user", status: "completed",
      speaker: @actor, control_owner_user: @user
    )
    assert_predicate above, :valid?
  end

  test "the empty-prefix fork records its pin at boundary -1" do
    child = Conversation.create!(workspace: @workspace, creating_user: @user)
    pin = ConversationAncestry.new(
      account: @account, conversation: child,
      ancestor_conversation: @conversation, depth: 1, boundary_position: -1
    )
    assert_predicate pin, :valid?, "a fork at position 0 reads nothing and still pins"
  end

  test "a soft-deleted variant cannot be the active one" do
    turn = build_turn(position: 0)
    ghost = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "manual", deleted_at: Time.current
    )

    turn.active_variant = ghost
    assert_not turn.valid?, "the reader filters deleted variants; the pointer must too"
  end

  # VARIANT RESTORE: concealment's mirror. The only refusal is an occupied slot — an honest
  # validation error, never a raw unique-index violation surfacing from below.
  test "a concealed variant restores unless a live sibling took its slot" do
    turn = build_turn(position: 0)
    original = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    original.update!(deleted_at: Time.current)
    usurper = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )

    original.deleted_at = nil
    assert_not original.valid?, "the freed slot was retaken; the refusal is honest"

    usurper.update!(deleted_at: Time.current)
    assert original.reload.update(deleted_at: nil),
      "with the slot free again, restore is concealment's exact mirror"
  end

  test "active turn and steering target are local, never a foreign splice" do
    other = Conversation.create!(workspace: @workspace, creating_user: @user)
    foreign = build_turn(conversation: other, position: 0, status: "running")

    @conversation.active_turn = foreign
    assert_not @conversation.valid?

    input = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user,
      state: "steering", steering_target_turn: foreign
    )
    assert_not input.valid?
  end

  test "a frozen prefix turn takes no new variant work" do
    first = build_turn(position: 0)
    build_turn(position: 1)

    minted = ConversationTurnVariant.new(
      account: @account, conversation_turn: first,
      position: 0, status: "running", source: "inference"
    )
    assert_not minted.valid?,
      "a regeneration must not land mid-history through the variant table"
  end

  test "a tombstoned recipient refuses new mail" do
    @conversation.update!(tombstoned_at: Time.current)

    input = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user
    )
    assert_not input.valid?, "mail nothing will drain is mail nobody agreed to lose"
  end

  # Archived is the conversation's recycle bin — read-only and reversible. Unlike the tombstone's
  # absence, the refusal names its reason: the sender can see the archived row.
  test "an archived recipient refuses new mail until unarchived" do
    @conversation.update!(archived_at: Time.current)

    input = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user
    )
    assert_not input.valid?
    assert input.errors.of_kind?(:host, :conversation_archived), "the reason may speak"

    @conversation.update!(archived_at: nil)
    assert_predicate input, :valid?, "unarchive restores everything; the bin is reversible"
  end

  # THE KERNEL CARVE-OUT (ruled 2026-08-28): archive is a user gesture that never blocks the
  # in-flight round's completion — the KERNEL'S OWN mail passes an archived recipient (Codex:
  # "Collaboration may resume an archived descendant without unarchiving it"; Claude Code's mailbox
  # has no recipient gate at all). The carve-out keys on the kernel's origin SET, never on the
  # sender stamp: a peer's `send` carries the stamp too and an archived recipient refuses it. The
  # tombstone still seals everything.
  test "the kernel's own mail passes an archived recipient by origin, never by stamp; the tombstone still seals" do
    @conversation.update!(archived_at: Time.current)
    base = {
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user,
      sender_conversation_public_id: SecureRandom.uuid,
    }

    stamped = ConversationInput.new(**base)
    assert_not stamped.valid?, "a stamp alone is a peer's send: the bin refuses it"
    assert stamped.errors.of_kind?(:host, :conversation_archived)

    child = ConversationInput.new(**base, origin: ConversationInput::CHILD_ORIGIN)
    assert_predicate child, :valid?,
      "the subagent's terminal notice is part of the round archive let finish"

    @conversation.update!(tombstoned_at: Time.current)
    assert_not child.valid?
    assert child.errors.of_kind?(:host, :not_found), "absence, even for the kernel"
  end

  test "a tombstoned recipient answers absence even when also archived" do
    @conversation.update!(archived_at: Time.current, tombstoned_at: Time.current)

    input = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user
    )
    assert_not input.valid?
    assert input.errors.of_kind?(:host, :not_found)
    assert_not input.errors.of_kind?(:host, :conversation_archived),
      "absence never names a reason"
  end

  test "the archive scopes split the bin from the default surface" do
    other = Conversation.create!(workspace: @workspace, creating_user: @user)
    @conversation.update!(archived_at: Time.current)

    assert_includes Conversation.archived, @conversation
    assert_not_includes Conversation.unarchived, @conversation
    assert_includes Conversation.unarchived, other

    @conversation.update!(archived_at: nil)
    assert_includes Conversation.unarchived, @conversation
  end

  test "a malformed uuid fence is an error, never a silent absence" do
    input = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user,
      expected_tail_turn_public_id: "not-a-uuid"
    )
    assert_not input.valid?,
      "the pg cast nils a malformed uuid, which would delete the caller's fence"
  end

  # The cross-account half of user_must_share_the_account is unreachable in a
  # singleton-account install (index_accounts_singleton), so the guard stands
  # as defense in depth and only the destroy story is bitten here.
  test "an actor with recorded speech refuses to die" do
    build_turn(position: 0)

    assert_not @actor.destroy
    assert_not_empty @actor.errors
  end

  test "conversation and actor metadata are bounded like every other bag" do
    @conversation.metadata = { "pad" => "x" * 4_096 }
    assert_not @conversation.valid?

    @actor.metadata = { "pad" => "x" * 4_096 }
    assert_not @actor.valid?
  end

  test "the substrate gains its two conversation owners with their roles" do
    turn = build_turn(position: 0)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "manual"
    )

    content = ContentBody.new(conversation_turn_variant: variant, role: "content")
    reasoning = ContentBody.new(conversation_turn_variant: variant, role: "reasoning")
    assert_predicate content, :valid?
    assert_predicate reasoning, :valid?
    assert_equal @account.id, content.tap(&:valid?).account_id,
      "the account derives from the owner"

    wrong_role = ContentBody.new(conversation_turn_variant: variant, role: "input")
    assert_not wrong_role.valid?

    input = ConversationInput.create!(
      account: @account, host: @conversation, queue_position: 0,
      kind: "message", speaker: @actor, authoring_user: @user
    )
    staged = ContentBody.new(conversation_input: input, role: "input")
    assert_predicate staged, :valid?

    two_owners = ContentBody.new(
      conversation_input: input, conversation_turn_variant: variant, role: "input"
    )
    assert_not two_owners.valid?, "exactly one owner, the standing rule"
  end
end
