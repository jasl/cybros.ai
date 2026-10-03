module ConversationAPITestHelper
  extend ActiveSupport::Concern

  included do
    include ActionCable::TestHelper
    include ActiveJob::TestHelper

    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      DevModelLane.ensure_enabled!(@account)
      @token = create_access_token_fixture(user: @human, name: "Member")
      @workspace = workspaces(:shared)
    end
  end

  private

    # The SQL a block runs, schema and transaction chatter excluded.
    def sql_count
      count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def create_conversation!(title: "t")
      result = Conversations::Create.call(Conversations::Create::Command.new(
        workspace: @workspace, creating_user: @human,
        title: title, metadata: {}, billing_subject: nil
      ))
      result.value
    end

    def conversations_path
      "/agent_api/v1/workspaces/#{@workspace.public_id}/conversations"
    end

    def archived_conversations_path = "#{conversations_path}/archived"
    def conversation_path(c) = "#{conversations_path}/#{c.public_id}"
    def archive_conversation_path(c) = "#{conversation_path(c)}/archive"
    def unarchive_conversation_path(c) = "#{conversation_path(c)}/unarchive"
    def conversation_inputs_path(c) = "#{conversation_path(c)}/inputs"
    def request_path(c, turn, variant) = "#{conversation_path(c)}/turns/#{turn.public_id}/variants/#{variant.public_id}/request"
    def conversation_forks_path(c) = "#{conversation_path(c)}/forks"
    def conversation_turns_path(c) = "#{conversation_path(c)}/turns"
    def conversation_events_path(c) = "#{conversation_path(c)}/events"
    def conversation_context_estimate_path(c) = "#{conversation_path(c)}/context_estimate"
    def conversation_compaction_path(c) = "#{conversation_path(c)}/compaction"

    def auth(key = nil)
      headers = { "Authorization" => "Bearer #{@token.secret}" }
      headers["Idempotency-Key"] = key if key
      headers
    end
end
