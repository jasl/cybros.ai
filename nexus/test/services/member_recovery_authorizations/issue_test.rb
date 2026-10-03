require "test_helper"

class MemberRecoveryAuthorizations::IssueTest < ActiveSupport::TestCase
  setup do
    @member = users(:member)
    @identity = identities(:member)
  end

  test "issue advances the generation, sets the fence, and reveals the secret once" do
    session = create_browser_session(@identity)

    result = nil
    assert_changes -> { @identity.reload.credential_recovery_generation }, from: 0, to: 1 do
      result = MemberRecoveryAuthorizations::Issue.call(user: @member)
    end

    assert_equal :issued, result.outcome
    assert result.secret.start_with?(MemberRecoveryAuthorization::WIRE_PREFIX)
    assert @identity.reload.local_recovery_pending?
    assert_no_match(
      /#{Regexp.escape(result.secret.split(".").last)}/,
      result.authorization.attributes.values.join(" ")
    )
    assert_equal result.authorization, MemberRecoveryAuthorization.find_by_secret(result.secret)
    assert_not session.reload.usable?
  end

  test "issue rejects agent-kind and inactive targets" do
    assert_equal :not_recoverable,
      MemberRecoveryAuthorizations::Issue.call(user: users(:system)).outcome
    assert_equal :not_recoverable,
      MemberRecoveryAuthorizations::Issue.call(user: nil).outcome

    @member.suspend
    assert_equal :not_recoverable,
      MemberRecoveryAuthorizations::Issue.call(user: @member.reload).outcome
  end

  test "reissue supersedes the previous secret and keeps the fence pending" do
    first = MemberRecoveryAuthorizations::Issue.call(user: @member)
    second = MemberRecoveryAuthorizations::Issue.call(user: @member)

    assert first.authorization.reload.superseded_at.present?
    assert_not first.authorization.consumable?
    assert second.authorization.consumable?
    assert_equal 2, @identity.reload.credential_recovery_generation
    assert @identity.local_recovery_pending?
  end

  test "row creation failure rolls back the generation fence and supersession" do
    current = MemberRecoveryAuthorizations::Issue.call(user: @member).authorization
    generation = @identity.reload.credential_recovery_generation
    failure = ->(*, **) { raise "row creation failed" }

    assert_raises(RuntimeError) do
      MemberRecoveryAuthorization.stub(:create!, failure) do
        MemberRecoveryAuthorizations::Issue.call(user: @member)
      end
    end

    assert_equal generation, @identity.reload.credential_recovery_generation
    assert current.reload.consumable?
  end

  test "the Active Record model exposes no raw-secret issuance factory" do
    assert_not_respond_to MemberRecoveryAuthorization, :mint
  end
end
