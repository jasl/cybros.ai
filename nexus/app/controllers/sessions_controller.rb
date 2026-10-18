class SessionsController < ApplicationController
  skip_before_action :require_completed_password_change, only: :destroy
  layout "public"

  require_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create,
    with: -> { redirect_to new_session_path(return_to: return_to_url), alert: t("sessions.create.rate_limited") }

  def new
  end

  def create
    credentials = params.permit(:email, :password)
    authentication = Sessions::Start.call(
      source: Sessions::Start::Credentials.new(
        email: credentials[:email].to_s,
        password: credentials[:password].to_s
      ),
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    )

    case authentication.outcome
    when :authenticated
      adopt_session authentication.session
      redirect_to after_authentication_url
    when :local_recovery_required
      redirect_to new_session_path(return_to: return_to_url), alert: t("sessions.create.local_recovery_required")
    when :invalid_credentials
      redirect_to new_session_path(return_to: return_to_url), alert: t("sessions.create.invalid_credentials")
    else
      raise "Unexpected authentication outcome: #{authentication.outcome.inspect}"
    end
  end

  def destroy
    return_to = return_to_url
    terminate_session
    redirect_to new_session_path(return_to: return_to), status: :see_other
  end
end
