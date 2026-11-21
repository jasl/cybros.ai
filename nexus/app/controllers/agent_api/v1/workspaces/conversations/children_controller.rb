# The follower listing: subagent conversations surface HERE, through
# their parent — never in the top-level lists.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::ChildrenController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::ConversationListing
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary List children
  # @tags Member, children
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsChildrenIndex
  def index
    conversation = find_listable_conversation(@workspace)
    scope = Conversation.visible_to(acting_user, workspace: @workspace)
      .subagents.where(parent_conversation_id: conversation.id)
      .includes(:active_turn, :answering_user, :spawn_node, :workspace)
    render_conversation_list(scope)
  end
end
