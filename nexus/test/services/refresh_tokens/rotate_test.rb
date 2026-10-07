require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class RefreshTokens::RotateTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_remove_accepted_before_rotation_fences_both_planes,
    :test_an_epoch_advance_accepted_before_rotation_final_acceptance_creates_nothing,
    :test_a_rotation_racing_a_revoke_serializes_on_the_user_instead_of_deadlocking

  setup do
    @owner = users(:owner)
    @member = create_agent_member(steward: @owner, display_name: "Rotator", agent_identifier: "install-rotate")
    @executor = @member.task_executors.create!(account: @member.account, executor_kind: :agent_application, display_name: "Rotator app")
    @initial = mint_family
  end

  # The race the global lock order exists for: rotation used to lock family-then-user while
  # revoke_connection locks user-then-family — an ABBA cycle PostgreSQL resolved by killing one side
  # with Deadlocked, which surfaced as a 500 on the token endpoint or on the steward's revoke click.
  # Both sides now descend users -> executor -> family, so overlapping them queues on the user row
  # and converges: either the rotation wins and the revoke fences its freshly minted pair, or the
  # revoke wins and the rotation reports invalid_grant. Never an exception.
  def test_a_rotation_racing_a_revoke_serializes_on_the_user_instead_of_deadlocking
    refresh = @initial.token
    # Held on the FAMILY row: under the old order the rotation queued here
    # FIRST while the revoke walked in through the free user row and queued
    # behind it — so releasing handed the family to the rotation while the
    # revoke already held the user, which is the cycle. Under the global order
    # the rotation takes the user before ever touching the family, so the
    # revoke queues on the user instead and the cycle cannot form.
    held = hold_row_lock(RefreshTokenFamily, refresh.refresh_token_family_id)

    rotation = start_database_call do
      RefreshTokens::Rotate.call(presented: RefreshToken.find(refresh.id))
    end
    wait_until_waiting_on_lock(rotation.pid)
    revoke = start_database_call do
      User.find(@member.id).revoke_connection
    end
    wait_until_waiting_on_lock(rotation.pid, revoke.pid)

    release_row_lock(held)
    held = nil
    rotation_result = finish_database_call(rotation)
    rotation = nil
    revoke_result = finish_database_call(revoke)
    revoke = nil

    assert_equal :revoked, revoke_result
    assert_includes %i[rotated invalid_grant], rotation_result.outcome
    assert_predicate @initial.token.refresh_token_family.reload, :revoked?,
      "whichever side wins, the family ends revoked"
    if rotation_result.outcome == :rotated
      assert_nil AccessToken.authenticate_executor_token(rotation_result.executor_access_secret),
        "a pair minted before the revoke won must be fenced by it"
    end
  ensure
    release_row_lock(held) if held
    stop_database_call(rotation) if rotation
    stop_database_call(revoke) if revoke
  end

  # A current executor-bound refresh stamps the address's contact time even though it does not pass
  # through executor endpoint authentication. Otherwise an unattended daemon that only refreshes
  # credentials would appear last seen at connection time.
  def test_a_rotation_records_that_the_address_was_seen
    @executor.update_columns(last_seen_at: nil)

    assert_equal :rotated, rotate(@initial.secret).outcome

    assert_not_nil @executor.reload.last_seen_at,
      "token rotation refreshes last_seen_at"
  end

  # The stamp shares the sampling every other last_seen_at writer uses,
  # and must never move the credential's own cutoff — folding the two would let
  # a contact sample extend a lineage's inactivity window.
  def test_the_rotation_stamp_is_sampled_and_leaves_the_credential_clock_alone
    first = rotate(@initial.secret)
    assert_equal :rotated, first.outcome
    stamped = @executor.reload.last_seen_at
    family_clock = @initial.token.refresh_token_family.reload.last_used_at

    second = rotate(first.refresh_secret)
    assert_equal :rotated, second.outcome

    assert_equal stamped, @executor.reload.last_seen_at, "inside the window, one stamp"
    assert_operator @initial.token.refresh_token_family.reload.last_used_at, :>, family_clock,
      "the credential clock advances on every rotation, independently"
  end

  def mint_family(member: @member, executor: @executor)
    family = RefreshTokenFamily.create!(
      account: member.account,
      user: member,
      access_token_name: "Device pairing",
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation,
      last_used_at: Time.current
    )
    access = member.access_tokens.create!(
      refresh_token_family: family,
      credential_plane: :executor_transport,
      name: "Device pairing", source: :oauth_device,
      lookup_id: SecureRandom.base58(24), secret_digest: "seed",
      expires_at: AccessToken::OAUTH_TTL.from_now, task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation
    )
    RefreshTokens::Issue.call(refresh_token_family: family, access_token: access)
  end

  RunnerLineage = Data.define(:runner, :family, :transport_secret, :initial)

  # Branch B: an identity-less lineage whose whole subject is the machine — no member, no member
  # authority snapshot, transport plane only. Mirrors what DeviceAuthorizations::Consume mints for a
  # runner connection.
  def mint_runner_lineage(identifier: "install-runner")
    runner = @member.account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Workshop laptop",
      registration_identifier: identifier,
      manager: @owner,
      assignment_scope: :user_private
    )
    name = "Runner connection — Workshop laptop"
    family = runner.account.refresh_token_families.create!(
      access_token_name: name,
      task_executor: runner,
      credential_epoch: runner.credential_epoch,
      last_used_at: Time.current
    )
    parts = AccessToken::DIGESTED.mint_parts
    transport = family.account.access_tokens.create!(
      refresh_token_family: family,
      credential_plane: :executor_transport,
      name: name, source: :oauth_device,
      lookup_id: parts.lookup_id, secret_digest: parts.digest,
      expires_at: AccessToken::OAUTH_TTL.from_now,
      task_executor: runner, credential_epoch: runner.credential_epoch
    )

    RunnerLineage.new(
      runner: runner, family: family, transport_secret: parts.raw,
      initial: RefreshTokens::Issue.call(refresh_token_family: family, access_token: transport)
    )
  end

  def rotate(secret)
    RefreshTokens::Rotate.call(presented: RefreshToken.find_by_secret(secret))
  end

  test "the current token rotates, preserving binding and generation" do
    result = rotate(@initial.secret)

    assert_equal :rotated, result.outcome
    assert result.refresh_secret.start_with?("rt-cybros-api-v1-")

    successor = result.refresh_token
    family = successor.refresh_token_family
    assert_equal @initial.token.refresh_token_family, family
    assert_equal @executor, family.task_executor
    assert_equal @member.authority_generation, family.user_authority_generation

    assert_equal "oauth_refresh", result.access_token.source
    assert_in_delta 14.days.from_now, result.access_token.expires_at, 5
    assert_equal family, result.access_token.refresh_token_family
    # Rotation reissues the whole bundle.
    assert_predicate result.access_token, :member_plane?
    assert_nil result.access_token.task_executor
    assert_equal result.access_token, AccessToken.authenticate_token(result.access_secret)
    assert_equal @executor, result.executor_access_token.task_executor
    assert_equal result.executor_access_token,
      AccessToken.authenticate_executor_token(result.executor_access_secret)

    @initial.token.reload
    assert_equal successor, @initial.token.superseded_by
    assert_not @initial.token.current?
  end

  test "Agent removal refuses rotation without minting either plane" do
    assert_equal :removed, @member.remove

    assert_no_difference "AccessToken.count" do
      assert_equal :invalid_grant, rotate(@initial.secret).outcome
    end
  end

  test "a bound lineage rotating under a suspended steward reissues transport alone" do
    users(:member).change_role(to: :admin)
    @member.account.transfer_ownership(to: users(:member).reload, by: @owner)
    assert_equal :suspended, @owner.reload.suspend

    result = rotate(@initial.secret)

    assert_equal :rotated, result.outcome
    assert_nil result.access_token
    assert result.executor_access_token
  end

  test "a restored steward with pending shutdown convergence reissues transport alone" do
    steward = users(:member)
    member = create_agent_member(
      steward: steward,
      display_name: "Pending shutdown",
      agent_identifier: "pending-shutdown-rotation"
    )
    executor = member.task_executors.create!(
      account: member.account,
      executor_kind: :agent_application,
      display_name: "Pending shutdown app"
    )
    initial = mint_family(member:, executor:)

    assert_equal :removed, steward.remove
    assert_equal :restored, steward.reload.restore
    assert_predicate member.reload, :active?
    assert_not member.steward_live?,
      "restore does not erase the durable Human-shutdown episode"

    result = rotate(initial.secret)

    assert_equal :rotated, result.outcome
    assert_nil result.access_token
    assert_nil result.access_secret
    assert_equal executor, result.executor_access_token.task_executor
    assert_equal result.executor_access_token,
      AccessToken.authenticate_executor_token(result.executor_access_secret)
    assert_equal result.executor_access_token, result.refresh_token.access_token
  end

  test "reuse of a superseded token revokes the whole family and its access tokens" do
    first = rotate(@initial.secret)
    live_access = first.executor_access_token
    assert live_access.executor_usable?

    # Replaying the original (now superseded) token is reuse.
    disconnected = nil
    reuse = RealtimeConnections::Disconnect.stub(
      :credentials,
      ->(tokens, reconnect: true) { disconnected = [tokens.map(&:id), reconnect] }
    ) do
      rotate(@initial.secret)
    end
    assert_equal :invalid_grant, reuse.outcome
    assert_equal [[first.access_token.id], true], disconnected,
      "reuse closes the old family socket after the family fence commits"

    family = first.refresh_token.refresh_token_family.reload
    assert_predicate family, :revoked?
    assert_predicate first.refresh_token.reload, :current?
    assert_not_predicate family, :rotation_acceptable?
    assert_nil AccessToken.authenticate_token(first.access_secret)
    assert_nil AccessToken.authenticate_executor_token(first.executor_access_secret)
    assert_nil live_access.reload.revoked_at, "the family fence is immediate; row markers converge later"
  end

  # A predecessor's fixed evidence window covers the access credentials minted
  # by the same rotation. Older predecessors can then be reclaimed without
  # waiting for a continually active family to lapse.
  test "each predecessor retains the fixed replay-recognition interval" do
    result = rotate(@initial.secret)

    assert_equal :rotated, result.outcome
    assert_equal(
      RefreshTokenFamily::INACTIVITY_WINDOW + AccessToken::OAUTH_TTL,
      RefreshToken::EVIDENCE_RETENTION
    )
    predecessor = @initial.token.reload
    evidence_until = predecessor.consumed_at + RefreshToken::EVIDENCE_RETENTION
    assert_operator result.access_token.expires_at, :<=, evidence_until
  end

  # The only natural death a connection has, now that nothing expires it on a
  # calendar. A lapse is not a reuse, so it must not fence the family.
  test "inactivity lapse is invalid_grant without a family cascade" do
    family = @initial.token.refresh_token_family
    family.update!(last_used_at: (RefreshTokenFamily::INACTIVITY_WINDOW + 1.day).ago)

    assert_equal :invalid_grant, rotate(@initial.secret).outcome
    assert_not family.reload.revoked?
  end

  # There is deliberately no absolute ceiling: a lineage that keeps rotating
  # keeps living, however old it is.
  test "an old lineage that keeps rotating never expires on age alone" do
    family = @initial.token.refresh_token_family
    family.update_columns(created_at: 2.years.ago, updated_at: 2.years.ago)

    assert_equal :rotated, rotate(@initial.secret).outcome
  end

  test "restoring an Agent does not revive its old refresh lineage" do
    @member.remove
    @member.restore

    assert_equal :invalid_grant, rotate(@initial.secret).outcome
  end

  test "a competing reconnect's epoch advance fences the family's rotation" do
    advance_credential_epoch(@executor)
    assert_equal :invalid_grant, rotate(@initial.secret).outcome
  end

  # A live runner rotates and revokes its own credential
  # (docs/oauth/device-flow.md, Branch B): the lineage names no principal, so
  # its own address is the whole authority it reissues under.
  test "an identity-less runner lineage rotates its transport plane alone" do
    lineage = mint_runner_lineage

    result = rotate(lineage.initial.secret)

    assert_equal :rotated, result.outcome
    # A runner is not a principal: there is no member plane to reissue.
    assert_nil result.access_token
    assert_nil result.access_secret

    transport = result.executor_access_token
    assert_predicate transport, :executor_transport_plane?
    assert_nil transport.user
    assert_nil transport.user_authority_generation
    assert_equal lineage.runner, transport.task_executor
    assert_equal lineage.runner.credential_epoch, transport.credential_epoch
    assert_equal lineage.family, transport.refresh_token_family
    assert_equal lineage.family.account, transport.account
    assert_equal "oauth_refresh", transport.source
    assert_in_delta 14.days.from_now, transport.expires_at, 5
    assert_equal transport, AccessToken.authenticate_executor_token(result.executor_access_secret)
    assert_nil AccessToken.authenticate_token(result.executor_access_secret)

    # The successor pairs with the lineage's leading credential — here its
    # only one — and the family's frozen facts survive rotation.
    successor = result.refresh_token
    assert_equal lineage.family, successor.refresh_token_family
    assert_nil successor.user
    assert_equal transport, successor.access_token
    assert_equal successor, lineage.initial.token.reload.superseded_by
    assert_not lineage.initial.token.current?
    assert_nil lineage.family.reload.user_id
    assert_nil lineage.family.user_authority_generation
    assert_equal lineage.runner, lineage.family.task_executor
  end

  test "a runner lineage rotates repeatedly on its own transport plane" do
    lineage = mint_runner_lineage

    first = rotate(lineage.initial.secret)
    assert_equal :rotated, first.outcome

    second = rotate(first.refresh_secret)
    assert_equal :rotated, second.outcome
    assert_predicate second.executor_access_token, :executor_transport_plane?
  end

  test "a competing runner reconnect's epoch advance fences the rotation" do
    lineage = mint_runner_lineage
    advance_credential_epoch(lineage.runner)

    assert_equal :invalid_grant, rotate(lineage.initial.secret).outcome
    # The superseded device lapsed; it was not reused, so nothing cascades.
    assert_not lineage.family.reload.revoked?
  end

  test "a revoked runner cannot rotate its own credential" do
    lineage = mint_runner_lineage
    lineage.runner.revoke

    assert_equal :invalid_grant, rotate(lineage.initial.secret).outcome
  end

  test "a runner lineage that lapsed for inactivity is an ordinary lapse" do
    lineage = mint_runner_lineage
    lineage.family.update!(last_used_at: (RefreshTokenFamily::INACTIVITY_WINDOW + 1.day).ago)

    assert_equal :invalid_grant, rotate(lineage.initial.secret).outcome
    assert_not lineage.family.reload.revoked?
  end

  test "reuse on a runner lineage revokes the family and leaves the machine" do
    lineage = mint_runner_lineage
    first = rotate(lineage.initial.secret)
    assert_equal :rotated, first.outcome

    assert_equal :invalid_grant, rotate(lineage.initial.secret).outcome

    assert_predicate lineage.family.reload, :revoked?
    assert_nil AccessToken.authenticate_executor_token(first.executor_access_secret)
    assert_nil AccessToken.authenticate_executor_token(lineage.transport_secret)
    # The machine outlives any one credential lineage: it reconnects under the
    # same registration_identifier rather than asking an administrator for a
    # credential (docs/oauth/device-flow.md, Branch B).
    assert_predicate lineage.runner.reload, :active?
  end

  test "evidence reaped after digest lookup is invalid_grant" do
    presented = RefreshToken.find_by_secret(@initial.secret)
    presented.destroy!

    result = RefreshTokens::Rotate.call(
      presented: presented)

    assert_equal :invalid_grant, result.outcome
  end

  test "two rotations of one current token: at most one successor, family revoked" do
    first = rotate(@initial.secret)
    second = rotate(@initial.secret)

    assert_equal :rotated, first.outcome
    assert_equal :invalid_grant, second.outcome
    # After reuse, no family credential authenticates.
    assert_nil AccessToken.authenticate_token(first.access_secret)
  end

  test "remove accepted before rotation fences both planes" do
    family_id = @initial.token.refresh_token_family_id
    initial_access_ids = AccessToken.where(refresh_token_family_id: family_id).ids
    held_lock = hold_row_lock(
      User,
      @member.id,
      before_commit: ->(locked) {
        outcome = locked.remove
        raise "agent removal failed: #{outcome}" unless outcome == :removed
      }
    )
    rotation_call = start_database_call do
      RefreshTokens::Rotate.call(
        presented: RefreshToken.find_by_secret(@initial.secret),
      )
    end

    wait_until_waiting_on_lock(rotation_call.pid)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_database_call(rotation_call)
    rotation_call = nil

    assert_equal :invalid_grant, result.outcome
    assert @member.reload.removed?
    assert_predicate @initial.token.reload, :current?
    assert_equal initial_access_ids,
      AccessToken.where(refresh_token_family_id: family_id).ids
  ensure
    release_row_lock(held_lock) if held_lock
    stop_database_call(rotation_call) if rotation_call
    if family_id
      RefreshToken.where(refresh_token_family_id: family_id).delete_all
      AccessToken.where(refresh_token_family_id: family_id).delete_all
      RefreshTokenFamily.where(id: family_id).delete_all
    end
    TaskExecutor.where(id: @executor.id).delete_all if @executor
    User.where(id: @member.id).delete_all if @member
  end

  test "an epoch advance accepted before rotation final acceptance creates nothing" do
    family_id = @initial.token.refresh_token_family_id
    initial_access_ids = AccessToken.where(refresh_token_family_id: family_id).ids
    held_lock = hold_row_lock(
      TaskExecutor,
      @executor.id,
      before_commit: ->(locked) {
        locked.update!(credential_epoch: locked.credential_epoch + 1)
      }
    )
    rotation_call = start_database_call do
      RefreshTokens::Rotate.call(
        presented: RefreshToken.find_by_secret(@initial.secret),
      )
    end

    wait_until_waiting_on_lock(rotation_call.pid)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_database_call(rotation_call)
    rotation_call = nil

    assert_equal :invalid_grant, result.outcome
    assert_equal 2, @executor.reload.credential_epoch
    assert @initial.token.reload.current?
    assert_equal initial_access_ids,
      AccessToken.where(refresh_token_family_id: family_id).ids
  ensure
    release_row_lock(held_lock) if held_lock
    stop_database_call(rotation_call) if rotation_call
    if family_id
      RefreshToken.where(refresh_token_family_id: family_id).delete_all
      AccessToken.where(refresh_token_family_id: family_id).delete_all
      RefreshTokenFamily.where(id: family_id).delete_all
    end
    TaskExecutor.where(id: @executor.id).delete_all if @executor
    User.where(id: @member.id).delete_all if @member
  end
end
