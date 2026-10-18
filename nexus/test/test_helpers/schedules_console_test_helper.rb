module SchedulesConsoleTestHelper
  private

    def console_schedule(conversation: @conversation, **attributes)
      starts_at = Time.current + 1.hour
      result = Schedules::Create.call(conversation: conversation, creating_user: conversation.creating_user,
        attributes: { name: "Inbox review", prompt: "Review the inbox", provider_id: "dev", model_ref: "mock-text",
          tool_names: [], rule: { "kind" => "interval", "every_seconds" => 3600,
            "starts_at" => starts_at.iso8601(6) } }.merge(attributes))
      assert_predicate result, :accepted?
      result.value
    end

    def schedule_conversation(**attributes)
      Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent), **attributes)
    end
end
