class Admin::Agents::RemovalsController < Admin::Agents::BaseController
  def create
    outcome = Users::Remove.call(user: @member)
    RealtimeConnections::Disconnect.user_authority(@member) if outcome == :removed

    if outcome == :removed
      redirect_to admin_agent_path(@member), notice: t("admin.agents.removed")
    else
      redirect_to admin_agent_path(@member), alert: t("admin.agents.not_active")
    end
  end
end
