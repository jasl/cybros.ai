class Admin::Users::SuspensionsController < Admin::Users::BaseController
  def create
    outcome = @member.suspend
    RealtimeConnections::Disconnect.user_authority(@member) if outcome == :suspended

    case outcome
    when :suspended
      redirect_to admin_user_path(@member), notice: t("admin.users.suspended")
    when :owner_protected
      redirect_to admin_user_path(@member), alert: t("admin.users.owner_protected")
    when :last_admin
      redirect_to admin_user_path(@member), alert: t("admin.users.last_admin")
    when :not_active
      redirect_to admin_user_path(@member), alert: t("admin.users.not_active")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_administrable")
    end
  end
end
