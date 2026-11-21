# PUT /agent_api/v1/workspaces/{id}/access_mode: owner-only, optimistic,
# and the commit is the entire authority cut.
# @auth [MemberBearer]
class AgentAPI::V1::Workspaces::AccessModesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  # @oas_include
  # @summary Update access modes
  # @tags Member, access modes
  # @parameter workspace_public_id(path) [!String] Public UUIDv7. format: (uuid)
  # @request_body_ref #/components/requestBodies/AgentApiV1WorkspacesAccessModesUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/AgentApiV1WorkspacesAccessModesUpdate
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
