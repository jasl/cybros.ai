# COMPACT NOW, task-grained. Not `adjudicate`: the answer carries the key
# of the summarizing task, so a caller follows the repair it asked for
# without diffing the graph.
class AgentAPI::V1::Workspaces::AgentRuns::Tasks::CompactsController <
      AgentAPI::V1::Workspaces::AgentRuns::BaseController
  def create
    agent_run = find_listable_loop(@workspace)
    result = AgentRuns::Tasks::Compact.call(AgentRuns::Tasks::Compact::Command.new(
      agent_run: agent_run, task_key: params.fetch(:task_key), acting_user: acting_user
    ))

    return render_adjudication_refusal(result.outcome) unless result.accepted?

    render json: {
      task: AgentAPI::AgentRunPresenter.task(result.node.reload),
      summary_task_key: result.summary_task_key,
    }, status: :accepted
  end
end
