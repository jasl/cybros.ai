# PUT /agent_api/v1/workspaces/{id}/access_mode: owner-only, optimistic,
# and the commit is the entire authority cut.
class AgentAPI::V1::Workspaces::AccessModesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def update
    fields = params.expect(access_mode: [:access_mode, :lock_version])
    raise ActionController::ParameterMissing.new(:access_mode) if fields[:access_mode].nil?

    result = ::Workspaces::UpdateAccessMode.call(
      workspace: @workspace,
      by: acting_user,
      to: fields[:access_mode],
      lock_version: lock_version_from(fields),
    )
    render_workspace_result(result)
  end
end
