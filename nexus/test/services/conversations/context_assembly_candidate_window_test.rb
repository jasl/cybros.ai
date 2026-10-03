require "test_helper"

# The assembler's read posture (the predecessor's 200-body cap, kept): the
# candidate window bounds the BODY read, an explicit larger max_entries
# widens it to match, and turns beyond the window still count as skipped
# evidence — the DB never pays for a full transcript, and the evidence
# never lies about what fell off.
class Conversations::ContextAssemblyCandidateWindowTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  # One REAL turn through the front door seeds the fragment; the rest are
  # mass-inserted rows entry-copying the same fragment — the clone
  # discipline the product itself uses, at fixture speed. Positions in
  # `blank` get a turn but no variant/body: a failed reply's contentless
  # shape.
  def build_timeline!(total, blank: [])
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @user, kind: "message",
      role: "user", entries: [{ "text" => "seed" }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil,
    ))
    assert_predicate result, :accepted?
    Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)

    seed = @conversation.conversation_turns.sole
    seed_entry = seed.active_variant.content_bodies.sole.content_body_entries.sole
    actor_id = seed.speaker_actor_id
    now = Time.current

    turn_ids = ConversationTurn.insert_all!(
      (1...total).map do |position|
        { account_id: @account.id, conversation_id: @conversation.id,
          position: position, kind: "message", role: "user", status: "completed",
          speaker_actor_id: actor_id, control_owner_user_id: @user.id,
          answering_user_id: @conversation.answering_user_id,
          visibility: "visible", created_at: now, updated_at: now }
      end, returning: %w[id]
    ).rows.flatten
    blank_turn_ids = blank.map { |position| turn_ids[position - 1] }
    bearing_turn_ids = turn_ids - blank_turn_ids
    variant_ids = ConversationTurnVariant.insert_all!(
      bearing_turn_ids.map do |turn_id|
        { account_id: @account.id, conversation_turn_id: turn_id, position: 0,
          status: "completed", source: "manual", created_at: now, updated_at: now }
      end, returning: %w[id conversation_turn_id]
    ).rows
    variant_ids.each do |variant_id, turn_id|
      ConversationTurn.where(id: turn_id).update_all(active_variant_id: variant_id)
    end
    body_ids = ContentBody.insert_all!(
      variant_ids.map do |variant_id, _|
        { account_id: @account.id, conversation_turn_variant_id: variant_id,
          role: "content", sealed_at: now, created_at: now, updated_at: now }
      end, returning: %w[id]
    ).rows.flatten
    ContentBodyEntry.insert_all!(
      body_ids.map do |body_id|
        { account_id: @account.id, content_body_id: body_id,
          content_fragment_id: seed_entry.content_fragment_id,
          position: seed_entry.position, created_at: now, updated_at: now }
      end
    )
    @conversation.reload.update!(timeline_position_head: total)
  end

  test "the window caps the read, widens with intent, and the evidence counts context" do
    build_timeline!(208, blank: [1, 2, 3])

    unbounded = Conversations::ContextAssembly::ChatHistory.call(conversation: @conversation)
    assert_equal 200, unbounded.selected_count
    assert_equal 5, unbounded.skipped_count,
      "beyond-window turns count only when content-bearing — a failed reply is not lost history"
    assert_equal "candidate_limit", unbounded.skipped_reason

    widened = Conversations::ContextAssembly::ChatHistory.call(
      conversation: @conversation, max_entries: 202
    )
    assert_equal 202, widened.selected_count
    assert_equal 3, widened.skipped_count
    assert_equal "candidate_limit", widened.skipped_reason,
      "no tighter bound fired; the window itself names the cut"

    bounded = Conversations::ContextAssembly::ChatHistory.call(
      conversation: @conversation, max_entries: 2
    )
    assert_equal 2, bounded.selected_count
    assert_equal 203, bounded.skipped_count,
      "in-window walked-out candidates plus content-bearing beyond"
    assert_equal "entry_limit", bounded.skipped_reason,
      "the nearest bound that fired names the reason"
  end

  # THE WINDOW'S CUT IS THE WALL TOO: with no bound the caller stated, a history longer than the
  # candidate window would slide one turn off the head on every reply — the edit a timeline
  # compaction exists to replace — so a reply past it arms the summary, as the fit's overflow does.
  test "a reply past the candidate window with no stated bound arms the timeline compaction" do
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: users(:agent))
    build_timeline!(201)
    result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @user, kind: "direct_reply",
      role: "user", entries: [{ "text" => "and now?" }], visible_in_context: true,
      delivery_mode: "queue", context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil, request_options: nil,
    ))
    assert_predicate result, :accepted?

    assert_equal 0, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
    assert_equal "running", @conversation.conversation_turns.find_by!(kind: "compaction_summary").status
    assert_equal "pending", result.value.reload.state, "the head waits behind the summary"
  end

  # THE SEED COUNTS AS CONTEXT: a reply turn whose prompt was kept is history even before — or
  # without — an answer, and a turn carrying both bodies counts once.
  test "a reply turn with a seed and no answer counts as context, once" do
    build_timeline!(1)
    turn = @conversation.conversation_turns.sole
    variant = turn.active_variant
    now = Time.current
    reply_turn_id = ConversationTurn.insert_all!([
      { account_id: @account.id, conversation_id: @conversation.id, position: 1, kind: "direct_reply",
        role: "assistant", status: "failed", speaker_actor_id: turn.speaker_actor_id,
        control_owner_user_id: @user.id, answering_user_id: @conversation.answering_user_id,
        visibility: "visible", created_at: now, updated_at: now },
    ], returning: %w[id]).rows.flatten.sole
    reply_variant_id = ConversationTurnVariant.insert_all!([
      { account_id: @account.id, conversation_turn_id: reply_turn_id, position: 0, status: "failed",
        source: "inference", created_at: now, updated_at: now },
    ], returning: %w[id]).rows.flatten.sole
    ConversationTurn.where(id: reply_turn_id).update_all(active_variant_id: reply_variant_id)
    @conversation.reload.update!(timeline_position_head: 2)
    fragment_id = variant.content_bodies.sole.content_body_entries.sole.content_fragment_id
    add_body = lambda do |role|
      body_id = ContentBody.insert_all!([
        { account_id: @account.id, conversation_turn_variant_id: reply_variant_id, role: role,
          sealed_at: now, created_at: now, updated_at: now },
      ], returning: %w[id]).rows.flatten.sole
      ContentBodyEntry.insert_all!([
        { account_id: @account.id, content_body_id: body_id, content_fragment_id: fragment_id,
          position: 0, created_at: now, updated_at: now },
      ])
    end

    count = -> { @conversation.timeline.content_bearing_count(surface: :assembly) }
    assert_equal 1, count.call, "the seed message alone"
    add_body.call("prompt")
    assert_equal 2, count.call, "a seed with no answer is context"
    add_body.call("content")
    assert_equal 2, count.call, "both bodies, one turn: DISTINCT"
  end
end
