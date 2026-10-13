class AgentAPI::V1::Workspaces::Conversations::DefaultRunnersController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::DefaultRunnerSelection

  def update
    select_default_runner(find_listable_conversation(@workspace))
  end

  private

    def render_selected_host(conversation)
      render json: { conversation: AgentAPI::ConversationPresenter.full(conversation.reload, acting_user: acting_user) }
    end
end
