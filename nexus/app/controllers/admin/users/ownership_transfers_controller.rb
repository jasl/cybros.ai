# Owner transfer bypasses the administrability pre-guard: the actor must be
# the owner and the target an active human admin; the account verb re-checks
# both under the row locks.
class Admin::Users::OwnershipTransfersController < Admin::BaseController
  def create
    target = Current.account.users.members.find_by!(public_id: params[:user_id])

    case Current.account.transfer_ownership(to: target, by: Current.user)
    when :transferred
      redirect_to admin_user_path(target), notice: t("admin.users.transferred")
    when :owner_required
      redirect_to admin_user_path(target), alert: t("admin.users.owner_required")
    else
      redirect_to admin_user_path(target), alert: t("admin.users.target_not_eligible")
    end
  end
end
