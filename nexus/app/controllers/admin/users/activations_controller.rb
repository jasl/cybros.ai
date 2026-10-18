class Admin::Users::ActivationsController < Admin::Users::BaseController
  def create
    case @member.reactivate
    when :reactivated
      redirect_to admin_user_path(@member), notice: t("admin.users.reactivated")
    when :not_applicable
      redirect_to admin_user_path(@member), alert: t("admin.users.not_administrable")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_suspended")
    end
  end
end
