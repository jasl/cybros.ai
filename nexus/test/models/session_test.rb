require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    @identity = identities(:member)
  end

  test "issuance freezes expiry and both authority snapshots" do
    freeze_time do
      session = create_browser_session(@identity)

      assert_equal Session::LIFETIME.from_now, session.expires_at
      assert_equal users(:member).authority_generation, session.user_authority_generation
      assert_equal @identity.credential_recovery_generation, session.identity_recovery_generation
    end
  end

  test "a fresh session is usable" do
    assert create_browser_session(@identity).usable?
  end

  test "an expired session is not usable" do
    session = create_browser_session(@identity)

    travel Session::LIFETIME + 1.minute do
      assert session.expired?
      assert_not session.usable?
    end
  end

  test "advancing the user authority generation fences earlier sessions" do
    session = create_browser_session(@identity)
    users(:member).increment!(:authority_generation)

    assert_not session.reload.usable?
  end

  test "advancing the identity recovery generation fences earlier sessions" do
    session = create_browser_session(@identity)
    @identity.increment!(:credential_recovery_generation)

    assert_not session.reload.usable?
  end

  test "a non-active frozen user makes the session unusable" do
    session = create_browser_session(@identity)
    users(:member).update!(status: :suspended)

    assert_not session.reload.usable?
  end

  test "a pending local-recovery fence makes the session unusable" do
    session = create_browser_session(@identity)
    @identity.update!(local_recovery_pending_at: Time.current)

    assert_not session.reload.usable?
  end

  test "listable_for excludes expired and generation-fenced sessions" do
    identity = identities(:member)
    live = create_browser_session(identity)
    expired = create_browser_session(identity)
    expired.update_column(:expires_at, 1.hour.ago)
    fenced = create_browser_session(identity)
    fenced.update_column(:identity_recovery_generation, identity.credential_recovery_generation - 1)

    listed = Session.listable_for(identity)
    assert_includes listed, live
    assert_not_includes listed, expired
    assert_not_includes listed, fenced
  end

  test "reap deletes expired and fenced sessions and keeps live ones" do
    identity = identities(:member)
    live = create_browser_session(identity)
    expired = create_browser_session(identity)
    expired.update_column(:expires_at, 1.hour.ago)
    fenced = create_browser_session(identity)
    fenced.update_column(:identity_recovery_generation, identity.credential_recovery_generation - 1)
    authority_fenced = create_browser_session(identity)
    authority_fenced.update_column(:user_authority_generation, identity.user.authority_generation + 1)

    result = Session.reap

    assert_equal 1, result[:expired]
    assert_equal 2, result[:fenced]
    assert Session.exists?(live.id)
    assert_not Session.exists?(expired.id)
    assert_not Session.exists?(fenced.id)
    assert_not Session.exists?(authority_fenced.id)
  end

  # The budget counts SCANNED source rows, not deletions: the fenced
  # predicate is a cross-table generation comparison no index can serve, so
  # clean rows consume budget and the cursor walks past them — the same
  # window idiom as every other M7 sweep. Driving the cursor here is exactly
  # what Sessions::ReapJob's continuation does.
  test "reap spends its batch on scanned windows and the cursor chain finishes the backlog" do
    now = Time.current
    identity = identities(:member)
    live = create_browser_session(identity)
    expired = 3.times.map do
      create_browser_session(identity).tap do |session|
        session.update_column(:expires_at, now - 1.hour)
      end
    end
    fenced = 3.times.map do
      create_browser_session(identity).tap do |session|
        session.update_column(
          :identity_recovery_generation,
          identity.credential_recovery_generation - 1
        )
      end
    end

    results = []
    cursor = 0
    20.times do
      result = Session.reap(now:, batch_size: 2, fenced_after_id: cursor)
      results << result
      cursor = result.cursor
      break unless result.more?
    end

    assert results.all? { |result| result[:scanned] <= 2 }
    assert_operator results.length, :<, 20, "the cursor chain must terminate"
    assert expired.none? { |session| Session.exists?(session.id) }
    assert fenced.none? { |session| Session.exists?(session.id) }
    assert Session.exists?(live.id)

    idle = Session.reap(now:, batch_size: 2)
    assert_equal 0, idle[:expired]
    assert_equal 0, idle[:fenced]
  end

  test "the recurring schedule invokes the session reap job" do
    assert_equal "Sessions::ReapJob",
      recurring_schedule.dig("reap_dead_sessions", "class")
  end
end
