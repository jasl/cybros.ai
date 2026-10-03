require "test_helper"
require_relative "../../test_helpers/inputs_apply_next_test_helper"

class Conversations::InputsApplyNextTest < ActiveSupport::TestCase
  include InputsApplyNextTestHelper

  test "the head materializes into a completed turn and the input dies with its body" do
    input = accept!(text: "materialize me")
    fragment_ids = input.content_body.content_body_entries.pluck(:content_fragment_id)

    assert_equal 1, drain!

    assert_not ConversationInput.exists?(input.id), "the row IS the message; the turn is now"
    turn = @conversation.conversation_turns.sole
    assert_equal 0, turn.position
    assert_equal "completed", turn.status
    assert_equal "visible", turn.visibility
    assert_equal @user.id, turn.control_owner_user_id

    variant = turn.active_variant
    assert_equal "manual", variant.source
    body = variant.content_bodies.sole
    assert_predicate body, :sealed?, "materialization seals"
    assert_equal fragment_ids, body.content_body_entries.pluck(:content_fragment_id),
      "seal-then-clone: the same fragments, zero content bytes"

    @conversation.reload
    assert_equal 1, @conversation.timeline_position_head
    assert_equal 1, @conversation.context_revision, "a visible completed turn is context"

    types = @conversation.conversation_event_items.order(:sequence).pluck(:item_type)
    assert_equal %w[input_accepted input_materialized turn_created], types
  end

  test "the queue drains FIFO and a second drain is a level-triggered no-op" do
    accept!(text: "first")
    accept!(text: "second")

    assert_equal 2, drain!
    assert_equal 0, drain!

    texts = @conversation.conversation_turns.order(:position).map do |turn|
      turn.active_variant.content_bodies.sole.effective_text
    end
    assert_equal %w[first second], texts
  end

  test "a busy lane, the bin, a blocked head, and a reply head all hold the queue" do
    input = accept!

    actor = input.speaker_actor
    running = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: 5,
      kind: "message", role: "user", status: "running",
      speaker_actor: actor, control_owner_user: @user
    )
    assert_equal :conversation_busy,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    running.update!(status: "canceled")
    running.destroy!

    @conversation.reload.update!(archived_at: Time.current)
    assert_equal :not_available,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    @conversation.update!(archived_at: nil)

    input.reload.update!(state: "blocked", blocked_reason: "policy")
    assert_equal :input_blocked,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert ConversationInput.exists?(input.id), "FIFO never skips; the queue waits"
  end

  test "provenance and view-state ride the materialization" do
    accept!(visible_in_context: false)
    stamped = ConversationInput.new(
      account: @account, host: @conversation, queue_position: 99,
      kind: "message", role: "user",
      speaker_actor: Actors::Resolve.member(account: @account, user: @user),
      authoring_user: @user, sender_conversation_public_id: SecureRandom.uuid
    )
    stamped.save!

    assert_equal 2, drain!

    excluded, mail = @conversation.conversation_turns.order(:position).to_a
    assert_equal "excluded_from_context", excluded.visibility
    assert_equal stamped.sender_conversation_public_id, mail.sender_conversation_public_id,
      "mail provenance copies from the input at materialization"
    assert_equal 1, @conversation.reload.context_revision,
      "only the visible turn bumped the revision"
  end

  test "acceptance kicks the drain after commit" do
    assert_enqueued_with(job: Conversations::Inputs::DrainJob, args: [@conversation.id]) do
      accept!
    end
  end

  test "a row before its time is neither the head nor a blocker; when due it drains at its arrival position" do
    later = scheduled!(text: "later", at: 1.hour.from_now)
    accept!(text: "now")

    assert_equal 1, drain!, "the row behind the scheduled one drains past it"
    assert_equal %w[now], turn_texts
    assert_equal "pending", later.reload.state, "not in the room yet, not blocking either"

    assert_equal 0, drain!
    assert_equal :input_queue_empty,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome,
      "only future rows: the room reads empty"

    later.update_columns(deliver_at: 1.second.ago)
    assert_equal 1, drain!
    assert_equal %w[now later], turn_texts

    first = scheduled!(text: "first, once due", at: 1.hour.from_now)
    accept!(text: "second")
    first.update_columns(deliver_at: 1.second.ago)
    assert_equal 2, drain!
    assert_equal ["now", "later", "first, once due", "second"], turn_texts,
      "a due row reads at its ARRIVAL position, never at its time"
  end

  # A row blocks only at materialization, which only a due row reaches, and
  # an edit that re-times a blocked row returns it to `pending` first
  # (Update#apply) — so a blocked row's `deliver_at` is past or nil and the
  # merged predicate never hides a blocker. The invariant rests on Update.
  test "a blocked row with a past deliver_at still stops the queue" do
    blocked = scheduled!(text: "policy", at: 1.minute.ago)
    accept!(text: "behind")
    blocked.update!(state: "blocked", blocked_reason: "policy")

    assert_equal :input_blocked,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    assert_equal 0, drain!
    assert_empty turn_texts
  end

  # THE FENCE, RE-READ: the door judged the author once; a scheduled word can outlive that judgement
  # by a week. The drain reads the door's own predicate again on every principal's head and parks a
  # failing one with a name the person can act on; the kernel's rows are exempt as at the door.
  test "an author who lost write standing between accept and due is parked blocked: author_not_authorized; kernel mail is exempt" do
    author = users(:curator)
    row = accept!(text: "a week ago I could", acting_user: author)
    kernel = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
      host: @conversation, acting_user: author, entries: [{ "text" => "<task_result>done</task_result>" }],
      origin: ConversationInput::TASK_RESULT_ORIGIN, sender_conversation_public_id: @conversation.public_id
    )).value
    @conversation.conversation_access_entries.create!(user: author, level: "read")
    assert_not @conversation.writable_by?(author)

    assert_equal 1, drain!, "the kernel's row reads first and lands; the person's is the wall"
    assert_not ConversationInput.exists?(kernel.id)
    assert_equal :input_blocked,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome
    row.reload
    assert_equal "blocked", row.state
    assert_equal "author_not_authorized", row.blocked_reason
    assert_equal 1, @conversation.conversation_turns.count, "no turn opened on the removed author's word"
    event = @conversation.conversation_event_items.where(item_type: "input_blocked").sole
    assert_equal "author_not_authorized", event.payload.fetch("blocked_reason")
    assert_equal row.public_id, event.payload.fetch("input_public_id")

    # The person's repair verbs: another member's edit re-pends it and it drains.
    edited = Conversations::Inputs::Update.call(Conversations::Inputs::Update::Command.new(
      host: @conversation, input_public_id: row.public_id, acting_user: @user,
      expected_lock_version: nil, entries: [{ "text" => "taken over" }], visible_in_context: nil,
      context_mode: nil, context_options: nil, provider_id: nil, model_ref: nil, reasoning_effort: nil,
      request_options: nil
    ))
    assert_predicate edited, :accepted?
    assert_equal :input_blocked,
      Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id).outcome,
      "an edit changes the words, not the author: the fence re-blocks it"
    assert_predicate Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: @conversation, input_public_id: row.public_id, acting_user: @user
    )), :accepted?
    assert_equal 0, drain!
  end
end
