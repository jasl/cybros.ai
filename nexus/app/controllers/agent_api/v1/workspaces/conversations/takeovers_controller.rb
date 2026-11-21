# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::TakeoversController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create takeovers
  # @tags Member, takeovers
  # @parameter conversation_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsTakeoversCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  def create
    conversation = find_listable_conversation(@workspace)
    result = ::Conversations::Takeover.call(conversation: conversation, acting_user: acting_user)
    if result.accepted?
      render json: { conversation: AgentAPI::ConversationPresenter.full(result.value, acting_user: acting_user) }
    else
      render_refusal(result.outcome)
    end
  end
end
