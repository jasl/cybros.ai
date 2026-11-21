# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::RetriesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Create retries
  # @tags Member, retries
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksRetriesCreate
  # @response_ref (410) #/components/responses/APIError
  def create
    model = params[:model]&.permit(:model, :reasoning_effort, :reasoning_enabled)&.to_h
    model["reasoning_enabled"] = cast_boolean(model["reasoning_enabled"]) if model&.key?("reasoning_enabled")
    adjudicate(Runs::Tasks::Retry, model: model)
  end
end
