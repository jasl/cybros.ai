# THE DEBUG DOOR: the round's sealed request — exactly the entries and the
# request_options — off the sealed body; a task with none (a tool row, a round
# never scheduled) is `request_not_sealed`.
class AgentAPI::V1::Workspaces::AgentLoops::Tasks::SealedRequestsController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def show
    agent_loop = find_listable_loop(@workspace)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: params.fetch(:task_key))
    invocation = node.selected_model_invocation_id && node.selected_model_invocation
    if invocation.nil?
      return render_error(:request_not_sealed, "This task has no sealed request", status: :not_found)
    end

    render json: AgentAPI::SealedRequestPresenter.call(invocation)
  end
end
