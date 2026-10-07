class PasswordsController < ApplicationController
  include CapabilityPageResponse

  layout "public"

  allow_unauthenticated_access only: %i[ new create edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: t("passwords.create.rate_limited") }
  # Token consumption gets its own counter: an attacker can brute-force reset
  # tokens on edit/update without ever requesting a mail via create.
  rate_limit to: 10, within: 3.minutes, only: %i[ edit update ], name: "consume", with: -> { redirect_to new_password_path, alert: t("passwords.create.rate_limited") }
  before_action :set_identity_by_token, only: %i[ edit update ]

  def new
  end

  # Enumeration-safe: the response is identical whether the address is
  # unknown, ineligible, mail-disabled, or a reset email was scheduled.
  def create
    email = params.permit(:email)[:email].to_s
    identity = Identity.find_by(email: email)

    if identity&.password_resettable? && ApplicationMailer.delivery_configured?
      enqueue_reset_mail(identity)
    end

    redirect_to new_session_path, notice: t("passwords.create.sent")
  end

  def edit
  end

  def update
    submitted = params.permit(:password, :password_confirmation)
    password = submitted[:password].to_s
    password_confirmation = submitted[:password_confirmation].to_s

    outcome = if @recovery_authorization
      @identity.consume_local_recovery(
        authorization: @recovery_authorization,
        password: password,
        password_confirmation: password_confirmation
      )
    else
      @identity.reset_password(token: @password_reset_token, password: password, password_confirmation: password_confirmation)
    end

    case outcome
    when :reset, :recovered
      redirect_to new_session_path, notice: t("passwords.update.reset")
    when :superseded
      redirect_to new_password_path, alert: t("passwords.invalid_token")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

    # Preserve the anonymous response when Solid Queue cannot accept work;
    # reporting keeps the operational failure visible without exposing which
    # submitted address was eligible.
    def enqueue_reset_mail(identity)
      PasswordsMailer.reset(identity).deliver_later
    rescue SolidQueue::Job::EnqueueError => error
      Rails.error.report(error, handled: true)
    end

    # Either capability: a deployment-local recovery secret (by prefix, resolved
    # by digest) or the emailed reset token; both invalid paths render one safe failure.
    def set_identity_by_token
      @password_reset_token = params[:token].to_s

      if @password_reset_token.start_with?(MemberRecoveryAuthorization::WIRE_PREFIX)
        authorization = MemberRecoveryAuthorization.find_by_secret(@password_reset_token)

        if authorization&.consumable?
          @recovery_authorization = authorization
          @identity = authorization.identity
        else
          redirect_to new_password_path, alert: t("passwords.invalid_token")
        end
      else
        identity = Identity.find_by_password_reset_token(@password_reset_token)

        if identity&.password_resettable?
          @identity = identity
        else
          redirect_to new_password_path, alert: t("passwords.invalid_token")
        end
      end
    end
end
