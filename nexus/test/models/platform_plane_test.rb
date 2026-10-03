require "test_helper"

# The platform plane: "this personal token is an administrator's platform
# credential" is a third credential_plane value, mint-frozen like the other
# two. One bearer, one plane.
class PlatformPlaneTest < ActiveSupport::TestCase
  def mint_platform_token(user:)
    parts = AccessToken::DIGESTED.mint_parts
    token = user.access_tokens.create!(
      name: "Ops",
      credential_plane: :platform,
      lookup_id: parts.lookup_id,
      secret_digest: parts.digest,
      user_authority_generation: user.authority_generation,
      identity_recovery_generation: user.identity&.credential_recovery_generation
    )
    [token, parts.raw]
  end

  test "a platform token authenticates only on the platform plane" do
    token, secret = mint_platform_token(user: users(:owner))

    assert_equal token, AccessToken.authenticate_platform_token(secret)
    assert_nil AccessToken.authenticate_token(secret),
      "a platform credential must never resolve as a member credential"
    assert_nil AccessToken.authenticate_executor_token(secret)
  end

  test "a member token never authenticates on the platform plane" do
    credential = create_access_token_fixture(user: users(:owner), name: "Automation")

    assert_nil AccessToken.authenticate_platform_token(credential.secret)
    assert AccessToken.authenticate_token(credential.secret)
  end

  test "the platform plane is a human personal credential and binds no executor" do
    agent_token = users(:agent).access_tokens.new(
      name: "Impossible", credential_plane: :platform,
      lookup_id: SecureRandom.base58(24), secret_digest: "x",
      user_authority_generation: users(:agent).authority_generation
    )
    assert_not agent_token.valid?
    assert agent_token.errors.of_kind?(:credential_plane, :platform_requires_human)

    bound = users(:owner).access_tokens.new(
      name: "Impossible", credential_plane: :platform,
      task_executor: task_executors(:address), credential_epoch: 1,
      lookup_id: SecureRandom.base58(24), secret_digest: "x",
      user_authority_generation: users(:owner).authority_generation,
      identity_recovery_generation: users(:owner).identity.credential_recovery_generation
    )
    assert_not bound.valid?
    assert bound.errors.of_kind?(:task_executor, :present)

    oauth_minted = users(:owner).access_tokens.new(
      name: "Impossible", credential_plane: :platform, source: :oauth_device,
      lookup_id: SecureRandom.base58(24), secret_digest: "x",
      user_authority_generation: users(:owner).authority_generation,
      identity_recovery_generation: users(:owner).identity.credential_recovery_generation
    )
    assert_not oauth_minted.valid?
    assert oauth_minted.errors.of_kind?(:credential_plane, :platform_requires_personal)
  end

  test "suspension fences a platform token by generation like any member credential" do
    token, secret = mint_platform_token(user: users(:member))
    assert_equal token, AccessToken.authenticate_platform_token(secret)

    users(:member).suspend

    assert_nil AccessToken.authenticate_platform_token(secret)
  end
end
