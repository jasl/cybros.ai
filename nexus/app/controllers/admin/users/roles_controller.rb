class Admin::Users::RolesController < Admin::Users::BaseController
  def update
    case @member.change_role(to: params.expect(role: [:role])[:role].to_s)
    when :role_changed
      redirect_to admin_user_path(@member), notice: t("admin.users.role_changed")
    when :invalid_role
      redirect_to admin_user_path(@member), alert: t("admin.users.invalid_role")
    when :last_admin
      redirect_to admin_user_path(@member), alert: t("admin.users.last_admin")
    when :owner_protected
      redirect_to admin_user_path(@member), alert: t("admin.users.owner_protected")
    when :not_active
      redirect_to admin_user_path(@member), alert: t("admin.users.not_active")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_administrable")
    end
  end
end
