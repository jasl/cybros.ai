# POST /api/v1/admin/users/{user_id}/removal: HTTP mapping only — lifecycle policy
# stays in the domain command. Not surfaced by the CybrosAgent gem.
class API::V1::Admin::Users::RemovalsController < API::V1::Admin::BaseController
  def create
    # Members-only scope: the synthetic system User is unreachable and a
    # cross-account id cannot exist under the single Account; both read as
    # absence.
    target = Current.user.account.users.members.find_by!(public_id: params.fetch(:user_public_id))

    if target.id == Current.user.id
      render_self_target(target)
    else
      outcome = Users::Remove.call(user: target)
      RealtimeConnections::Disconnect.user_authority(target) if outcome == :removed
      render_removal_outcome(outcome, target)
    end
  end

  private

    def render_self_target(target)
      if target.owner?
        render_refusal(:installation_owner)
      else
        render_refusal(:not_administrable, "You cannot remove yourself")
      end
    end

    def render_removal_outcome(outcome, target)
      if outcome == :removed
        render json: { user: user_projection(target.reload) }
      else
        render_refusal(outcome)
      end
    end

    def user_projection(user)
      {
        public_id: user.public_id,
        kind: user.kind,
        role: user.role,
        status: user.status,
        display_name: user.display_name,
      }
    end
end
