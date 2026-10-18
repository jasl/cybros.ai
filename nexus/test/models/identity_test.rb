require "test_helper"

class IdentityTest < ActiveSupport::TestCase
  setup do
    @identity = identities(:member)
  end

  test "email address is normalized on assignment" do
    identity = Identity.new(email: "  Mixed.Case@Example.COM ")

    assert_equal "mixed.case@example.com", identity.email
  end

  test "email address must be unique after normalization" do
    duplicate = accounts(:cybros).identities.build(
      email: " MEMBER@example.com ", password: "long enough password"
    )

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:email, :taken)
  end

  test "email address must look like an email" do
    @identity.email = "not-an-email"

    assert_not @identity.valid?
  end

  test "password must meet the minimum length" do
    @identity.password = "short"

    assert_not @identity.valid?
  end

  test "password values containing null bytes fail validation before BCrypt hashing" do
    identity = accounts(:cybros).identities.build(email: "null-password@example.com")

    BCrypt::Password.stub(:create, ->(*arguments, **keywords) { flunk "BCrypt received #{arguments.inspect} #{keywords.inspect}" }) do
      identity.password = "long\0enough password"
    end
    identity.password_confirmation = "long\0enough password"

    assert_not identity.valid?
    assert identity.errors.of_kind?(:password, :invalid)
    assert_nil identity.password_digest
  end

  test "password values containing null bytes fail every BCrypt verification path before the KDF" do
    reject_bcrypt = ->(*arguments, **keywords) { flunk "BCrypt received #{arguments.inspect} #{keywords.inspect}" }

    BCrypt::Password.stub(:new, reject_bcrypt) do
      BCrypt::Password.stub(:create, reject_bcrypt) do
        assert_not @identity.authenticate("pass\0word")
        assert_not @identity.authenticate_password("pass\0word")
        assert_nil Identity.authenticate_by(email: @identity.email, password: "pass\0word")
        assert_nil Identity.authenticate_by(email: "missing@example.com", password: "pass\0word")
      end
    end
  end

  test "passwords at exactly 72 bytes remain representable" do
    {
      ascii: "a" * 72,
      multibyte: "界" * 24,
    }.each do |label, password|
      assert_equal 72, password.bytesize

      identity = accounts(:cybros).identities.build(
        email: "#{label}-password-boundary@example.com",
        password: password,
        password_confirmation: password
      )

      assert identity.save, identity.errors.full_messages.to_sentence
      assert identity.authenticate(password)
    end
  end

  test "passwords over 72 bytes fail validation before BCrypt hashing" do
    passwords = {
      ascii: "a" * 73,
      multibyte: "界" * 25,
    }
    reject_bcrypt = ->(*arguments, **keywords) { flunk "BCrypt received #{arguments.inspect} #{keywords.inspect}" }

    assert_operator passwords.fetch(:multibyte).length, :<, 72

    BCrypt::Password.stub(:create, reject_bcrypt) do
      passwords.each do |label, password|
        assert_operator password.bytesize, :>, 72

        identity = accounts(:cybros).identities.build(email: "#{label}-overlong-password@example.com")
        identity.password = password
        identity.password_confirmation = password

        assert_not identity.valid?
        assert identity.errors.of_kind?(:password, :password_too_long)
        assert_nil identity.password_digest
      end
    end
  end

  test "passwords over 72 bytes fail every BCrypt verification path before the KDF" do
    represented_password = "a" * 72
    overlong_password = "#{represented_password}x"
    identity = accounts(:cybros).identities.create!(
      email: "overlong-authentication@example.com",
      password: represented_password,
      password_confirmation: represented_password
    )
    reject_bcrypt = ->(*arguments, **keywords) { flunk "BCrypt received #{arguments.inspect} #{keywords.inspect}" }

    BCrypt::Password.stub(:new, reject_bcrypt) do
      BCrypt::Password.stub(:create, reject_bcrypt) do
        assert_not identity.authenticate(overlong_password)
        assert_not identity.authenticate_password(overlong_password)
        assert_nil Identity.authenticate_by(email: identity.email, password: overlong_password)
        assert_nil Identity.authenticate_by(email: "missing@example.com", password: overlong_password)
      end
    end
  end

  test "reset_password changes the password and advances the recovery generation" do
    token = @identity.password_reset_token

    assert_changes -> { @identity.reload.credential_recovery_generation }, from: 0, to: 1 do
      assert_equal :reset, @identity.reset_password(token: token, password: "a brand new password", password_confirmation: "a brand new password")
    end

    assert @identity.reload.authenticate("a brand new password")
    assert_nil Identity.find_by_password_reset_token(token)
  end

  test "reset_password clears the forced-change flag" do
    @identity.update!(password_change_required: true)
    token = @identity.password_reset_token

    assert_equal :reset, @identity.reset_password(token: token, password: "a brand new password", password_confirmation: "a brand new password")
    assert_not @identity.reload.password_change_required?
  end

  test "reset_password rejects a confirmation mismatch without a state change" do
    token = @identity.password_reset_token

    assert_no_changes -> { @identity.reload.credential_recovery_generation } do
      assert_equal :invalid_input, @identity.reset_password(token: token, password: "a brand new password", password_confirmation: "different")
    end

    assert @identity.reload.authenticate("password")
  end

  test "reset_password consuming a superseded password state loses" do
    stale = Identity.find(@identity.id)
    stale_token = stale.password_reset_token
    assert_equal :reset, @identity.reset_password(token: @identity.password_reset_token, password: "a brand new password", password_confirmation: "a brand new password")

    # The stale copy models a concurrent consume whose token was minted from
    # the now-replaced password state; the in-lock re-resolve is the final
    # acceptance decision.
    assert_no_changes -> { @identity.reload.credential_recovery_generation } do
      assert_equal :superseded, stale.reset_password(token: stale_token, password: "attacker password", password_confirmation: "attacker password")
    end

    assert @identity.reload.authenticate("a brand new password")
  end

  test "a token resolved before an email change is rejected at final acceptance" do
    token = @identity.password_reset_token
    resolved = Identity.find_by_password_reset_token(token)
    assert_equal @identity, resolved

    # The email change commits after the controller resolved the token but
    # before consumption — the in-lock re-resolve must refuse it.
    Identity.find(@identity.id).change_email("moved@example.com", current_password: "password")

    assert_equal :superseded, resolved.reset_password(token: token, password: "attacker password", password_confirmation: "attacker password")
    assert @identity.reload.authenticate("password")
  end

  test "an A-to-B-to-A email round-trip keeps old reset tokens dead" do
    original = @identity.email
    token = @identity.password_reset_token

    assert @identity.change_email("elsewhere@example.com", current_password: "password")
    assert @identity.change_email(original, current_password: "password")

    assert_nil Identity.find_by_password_reset_token(token)
  end

  test "the readable reset-token payload does not contain the raw email" do
    encoded_payload = @identity.password_reset_token.split("--").first
    payload = Base64.urlsafe_decode64(encoded_payload)

    assert_not_includes payload, @identity.email
  end

  test "an email change invalidates every outstanding reset token" do
    token = @identity.password_reset_token

    assert @identity.change_email("moved@example.com", current_password: "password")
    assert_nil Identity.find_by_password_reset_token(token)
  end

  test "email change requires the current password" do
    assert_not @identity.change_email("moved@example.com", current_password: "wrong")
    assert @identity.errors[:current_password].any?
    assert_equal identities(:member).email, @identity.reload.email
  end

  test "email change treats a null-byte current password as invalid" do
    assert_not @identity.change_email("moved@example.com", current_password: "pass\0word")
    assert @identity.errors.of_kind?(:current_password, :invalid)
    assert_equal identities(:member).email, @identity.reload.email
  end

  test "email change rejects an address held by an open invitation" do
    accounts(:cybros).invitations.create!(inviter: users(:owner), email: "held@example.com")

    assert_not @identity.change_email("held@example.com", current_password: "password")
    assert @identity.errors[:email].any?
  end

  test "credential mutation requires explicit non-empty password and confirmation" do
    token = @identity.password_reset_token
    # Empty new password would otherwise be a silent no-op success.
    assert_equal :invalid_input, @identity.reset_password(token: token, password: "", password_confirmation: "")
    assert_equal :invalid_input, @identity.reset_password(token: token, password: "a brand new password", password_confirmation: nil)
    assert_nil @identity.change_password(
      current_password: "password", password: "", password_confirmation: "",
      presented_session: create_browser_session(@identity)
    )
    assert @identity.reload.authenticate("password")
  end

  test "credential mutations reject null-byte passwords without changing durable state" do
    reset_identity = Identity.find(@identity.id)
    reset_token = reset_identity.password_reset_token

    assert_no_changes -> { @identity.reload.password_digest } do
      assert_equal :invalid_input, reset_identity.reset_password(
        token: reset_token,
        password: "a brand\0new password",
        password_confirmation: "a brand\0new password"
      )
    end
    assert reset_identity.errors.of_kind?(:password, :invalid)

    change_identity = Identity.find(@identity.id)
    presented_session = create_browser_session(change_identity)
    assert_no_changes -> { @identity.reload.password_digest } do
      assert_nil change_identity.change_password(
        current_password: "password",
        password: "a brand\0new password",
        password_confirmation: "a brand\0new password",
        presented_session: presented_session
      )
    end
    assert change_identity.errors.of_kind?(:password, :invalid)
    assert Session.exists?(presented_session.id)
  end

  test "password change treats a null-byte current password as invalid" do
    presented_session = create_browser_session(@identity)

    assert_no_changes -> { @identity.reload.password_digest } do
      assert_nil @identity.change_password(
        current_password: "pass\0word",
        password: "a brand new password",
        password_confirmation: "a brand new password",
        presented_session: presented_session
      )
    end

    assert @identity.errors.of_kind?(:current_password, :invalid)
    assert Session.exists?(presented_session.id)
  end

  test "a session issued from stale identity state across a reset is born fenced" do
    # Login is not serialized against generation-advancing mutations: the
    # losing ordering mints a Session frozen to the stale generation
    # snapshot, which the validity predicate rejects on its first use.
    stale = Identity.find(@identity.id)
    assert_equal :reset, @identity.reset_password(token: @identity.password_reset_token, password: "a brand new password", password_confirmation: "a brand new password")

    session = create_browser_session(stale)
    assert_nil Session.find_usable(session.public_id)
  end

  test "change_password rejects a presented session revoked from another device" do
    session = create_browser_session(@identity)
    Session.find(session.id).destroy!

    assert_nil @identity.change_password(
      current_password: "password", password: "a brand new password", password_confirmation: "a brand new password",
      presented_session: session
    )
    assert @identity.reload.authenticate("password")
  end

  test "change_password rejects an expired presented session still present in storage" do
    session = create_browser_session(@identity)
    session.update_column(:expires_at, 1.second.ago)

    assert_no_changes -> { @identity.reload.credential_recovery_generation } do
      assert_nil @identity.change_password(
        current_password: "password", password: "a brand new password", password_confirmation: "a brand new password",
        presented_session: session
      )
    end

    assert Session.exists?(session.id)
    assert @identity.reload.authenticate("password")
  end

  test "change_password rejects a presented session with a stale identity authority snapshot" do
    session = create_browser_session(@identity)
    @identity.update!(credential_recovery_generation: @identity.credential_recovery_generation + 1)

    assert_no_changes -> { @identity.reload.credential_recovery_generation } do
      assert_nil @identity.change_password(
        current_password: "password", password: "a brand new password", password_confirmation: "a brand new password",
        presented_session: session
      )
    end

    assert Session.exists?(session.id)
    assert @identity.reload.authenticate("password")
  end

  test "change_password rejects a presented session with a stale member authority snapshot" do
    session = create_browser_session(@identity)
    @identity.user.update!(authority_generation: @identity.user.authority_generation + 1)

    assert_no_changes -> { @identity.reload.credential_recovery_generation } do
      assert_nil @identity.change_password(
        current_password: "password", password: "a brand new password", password_confirmation: "a brand new password",
        presented_session: session
      )
    end

    assert Session.exists?(session.id)
    assert @identity.reload.authenticate("password")
  end

  test "password_resettable? requires an active human member with a clear recovery fence" do
    assert @identity.password_resettable?

    @identity.user.update!(status: :suspended)
    assert_not @identity.password_resettable?

    @identity.user.update!(status: :active)
    @identity.update!(local_recovery_pending_at: Time.current)
    assert_not @identity.password_resettable?

    orphan = accounts(:cybros).identities.create!(
      email: "orphan@example.com",
      password: "long enough password", password_confirmation: "long enough password"
    )
    assert_not orphan.password_resettable?
  end
end
