require "test_helper"
require_relative "../support/conversation_fixtures"
require_relative "../support/fake_realtime_client"

class ApiConversationFeedsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  # --- the feeds ------------------------------------------------------

  def test_events_is_the_replay_window_with_the_head_a_follower_drains_to
    page = chat([[200, {}, contract.fetch("valid_events_fixture")]]).events(after: "Y3ZlaS0x")

    assert_equal "#{PATH}/events", request.fetch(:path)
    assert_equal({ "after" => "Y3ZlaS0x" }, request.fetch(:params))
    assert_equal 7, page.watermark
    assert_equal "turn_status", page.first.type
    assert_equal "conversation", page.first.resource_type
  end

  # THE TRANSCRIPT OPENER: the same channel as the feed, `items:
  # "transcript"`, and one item type whichever kind arrives — a delta with
  # its fields in `payload`, the settled turn with `turn`, a run-backed
  # round's settled `round` under `task_key` with the run's id beside the
  # turn's. The keys are read by presence: the pack's direct-reply
  # fixtures carry no run keys, and the item says so.
  # THE EPHEMERAL FEED on a conversation: the frames its
  # bound runner posts, keyed by this conversation, under `{frame}`.
  def test_progress_opens_the_conversations_progress_feed_and_projects_a_process_frame
    frames = [{ "frame" => {
      "type" => "process_output", "conversation_public_id" => CONVERSATION_ID, "process_id" => "p3",
      "executor_public_id" => "ex-1", "at" => "2026-09-13T10:00:00.250Z",
      "lines" => ["Listening on :4000"], "exit" => nil,
    } }]
    client = CybrosAgentTest::FakeRealtimeClient.new(frames)

    items = []
    chat([]).progress(realtime: client).call.each { |item| items << item }

    subscription = client.subscriptions.fetch(0)
    assert_equal "AgentAPI::V1::ConversationEventsChannel", subscription.channel
    assert_equal({ workspace_id: WORKSPACE_ID, conversation_id: CONVERSATION_ID, items: "progress" },
      subscription.params)

    frame = items.fetch(0)
    assert_predicate frame, :process_output?
    assert_equal [CONVERSATION_ID, "p3", "ex-1"], [frame.conversation_public_id, frame.process_id, frame.executor_public_id]
    assert_nil frame.run_public_id
    assert_nil frame.task_key
    assert_equal ["Listening on :4000"], frame.lines
    assert_equal({ "lines" => ["Listening on :4000"], "exit" => nil }, frame.payload)
  end

  def test_transcript_opens_the_transcript_feed_and_projects_every_kind_of_item_through_one_type
    delta = contract.fetch("valid_transcript_delta_fixture")
    settled = contract.fetch("valid_transcript_settled_fixture")
    round = { "event" => {
      "type" => "round", "turn_public_id" => TURN_ID, "variant_public_id" => VARIANT_ID,
      "run_public_id" => "run-1", "task_key" => "r1",
      "round" => { "task_key" => "r1", "status" => "completed", "text_preview" => "did it" },
    } }
    unknown = { "event" => contract.fetch("unknown_transcript_item_fixture") }
    client = CybrosAgentTest::FakeRealtimeClient.new([delta, settled, round, unknown])

    items = []
    chat([]).transcript(realtime: client).call.each { |item| items << item }

    subscription = client.subscriptions.fetch(0)
    assert_equal "AgentAPI::V1::ConversationEventsChannel", subscription.channel
    assert_equal({ workspace_id: WORKSPACE_ID, conversation_id: CONVERSATION_ID, items: "transcript" },
      subscription.params)

    text, turn, settled_round, carried = items
    assert_equal "text_delta", text.type
    assert_equal "Here is ", text.text
    assert_equal [TURN_ID, VARIANT_ID, nil, nil],
      [text.turn_public_id, text.variant_public_id, text.run_public_id, text.task_key],
      "a direct reply's delta carries the turn keys and no run keys"
    refute_predicate text, :settled?

    assert_predicate turn, :settled?
    assert_equal TURN_ID, turn.turn_public_id
    assert_equal "completed", turn.turn.status
    assert_equal({}, turn.payload, "the settled turn is its projection, not a payload")

    assert_predicate settled_round, :settled?
    assert_predicate settled_round, :model_task?
    refute_predicate settled_round, :call?
    assert_equal %w[run-1 r1], [settled_round.run_public_id, settled_round.task_key]
    assert_equal TURN_ID, settled_round.turn_public_id, "a run-backed round names its turn through the seam"
    assert_equal "did it", settled_round.payload.dig("round", "text_preview"),
      "the snapshot rides the payload as the feed carries it"

    assert_equal "future_delta", carried.type
    assert_equal "carried through", carried.payload.fetch("future_field"),
      "an item this gem predates reaches the caller whole"
  end

  # The vocabularies here GROW. A consumer that matched a frozen set would
  # refuse the first value it predates instead of carrying it through.
  def test_unknown_kinds_statuses_and_item_types_are_carried_verbatim
    body = contract.fetch("valid_turns_fixture")
    body = body.merge("turns" => [contract.fetch("unknown_turn_kind_fixture")])
    assert_equal "future_kind", chat([[200, {}, body]]).turns.list.first.kind

    events = { "events" => [contract.fetch("unknown_event_type_fixture")],
               "pagination" => { "next_after" => nil, "watermark" => 7 } }
    assert_equal "future_item", chat([[200, {}, events]]).events.first.type
  end
end
