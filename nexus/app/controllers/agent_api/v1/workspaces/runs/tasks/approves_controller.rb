# THE APPROVER'S VERBS: any principal with write standing on the
# workspace, the agent acting for its person included.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::Runs::Tasks::ApprovesController <
      AgentAPI::V1::Workspaces::Runs::BaseController
  # @oas_include
  # @summary Create approves
  # @tags Member, approves
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
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRunsTasksApprovesCreate
  def create
    adjudicate(Runs::Tasks::Approve)
  end
end
