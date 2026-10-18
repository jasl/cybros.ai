require "test_helper"

class MemberRecoveryAuthorization::ConvergenceTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.local(2026, 7, 28, 12)
    @member = users(:member)
    @owner = users(:owner)
  end

  test "reap removes only retained terminal or expired evidence" do
    old = @now - MemberRecoveryAuthorization::EVIDENCE_RETENTION - 1.second
    recent = @now - MemberRecoveryAuthorization::EVIDENCE_RETENTION + 1.second

    old_consumed = create_authorization(user: @member, consumed_at: old)
    old_superseded = create_authorization(user: @member, superseded_at: old)
    old_expired = create_authorization(user: @owner, expires_at: old)
    recent_consumed = create_authorization(user: @member, consumed_at: recent)
    current_unexpired = create_authorization(
      user: @member,
      expires_at: MemberRecoveryAuthorization::SECRET_LIFETIME.from_now(@now)
    )

    assert_equal 3, MemberRecoveryAuthorization.reap(now: @now)[:reaped]

    assert_not MemberRecoveryAuthorization.exists?(old_consumed.id)
    assert_not MemberRecoveryAuthorization.exists?(old_superseded.id)
    assert_not MemberRecoveryAuthorization.exists?(old_expired.id)
    assert MemberRecoveryAuthorization.exists?(recent_consumed.id)
    assert MemberRecoveryAuthorization.exists?(current_unexpired.id)
  end

  test "reap performs one bounded batch and repeated invocations continue idempotently" do
    old = @now - MemberRecoveryAuthorization::EVIDENCE_RETENTION - 1.second
    authorizations = Array.new(3) do
      create_authorization(user: @member, consumed_at: old)
    end
    authorization_ids = authorizations.map(&:id)

    assert_equal 1, MemberRecoveryAuthorization.reap(now: @now, batch_size: 1)[:reaped]
    assert_equal 2, MemberRecoveryAuthorization.where(id: authorization_ids).count

    assert_equal 1, MemberRecoveryAuthorization.reap(now: @now, batch_size: 1)[:reaped]
    assert_equal 1, MemberRecoveryAuthorization.where(id: authorization_ids).count

    assert_equal 1, MemberRecoveryAuthorization.reap(now: @now, batch_size: 1)[:reaped]
    assert_equal 0, MemberRecoveryAuthorization.where(id: authorization_ids).count
    assert_equal 0, MemberRecoveryAuthorization.reap(now: @now, batch_size: 1)[:reaped]
  end

  test "a source row spends budget when the applying delete loses" do
    old = @now - MemberRecoveryAuthorization::EVIDENCE_RETENTION - 1.second
    create_authorization(user: @member, consumed_at: old)
    create_authorization(user: @member, superseded_at: old)
    discoveries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.start_with?('SELECT "member_recovery_authorizations"."id"')
        discoveries << sql
      end
    end

    result = MemberRecoveryAuthorization.stub(:delete_reap_window, ->(_window) { 0 }) do
      MemberRecoveryAuthorization.reap(now: @now, batch_size: 1)
    end

    assert_equal 0, result[:reaped]
    assert_equal 1, result[:scanned]
    assert result.more?
    assert_equal 1, discoveries.length,
      "the full source window leaves no budget for another cause"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "recurring schedule invokes the bounded reaper" do
    schedule = recurring_schedule

    assert_equal(
      "MemberRecoveryAuthorizations::ReapJob",
      schedule.dig("reap_member_recovery_authorizations", "class")
    )
  end

  private

    def create_authorization(user:, consumed_at: nil, superseded_at: nil, expires_at: 1.day.from_now(@now))
      MemberRecoveryAuthorization.create!(
        account: user.account,
        identity: user.identity,
        user: user,
        generation: user.identity.credential_recovery_generation,
        lookup_id: SecureRandom.base58(24),
        secret_digest: "test digest",
        expires_at: expires_at,
        consumed_at: consumed_at,
        superseded_at: superseded_at
      )
    end
end
