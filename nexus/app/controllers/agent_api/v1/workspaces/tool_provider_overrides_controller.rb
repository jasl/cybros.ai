# PUT /agent_api/v1/workspaces/{id}/tool_provider_overrides: the provider
# override opt-in — a whole replacement of the map under the workspace's CAS,
# write standing under the dedication fence. Two rules the docs also say: the
# kernel's description bytes stay the model's contract and become the PROVIDER's
# to honour (the kernel stamps every routed row with `scope` so it can); drift
# is level-triggered — a provider that drops a verb fails that verb's calls
# `tool_not_served`, and the read still names it.
class AgentAPI::V1::Workspaces::ToolProviderOverridesController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def update
    fields = params.expect(tool_provider_overrides: [{ overrides: {} }, :lock_version])
    # REQUIRED: an absent map is never "clear" — the clearing PUT sends `{}`.
    raise ActionController::ParameterMissing.new(:overrides) if fields[:overrides].nil?

    overrides = fields[:overrides].to_h
    # A nested object under a namespace is not a public id.
    raise APIErrors::ParameterInvalid, :overrides unless overrides.values.all?(String)

    result = ::Workspaces::SetToolProviderOverrides.call(
      workspace: @workspace,
      by: acting_user,
      overrides: overrides,
      lock_version: lock_version_from(fields),
    )
    render_workspace_result(result)
  end
end
