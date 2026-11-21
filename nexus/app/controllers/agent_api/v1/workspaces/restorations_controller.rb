# POST /agent_api/v1/workspaces/{id}/restoration: acceptance commits
# `restoring` and live access returns immediately; completion to `active` is
# post-commit here and owned by the recurring sweep.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::RestorationsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create restorations
  # @tags Member, restorations
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesRestorationsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesRestorationsCreate
  def create
    fields = params.expect(command: [:lock_version])

    result = ::Workspaces::Restore.call(
      workspace: @workspace, by: acting_user, lock_version: lock_version_from(fields)
    )
    render_workspace_result(result)
    complete_transition_after(result)
  end
end
