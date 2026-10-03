# The creator's cancel as a named POST command: idempotent and total —
# cancelling terminal work returns the standing state. Whoever may create
# work in a workspace may stop it.
class AgentAPI::V1::Workspaces::OneShots::CancellationsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def create
    one_shot = OneShot.where(workspace_id: @workspace.id).listable
      .find_by!(public_id: params.fetch(:one_shot_public_id))
    return unless authorize_writable(@workspace)

    OneShots::Cancel.call(one_shot: one_shot)

    render json: { one_shot: AgentAPI::OneShotPresenter.full(one_shot.reload) }
  end
end
