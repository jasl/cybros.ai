# POST /agent_api/v1/workspaces/{id}/ownership_transfer. An unknown or
# ineligible target is 422, never a concealment answer: the target is an
# argument, not the located resource.
class AgentAPI::V1::Workspaces::OwnershipTransfersController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    fields = params.expect(ownership_transfer: [:target_user_public_id, :lock_version])
    lock_version = lock_version_from(fields)
    raise ActionController::ParameterMissing.new(:target_user_public_id) unless fields.key?(:target_user_public_id)
    raise APIErrors::ParameterInvalid, :target_user_public_id if fields[:target_user_public_id].nil?

    # Authority answers before target existence, so a non-owner reader
    # cannot probe member public ids through eligibility responses. The
    # domain service remains the final winner under its locks.
    unless @workspace.manageable_by?(acting_user)
      return render_error(
        :not_workspace_owner, "Only the active Human owner manages a workspace", status: :forbidden
      )
    end

    target = current_account.users.members.find_by(public_id: fields[:target_user_public_id].to_s)
    if target.nil?
      return render_error(
        :target_not_eligible,
        "The transfer target is not an eligible active Human",
        status: :unprocessable_entity
      )
    end

    result = ::Workspaces::TransferOwnership.call(
      workspace: @workspace, by: acting_user, to: target, lock_version: lock_version
    )
    render_workspace_result(result)
  end
end
