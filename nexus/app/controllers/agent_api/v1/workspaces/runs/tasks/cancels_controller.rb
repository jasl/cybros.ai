# The person-side branch cancel: the call key the model saw, or any branch
# node; 409 `not_a_branch` for the mainline.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::CancelsController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Create cancels
  # @tags Member, cancels
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksCancelsCreate
  def create
    adjudicate(Runs::CancelBranch)
  end
end
