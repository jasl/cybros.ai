class Admin::InvitationsController < Admin::BaseController
  PAGE_SIZE = 25

  def index
    @invitation_filter = params[:filter] == "all" ? :all : :pending
    scope = Current.account.invitations.includes(:inviter).order_by_recency
    scope = scope.unexpired if @invitation_filter == :pending

    @invitations_pagy, @invitations = pagy(:offset, scope, limit: PAGE_SIZE)
  end

  # Creation never requires outbound mail: without it the row is link-only and
  # the admin shares the link out of band. Success claims the accepted request, never transport.
  def create
    @invitation = Current.account.invitations.new(invitation_params.merge(inviter: Current.user))

    if @invitation.save
      if @invitation.delivery_requested?
        @invitation.deliver_later
        redirect_to admin_invitations_path, notice: t("admin.invitations.create.requested")
      else
        redirect_to admin_invitations_path, notice: t("admin.invitations.create.link_only")
      end
    else
      redirect_to admin_invitations_path, alert: @invitation.errors.full_messages.to_sentence
    end
  end

  def destroy
    Current.account.invitations.find_by!(public_id: params[:id]).destroy!
    redirect_to admin_invitations_path, notice: t("admin.invitations.destroy.revoked")
  end

  private

    def invitation_params
      params.expect(invitation: [:email, :role])
    end
end
