require "test_helper"

class InputMaterializationTest < Minitest::Test
  Event = Data.define(:sequence, :cursor, :type, :payload)
  Page = Data.define(:items, :next_after, :watermark)

  def event(sequence, type, **payload)
    Event.new(sequence: sequence, cursor: "c#{sequence}", type: type, payload: payload.transform_keys(&:to_s))
  end

  def reader(events, position: CybrosAgent::KernelFeed::Position.start)
    Rho::InputMaterialization.new(input_public_id: "mine", position: position, replay: ->(cursor) {
      sequence = cursor ? cursor.delete_prefix("c").to_i : 0
      items = events.select { |item| item.sequence > sequence }
      Page.new(items: items, next_after: nil, watermark: events.last&.sequence || 0)
    })
  end

  def test_queued_input_ignores_another_senders_new_turn_and_keeps_its_own_pair
    events = [event(1, "input_materialized", input_public_id: "earlier", turn_public_id: "t-other"),
              event(2, "turn_status", turn_public_id: "t-other", agent_loop_public_id: "l-other")]
    projection = reader(events)
    assert_nil projection.refresh.result

    events << event(3, "input_materialized", input_public_id: "mine", turn_public_id: "t-mine")
    assert_nil projection.refresh.result
    events << event(4, "turn_status", turn_public_id: "t-mine", agent_loop_public_id: "l-mine")
    events << event(5, "turn_status", turn_public_id: "t-later", agent_loop_public_id: "l-later")
    assert_equal Rho::InputMaterialization::Result.new(turn: "t-mine", loop: "l-mine"), projection.refresh.result
  end

  def test_only_the_accepted_inputs_block_is_a_refusal
    events = [event(1, "input_blocked", input_public_id: "earlier", blocked_reason: "unknown_model")]
    projection = reader(events)
    assert_nil projection.refresh.blocked_reason
    events << event(2, "input_blocked", input_public_id: "mine", blocked_reason: "answerer_not_eligible")
    assert_equal "answerer_not_eligible", projection.refresh.blocked_reason
  end

  def test_compaction_is_progress_until_the_accepted_input_materializes
    events = [event(1, "turn_status", turn_public_id: "t-summary", agent_loop_public_id: "l-summary", turn_kind: "compaction_summary")]
    projection = reader(events).refresh
    assert_nil projection.result
    assert_equal "l-summary", projection.compaction.loop
    events << event(2, "input_materialized", input_public_id: "mine", turn_public_id: "t-mine")
    events << event(3, "turn_created", turn_public_id: "t-mine", kind: "direct_reply")
    assert_nil projection.refresh.result
    events << event(4, "turn_status", turn_public_id: "t-mine", agent_loop_public_id: "l-mine")
    assert_equal "l-mine", projection.refresh.result.loop
  end

  def test_a_message_materializes_without_borrowing_a_following_replies_loop
    events = [event(1, "input_materialized", input_public_id: "mine", turn_public_id: "t-message"),
              event(2, "turn_created", turn_public_id: "t-message", kind: "message"),
              event(3, "turn_status", turn_public_id: "t-other", agent_loop_public_id: "l-other")]
    assert_equal Rho::InputMaterialization::Result.new(turn: "t-message", loop: nil), reader(events).refresh.result
  end

  def test_a_loop_hold_leaves_the_input_pending
    events = [event(1, "input_blocked", input_public_id: "mine", blocked_reason: "loop_held")]
    projection = reader(events).refresh
    assert_nil projection.result
    assert_nil projection.blocked_reason
  end

  def test_a_pending_surface_replays_the_original_position_across_a_split_pair
    events = [event(1, "input_accepted", input_public_id: "older")]
    position = CybrosAgent::KernelFeed::Position.new(cursor: "c1", sequence: 1)
    events << event(2, "input_materialized", input_public_id: "mine", turn_public_id: "t-mine")
    assert_nil reader(events, position: position).refresh.result
    events << event(3, "turn_status", turn_public_id: "t-mine", agent_loop_public_id: "l-mine")
    assert_equal "t-mine", reader(events, position: position).refresh.result.turn
  end
end
