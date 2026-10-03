# THE HANDOFF: a nested singular resource, PUT and never the PATCH twin — a
# whole replacement of one column, the sanctioned rebinding of
# `runner_executor_id`. The conversation is the host: its loop-backed loops'
# unclaimed runner rows move with it.
class AgentAPI::V1::Workspaces::Conversations::RunnersController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::RunnerBinding

  def update
    bind_runner(find_listable_conversation(@workspace))
  end

  private

    def render_bound_host(conversation)
      render json: { conversation: AgentAPI::ConversationPresenter.full(conversation.reload) }
    end
end
