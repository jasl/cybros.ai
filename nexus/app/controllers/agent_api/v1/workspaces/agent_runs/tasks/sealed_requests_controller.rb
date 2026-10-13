# THE DEBUG DOOR: the round's sealed request — exactly the entries and the
# request_options — off the sealed body; a task with none (a tool row, a round
# never scheduled) is `request_not_sealed`.
class AgentAPI::V1::Workspaces::AgentRuns::Tasks::SealedRequestsController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def show
    agent_run = find_listable_loop(@workspace)
    node = agent_run.agent_run_tasks.find_by!(node_key: params.fetch(:task_key))
    invocation = node.selected_model_invocation_id && node.selected_model_invocation
    if invocation.nil?
      return render_error(:request_not_sealed, "This task has no sealed request", status: :not_found)
    end

    render json: AgentAPI::SealedRequestPresenter.call(invocation)
  end
end
