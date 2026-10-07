require "test_helper"

# One bearer resolves to exactly one authorization plane. A member credential carries Agent
# member/data authority; an executor transport credential proves one delivery address at one epoch.
# No stored secret ever satisfies both.
class CredentialPlaneTest < ActiveSupport::TestCase
  setup do
    @member = users(:agent)
    @human = users(:member)
    @executor = task_executors(:address)
  end

  test "a member credential authorizes the member plane and never the executor plane" do
    credential = create_access_token_fixture(user: @human, name: "Member")
    token = credential.token

    assert_predicate token, :member_plane?
    assert token.usable?
    assert_not token.executor_usable?
    assert_nil AccessToken.authenticate_executor_token(credential.secret)
    assert_equal token, AccessToken.authenticate_token(credential.secret)
  end

  test "an executor transport credential authorizes the executor plane and never the member plane" do
    minted = create_bound_credential(executor: @executor, name: "Transport")
    token = minted.token

    assert_predicate token, :executor_transport_plane?
    assert token.executor_usable?
    # The cross-plane rejection: a transport credential can never publish a
    # task, submit a compaction, answer an approval, or read member resources.
    assert_not token.usable?
    assert_nil AccessToken.authenticate_token(minted.secret)
    assert_equal token, AccessToken.authenticate_executor_token(minted.secret)
  end

  def plane_attributes(user:)
    parts = AccessToken::DIGESTED.mint_parts
    {
      name: "T",
      lookup_id: parts.lookup_id, secret_digest: parts.digest,
      user_authority_generation: user.authority_generation,
      identity_recovery_generation: user.identity&.credential_recovery_generation,
    }
  end

  test "a credential belongs to exactly one plane" do
    both = @member.access_tokens.build(
      **plane_attributes(user: @member),
      task_executor: @executor,
      credential_plane: :member
    )

    assert_not both.valid?
    assert both.errors.of_kind?(:task_executor, :present)
  end

  test "an executor transport credential requires its delivery address" do
    unbound = @member.access_tokens.build(
      **plane_attributes(user: @member),
      credential_plane: :executor_transport
    )

    assert_not unbound.valid?
    assert unbound.errors.of_kind?(:task_executor, :blank)
  end
end
