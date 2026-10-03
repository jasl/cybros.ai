require "test_helper"

class AccessTokensIssueTest < ActiveSupport::TestCase
  setup do
    @user = users(:member)
    @identity = identities(:member)
    @presented_session = create_browser_session(@identity)
  end

  test "successful issuance reveals the bearer once and stores only its lookup and digest" do
    result = nil

    assert_difference -> { @user.access_tokens.count }, 1 do
      result = issue_token
    end

    assert_equal :issued, result.outcome
    assert result.secret.start_with?("sk-cybros-api-v1-")

    token = result.token
    assert_equal @user, token.user
    assert_equal "personal", token.source
    assert_predicate token, :member_plane?
    assert_equal @user.authority_generation, token.user_authority_generation
    assert_equal @identity.credential_recovery_generation, token.identity_recovery_generation
    assert_nil token.expires_at
    assert_no_match(/#{Regexp.escape(result.secret.split(".").last)}/, token.attributes.values.join(" "))
    assert_equal token, AccessToken.authenticate_token(result.secret)
  end

  test "generation advancement after the final session check permits issuance but the token is born fenced" do
    authority_generation = @user.authority_generation
    recovery_generation = @identity.credential_recovery_generation
    original_mint_parts = AccessToken::DIGESTED.method(:mint_parts)
    result = nil

    assert_difference -> { @user.access_tokens.count }, 1 do
      AccessToken::DIGESTED.stub(:mint_parts, -> {
        @user.increment!(:authority_generation)
        @identity.increment!(:credential_recovery_generation)
        original_mint_parts.call
      }) do
        result = issue_token
      end
    end

    assert_equal :issued, result.outcome
    assert_equal authority_generation, result.token.user_authority_generation
    assert_equal recovery_generation, result.token.identity_recovery_generation
    assert_equal authority_generation + 1, @user.reload.authority_generation
    assert_equal recovery_generation + 1, @identity.reload.credential_recovery_generation
    assert_not result.token.reload.usable?
    assert_nil AccessToken.authenticate_token(result.secret)
  end

  test "successful issuance verifies the current password exactly once" do
    bcrypt_calls = 0
    original_new = BCrypt::Password.method(:new)
    result = nil

    BCrypt::Password.stub(:new, ->(*arguments, **keywords, &block) {
      bcrypt_calls += 1
      original_new.call(*arguments, **keywords, &block)
    }) do
      result = issue_token
    end

    assert_equal :issued, result.outcome
    assert_equal 1, bcrypt_calls
  end

  test "the current password is required" do
    result = nil

    assert_no_difference -> { AccessToken.count } do
      result = issue_token(current_password: "wrong")
    end

    assert_equal :invalid_password, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "a null-byte current password is an ordinary invalid credential" do
    result = nil

    assert_no_difference -> { AccessToken.count } do
      result = issue_token(current_password: "pass\0word")
    end

    assert_equal :invalid_password, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "model validation failures return the unsaved token without a secret" do
    result = nil

    assert_no_difference -> { AccessToken.count } do
      result = issue_token(name: "")
    end

    assert_equal :invalid, result.outcome
    assert_not result.token.persisted?
    assert result.token.errors.of_kind?(:name, :blank)
    assert_nil result.secret
  end

  test "an administrator mints a platform token under the live role" do
    admin = users(:owner)
    session = create_browser_session(identities(:owner))

    result = AccessTokens::Issue.call(
      user: admin, presented_session: session, current_password: "password",
      name: "Ops", note: nil, credential_plane: "platform"
    )

    assert_equal :issued, result.outcome
    assert_predicate result.token, :platform_plane?
    assert_equal result.token, AccessToken.authenticate_platform_token(result.secret)
    assert_nil AccessToken.authenticate_token(result.secret)
  end

  test "a member cannot mint a platform token" do
    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token(credential_plane: "platform")
    end

    assert_equal :not_issuable, result.outcome
  end

  test "an inactive member cannot issue a token" do
    @user.suspend

    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token(user: @user.reload)
    end

    assert_equal :not_issuable, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "a pending local-recovery fence prevents issuance" do
    MemberRecoveryAuthorizations::Issue.call(user: @user)

    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token(user: @user.reload)
    end

    assert_equal :not_issuable, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "a revoked presented browser session cannot issue a token" do
    Session.find(@presented_session.id).destroy!

    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token
    end

    assert_equal :not_issuable, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "an expired presented browser session cannot issue a token" do
    @presented_session.update_column(:expires_at, 1.minute.ago)

    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token
    end

    assert_equal :not_issuable, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "a generation-fenced presented browser session cannot issue a token" do
    @identity.update!(credential_recovery_generation: @identity.credential_recovery_generation + 1)

    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token(user: @user.reload)
    end

    assert_equal :not_issuable, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "a presented session belonging to another member cannot issue a token" do
    other_session = create_browser_session(identities(:owner))

    result = nil
    assert_no_difference -> { AccessToken.count } do
      result = issue_token(presented_session: other_session)
    end

    assert_equal :not_issuable, result.outcome
    assert_nil result.token
    assert_nil result.secret
  end

  test "the model does not expose a raw-secret issuance factory" do
    refute_respond_to AccessToken, :mint
  end

  private

    def issue_token(
      user: @user,
      presented_session: @presented_session,
      current_password: "password",
      name: "CI",
      note: nil,
      credential_plane: "member"
    )
      AccessTokens::Issue.call(
        user: user,
        presented_session: presented_session,
        current_password: current_password,
        name: name,
        note: note,
        credential_plane: credential_plane
      )
    end
end
