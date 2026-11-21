# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::ExportsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include DiagnosticDownload

  # @oas_include
  # @summary Read exports
  # @tags Member, exports
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsExportsShow
  # @response_ref (304) #/components/responses/Empty
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def show
    conversation = find_listable_conversation(@workspace)
    download_diagnostics(::AgentAPI::ConversationExport.new(conversation: conversation, user: acting_user),
      filename: "conversation-#{conversation.public_id}.jsonl.gz")
  end
end
