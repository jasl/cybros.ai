require "test_helper"

# The recorded maintenance-slice item, landing with its twin: replay
# evidence ages out, the timeline it narrated does not.
class ConversationEventItems::ReapJobTest < ActiveJob::TestCase
  setup do
    @conversation = Conversation.create!(
      workspace: workspaces(:shared), creating_user: users(:member)
    )
  end

  test "aged items go and the timeline stays" do
    ConversationEvent::Append.call(
      host: @conversation,
      items: [{ type: "turn_status", payload: { "status" => "completed" } }]
    )
    assert_equal 1, @conversation.conversation_event_items.count

    ConversationEventItems::ReapJob.perform_now
    assert_equal 1, @conversation.conversation_event_items.count,
      "a fresh item is inside the window"

    ConversationEventItem.where(host: @conversation)
      .update_all(created_at: 40.days.ago)
    ConversationEventItems::ReapJob.perform_now

    assert_equal 0, @conversation.conversation_event_items.count
    assert_not_nil Conversation.find_by(id: @conversation.id)
  end

  test "expired items do not erase append idempotency or reuse sequences" do
    agent_run = AgentRun.create!(
      workspace: workspaces(:shared), creating_user: users(:member), status: "running",
      approval_mode: "bypass"
    )

    [@conversation, agent_run].each do |host|
      items = [
        { type: "turn_status", payload: { "status" => "running" } },
        { type: "turn_status", payload: { "status" => "completed" } },
      ]
      original = ConversationEvent::Append.call(
        host: host, items: items, idempotency_key: "before-retention"
      )
      cursor = host.reload.conversation_event_cursor
      assert_equal [1, 2], host.conversation_event_items.order(:sequence).pluck(:sequence)

      host.conversation_event_items.update_all(created_at: 40.days.ago)
      ConversationEventItems::ReapJob.perform_now

      replay = ConversationEvent::Append.call(
        host: host, items: items, idempotency_key: "before-retention"
      )
      assert_equal original.id, replay.id
      assert_equal 1, host.conversation_events.count
      assert_empty host.conversation_event_items
      assert_equal cursor.id, host.reload.conversation_event_cursor.id
      assert_equal 3, cursor.reload.next_sequence

      ConversationEvent::Append.call(
        host: host, items: [items.first], idempotency_key: "after-retention"
      )
      assert_equal [3], host.conversation_event_items.order(:sequence).pluck(:sequence)
      assert_equal 4, cursor.reload.next_sequence
      assert_equal 2, host.conversation_events.count
    end
  end
end
