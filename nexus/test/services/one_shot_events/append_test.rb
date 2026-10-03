require "test_helper"

# The append's two load-bearing moves, each pinned: the same-key replay
# short-circuit and cursor-lock-serialized contiguous sequences.
class OneShotEvents::AppendTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @one_shot = OneShot.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
  end

  test "sequences are OneShot-local, contiguous, and start at one" do
    event = OneShotEvents::Append.call(
      one_shot: @one_shot, idempotency_key: "key-1",
      items: [
        { type: "run_status", payload: { "status" => "completed" } },
        { type: "result", payload: { "result" => { "status" => "completed" } } },
      ]
    )

    assert_equal [1, 2], event.one_shot_event_items.order(:sequence).pluck(:sequence)
    assert_equal 3, @one_shot.one_shot_event_cursor.next_sequence
    assert_equal @account.id, event.account_id
  end

  test "the same key replays the same event and appends nothing new" do
    first = OneShotEvents::Append.call(
      one_shot: @one_shot, idempotency_key: "key-1",
      items: [{ type: "run_status", payload: { "status" => "failed" } }]
    )
    replay = OneShotEvents::Append.call(
      one_shot: @one_shot, idempotency_key: "key-1",
      items: [{ type: "run_status", payload: { "status" => "completed" } }]
    )

    assert_equal first.id, replay.id
    assert_equal 1, OneShotEventItem.where(one_shot_id: @one_shot.id).count
  end

  test "empty items refuse loudly" do
    assert_raises(ArgumentError) do
      OneShotEvents::Append.call(one_shot: @one_shot, idempotency_key: "key-1", items: [])
    end
  end

  test "an oversized payload refuses the append whole" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      OneShotEvents::Append.call(
        one_shot: @one_shot, idempotency_key: "key-1",
        items: [{ type: "text_delta", payload: { "text" => "x" * 70_000 } }]
      )
    end

    assert error.record.errors.of_kind?(:payload, Nexus::SizeBounds::REJECTION)
    assert_empty OneShotEvent.where(one_shot_id: @one_shot.id),
      "the envelope never outlives its refused item"
  end
end
