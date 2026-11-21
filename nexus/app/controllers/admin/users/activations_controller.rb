class Admin::Users::ActivationsController < Admin::Users::BaseController
  def create
    case @member.reactivate(reconnect: params[:reconnect] == "1")
    when :login_method_required
      redirect_to admin_user_path(@member), alert: t("sso_identity.reconnect_required")
    when :restored_for_recovery
      redirect_to admin_user_path(@member), notice: t("sso_identity.restored_for_recovery")
    when :reactivated
      redirect_to admin_user_path(@member), notice: t("admin.users.reactivated")
    when :not_applicable
      redirect_to admin_user_path(@member), alert: t("admin.users.not_administrable")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_suspended")
    end
  end
end
