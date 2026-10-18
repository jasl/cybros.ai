class Admin::Agents::StewardsController < Admin::Agents::BaseController
  PAGE_SIZE = 25
  SEARCH_QUERY_MAX_LENGTH = 100

  def show
    @query = search_query
    @stewards_pagy, @steward_candidates = pagy(
      :offset,
      Current.account.active_humans_matching(@query),
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
      redirect_to admin_agent_path(@member), notice: t("admin.agents.steward_changed")
    when :not_agent
      redirect_to admin_agent_path(@member), alert: t("admin.agents.not_agent")
    when :shutdown_pending
      redirect_to admin_agent_path(@member),
        alert: t("admin.agents.steward_shutdown_pending")
    else
      redirect_to admin_agent_path(@member), alert: t("admin.agents.invalid_steward")
    end
  end

  private

    def search_query
      params.permit(:query).fetch(:query, "").to_s.strip[0, SEARCH_QUERY_MAX_LENGTH]
    end
end
