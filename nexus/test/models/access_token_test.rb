require "test_helper"

class AccessTokenTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @member = users(:member)
    @owner = users(:owner)
  end

  test "a stored lookup and digest authenticate without retaining the wire secret" do
    credential = create_access_token_fixture(user: @member, name: "CI runner")

    assert credential.secret.start_with?("sk-cybros-api-v1-")
    token = credential.token
    assert_predicate token, :member_plane?
    assert_equal 0, token.user_authority_generation
    assert_equal 0, token.identity_recovery_generation
    assert_no_match(/#{Regexp.escape(credential.secret.split(".").last)}/, token.attributes.values.join(" "))
    assert_equal token, AccessToken.authenticate_token(credential.secret)
  end

  test "an unbound credential never authenticates the executor transport plane" do
    # The transport predicate deliberately performs no member/steward/ generation check, so the
    # binding clause is the only thing keeping an ordinary member credential off that plane.
    credential = create_access_token_fixture(user: @member, name: "Unbound")

    assert credential.token.usable?
    assert_not credential.token.executor_usable?
    assert_nil AccessToken.authenticate_executor_token(credential.secret)
  end

  test "the credential plane vocabulary is closed" do
    token = @owner.access_tokens.build(
      **access_token_attributes(user: @owner), credential_plane: "sovereign"
    )

    assert_not token.valid?
    assert token.errors.of_kind?(:credential_plane, :inclusion)
  end

  test "authentication rejects revoked, expired, tampered, and fenced tokens" do
    credential = create_access_token_fixture(user: @member, name: "T")
    secret = credential.secret

    assert_nil AccessToken.authenticate_token(secret.sub("api-v1", "xxx-v1"))
    assert_nil AccessToken.authenticate_token(secret.chop + (secret.end_with?("a") ? "b" : "a"))
    assert_nil credential.token.reload.last_used_at

    credential.token.revoke
    assert_nil AccessToken.authenticate_token(secret)
    assert credential.token.reload.revoked?
    assert_nil credential.token.last_used_at

    fresh = create_access_token_fixture(user: @member, name: "T2")
    @member.suspend
    assert_nil AccessToken.authenticate_token(fresh.secret)
    assert_nil fresh.token.reload.last_used_at

    @member.reload.reactivate
    # Reactivation never revives superseded-generation credentials.
    assert_nil AccessToken.authenticate_token(fresh.secret)
  end

  test "an expired token never authenticates" do
    credential = create_access_token_fixture(
      user: @member,
      name: "T",
      expires_at: 1.minute.ago
    )

    assert credential.token.expired?
    assert_nil AccessToken.authenticate_token(credential.secret)
  end

  test "member and executor credentials expire at the OAuth bundle cutoff" do
    freeze_time do
      bundle = connect_agent_session(steward: @owner, agent_identifier: "expiry-cutoff")
      cutoff = bundle.access_token.expires_at
      assert_equal cutoff, bundle.executor_access_token.expires_at

      travel_to cutoff - 1.second
      assert_equal bundle.access_token, AccessToken.authenticate_token(bundle.access_secret)
      assert_equal bundle.executor_access_token,
        AccessToken.authenticate_executor_token(bundle.executor_access_secret)

      travel_to cutoff
      assert_no_queries_match(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) do
        assert_nil AccessToken.authenticate_token(bundle.access_secret)
        assert_nil AccessToken.authenticate_executor_token(bundle.executor_access_secret)
      end
    end
  end

  test "platform authentication honors a finite expiry and preserves tokens without one" do
    freeze_time do
      finite = create_access_token_fixture(
        user: @owner, name: "Finite", plane: :platform, expires_at: 1.hour.from_now
      )
      permanent = create_access_token_fixture(user: @owner, name: "Permanent", plane: :platform)

      assert_equal finite.token, AccessToken.authenticate_platform_token(finite.secret)
      travel_to finite.token.expires_at

      assert_no_queries_match(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) do
        assert_nil AccessToken.authenticate_platform_token(finite.secret)
      end
      assert_equal permanent.token, AccessToken.authenticate_platform_token(permanent.secret)
    end
  end

  test "a recovery-generation advance alone fences a human token" do
    credential = create_access_token_fixture(user: @member, name: "T")
    @member.identity.update!(credential_recovery_generation: 1)

    assert_nil AccessToken.authenticate_token(credential.secret)
  end

  test "Agent removal fences transport immediately and restore does not revive it" do
    credential = create_bound_credential(executor: task_executors(:address), name: "Op")

    assert_nil credential.token.identity_recovery_generation
    assert_nil AccessToken.authenticate_token(credential.secret)
    assert_equal credential.token, AccessToken.authenticate_executor_token(credential.secret)

    users(:agent).remove
    assert_nil AccessToken.authenticate_token(credential.secret)
    assert_nil AccessToken.authenticate_executor_token(credential.secret)

    users(:agent).restore
    assert_nil AccessToken.authenticate_executor_token(credential.secret)
    assert_predicate task_executors(:address).reload, :active?
  end

  test "a personal token belongs only to a human member" do
    agent = users(:agent)
    token = agent.access_tokens.build(**access_token_attributes(user: agent))

    assert_not token.valid?
    assert token.errors.of_kind?(:source, :personal_requires_human)
  end

  test "a recovery mint fences a human member's tokens immediately" do
    credential = create_access_token_fixture(user: @member, name: "T")
    MemberRecoveryAuthorizations::Issue.call(user: @member)

    assert_nil AccessToken.authenticate_token(credential.secret)
  end

  test "revoke is a guarded idempotent single statement" do
    token = create_access_token_fixture(user: @member, name: "T").token
    token.revoke
    first_stamp = token.reload.revoked_at

    travel 1.minute do
      token.revoke
    end
    assert_equal first_stamp, token.reload.revoked_at
  end

  test "authentication refreshes last-used at most once per hour" do
    credential = create_access_token_fixture(user: @member, name: "T")

    freeze_time do
      assert_changes -> { credential.token.reload.last_used_at }, from: nil, to: Time.current do
        assert_equal credential.token, AccessToken.authenticate_token(credential.secret)
      end
    end
    first = credential.token.reload.last_used_at

    travel 59.minutes do
      assert_no_queries_match(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) do
        assert_equal credential.token, AccessToken.authenticate_token(credential.secret)
      end
      assert_equal first, credential.token.reload.last_used_at
    end

    travel 61.minutes do
      assert_changes -> { credential.token.reload.last_used_at }, from: first do
        assert_equal credential.token, AccessToken.authenticate_token(credential.secret)
      end
    end
  end

  test "last-used refresh is persisted at most once per hour across stale instances" do
    token = create_access_token_fixture(user: @member, name: "T").token
    stale = AccessToken.find(token.id)

    token.refresh_last_used_at
    first = token.reload.last_used_at
    assert first.present?

    travel 10.minutes do
      assert_no_changes -> { token.reload.last_used_at } do
        stale.refresh_last_used_at
      end
    end

    travel 2.hours do
      stale.reload.refresh_last_used_at
      assert_not_equal first, token.reload.last_used_at
    end
  end

  private

    def access_token_attributes(user:)
      parts = AccessToken::DIGESTED.mint_parts
      {
        name: "T",
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest,
        user_authority_generation: user.authority_generation,
        identity_recovery_generation: user.identity&.credential_recovery_generation,
      }
    end
end
