class Admin::Agents::RestorationsController < Admin::Agents::BaseController
  def create
    case @member.restore
    when :restored
      redirect_to admin_agent_path(@member), notice: t("admin.agents.restored")
    when :shutdown_pending
      redirect_to admin_agent_path(@member), alert: t("admin.agents.restore_shutdown_pending")
    else
      redirect_to admin_agent_path(@member), alert: t("admin.agents.not_removed")
    end
  end
end
