require "test_helper"

class RefreshTokenTest < ActiveSupport::TestCase
  setup do
    @member = create_agent_member(display_name: "Family", agent_identifier: "install-family")
  end

  def mint
    executor = @member.task_executors.first || @member.task_executors.create!(
      account: @member.account, executor_kind: :agent_application, display_name: "Family app"
    )
    family = RefreshTokenFamily.create!(
      account: @member.account,
      user: @member,
      access_token_name: "Device pairing",
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: @member.authority_generation,
      last_used_at: Time.current
    )
    access = @member.access_tokens.create!(
      refresh_token_family: family,
      name: "Device pairing", source: :oauth_device,
      lookup_id: SecureRandom.base58(24), secret_digest: "seed", expires_at: AccessToken::OAUTH_TTL.from_now,
      user_authority_generation: @member.authority_generation, task_executor: nil, credential_epoch: nil
    )
    RefreshTokens::Issue.call(refresh_token_family: family, access_token: access)
  end

  test "find_by_secret round-trips and rejects tampering" do
    result = mint
    assert_equal result.token, RefreshToken.find_by_secret(result.secret)
    assert_nil RefreshToken.find_by_secret(result.secret.sub(/.\z/, "x"))
    assert_nil RefreshToken.find_by_secret("garbage")
  end

  test "family revocation immediately fences refresh and access without per-row markers" do
    result = mint
    paired = result.token.access_token
    family = result.token.refresh_token_family

    family.revoke

    assert family.reload.revoked?
    assert_nil result.token.reload.revoked_at
    assert_nil paired.reload.revoked_at
    assert_predicate result.token, :current?
    assert_not_predicate family, :rotation_acceptable?
    assert_not paired.usable?
  end

  test "replayable_evidence? recognizes a consumed token" do
    result = mint
    assert_not result.token.replayable_evidence?

    result.token.update!(consumed_at: Time.current)
    assert result.token.replayable_evidence?
  end
end
