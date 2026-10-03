# COMPACT NOW, task-grained. Not `adjudicate`: the answer carries the key
# of the summarizing task, so a caller follows the repair it asked for
# without diffing the graph.
class AgentAPI::V1::Workspaces::AgentLoops::Tasks::CompactsController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  def create
    agent_loop = find_listable_loop(@workspace)
    result = AgentLoops::Tasks::Compact.call(AgentLoops::Tasks::Compact::Command.new(
      agent_loop: agent_loop, task_key: params.fetch(:task_key), acting_user: acting_user
    ))

    return render_adjudication_refusal(result.outcome) unless result.accepted?

    render json: {
      task: AgentAPI::AgentLoopPresenter.task(result.node.reload),
      summary_task_key: result.summary_task_key,
    }, status: :accepted
  end
end
