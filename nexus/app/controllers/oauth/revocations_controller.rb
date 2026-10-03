# POST /oauth/revoke (RFC 7009): always 200 with an empty body, never revealing
# whether the token existed. A refresh token revokes its family; an access token
# revokes itself and its minting family.
class OAuth::RevocationsController < OAuth::MachineController
  rate_limit to: 12, within: 1.minute,
    by: -> { request.remote_ip },
    scope: "oauth/revoke",
    with: -> { render_rate_limited(retry_after: 5) }

  rescue_from OAuth::InvalidRequest, with: -> { render_oauth_error(:invalid_request) }

  def create
    return render_oauth_error(:invalid_client) unless scalar_field(:client_id) == OAuth::DEVICE_CLIENT_ID

    scalar_field(:token_type_hint)
    raw = scalar_field(:token)
    return render_oauth_error(:invalid_request) if raw.nil?

    revoke(raw)
    head :ok
  end

  private

    # token_type_hint is non-authoritative: try both families, act on whatever
    # a recognized secret resolves to. A missing/unknown token is a silent 200.
    def revoke(raw)
      if (refresh = RefreshToken.find_by_secret(raw))
        RefreshTokenFamilies::Revoke.call(refresh.refresh_token_family)
      elsif (access = AccessToken.find_by_secret(raw))
        AccessTokens::Revoke.call(access)
      end
    end
end
