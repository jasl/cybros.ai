# COMPACT NOW, task-grained. Not `adjudicate`: the answer carries the key
# of the summarizing task, so a caller follows the repair it asked for
# without diffing the graph.
class AgentAPI::V1::Workspaces::Runs::Tasks::CompactsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  def create
    run = find_listable_loop(@workspace)
    result = Runs::Tasks::Compact.call(Runs::Tasks::Compact::Command.new(
      run: run, task_key: params.fetch(:task_key), acting_user: acting_user
    ))

    return render_adjudication_refusal(result.outcome) unless result.accepted?

    render json: {
      task: AgentAPI::RunPresenter.task(result.node.reload),
      summary_task_key: result.summary_task_key,
    }, status: :accepted
  end
end
