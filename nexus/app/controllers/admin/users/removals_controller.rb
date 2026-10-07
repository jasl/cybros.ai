class Admin::Users::RemovalsController < Admin::Users::BaseController
  def create
    outcome = Users::Remove.call(user: @member)
    RealtimeConnections::Disconnect.user_authority(@member) if outcome == :removed

    case outcome
    when :removed
      notice_key = @member.agent? ? "admin.users.agent_removed" : "admin.users.removed"
      redirect_to admin_user_path(@member), notice: t(notice_key)
    when :owner_protected
      redirect_to admin_user_path(@member), alert: t("admin.users.owner_protected")
    when :last_admin
      redirect_to admin_user_path(@member), alert: t("admin.users.last_admin")
    when :not_active
      redirect_to admin_user_path(@member), alert: t("admin.users.not_active")
    when :workspace_ownership_transfer_required
      # Transfer-first guidance: the current owner signs in and transfers or
      # deletes; there is no admin bypass.
      redirect_to admin_user_path(@member),
        alert: t("admin.users.workspace_ownership_transfer_required")
    else
      redirect_to admin_user_path(@member), alert: t("admin.users.not_administrable")
    end
  end
end
