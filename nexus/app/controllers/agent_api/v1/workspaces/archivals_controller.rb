# POST /agent_api/v1/workspaces/{id}/archival: acceptance commits
# `archiving` and answers with it; completion is post-commit and
# best-effort here, correct through the recurring sweep.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::ArchivalsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Create archivals
  # @tags Member, archivals
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesArchivalsCreate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesArchivalsCreate
  def create
    fields = params.expect(command: [:lock_version])

    result = ::Workspaces::Archive.call(
      workspace: @workspace, by: acting_user, lock_version: lock_version_from(fields)
    )
    render_workspace_result(result)
    complete_transition_after(result)
  end
end
