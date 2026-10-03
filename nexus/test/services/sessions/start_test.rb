require "test_helper"

class SessionsStartTest < ActiveSupport::TestCase
  setup do
    @identity = identities(:member)
  end

  test "browser login returns an authenticated session without a bearer secret" do
    result = Sessions::Start.call(
      source: credentials(email: @identity.email, password: "password"),
      user_agent: "Test browser",
      ip_address: "203.0.113.10"
    )

    assert_equal :authenticated, result.outcome
    assert result.session.browser?
    assert_equal "Test browser", result.session.user_agent
    assert_equal "203.0.113.10", result.session.ip_address
    assert_nil result.secret
  end

  test "api login reveals the bearer once and stores only its lookup and digest" do
    freeze_time do
      result = Sessions::Start.call(source: credentials(email: @identity.email, password: "password"), kind: :api)

      assert_equal :authenticated, result.outcome
      assert result.secret.start_with?("sk-cybros-session-v1-")

      session = result.session
      assert session.api?
      assert session.lookup_id.present?
      assert session.secret_digest.present?
      assert_equal users(:member).authority_generation, session.user_authority_generation
      assert_equal @identity.credential_recovery_generation, session.identity_recovery_generation
      assert_equal Session::LIFETIME.from_now, session.expires_at
      assert_no_match(/#{Regexp.escape(result.secret.split(".").last)}/, session.attributes.values.join(" "))
      assert_equal session, Session.authenticate_api_token(result.secret)
    end
  end

  test "valid login performs one password verification" do
    verification_count = 0
    original_new = BCrypt::Password.method(:new)

    result = BCrypt::Password.stub(:new, ->(*args, **kwargs) {
      verification_count += 1
      original_new.call(*args, **kwargs)
    }) do
      Sessions::Start.call(source: credentials(email: @identity.email, password: "password"))
    end

    assert_equal 1, verification_count
    assert_equal :authenticated, result.outcome
    assert result.session.persisted?
  end

  test "unknown email preserves the dummy password hash" do
    hash_count = 0
    original_create = BCrypt::Password.method(:create)

    result = BCrypt::Password.stub(:create, ->(*args, **kwargs) {
      hash_count += 1
      original_create.call(*args, **kwargs)
    }) do
      Sessions::Start.call(source: credentials(email: "unknown@example.com", password: "password"))
    end

    assert_equal 1, hash_count
    assert_equal :invalid_credentials, result.outcome
    assert_nil result.session
    assert_nil result.secret
  end

  test "unrepresentable credentials are rejected before authentication" do
    [
      credentials(email: "#{@identity.email}\0", password: "password"),
      credentials(email: @identity.email, password: "password\0"),
      credentials(email: @identity.email, password: "a" * 73),
    ].each do |source|
      assert_no_difference -> { Session.count } do
        result = Sessions::Start.call(source: source)

        assert_equal :invalid_credentials, result.outcome
        assert_nil result.session
        assert_nil result.secret
      end
    end
  end

  test "pending recovery refuses both session kinds without revealing a secret" do
    MemberRecoveryAuthorizations::Issue.call(user: users(:member))

    %i[ browser api ].each do |kind|
      assert_no_difference -> { Session.count } do
        result = Sessions::Start.call(source: credentials(email: @identity.email, password: "password"), kind: kind)

        assert_equal :local_recovery_required, result.outcome
        assert_nil result.session
        assert_nil result.secret
      end
    end
  end

  test "forced password change refuses api login without revealing a secret" do
    @identity.update!(password_change_required: true)

    assert_no_difference -> { Session.count } do
      result = Sessions::Start.call(source: credentials(email: @identity.email, password: "password"), kind: :api)

      assert_equal :password_change_required, result.outcome
      assert_nil result.session
      assert_nil result.secret
    end
  end

  test "an established identity starts a browser session without password verification" do
    authentication_attempted = false
    user_agent = "Setup browser " * 30

    result = Identity.stub(:authenticate_by, ->(**) { authentication_attempted = true }) do
      Sessions::Start.call(source: @identity, user_agent: user_agent, ip_address: "203.0.113.11")
    end

    assert_equal :authenticated, result.outcome
    assert result.session.browser?
    assert_equal accounts(:cybros), result.session.account
    assert_equal users(:member), result.session.user
    assert_equal user_agent.first(255), result.session.user_agent
    assert_equal "203.0.113.11", result.session.ip_address
    assert_nil result.secret
    assert_not authentication_attempted
  end

  test "an established identity cannot mint an api bearer" do
    assert_raises ArgumentError do
      Sessions::Start.call(source: @identity, kind: :api)
    end
  end

  test "models do not expose general session-start or raw-secret issuance factories" do
    refute_respond_to Identity, :authenticate_and_start_session
    refute_respond_to @identity, :start_session
    refute_respond_to Session, :issue_api
  end

  private

    def credentials(email:, password:)
      Sessions::Start::Credentials.new(email: email, password: password)
    end
end
