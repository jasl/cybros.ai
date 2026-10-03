require "test_helper"

# The archive → tombstone → reap lifecycle: subagent children are lifecycle FOLLOWERS (the parent's
# verbs stamp the whole tree; children never take verbs directly), fork children are independent
# (the pin defers reap; the verbs never touch them).
class Conversations::LifecycleTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @root = create_conversation
    @child = create_conversation(parent: @root)
    @grandchild = create_conversation(parent: @child)
  end

  def create_conversation(parent: nil)
    Conversation.create!(
      workspace: @workspace, creating_user: @user,
      parent_conversation: parent,
      parent_conversation_public_id: parent&.public_id
    )
  end

  def build_turn(conversation:, position: 0, status: "completed")
    @actor ||= Actor.create!(
      account: @account, kind: "member", user: @user,
      channel_key: "console", external_id: @user.public_id, display_name: "Member"
    )
    ConversationTurn.create!(
      account: @account, conversation: conversation, position: position,
      kind: "message", role: "user", status: status,
      speaker_actor: @actor, control_owner_user: @user
    )
  end

  # ── archive / unarchive ────────────────────────────────────────────────

  test "archive stamps the whole subagent tree and unarchive blanket-clears it" do
    result = Conversations::Archive.call(conversation: @root)

    assert_predicate result, :accepted?
    assert [@root, @child, @grandchild].all? { |c| c.reload.archived? },
      "the follower tree is stamped transitively"

    undone = Conversations::Unarchive.call(conversation: @root)
    assert_predicate undone, :accepted?
    assert [@root, @child, @grandchild].none? { |c| c.reload.archived? }
  end

  test "a subagent child never takes a lifecycle verb directly" do
    [Conversations::Archive, Conversations::Unarchive, Conversations::Tombstone].each do |verb|
      result = verb.call(conversation: @child)
      assert_equal :subagent_follows_parent, result.outcome, verb.name
    end
  end

  # A record in hand locks itself: a row that vanished under the caller is the family 404, not a
  # service outcome.
  test "a lifecycle verb on a vanished row raises RecordNotFound" do
    lone = create_conversation
    Conversation.where(id: lone.id).delete_all

    assert_raises(ActiveRecord::RecordNotFound) { Conversations::Archive.call(conversation: lone) }
  end

  test "archive skips tombstoned members and refuses a tombstoned root as absence" do
    @grandchild.update!(tombstoned_at: 1.day.ago)

    assert_predicate Conversations::Archive.call(conversation: @root), :accepted?
    assert_not @grandchild.reload.archived?, "the condemned phase is beyond the bin"

    @root.reload.update!(tombstoned_at: Time.current)
    assert_equal :not_found, Conversations::Archive.call(conversation: @root).outcome
  end

  test "a fork child is untouched by its source's archive" do
    fork_child = create_conversation
    ConversationAncestry.create!(
      account: @account, conversation: fork_child,
      ancestor_conversation: @root, depth: 1, boundary_position: -1
    )

    Conversations::Archive.call(conversation: @root)

    assert_not fork_child.reload.archived?, "fork children are independent conversations"
  end

  # ── tombstone ──────────────────────────────────────────────────────────

  test "tombstone stamps the tree, composes over archive, and repeats as absence" do
    Conversations::Archive.call(conversation: @root)

    result = Conversations::Tombstone.call(conversation: @root)

    assert_predicate result, :accepted?
    assert [@root, @child, @grandchild].all? { |c| c.reload.tombstoned? }
    stamped_at = @root.reload.tombstoned_at

    repeat = Conversations::Tombstone.call(conversation: @root)
    assert_equal :already_tombstoned, repeat.outcome
    assert_equal stamped_at, @root.reload.tombstoned_at,
      "a repeat never extends the reclamation clock"
  end

  test "live work anywhere in the tree refuses the tombstone" do
    build_turn(conversation: @grandchild, status: "running")

    result = Conversations::Tombstone.call(conversation: @root)

    assert_equal :conversation_busy, result.outcome
    assert_not @root.reload.tombstoned?
    assert_not @grandchild.reload.tombstoned?
  end

  # An end that consumers can replay must be persisted as an event with the lifecycle change.

  def ended_items(conversation)
    ConversationEventItem.where(host: conversation, item_type: "conversation_ended").order(:sequence)
  end

  test "archive narrates conversation_ended on every member it stamps, in the verb's transaction" do
    streams = capture_broadcasts("agent_api:v1:conversation:#{@root.public_id}:events") do
      assert_predicate Conversations::Archive.call(conversation: @root), :accepted?
    end

    [@root, @child, @grandchild].each do |member|
      item = ended_items(member).sole
      assert_equal({ "reason" => "archived", "conversation_public_id" => member.public_id }, item.payload,
        "each stamped member's own feed says it ended, naming itself")
    end
    assert_equal ["conversation_ended"], streams.map { |message| message.dig("event", "type") },
      "the item rides the cable like every other item"
  end

  test "a follower narrowed to lifecycle still hears the end" do
    lifecycle = capture_broadcasts("agent_api:v1:conversation:#{@root.public_id}:lifecycle") do
      Conversations::Archive.call(conversation: @root)
    end

    assert_equal ["conversation_ended"], lifecycle.map { |message| message.dig("event", "type") }
  end

  test "archive narrates nothing on a member it left alone, and twice never" do
    @grandchild.update!(tombstoned_at: 1.day.ago)

    Conversations::Archive.call(conversation: @root)
    assert_empty ended_items(@grandchild), "the condemned member was not stamped, so it is not told"

    Conversations::Unarchive.call(conversation: @root)
    Conversations::Archive.call(conversation: @root)
    assert_equal 2, ended_items(@root).count, "each archive is its own end; nothing is deduplicated"
  end

  test "tombstone narrates conversation_ended as the feed's last item" do
    result = Conversations::Tombstone.call(conversation: @root)

    assert_predicate result, :accepted?
    item = ended_items(@root).sole
    assert_equal({ "reason" => "tombstoned", "conversation_public_id" => @root.public_id }, item.payload)
    assert_equal item.sequence, ConversationEventItem.where(host: @root).maximum(:sequence),
      "nothing follows it on the feed"
    assert_equal 1, ended_items(@child).count
  end

  test "a refused verb narrates no end" do
    build_turn(conversation: @grandchild, status: "running")

    assert_equal :conversation_busy, Conversations::Tombstone.call(conversation: @root).outcome
    assert_empty ended_items(@root)
    assert_equal :subagent_follows_parent, Conversations::Archive.call(conversation: @child).outcome
    assert_empty ended_items(@child)
  end

  # ── reap ───────────────────────────────────────────────────────────────

  def age_tombstone!(conversation)
    Conversations::Tombstone.call(conversation: conversation)
    Conversation.where(id: Conversations::SubagentTree.member_ids(conversation))
      .update_all(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
  end

  test "an aged tombstoned tree reaps, each member as its own aggregate" do
    build_turn(conversation: @root)
    age_tombstone!(@root)

    result = Conversations::Reap.call(batch: 10)

    assert_equal 3, result.value[:reaped]
    assert_equal 0, Conversation.count
  end

  test "a fresh tombstone waits out its retention window" do
    Conversations::Tombstone.call(conversation: @root)

    result = Conversations::Reap.call(batch: 10)

    assert_equal 3, result.value[:scanned]
    assert_equal 0, result.value[:reaped]
    assert_equal 3, Conversation.count
  end

  test "a pinned ancestor is a level-triggered skip until its descendant dies" do
    lone = create_conversation
    fork_child = create_conversation
    ConversationAncestry.create!(
      account: @account, conversation: fork_child,
      ancestor_conversation: lone, depth: 1, boundary_position: -1
    )
    Conversations::Tombstone.call(conversation: lone)
    Conversation.where(id: lone.id)
      .update_all(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)

    assert_equal 0, Conversations::Reap.call(batch: 10).value[:reaped]
    assert Conversation.exists?(lone.id), "the pin defers physical reap"

    fork_child.destroy!
    assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]
    assert_not Conversation.exists?(lone.id), "the descendant's death releases the row"
  end

  test "nonterminal invocation work fences reclamation" do
    lone = create_conversation
    turn = build_turn(conversation: lone)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    holder = OneShot.create!(
      account: @account, workspace: @workspace, creating_user: @user,
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: holder)
    # The reply lane's ownership column is the fence's key; stamped directly
    # because the full lane has its own end-to-end test.
    ModelInvocation.where(id: invocation.id)
      .update_all(status: "running", conversation_id: lone.id)
    variant.update!(model_invocation_id: invocation.id)
    Conversations::Tombstone.call(conversation: lone)
    Conversation.where(id: lone.id)
      .update_all(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)

    assert_equal 0, Conversations::Reap.call(batch: 10).value[:reaped]
    assert Conversation.exists?(lone.id), "a running result-writer must never find its aggregate gone"

    ModelInvocation.where(id: invocation.id).update_all(status: "completed")
    assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]
  end

  # ── The side conversation: DELETE reaps at once; the parent cascades ──

  def build_settled_reply!(conversation, position: 0)
    turn = build_turn(conversation: conversation, position: position)
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "completed", source: "inference"
    )
    turn.update!(active_variant: variant)
    conversation.update!(timeline_position_head: position + 1)
    turn
  end

  def fork!(source, side: false, turn: nil)
    result = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: source.reload, turn_public_id: turn&.public_id, variant_public_id: nil,
      acting_user: @user, title: nil, side: side
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value
  end

  # A reply in flight on the side: a running turn over a running invocation
  # whose attempt has not settled — the fence the reap honours.
  def run_reply!(conversation)
    turn = build_turn(conversation: conversation, position: conversation.timeline_position_head,
      status: "running")
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn,
      position: 0, status: "running", source: "inference"
    )
    holder = OneShot.create!(
      account: @account, workspace: @workspace, creating_user: @user, workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: holder)
    # Re-owned as the reply's own invocation: one purpose owner, the
    # conversation, so the kernel's cancel can terminalize it.
    ModelInvocation.where(id: invocation.id).update_all(
      status: "running", conversation_id: conversation.id, one_shot_id: nil,
      purpose: ModelInvocation::CONVERSATION_REPLY_PURPOSE
    )
    variant.update!(model_invocation_id: invocation.id)
    turn.update!(active_variant: variant)
    conversation.update!(active_turn: turn, timeline_position_head: turn.position + 1)
    attempt = ModelInvocationAttempt.create!(
      account: @account, model_invocation: invocation, ordinal: 1,
      admission_shape: "admitted_free", deadline_at: 10.minutes.from_now,
      provider_started_at: Time.current, status: "running", settlement_state: "pending",
      consumer_public_id: @user.public_id, payer_public_id: @user.public_id
    )
    [invocation.reload, attempt]
  end

  test "DELETE on an idle side tombstones and reaps in one call" do
    lone = create_conversation
    build_settled_reply!(lone)
    side = fork!(lone, side: true)

    result = Conversations::Tombstone.call(conversation: side)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_not Conversation.exists?(side.id), "tombstone AND reap at once: no 30-day clock for a side"
    assert_not ConversationAncestry.where(ancestor_conversation_id: lone.id).exists?,
      "the pin dies with the side"
    assert Conversation.exists?(lone.id)
    assert_not lone.reload.tombstoned?, "the parent is untouched"
  end

  test "DELETE on a running side cancels first; the reap waits only for the settlement fence" do
    lone = create_conversation
    build_settled_reply!(lone)
    side = fork!(lone, side: true)
    invocation, attempt = run_reply!(side)

    result = Conversations::Tombstone.call(conversation: side)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "canceled", invocation.reload.status, "the kernel's own cancel, no standing asked"
    assert_predicate side.reload, :tombstoned?
    assert Conversation.exists?(side.id), "a pending settlement fences the physical reap"

    assert_equal 0, Conversations::Reap.call(batch: 10).value[:reaped]
    attempt.update!(settlement_state: "settled", status: "canceled", terminal_at: Time.current)
    ModelInvocation.where(id: invocation.id).update_all(status: "canceled")

    sweep = Conversations::Reap.call(batch: 10)
    assert_equal 1, sweep.value[:reaped], "the sweep's candidates carry a tombstoned side at any age"
    assert_not Conversation.exists?(side.id)
  end

  test "the parent's archive and tombstone reap their sides first; a side never pins the parent's reap" do
    lone = create_conversation
    target = build_settled_reply!(lone)
    side = fork!(lone, side: true)
    plain_child = fork!(lone, turn: target)

    assert_predicate Conversations::Archive.call(conversation: lone), :accepted?
    assert_not Conversation.exists?(side.id), "the parent's archive reaps its side"
    assert_predicate lone.reload, :archived?
    assert_not plain_child.reload.archived?, "the plain fork child stays independent"

    second_side = fork!(lone, side: true)
    result = Conversations::Tombstone.call(conversation: lone)
    assert_predicate result, :accepted?, result.outcome.inspect
    assert_not Conversation.exists?(second_side.id), "the parent's tombstone reaps its side"
    assert_predicate lone.reload, :tombstoned?

    Conversation.where(id: lone.id).update_all(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
    assert_equal 0, Conversations::Reap.call(batch: 10).value[:reaped]
    assert Conversation.exists?(lone.id), "the plain child still pins, as before"
    plain_child.reload.destroy!
    assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]
  end

  test "a running side under the parent's tombstone is cancelled, never a busy refusal" do
    lone = create_conversation
    build_settled_reply!(lone)
    side = fork!(lone, side: true)
    invocation, _attempt = run_reply!(side)

    result = Conversations::Tombstone.call(conversation: lone)

    assert_predicate result, :accepted?, result.outcome.inspect
    assert_equal "canceled", invocation.reload.status
    assert_predicate side.reload, :tombstoned?, "fenced by its settlement, tombstoned all the same"
    assert_predicate lone.reload, :tombstoned?
  end

  test "archive and unarchive on a side refuse side_conversation" do
    lone = create_conversation
    build_settled_reply!(lone)
    side = fork!(lone, side: true)

    assert_equal :side_conversation, Conversations::Archive.call(conversation: side).outcome
    assert_equal :side_conversation, Conversations::Unarchive.call(conversation: side).outcome
    assert_not side.reload.archived?
    assert Conversation.exists?(side.id)
  end

  # ── The access carrier leaves with the row ───────────────

  def grant!(conversation, **levels)
    levels.each { |name, level| conversation.conversation_access_entries.create!(user: users(name), level: level) }
  end

  test "the physical reap deletes a conversation's access entries with it" do
    lone = create_conversation
    grant!(lone, curator: "read", owner: "none")
    age_tombstone!(lone)

    assert_difference -> { ConversationAccessEntry.count }, -2 do
      assert_equal 1, Conversations::Reap.call(batch: 10).value[:reaped]
    end
    assert_not Conversation.exists?(lone.id)
  end

  test "DELETE on a side takes the side's copied entries and leaves the parent's" do
    lone = create_conversation
    grant!(lone, curator: "read", owner: "none")
    build_settled_reply!(lone)
    side = fork!(lone, side: true)
    assert_equal 2, side.conversation_access_entries.count, "the side copied the parent's rows"

    assert_difference -> { ConversationAccessEntry.count }, -2 do
      assert_predicate Conversations::Tombstone.call(conversation: side), :accepted?
    end
    assert_not Conversation.exists?(side.id)
    assert_equal 2, lone.conversation_access_entries.count, "the parent's rows are untouched"
  end
end
