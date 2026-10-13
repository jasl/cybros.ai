require "test_helper"
require_relative "../../test_helpers/conversation_api_test_helper"

class Conversations::UpdateTest < ActiveSupport::TestCase
  include ConversationAPITestHelper

  test "a writer winning after the resource read preserves its values" do
    conversation = create_conversation!(title: "Initial")
    winner = Conversation.find(conversation.id)
    winner.update!(title: "Manual title", metadata: { "topic" => "manual" })

    result = Conversations::Update.call(conversation: conversation, lock_version: conversation.lock_version,
      changes: { title: "Late title", metadata: { "topic" => "late" } })

    assert_equal :stale_object, result.outcome
    assert_equal "Manual title", conversation.reload.title
    assert_equal({ "topic" => "manual" }, conversation.metadata)
  end
end
