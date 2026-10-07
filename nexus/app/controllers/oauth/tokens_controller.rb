# POST /oauth/token: client validation precedes secret lookup, and a
# malformed, unknown or mismatched secret is invalid_grant without
# revealing which.
class OAuth::TokensController < OAuth::MachineController
  RATE_LIMIT = 120
  RATE_LIMIT_WINDOW = 1.minute
  IP_BACKSTOP_RATE_LIMIT = RATE_LIMIT * 100
  REFRESH_FAMILY_RATE_LIMIT = 12
  REFRESH_ACCOUNT_RATE_LIMIT = 120
  REFRESH_RATE_LIMIT_WINDOW = 1.hour

  # Source IP is an abuse backstop, never credential or device identity. The
  # wide ceiling admits one hundred callers exhausting their ordinary budgets
  # behind one NAT before the coarse counter intervenes.
  rate_limit to: IP_BACKSTOP_RATE_LIMIT, within: RATE_LIMIT_WINDOW,
    by: -> { "ip/#{request.remote_ip}" },
    scope: "oauth/token",
    name: "ip-backstop",
    with: -> { render_rate_limited(retry_after: RATE_LIMIT_WINDOW.to_i) }

  before_action :resolve_token_rate_limit_subject

  # A recognized device secret is paced per authorization and a recognized
  # refresh secret per family. Unknown secrets share one IP bucket, so random
  # bearer text cannot mint unbounded cache keys.
  rate_limit to: RATE_LIMIT, within: RATE_LIMIT_WINDOW,
    by: -> { token_rate_limit_identity },
    scope: "oauth/token",
    name: "grant-or-family",
    with: -> { render_rate_limited(retry_after: RATE_LIMIT_WINDOW.to_i) }

  # A successful refresh is a durable writer: bound one buggy lineage and the
  # aggregate write rate below the collectors' drain capacity.
  rate_limit to: REFRESH_FAMILY_RATE_LIMIT, within: REFRESH_RATE_LIMIT_WINDOW,
    by: -> { "refresh-token-family/#{@refresh_token.refresh_token_family.public_id}" },
    scope: "oauth/token",
    name: "refresh-family-writes",
    if: :recognized_refresh_grant?,
    with: -> { render_rate_limited(retry_after: REFRESH_RATE_LIMIT_WINDOW.to_i) }

  rate_limit to: REFRESH_ACCOUNT_RATE_LIMIT, within: REFRESH_RATE_LIMIT_WINDOW,
    by: -> { "account/#{@refresh_token.account_id}" },
    scope: "oauth/token",
    name: "refresh-account-writes",
    if: :recognized_refresh_grant?,
    with: -> { render_rate_limited(retry_after: REFRESH_RATE_LIMIT_WINDOW.to_i) }

  rescue_from OAuth::InvalidRequest, with: -> { render_oauth_error(:invalid_request) }

  def create
    return render_oauth_error(:invalid_client) unless OAuth::Client.registered?(scalar_field(:client_id))
    # Application login has one coarse scope. The retained connector still
    # accepts its optional scalar without turning it into authority.
    scope = scalar_field(:scope)
    if scalar_field(:client_id) == OAuth::APPLICATION_CLIENT_ID && scope && scope != OAuth::APPLICATION_SCOPE
      return render_oauth_error(:invalid_scope)
    end

    case @token_grant_type
    when OAuth::CODE_GRANT_TYPE
      if scalar_field(:client_id) == OAuth::APPLICATION_CLIENT_ID
        consume_authorization_code
      else
        render_oauth_error(:unsupported_grant_type)
      end
    when OAuth::DEVICE_GRANT_TYPE then consume_device_code
    when OAuth::REFRESH_GRANT_TYPE then rotate_refresh_token
    when nil then render_oauth_error(:invalid_request)
    else render_oauth_error(:unsupported_grant_type)
    end
  end

  private

    # Client validation still precedes secret lookup. A wrong client keeps the
    # fallback IP subject and the action returns invalid_client without
    # resolving either secret family.
    def resolve_token_rate_limit_subject
      if OAuth::Client.registered?(scalar_field(:client_id))
        @token_grant_type = scalar_field(:grant_type)
        case @token_grant_type
        when OAuth::CODE_GRANT_TYPE, OAuth::DEVICE_GRANT_TYPE
          @presented_device_code = scalar_field(@token_grant_type == OAuth::CODE_GRANT_TYPE ? :code : :device_code)
          @device_authorization =
            DeviceAuthorization.find_by_device_code(@presented_device_code) if @presented_device_code
          if @device_authorization&.client_id != scalar_field(:client_id)
            @device_authorization = nil
          end
          if @device_authorization
            @token_rate_limit_subject =
              "device-authorization/#{@device_authorization.public_id}"
          end
        when OAuth::REFRESH_GRANT_TYPE
          @presented_refresh_secret = scalar_field(:refresh_token)
          @refresh_token =
            RefreshToken.find_by_secret(@presented_refresh_secret) if @presented_refresh_secret
          if @refresh_token&.refresh_token_family&.client_id != scalar_field(:client_id)
            @refresh_token = nil
          end
          if @refresh_token
            @token_rate_limit_subject =
              "refresh-token-family/#{@refresh_token.refresh_token_family.public_id}"
          end
        when nil
          nil
        else
          nil
        end
      end
    end

    def token_rate_limit_identity
      @token_rate_limit_subject || "ip/#{request.remote_ip}"
    end

    def recognized_refresh_grant?
      @token_grant_type == OAuth::REFRESH_GRANT_TYPE && @refresh_token.present?
    end

    def consume_device_code
      return render_oauth_error(:invalid_request) if @presented_device_code.nil?
      return render_oauth_error(:invalid_grant) unless @device_authorization&.device_code?

      result = DeviceAuthorizations::Consume.call(authorization: @device_authorization)

      if result.outcome == :minted
        render_token(result)
      else
        render_oauth_error(result.outcome)
      end
    end

    def consume_authorization_code
      verifier = scalar_field(:code_verifier)
      redirect_uri = scalar_field(:redirect_uri)
      return render_oauth_error(:invalid_request) if @presented_device_code.nil? || verifier.nil? || redirect_uri.nil?

      authorization = @device_authorization
      unless authorization&.authorization_code? && authorization.redirect_uri == redirect_uri &&
          verifier.match?(/\A[A-Za-z0-9._~-]{43,128}\z/) &&
          ActiveSupport::SecurityUtils.secure_compare(
            authorization.code_challenge, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
          )
        return render_oauth_error(:invalid_grant)
      end

      result = DeviceAuthorizations::Consume.call(authorization: authorization)
      if result.outcome == :minted
        render_token(result)
      else
        render_oauth_error(:invalid_grant)
      end
    end

    def rotate_refresh_token
      return render_oauth_error(:invalid_request) if @presented_refresh_secret.nil?
      return render_oauth_error(:invalid_grant) if @refresh_token.nil?

      result = RefreshTokens::Rotate.call(presented: @refresh_token)

      if result.outcome == :rotated
        render_token(result)
      else
        render_oauth_error(result.outcome)
      end
    end

    def render_token(result)
      primary = result.access_token || result.executor_access_token
      body = token_body(result)
      if primary.platform_plane?
        human = primary.user
        body[:scope] = OAuth::APPLICATION_SCOPE
        body[:user] = { public_id: human.public_id, display_name: human.display_name, role: human.role }
        body[:agent_public_id] = result.agent_public_id if result.agent_public_id
        body[:agent] = token_body(result.agent) if result.agent
        body[:runner] = token_body(result.runner) if result.runner
      elsif result.runner
        body[:runner] = {
          access_token: result.runner.executor_access_secret,
          refresh_token: result.runner.refresh_secret,
        }
      end
      render json: body
    end

    def token_body(bundle)
      primary = bundle.access_token || bundle.executor_access_token
      body = {
        access_token: bundle.access_secret || bundle.executor_access_secret,
        plane: primary.credential_plane,
        refresh_token: bundle.refresh_secret,
        token_type: "Bearer",
        expires_in: AccessToken::OAUTH_TTL.to_i,
      }
      if bundle.access_token && bundle.executor_access_secret
        body[:executor_access_token] = bundle.executor_access_secret
      end
      body
    end
end
