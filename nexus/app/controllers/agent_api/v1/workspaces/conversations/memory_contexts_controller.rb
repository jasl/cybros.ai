class AgentAPI::V1::Workspaces::Conversations::MemoryContextsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::MemoryContextParameters

  def create
    conversation = find_listable_conversation(@workspace)
    raise ActionController::ParameterMissing, :memory_context unless params.key?(:memory_context)

    result = ::Conversations::SetMemoryContext.call(conversation: conversation,
      acting_user: acting_user, memory_context: memory_context_parameter(params))
    if result.accepted?
      render json: { conversation: AgentAPI::ConversationPresenter.full(result.value) }
    elsif result.invalid?
      render_domain_invalid(result.record.errors)
    else
      render_refusal(result.outcome)
    end
  end
end
