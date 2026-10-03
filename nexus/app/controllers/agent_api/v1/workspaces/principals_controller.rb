# THE PRINCIPALS LISTING: who may be named on a conversation's access
# carrier — every member User of the account with access to this
# workspace, of either kind (Workspace::Access's one relation, answered
# per row), with the kernel's key beside the words a person reads. The
# member plane has no other user listing: this is where an agent learns
# its peers' ids and its own steward's. Ordered by display name; no
# pagination — the set is an account's members with access, small by
# construction (the executors listing's shape). The system user is never a
# member and never a principal.
class AgentAPI::V1::Workspaces::PrincipalsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def index
    render json: { principals: principals.map { |user| AgentAPI::PrincipalPresenter.basic(user) } }
  end

  private

    # The access relation reads the steward's liveness for an agent, and
    # the fence a named definition's declarer, so both are preloaded and
    # the rows judged in Ruby — one query for the members, one each for
    # their stewards and declarers.
    def principals
      User.members.where(account_id: current_account.id).includes(:steward, :derived_from).order_by_display_name
        .select { |user| @workspace.data_accessible_by?(user) }
    end
end
