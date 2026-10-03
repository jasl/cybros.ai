class API::V1::SessionsController < API::V1::BaseController
  LOGIN_RATE_LIMIT_WINDOW = 3.minutes.freeze

  allow_unauthenticated_access only: :create
  rate_limit to: 10,
    within: LOGIN_RATE_LIMIT_WINDOW,
    only: :create,
    with: -> { render_rate_limited(retry_after: LOGIN_RATE_LIMIT_WINDOW) }

  def show
    if Current.session
      render json: { session: session_payload(Current.session) }
    else
      render_not_found
    end
  end

  # cmctl login: password authentication reveals the bearer exactly once.
  def create
    credentials = params.permit(:email, :password)
    outcome = Sessions::Start.call(
      source: Sessions::Start::Credentials.new(
        email: credentials[:email].to_s,
        password: credentials[:password].to_s
      ),
      kind: :api
    )

    case outcome.outcome
    when :authenticated
      render json: {
        session: session_payload(outcome.session),
        token: outcome.secret,
        token_type: "Bearer",
      }, status: :created
    when :local_recovery_required
      render_error(:local_recovery_required, "Password sign-in is locked pending local recovery", status: :forbidden)
    when :password_change_required
      render_error(:password_change_required, "Change the temporary password in the web console first", status: :forbidden)
    when :invalid_credentials
      render_error(:invalid_credentials, "Invalid email or password", status: :unauthorized)
    else
      raise ArgumentError, "unknown session-start outcome: #{outcome.outcome.inspect}"
    end
  end

  def destroy
    if Current.session
      Current.session.destroy
      render json: { revoked: true }
    else
      render_not_found
    end
  end

  private

    def session_payload(session)
      {
        public_id: session.public_id,
        kind: session.kind,
        expires_at: session.expires_at,
      }
    end
end
