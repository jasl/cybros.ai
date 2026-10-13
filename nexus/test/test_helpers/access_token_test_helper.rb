module AccessTokenTestHelper
  Fixture = Data.define(:token, :secret)

  # Authentication and request setup need a persisted credential without
  # exercising the personal-issuance password and Session policy.
  def create_access_token_fixture(user:, name:, plane: :member, note: nil, expires_at: nil)
    parts = AccessToken::DIGESTED.mint_parts
    token = user.access_tokens.create!(
      name: name,
      note: note,
      credential_plane: plane,
      lookup_id: parts.lookup_id,
      secret_digest: parts.digest,
      expires_at: expires_at,
      user_authority_generation: user.authority_generation,
      identity_recovery_generation: user.identity&.credential_recovery_generation
    )

    Fixture.new(token: token, secret: parts.raw)
  end
end
