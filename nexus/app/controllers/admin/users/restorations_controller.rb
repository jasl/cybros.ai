class Admin::Users::RestorationsController < Admin::Users::BaseController
  def create
    case @member.restore
    when :restored
      redirect_to admin_user_path(@member), notice: t("admin.users.restored")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_removed")
    end
  end
end
