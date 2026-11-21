# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Conversations::MemoryContextsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::MemoryContextParameters

  # @oas_include
  # @summary Create memory contexts
  # @tags Member, memory contexts
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesConversationsMemoryContextsCreate
  def create
    conversation = find_listable_conversation(@workspace)
    raise ActionController::ParameterMissing, :memory_context unless params.key?(:memory_context)

    result = ::Conversations::SetMemoryContext.call(conversation: conversation,
      acting_user: acting_user, memory_context: memory_context_parameter(params))
    if result.accepted?
      render json: { conversation: AgentAPI::ConversationPresenter.full(result.value, acting_user: acting_user) }
    elsif result.invalid?
      render_domain_invalid(result.record.errors)
    else
      render_refusal(result.outcome)
    end
  end
end
