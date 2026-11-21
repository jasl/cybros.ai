# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::DefaultRunnersController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::DefaultRunnerSelection

  # @oas_include
  # @summary Update default runners
  # @tags Member, default runners
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsDefaultRunnersUpdate
  def update
    select_default_runner(find_listable_conversation(@workspace))
  end

  private

    def render_selected_host(conversation)
      render json: { conversation: AgentAPI::ConversationPresenter.full(conversation.reload, acting_user: acting_user) }
    end
end
