require "test_helper"

class RefreshTokens::IssueTest < ActiveSupport::TestCase
  setup do
    @member = create_agent_member(
      display_name: "Refresh issuer",
      agent_identifier: "install-refresh-issuer"
    )
    executor = @member.task_executors.create!(
      account: @member.account,
      executor_kind: :agent_application,
      display_name: "Refresh issuer app"
    )
    @family = RefreshTokenFamily.create!(
      account: @member.account,
      user: @member,
      access_token_name: "Device pairing",
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: @member.authority_generation,
      last_used_at: Time.current
    )
    @access = @member.access_tokens.create!(
      refresh_token_family: @family,
      name: "Device pairing",
      source: :oauth_device,
      lookup_id: SecureRandom.base58(24),
      secret_digest: "seed",
      expires_at: AccessToken::OAUTH_TTL.from_now,
      user_authority_generation: @member.authority_generation
    )
  end

  test "issue stores replay evidence under the family authority and reveals the secret once" do
    assert_not_respond_to RefreshToken, :mint

    result = RefreshTokens::Issue.call(
      refresh_token_family: @family,
      access_token: @access
    )

    assert result.secret.start_with?("rt-cybros-api-v1-")
    assert_equal @family, result.token.refresh_token_family
    assert_predicate result.token, :current?
    assert_predicate @family, :rotation_acceptable?
    assert_no_match(
      /#{Regexp.escape(result.secret.split(".").last)}/,
      result.token.attributes.values.join(" ")
    )
  end
end
