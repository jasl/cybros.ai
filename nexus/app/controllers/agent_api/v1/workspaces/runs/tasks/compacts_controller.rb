# COMPACT NOW, task-grained. Not `adjudicate`: the answer carries the key
# of the summarizing task, so a caller follows the repair it asked for
# without diffing the graph.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::CompactsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Create compacts
  # @tags Member, compacts
  # @parameter run_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @parameter task_key(path) [!String] Resource selector.
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (202) #/components/responses/AgentApiV1WorkspacesRunsTasksCompactsCreate
  # @response_ref (410) #/components/responses/APIError
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
