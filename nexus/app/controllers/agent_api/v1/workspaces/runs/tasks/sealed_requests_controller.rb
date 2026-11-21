# THE DEBUG DOOR: the round's sealed request — exactly the entries and the
# request_options — off the sealed body; a task with none (a tool row, a round
# never scheduled) is `request_not_sealed`.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::SealedRequestsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Read sealed requests
  # @tags Member, sealed requests
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksSealedRequestsShow
  # @response_ref (410) #/components/responses/APIError
  def show
    run = find_listable_loop(@workspace)
    node = run.tasks.find_by!(node_key: params.fetch(:task_key))
    invocation = node.selected_model_invocation_id && node.selected_model_invocation
    if invocation.nil?
      return render_error(:request_not_sealed, "This task has no sealed request", status: :not_found)
    end

    render json: AgentAPI::SealedRequestPresenter.call(invocation)
  end
end
