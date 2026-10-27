class AgentAPI::V1::Workspaces::Conversations::TakeoversController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

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
