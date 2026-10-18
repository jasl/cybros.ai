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
      # Signing the new member in happens outside the acceptance transaction:
      # a session failure leaves the member created, and they sign in normally.
      start_new_session_for(result.member.identity)
      redirect_to root_path
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

      if @invitation.nil?
        render :invalid, status: :not_found
      end
    end

    def acceptance_params
      params.expect(acceptance: [:display_name, :password, :password_confirmation])
    end
end
