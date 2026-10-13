require "test_helper"

class MemberRecoveryAuthorizationTest < ActiveSupport::TestCase
  setup do
    @member = users(:member)
    @identity = identities(:member)
  end

  test "consume changes the password, clears the fence, and creates no session" do
    issue = MemberRecoveryAuthorizations::Issue.call(user: @member)

    assert_no_difference -> { Session.count } do
      assert_equal :recovered, @identity.reload.consume_local_recovery(
        authorization: issue.authorization,
        password: "a brand new password",
        password_confirmation: "a brand new password"
      )
    end

    @identity.reload
    assert @identity.authenticate("a brand new password")
    assert_not @identity.local_recovery_pending?
    assert issue.authorization.reload.consumed_at.present?
    # The generation stays at the minted value: pending(n) -> clear(n).
    assert_equal 1, @identity.credential_recovery_generation
  end

  test "consume rejects a null-byte password without consuming the authorization" do
    issue = MemberRecoveryAuthorizations::Issue.call(user: @member)
    identity = @identity.reload
    original_digest = identity.password_digest

    assert_equal :invalid_input, identity.consume_local_recovery(
      authorization: issue.authorization,
      password: "a brand\0new password",
      password_confirmation: "a brand\0new password"
    )

    assert identity.errors.of_kind?(:password, :invalid)
    assert_equal original_digest, identity.reload.password_digest
    assert identity.local_recovery_pending?
    assert issue.authorization.reload.consumable?
  end

  test "a repeated consume of the same secret makes no state change" do
    issue = MemberRecoveryAuthorizations::Issue.call(user: @member)
    stale_copy = MemberRecoveryAuthorization.find(issue.authorization.id)

    assert_equal :recovered, @identity.reload.consume_local_recovery(
      authorization: issue.authorization,
      password: "a brand new password",
      password_confirmation: "a brand new password"
    )

    # The repeat consumer holds the pre-consume in-memory row; the in-lock
    # reload must observe the winner's consumed_at and refuse.
    assert_equal :superseded, @identity.reload.consume_local_recovery(
      authorization: stale_copy,
      password: "another password entirely",
      password_confirmation: "another password entirely"
    )
    assert @identity.reload.authenticate("a brand new password")
  end

  test "consume clears the forced-change flag" do
    @identity.update!(password_change_required: true)
    issue = MemberRecoveryAuthorizations::Issue.call(user: @member)

    assert_equal :recovered, @identity.reload.consume_local_recovery(
      authorization: issue.authorization,
      password: "a brand new password",
      password_confirmation: "a brand new password"
    )
    assert_not @identity.reload.password_change_required?
  end

  test "a superseded or expired secret cannot consume and never clears the fence" do
    first = MemberRecoveryAuthorizations::Issue.call(user: @member)
    MemberRecoveryAuthorizations::Issue.call(user: @member)

    assert_equal :superseded, @identity.reload.consume_local_recovery(
      authorization: first.authorization.reload,
      password: "a brand new password",
      password_confirmation: "a brand new password"
    )
    assert @identity.reload.local_recovery_pending?

    current = MemberRecoveryAuthorization.current.find_by!(identity: @identity)
    travel MemberRecoveryAuthorization::SECRET_LIFETIME + 1.second do
      assert_equal :superseded, @identity.reload.consume_local_recovery(
        authorization: current,
        password: "a brand new password",
        password_confirmation: "a brand new password"
      )
    end
    assert @identity.reload.local_recovery_pending?
    assert @identity.authenticate("password")
  end

  test "while pending the emailed reset path is ineligible and login is refused" do
    MemberRecoveryAuthorizations::Issue.call(user: @member)
    identity = @identity.reload

    assert_not identity.password_resettable?
    outcome = Sessions::Start.call(
      source: Sessions::Start::Credentials.new(email: identity.email, password: "password")
    )
    assert_equal :local_recovery_required, outcome.outcome
    assert_nil outcome.session
  end
end
