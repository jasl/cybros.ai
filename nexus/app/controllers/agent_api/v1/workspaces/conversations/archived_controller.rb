# The recycle bin's own view — the working list's shape, opposite archived filter.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::ArchivedController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::ConversationListing
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary List archived
  # @tags Member, archived
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsArchivedIndex
  def index
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .archived.lifecycle_roots
      .includes(:active_turn, :answering_user, :workspace)
    render_conversation_list(filter_conversation_answerer(scope))
  end
end
