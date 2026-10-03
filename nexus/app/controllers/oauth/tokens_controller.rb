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
    return render_oauth_error(:invalid_client) unless scalar_field(:client_id) == OAuth::DEVICE_CLIENT_ID
    # Both grants reissue exactly what the connection defines. The optional
    # OAuth scalar is accepted for library compatibility and ignored.
    scalar_field(:scope)

    case @token_grant_type
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
      if scalar_field(:client_id) == OAuth::DEVICE_CLIENT_ID
        @token_grant_type = scalar_field(:grant_type)
        case @token_grant_type
        when OAuth::DEVICE_GRANT_TYPE
          @presented_device_code = scalar_field(:device_code)
          @device_authorization =
            DeviceAuthorization.find_by_device_code(@presented_device_code) if @presented_device_code
          if @device_authorization
            @token_rate_limit_subject =
              "device-authorization/#{@device_authorization.public_id}"
          end
        when OAuth::REFRESH_GRANT_TYPE
          @presented_refresh_secret = scalar_field(:refresh_token)
          @refresh_token =
            RefreshToken.find_by_secret(@presented_refresh_secret) if @presented_refresh_secret
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
      return render_oauth_error(:invalid_grant) if @device_authorization.nil?

      result = DeviceAuthorizations::Consume.call(authorization: @device_authorization)

      if result.outcome == :minted
        render_token(result)
      else
        render_oauth_error(result.outcome)
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

    # `access_token` carries the connection's leading plane and the response
    # names it, because a runner and an agent whose member authority died
    # both lead with the transport credential. A combined consume adds the
    # nested `runner` object — the second lineage's transport and refresh
    # secrets — on the MEMBER-led body only; `Rotate::Result#runner` answers
    # nil, so a rotation body never carries the key and a transport-led
    # response never carries a second transport credential.
    def render_token(result)
      primary = result.access_token || result.executor_access_token
      primary_secret = result.access_secret || result.executor_access_secret
      # A runner bundle has no member plane, so its transport half leads
      # instead of accompanying.
      accompanying_secret = result.executor_access_secret if result.access_token

      body = {
        access_token: primary_secret,
        plane: primary.credential_plane,
        refresh_token: result.refresh_secret,
        token_type: "Bearer",
        expires_in: AccessToken::OAUTH_TTL.to_i,
      }
      body[:executor_access_token] = accompanying_secret if accompanying_secret
      if result.runner
        body[:runner] = {
          access_token: result.runner.executor_access_secret,
          refresh_token: result.runner.refresh_secret,
        }
      end

      render json: body
    end
end
