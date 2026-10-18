# POST /agent_api/v1/workspaces/{id}/restoration: acceptance commits
# `restoring` and live access returns immediately; completion to `active` is
# post-commit here and owned by the recurring sweep.
class AgentAPI::V1::Workspaces::RestorationsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    fields = params.expect(command: [:lock_version])

    result = ::Workspaces::Restore.call(
      workspace: @workspace, by: acting_user, lock_version: lock_version_from(fields)
    )
    render_workspace_result(result)
    complete_transition_after(result)
  end
end
