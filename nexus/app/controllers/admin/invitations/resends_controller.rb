class Admin::Invitations::ResendsController < Admin::BaseController
  def create
    invitation = Current.account.invitations.find_by!(public_id: params[:invitation_id])

    outcome = invitation.resend

    case outcome
    when :resent
      redirect_to admin_invitations_path, notice: t("admin.invitations.resend.requested")
    when :resend_too_soon
      redirect_to admin_invitations_path,
        alert: t("admin.invitations.resend.too_soon", seconds: invitation.resend_available_in.ceil)
    when :member_already_exists
      redirect_to admin_invitations_path, alert: t("admin.invitations.member_already_exists")
    when :mail_delivery_unavailable
      redirect_to admin_invitations_path, alert: t("admin.invitations.mail_delivery_unavailable")
    else
      raise ArgumentError, "unknown invitation-resend outcome: #{outcome.inspect}"
    end
  end
end
