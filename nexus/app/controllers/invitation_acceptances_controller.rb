class InvitationAcceptancesController < ApplicationController
  include CapabilityPageResponse

  layout "public"

  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to join_path(token: params[:token].to_s), alert: t("invitation_acceptances.create.rate_limited") }

  before_action :set_invitation

  def new
    @errors = @invitation.errors
  end

  def create
    submitted = acceptance_params
    @submitted_display_name = submitted[:display_name].to_s
    result = @invitation.accept(
      display_name: @submitted_display_name,
      password: submitted[:password].to_s,
      password_confirmation: submitted[:password_confirmation].to_s
    )

    case result.outcome
    when :accepted
      # Acceptance survives a later Session failure. The password-based
      # browser sign-in must still be permitted when its Session is issued.
      policy = result.member.account
      started = policy.with_lock { start_new_session_for(result.member.identity) unless policy.sso_only? }
      if started
        redirect_to root_path
      else
        redirect_to new_session_path, notice: t("sso_identity.sso_required")
      end
    when :member_already_exists
      redirect_to new_session_path, alert: t("invitation_acceptances.create.member_already_exists")
    when :rejected
      @errors = result.errors
      render :new, status: :unprocessable_entity
    else
      raise ArgumentError, "unsupported invitation acceptance outcome: #{result.outcome.inspect}"
    end
  end

  private

    # Every mailed link resolves the same current row; validity comes only
    # from the row's current expires_at.
    def set_invitation
      @invitation = Invitation.find_by_acceptance_token(params[:token].to_s)

      if @invitation
        @login_providers = @invitation.account.sso_providers.where(enabled: true).listed
      else
        render :invalid, status: :not_found
      end
    end

    def acceptance_params
      params.expect(acceptance: [:display_name, :password, :password_confirmation])
    end
end
