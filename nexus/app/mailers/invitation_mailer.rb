class InvitationMailer < ApplicationMailer
  # Guarded lookup by JSON-native public id: a job whose Invitation is gone or
  # expired sends nothing. The signed acceptance capability is generated at
  # render time and never persisted.
  def acceptance(invitation_public_id)
    @invitation = Invitation.unexpired.find_by(public_id: invitation_public_id)
    return if @invitation.nil?

    @acceptance_url = join_url(token: @invitation.acceptance_token)
    mail to: @invitation.email, subject: t("invitation_mailer.acceptance.subject", brand: t("brand.name"))
  end
end
