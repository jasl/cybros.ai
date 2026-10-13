# Per-member admin commands: load the target through the members scope (the
# synthetic system user is unreachable) and pre-guard administrability for
# the friendly path; each verb re-checks inside the row lock.
class Admin::Users::BaseController < Admin::BaseController
  before_action :set_member
  before_action :ensure_administrable

  private

    def set_member
      @member = Current.account.users.members.find_by!(public_id: params[:user_id])
    end

    def ensure_administrable
      unless @member.administrable_by?(Current.user)
        redirect_to admin_user_path(@member), alert: t("admin.users.not_administrable")
      end
    end
end
