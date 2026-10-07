module DeviceAuthorizations
  # Minted inside Consume's existing transaction after every binding check.
  # The Human lineage is independent of the Agent and Runner lineages.
  class ApplicationCredentials
    def self.call(authorization:, human:, agent: nil, runner: nil)
      now = Time.current
      family = human.refresh_token_families.create!(
        account: human.account,
        client_id: authorization.client_id,
        bound_agent: agent,
        bound_runner: runner,
        access_token_name: "Application login",
        user_authority_generation: authorization.connected_by_authority_generation,
        identity_recovery_generation: authorization.connected_by_identity_recovery_generation,
        last_used_at: now,
        device_ip: authorization.request_ip,
        device_user_agent: authorization.request_user_agent
      )
      parts = AccessToken::DIGESTED.mint_parts
      access = human.access_tokens.create!(
        name: family.access_token_name,
        source: authorization.authorization_code? ? :oauth_authorization : :oauth_device,
        credential_plane: :platform,
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest,
        expires_at: now + AccessToken::OAUTH_TTL,
        user_authority_generation: family.user_authority_generation,
        identity_recovery_generation: family.identity_recovery_generation,
        refresh_token_family: family
      )
      refresh = RefreshTokens::Issue.call(refresh_token_family: family, access_token: access)
      RefreshTokens::Bundle.new(
        access_token: access, executor_access_token: nil,
        refresh_token: refresh.token, access_secret: parts.raw,
        executor_access_secret: nil, refresh_secret: refresh.secret
      )
    end
  end
end
