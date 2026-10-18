require "test_helper"

# The recorded maintenance-slice item, landing with its twin: replay
# evidence ages out, the timeline it narrated does not.
class EventItems::ReapJobTest < ActiveJob::TestCase
  setup do
    @conversation = Conversation.create!(
      workspace: workspaces(:shared), creating_user: users(:member)
    )
  end

  test "aged items go and the timeline stays" do
    Event::Append.call(
      host: @conversation,
      items: [{ type: "turn_status", payload: { "status" => "completed" } }]
    )
    assert_equal 1, @conversation.event_items.count

    EventItems::ReapJob.perform_now
    assert_equal 1, @conversation.event_items.count,
      "a fresh item is inside the window"

    EventItem.where(host: @conversation)
      .update_all(created_at: 40.days.ago)
    EventItems::ReapJob.perform_now

    assert_equal 0, @conversation.event_items.count
    assert_not_nil Conversation.find_by(id: @conversation.id)
  end

  test "expired items do not erase append idempotency or reuse sequences" do
    run = Run.create!(
      workspace: workspaces(:shared), creating_user: users(:member), status: "running",
      approval_mode: "bypass"
    )

    [@conversation, run].each do |host|
      items = [
        { type: "turn_status", payload: { "status" => "running" } },
        { type: "turn_status", payload: { "status" => "completed" } },
      ]
      original = Event::Append.call(
        host: host, items: items, idempotency_key: "before-retention"
      )
      cursor = host.reload.event_cursor
      assert_equal [1, 2], host.event_items.order(:sequence).pluck(:sequence)

      host.event_items.update_all(created_at: 40.days.ago)
      EventItems::ReapJob.perform_now

      replay = Event::Append.call(
        host: host, items: items, idempotency_key: "before-retention"
      )
      assert_equal original.id, replay.id
      assert_equal 1, host.events.count
      assert_empty host.event_items
      assert_equal cursor.id, host.reload.event_cursor.id
      assert_equal 3, cursor.reload.next_sequence

      Event::Append.call(
        host: host, items: [items.first], idempotency_key: "after-retention"
      )
      assert_equal [3], host.event_items.order(:sequence).pluck(:sequence)
      assert_equal 4, cursor.reload.next_sequence
      assert_equal 2, host.events.count
    end
  end
end
