class AgentAPI::V1::Workspaces::Runs::DefaultRunnersController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::DefaultRunnerSelection

  def update
    run = find_listable_loop(@workspace)
    return render_refusal(:conversation_hosted) unless run.standalone?

    select_default_runner(run)
  end

  private

    def render_selected_host(run)
      render json: { run: AgentAPI::RunPresenter.full(run.reload) }
    end
end
