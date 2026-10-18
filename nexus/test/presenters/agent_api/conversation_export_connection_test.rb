require "test_helper"

class AgentAPI::ConversationExportConnectionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @human = users(:member)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
    actor = Speakers::Resolve.member(account: accounts(:cybros), user: @human)
    (AgentAPI::ConversationExport::PAGE_SIZE + 1).times do |index|
      @conversation.inputs.create!(kind: "message", role: "user", origin: "person",
        authoring_user: @human, speaker: actor, queue_position: index,
        delivery_mode: "queue", context_mode: "assembled")
    end
  end

  teardown do
    Conversation.find_by(id: @conversation&.id)&.destroy!
  end

  test "each compressed chunk reaches its reader after returning every page connection" do
    pool = ApplicationRecord.connection_pool
    body = AgentAPI::ConversationExport.new(conversation: @conversation, user: @human)
    pool.release_connection
    chunks = 0

    body.each do |_chunk|
      assert_nil pool.active_connection?, "a slow reader must not retain the page's database connection"
      chunks += 1
    end

    assert_operator chunks, :>, AgentAPI::ConversationExport::PAGE_SIZE
    assert_nil pool.active_connection?
  end
end
