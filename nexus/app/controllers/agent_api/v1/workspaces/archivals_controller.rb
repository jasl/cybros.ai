# POST /agent_api/v1/workspaces/{id}/archival: acceptance commits
# `archiving` and answers with it; completion is post-commit and
# best-effort here, correct through the recurring sweep.
class AgentAPI::V1::Workspaces::ArchivalsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    fields = params.expect(command: [:lock_version])

    result = ::Workspaces::Archive.call(
      workspace: @workspace, by: acting_user, lock_version: lock_version_from(fields)
    )
    render_workspace_result(result)
    complete_transition_after(result)
  end
end
