class Admin::Users::RestorationsController < Admin::Users::BaseController
  def create
    case @member.restore(reconnect: params[:reconnect] == "1")
    when :login_method_required
      redirect_to admin_user_path(@member), alert: t("sso_identity.reconnect_required")
    when :restored_for_recovery
      redirect_to admin_user_path(@member), notice: t("sso_identity.restored_for_recovery")
    when :restored
      redirect_to admin_user_path(@member), notice: t("admin.users.restored")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_removed")
    end
  end
end
