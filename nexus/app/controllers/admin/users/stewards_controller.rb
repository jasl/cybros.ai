class Admin::Users::StewardsController < Admin::Users::BaseController
  PAGE_SIZE = 25
  SEARCH_QUERY_MAX_LENGTH = 100

  before_action :ensure_agent_profile, only: :show

  def show
    @query = search_query
    @stewards_pagy, @steward_candidates = pagy(
      :offset,
      Current.account.steward_candidates_for(@member, query: @query),
      limit: PAGE_SIZE
    )
  end

  def update
    target = Current.account.users.members.find_by(
      public_id: params.expect(steward: [:steward_public_id])[:steward_public_id].to_s
    )

    outcome = @member.change_steward(to: target)
    if outcome == :changed
      RealtimeConnections::Disconnect.user_authority(@member, reconnect: true)
    end

    case outcome
    when :changed
      redirect_to admin_user_path(@member), notice: t("admin.users.steward_changed")
    when :not_agent
      redirect_to admin_user_path(@member), alert: t("admin.users.not_agent")
    when :shutdown_pending
      redirect_to admin_user_path(@member),
        alert: t("admin.users.steward_shutdown_pending")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.invalid_steward")
    end
  end

  private

    def ensure_agent_profile
      unless @member.agent?
        redirect_to admin_user_path(@member), alert: t("admin.users.not_agent")
      end
    end

    def search_query
      params.permit(:query).fetch(:query, "").to_s.strip[0, SEARCH_QUERY_MAX_LENGTH]
    end
end
