# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::Links::ClosuresController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create closures
  # @tags Member, closures
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter link_public_id(path) [!String] Public UUIDv7. format: (uuid)
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsLinksClosuresCreate
  def create
    conversation = find_listable_conversation(@workspace)
    return unless authorize_writable(conversation)
    link = ConversationLink.for_conversation(conversation).find_by!(public_id: params.fetch(:link_public_id))
    link.close(acting_user: acting_user)
    render json: { link: ::Conversations::LinkProjection.call(link.reload, conversation: conversation) }
  end
end
