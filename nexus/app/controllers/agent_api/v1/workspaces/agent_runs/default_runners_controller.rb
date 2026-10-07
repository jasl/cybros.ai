class AgentAPI::V1::Workspaces::AgentRuns::DefaultRunnersController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::DefaultRunnerSelection

  def update
    agent_run = find_listable_loop(@workspace)
    return render_refusal(:conversation_hosted) unless agent_run.standalone?

    select_default_runner(agent_run)
  end

  private

    def render_selected_host(agent_run)
      render json: { run: AgentAPI::AgentRunPresenter.full(agent_run.reload) }
    end
end
