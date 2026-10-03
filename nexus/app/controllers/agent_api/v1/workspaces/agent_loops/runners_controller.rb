# THE HANDOFF at the loop's address: a nested singular resource, PUT and
# never the PATCH twin — a whole replacement of one column, the sanctioned
# rebinding of `runner_executor_id`. A STANDALONE loop is its own host; a
# loop-backed loop's host is its conversation, so its address answers
# `conversation_hosted` (the feed's rule, events_controller).
class AgentAPI::V1::Workspaces::AgentLoops::RunnersController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  include AgentAPI::V1::Workspaces::RunnerBinding

  def update
    agent_loop = find_listable_loop(@workspace)
    return render_refusal(:conversation_hosted) unless agent_loop.standalone?

    bind_runner(agent_loop)
  end

  private

    def render_bound_host(agent_loop)
      render json: { agent_loop: AgentAPI::AgentLoopPresenter.full(agent_loop.reload) }
    end
end
