require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::EventRetentionReadsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  test "replay reports committed progress after all retained items expire" do
    conversation = create_conversation!
    agent_run = AgentRun.create!(workspace: @workspace, creating_user: @human, approval_mode: "bypass")

    [conversation, agent_run].each do |host|
      path = host == conversation ? conversation_events_path(host) :
        "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{host.public_id}/events"
      get path, headers: auth
      assert_response :success
      assert_equal 0, response.parsed_body.dig("pagination", "watermark")

      append(host, "running")
      get path, headers: auth
      cursor = response.parsed_body.fetch("events").last.fetch("cursor")
      append(host, "completed")
      host.conversation_event_items.update_all(created_at: 40.days.ago)
      ConversationEventItems::ReapJob.perform_now

      get path, params: { after: cursor }, headers: auth
      assert_response :success
      assert_empty response.parsed_body.fetch("events")
      assert_nil response.parsed_body.dig("pagination", "next_after")
      assert_equal 2, response.parsed_body.dig("pagination", "watermark"),
        "an empty retained window still reports the missed committed progress"

      ApplicationRecord.transaction(requires_new: true) do
        append(host, "running")
        raise ActiveRecord::Rollback
      end
      get path, params: { after: cursor }, headers: auth
      assert_equal 2, response.parsed_body.dig("pagination", "watermark"),
        "a rolled-back allocation is not committed progress"

      append(host, "running")
      get path, params: { after: cursor }, headers: auth
      assert_equal [3], response.parsed_body.fetch("events").map { |event| event.fetch("sequence") }
      assert_equal 3, response.parsed_body.dig("pagination", "watermark")
    end
  end

  private

    def append(host, status)
      ConversationEvent::Append.call(host: host,
        items: [{ type: "turn_status", payload: { "status" => status } }])
    end
end
