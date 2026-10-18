require "test_helper"

# The append's two load-bearing moves, each pinned: the same-key replay
# short-circuit and cursor-lock-serialized contiguous sequences.
class InferenceRequestEvents::AppendTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
  end

  test "sequences are InferenceRequest-local, contiguous, and start at one" do
    event = InferenceRequestEvents::Append.call(
      inference_request: @inference_request, idempotency_key: "key-1",
      items: [
        { type: "run_status", payload: { "status" => "completed" } },
        { type: "result", payload: { "result" => { "status" => "completed" } } },
      ]
    )

    assert_equal [1, 2], event.inference_request_event_items.order(:sequence).pluck(:sequence)
    assert_equal 3, @inference_request.inference_request_event_cursor.next_sequence
    assert_equal @account.id, event.account_id
  end

  test "the same key replays the same event and appends nothing new" do
    first = InferenceRequestEvents::Append.call(
      inference_request: @inference_request, idempotency_key: "key-1",
      items: [{ type: "run_status", payload: { "status" => "failed" } }]
    )
    replay = InferenceRequestEvents::Append.call(
      inference_request: @inference_request, idempotency_key: "key-1",
      items: [{ type: "run_status", payload: { "status" => "completed" } }]
    )

    assert_equal first.id, replay.id
    assert_equal 1, InferenceRequestEventItem.where(inference_request_id: @inference_request.id).count
  end

  test "empty items refuse loudly" do
    assert_raises(ArgumentError) do
      InferenceRequestEvents::Append.call(inference_request: @inference_request, idempotency_key: "key-1", items: [])
    end
  end

  test "an oversized payload refuses the append whole" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      InferenceRequestEvents::Append.call(
        inference_request: @inference_request, idempotency_key: "key-1",
        items: [{ type: "text_delta", payload: { "text" => "x" * 70_000 } }]
      )
    end

    assert error.record.errors.of_kind?(:payload, Nexus::SizeBounds::REJECTION)
    assert_empty InferenceRequestEvent.where(inference_request_id: @inference_request.id),
      "the envelope never outlives its refused item"
  end
end
