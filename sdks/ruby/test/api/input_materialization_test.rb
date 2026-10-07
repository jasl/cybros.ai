require "test_helper"

class InputMaterializationTest < Minitest::Test
  Event = Data.define(:sequence, :cursor, :type, :payload)
  Page = Data.define(:items, :next_after, :watermark)

  def event(sequence, type, **payload)
    Event.new(sequence: sequence, cursor: "c#{sequence}", type: type, payload: payload.transform_keys(&:to_s))
  end

  def materialized(sequence, input: "mine", turn: "t-mine", variant: "v-mine", run_id: "l-mine")
    event(sequence, "input_materialized", input_public_id: input, turn_public_id: turn,
      variant_public_id: variant, run_public_id: run_id)
  end

  def reader(events, position: CybrosAgent::KernelFeed::Position.start, head: nil, recover: nil)
    CybrosAgent::InputMaterialization.new(input_public_id: "mine", position: position, recover: recover,
      replay: ->(cursor) {
        sequence = cursor ? cursor.delete_prefix("c").to_i : 0
        items = events.select { |item| item.sequence > sequence }
        Page.new(items: items, next_after: nil, watermark: head || events.last&.sequence || 0)
      })
  end

  def test_queued_input_correlates_from_one_event_without_borrowing_another_senders_execution
    events = [materialized(1, input: "earlier", turn: "t-other", variant: "v-other", run_id: "l-other")]
    projection = reader(events, recover: ->(_) { flunk "complete replay needs no durable lookup" })
    assert_nil projection.refresh.result

    events << materialized(2)
    events << event(3, "turn_status", turn_public_id: "t-later", variant_public_id: "v-later", run_public_id: "l-later")
    assert_equal CybrosAgent::InputMaterialization::Result.new(turn: "t-mine", variant: "v-mine", run_public_id: "l-mine"),
      projection.refresh.result
    assert_equal "c3", projection.position.cursor
  end

  def test_only_the_accepted_inputs_block_is_a_refusal_and_materialization_clears_it
    events = [event(1, "input_blocked", input_public_id: "earlier", blocked_reason: "unknown_model")]
    projection = reader(events)
    assert_nil projection.refresh.blocked_reason
    events << event(2, "input_blocked", input_public_id: "mine", blocked_reason: "answerer_not_eligible")
    assert_equal "answerer_not_eligible", projection.refresh.blocked_reason
    events << materialized(3)
    assert_nil projection.refresh.blocked_reason
    assert_equal "l-mine", projection.result.run_public_id
  end

  def test_compaction_is_progress_until_the_accepted_input_materializes
    events = [event(1, "turn_status", turn_public_id: "t-summary", variant_public_id: "v-summary",
      run_public_id: "l-summary", turn_kind: "compaction_summary")]
    projection = reader(events).refresh
    assert_nil projection.result
    assert_equal "l-summary", projection.compaction.run_public_id
    events << materialized(2)
    assert_equal "l-mine", projection.refresh.result.run_public_id
  end

  def test_message_and_direct_inference_materialize_without_a_run
    %w[t-message t-inference].each do |turn|
      events = [materialized(1, turn: turn, variant: "v-#{turn}", run_id: nil),
        event(2, "turn_status", turn_public_id: "t-other", run_public_id: "l-other")]
      result = reader(events).refresh.result
      assert_equal turn, result.turn
      assert_equal "v-#{turn}", result.variant
      assert_nil result.run_public_id
    end
  end

  def test_steer_uses_the_execution_that_consumed_it_without_waiting_for_another_turn
    events = [materialized(1, turn: "t-running", variant: "v-running", run_id: "l-running")]
    projection = reader(events).refresh
    assert_equal "t-running", projection.result.turn
    assert_equal "v-running", projection.result.variant
    assert_equal "l-running", projection.result.run_public_id
  end

  def test_a_run_hold_leaves_the_input_pending
    events = [event(1, "input_blocked", input_public_id: "mine", blocked_reason: "run_held")]
    projection = reader(events).refresh
    assert_nil projection.result
    assert_nil projection.blocked_reason
  end

  def test_regeneration_does_not_replace_the_correlated_original_execution
    events = [materialized(1)]
    projection = reader(events).refresh
    events << event(2, "turn_status", turn_public_id: "t-mine", variant_public_id: "v-new", run_public_id: "l-new")
    assert_equal "v-mine", projection.refresh.result.variant
    assert_equal "l-mine", projection.result.run_public_id
  end

  def test_a_pending_surface_resumes_the_original_position
    position = CybrosAgent::KernelFeed::Position.new(cursor: "c1", sequence: 1)
    events = [materialized(1, turn: "t-old"), materialized(2)]
    projection = reader(events, position: position).refresh
    assert_equal "t-mine", projection.result.turn
    assert_equal CybrosAgent::KernelFeed::Position.new(cursor: "c2", sequence: 2), projection.position
  end

  def test_expired_materialization_recovers_once_without_inventing_a_cursor
    calls = []
    retained = CybrosAgent::Api::InputMaterialization.new(input_public_id: "mine", turn_public_id: "t-old",
      variant_public_id: "v-original", run_public_id: "l-original")
    original = CybrosAgent::InputMaterialization::Result.from_materialization(retained)
    projection = reader([], head: 20, recover: ->(input) { calls << input; original })
    assert_equal original, projection.refresh.result
    2.times { projection.refresh }
    assert_equal ["mine"], calls
    assert_equal CybrosAgent::KernelFeed::Position.start, projection.position
    assert_equal "v-original", projection.result.variant
    assert_nil CybrosAgent::InputMaterialization::Result.from_materialization(nil)
  end

  def test_a_missing_prefix_recovers_after_all_retained_events_even_at_the_head
    calls = []
    events = [event(4, "input_accepted", input_public_id: "another")]
    projection = reader(events, recover: ->(input) { calls << input; nil })
    assert_nil projection.refresh.result
    assert_equal ["mine"], calls
    assert_equal "c4", projection.position.cursor
    projection.refresh
    assert_equal ["mine"], calls, "an unchanged expired head does not trigger repeated reads"
    events << materialized(5)
    assert_equal "l-mine", projection.refresh.result.run_public_id
  end

  def test_recovery_failure_can_retry_without_consuming_the_missing_receipt
    calls = 0
    original = CybrosAgent::InputMaterialization::Result.new(turn: "t-mine", variant: "v-original", run_public_id: "l-original")
    projection = reader([], head: 20, recover: ->(_) {
      calls += 1
      raise CybrosAgent::TransportError, "unavailable" if calls == 1

      original
    })
    assert_raises(CybrosAgent::TransportError) { projection.refresh }
    assert_equal original, projection.refresh.result
    assert_equal 2, calls
  end
end
