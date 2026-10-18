class Conversations::ExportsController < Work::BaseController
  include DiagnosticDownload

  def show
    conversation = find_visible_conversation(:conversation_id)
    download_diagnostics(AgentAPI::ConversationExport.new(conversation: conversation, user: acting_user),
      filename: "conversation-#{conversation.public_id}.jsonl.gz")
  end
end
