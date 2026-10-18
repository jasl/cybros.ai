class AgentAPI::V1::Workspaces::Conversations::ExportsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include DiagnosticDownload

  def show
    conversation = find_listable_conversation(@workspace)
    download_diagnostics(::AgentAPI::ConversationExport.new(conversation: conversation, user: acting_user),
      filename: "conversation-#{conversation.public_id}.jsonl.gz")
  end
end
