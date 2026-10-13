class Admin::Users::RestorationsController < Admin::Users::BaseController
  def create
    case @member.restore
    when :restored
      notice_key = @member.agent? ? "admin.users.agent_restored" : "admin.users.restored"
      redirect_to admin_user_path(@member), notice: t(notice_key)
    when :shutdown_pending
      redirect_to admin_user_path(@member),
        alert: t("admin.users.agent_restore_shutdown_pending")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_removed")
    end
  end
end
