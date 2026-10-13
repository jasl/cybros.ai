require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class DeviceAuthorizations::ConsumeTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_consume_and_connection_lock_the_user_before_the_address,
    :test_consume_classifies_a_terminal_state_that_wins_while_waiting_for_the_authorization_lock,
    :test_consume_crossing_its_deadline_while_waiting_for_authority_expires_without_minting,
    :test_consume_crossing_its_deadline_while_waiting_for_the_agent_address_preserves_the_pairing,
    :test_authority_drift_terminalizes_inside_the_mint_transaction

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  # Build a connected grant the way the browser connection leaves it: the
  # mapping, its authority snapshot, and the current delivery-address
  # precondition are frozen; the address is still created or re-paired only
  # at consume.
  def connected_grant(agent_identifier: "install-consume", member: nil,
                      display_name: "Consumer app", connected_by: @owner)
    grant = DeviceAuthorizations::Issue.call(
      account: @account, agent_identifier: agent_identifier, agent_display_name: "Consumer",
      requested_executor_display_name: display_name).authorization
    grant.record_connection(
      user: member,
      connector: connected_by,
      expected_task_executor: (TaskExecutor.address_for(member) if member)
    )
    grant
  end

  def new_agent(identifier: "install-consume")
    @account.users.create!(kind: :agent, role: :member, steward: @owner, display_name: "Consumer", agent_identifier: identifier)
  end

  test "consuming a new-executor grant mints the credential pair and creates the executor" do
    member = new_agent
    grant = connected_grant(member: member)

    result = DeviceAuthorizations::Consume.call(authorization: grant)

    assert_equal :minted, result.outcome
    assert result.access_secret.start_with?("sk-cybros-api-v1-")
    assert result.refresh_secret.start_with?("rt-cybros-api-v1-")

    grant.reload
    assert grant.consumed?
    executor = member.task_executors.sole
    assert_equal "agent_application", executor.executor_kind
    assert_equal "Consumer app", executor.display_name
    # One connection, one bundle: a member credential for the member/data plane and this executor's
    # transport credential.
    assert_predicate result.access_token, :member_plane?
    assert_nil result.access_token.task_executor
    assert_equal result.access_token, AccessToken.authenticate_token(result.access_secret)

    transport = result.executor_access_token
    assert_predicate transport, :executor_transport_plane?
    assert_equal executor, transport.task_executor
    assert_equal executor.credential_epoch, transport.credential_epoch
    assert_equal "oauth_device", transport.source
    assert_in_delta 14.days.from_now, transport.expires_at, 5
    assert_equal transport, AccessToken.authenticate_executor_token(result.executor_access_secret)
    # Each credential answers only its own plane.
    assert_nil AccessToken.authenticate_executor_token(result.access_secret)
    assert_nil AccessToken.authenticate_token(result.executor_access_secret)

    family = result.refresh_token.refresh_token_family
    assert_equal family, result.access_token.refresh_token_family
    assert_equal family, transport.refresh_token_family
    assert_equal executor, family.task_executor
    assert_predicate result.refresh_token, :current?
    assert_predicate family, :rotation_acceptable?
    assert_equal result.access_token, grant.access_token
    assert_equal result.refresh_token, grant.refresh_token
  end

  test "two grants connected against an absent address have one consume winner" do
    # Both codes connected while the program raced itself (restarted
    # mid-flow). Both froze "no address"; the first winner creates it, and the
    # other grant is stale rather than immediately re-pairing that new address.
    member = new_agent
    first = connected_grant(member: member)
    second = connected_grant(member: member)

    assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: first).outcome
    assert_equal :access_denied,
      DeviceAuthorizations::Consume.call(authorization: second).outcome
    assert_equal 1, member.task_executors.count
    assert_equal 1, member.task_executors.sole.credential_epoch

    assert_equal 1, member.refresh_token_families.count
    assert_equal 1, member.refresh_token_families.live.count
  end

  test "consume and connection lock the user before the address" do
    # Consume re-pairs the profile's address under the member lock;
    # connection takes only user locks. Holding that address's row while
    # both run proves the shared user-before-executor lock order holds and
    # neither call deadlocks.
    member = users(:agent)
    executor = task_executors(:address)
    consume_grant = connected_grant(
      member: member,
      agent_identifier: member.agent_identifier
    )
    connection_grant = DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: member.agent_identifier,
      agent_display_name: member.display_name,
      requested_executor_display_name: "Replacement",
    ).authorization
    held_lock = hold_row_lock(TaskExecutor, executor.id)
    consume_call = start_database_call do
      DeviceAuthorizations::Consume.call(
        authorization: DeviceAuthorization.find(consume_grant.id)
      )
    end

    wait_until_waiting_on_lock(consume_call.pid)
    connection_call = start_database_call do
      DeviceAuthorizations::Connect.call(
        authorization: DeviceAuthorization.find(connection_grant.id),
        connector: User.find(@owner.id)
      )
    end
    wait_until_waiting_on_lock(consume_call.pid, connection_call.pid)

    release_row_lock(held_lock)
    held_lock = nil
    consume_result = finish_database_call(consume_call)
    consume_call = nil
    connection_result = finish_database_call(connection_call)
    connection_call = nil

    assert_equal :minted, consume_result.outcome
    assert_equal :connected, connection_result.outcome
    assert consume_grant.reload.consumed?
    assert connection_grant.reload.connected?
    assert_equal 2, executor.reload.credential_epoch, "the winning consume re-pairs the address"
  ensure
    release_row_lock(held_lock) if held_lock
    stop_database_call(consume_call) if consume_call
    stop_database_call(connection_call) if connection_call
    DeviceAuthorization.where(id: [consume_grant&.id, connection_grant&.id].compact).delete_all
    if consume_result&.access_token
      family_id = consume_result.access_token.refresh_token_family_id
      RefreshToken.where(refresh_token_family_id: family_id).delete_all
      AccessToken.where(refresh_token_family_id: family_id).delete_all
      RefreshTokenFamily.where(id: family_id).delete_all
    end
  end

  test "a new connection fences the previous one on both planes" do
    # Single-instance means a reconnect is the same agent arriving again, so the credential the
    # previous process held stops working: the transport one by the epoch fence, the member one
    # because its lineage is superseded.
    member = users(:agent)
    executor = task_executors(:address)
    old = create_bound_credential(executor: executor, name: "Old session")
    old_refresh = RefreshTokens::Issue.call(
      refresh_token_family: old.token.refresh_token_family,
      access_token: old.token
    )
    grant = connected_grant(member: member, agent_identifier: member.agent_identifier)

    assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: grant).outcome
    assert_equal 2, executor.reload.credential_epoch
    assert_nil AccessToken.authenticate_executor_token(old.secret),
      "the previous transport credential is fenced by the epoch advance"

    rotated = RefreshTokens::Rotate.call(
      presented: RefreshToken.find_by_secret(old_refresh.secret)
    )
    assert_equal :invalid_grant, rotated.outcome,
      "the superseded lineage cannot rotate its way back in"

    # The address itself survives: it is the profile's, not the session's.
    assert_predicate executor.reload, :active?
    assert_equal executor, TaskExecutor.address_for(member)
  end

  test "a steward change after connection is mapping drift and invalidates at consume" do
    # Consume re-resolves within the connecting human's scope; a member
    # re-stewarded elsewhere no longer resolves there, so the Request
    # invalidates without consulting (or locking) the new steward's row.
    member = users(:agent)
    grant = connected_grant(
      member: member,
      agent_identifier: member.agent_identifier,
      display_name: "App"
    )
    assert_equal :changed, member.change_steward(to: users(:member))

    result = DeviceAuthorizations::Consume.call(authorization: grant)

    assert_equal :access_denied, result.outcome
    assert grant.reload.invalidated?
    assert_nil grant.access_token_id
    assert_nil grant.refresh_token_id
  end

  test "a connector suspended after connection invalidates at consume and creates nothing" do
    grant = connected_grant(
      agent_identifier: "install-suspended-connector",
      display_name: "App",
      connected_by: users(:member)
    )
    assert_equal :suspended, users(:member).suspend

    assert_no_difference -> { User.count } do
      result = DeviceAuthorizations::Consume.call(authorization: grant)
      assert_equal :access_denied, result.outcome
    end
    assert grant.reload.invalidated?
  end

  test "a create grant connected before Human remove and restore cannot mint" do
    connector = users(:member)
    identifier = "pre-shutdown-create"
    grant = connected_grant(
      agent_identifier: identifier,
      display_name: "App",
      connected_by: connector
    )
    frozen_generation = grant.connected_by_authority_generation

    assert_equal :removed, connector.remove
    assert_equal :restored, connector.restore
    assert_operator connector.authority_generation, :>, frozen_generation

    assert_no_difference -> { User.where(agent_identifier: identifier).count } do
      assert_no_difference -> { AccessToken.count } do
        assert_no_difference -> { RefreshTokenFamily.count } do
          assert_equal :access_denied,
            DeviceAuthorizations::Consume.call(authorization: grant).outcome
        end
      end
    end
    assert_predicate grant.reload, :invalidated?
  end

  test "an existing-address grant connected before Human remove and restore cannot re-pair" do
    connector = users(:member)
    member = create_agent_member(
      steward: connector,
      agent_identifier: "pre-shutdown-repair"
    )
    executor = member.task_executors.create!(
      account: @account,
      executor_kind: :agent_application,
      display_name: "Original"
    )
    grant = connected_grant(
      member: member,
      agent_identifier: member.agent_identifier,
      display_name: "Replacement",
      connected_by: connector
    )
    original_epoch = executor.credential_epoch

    assert_equal :removed, connector.remove
    assert_equal :restored, connector.restore

    assert_no_difference -> { AccessToken.count } do
      assert_no_difference -> { RefreshTokenFamily.count } do
        assert_equal :access_denied,
          DeviceAuthorizations::Consume.call(authorization: grant).outcome
      end
    end
    assert_predicate grant.reload, :invalidated?
    assert_equal original_epoch, executor.reload.credential_epoch
  end

  test "consume classifies a terminal state that wins while waiting for the authorization lock" do
    {
      expired: :expired_token,
      invalidated: :access_denied,
    }.each do |status, expected_outcome|
      identifier = "install-lock-time-#{status}"
      member = new_agent(identifier: identifier)
      grant = connected_grant(
        member: member,
        display_name: "App",
        agent_identifier: identifier
      )
      held_lock = hold_row_lock(
        DeviceAuthorization,
        grant.id,
        before_commit: ->(locked) { locked.update!(status: status) }
      )
      consume_call = start_database_call do
        DeviceAuthorizations::Consume.call(
          authorization: DeviceAuthorization.find(grant.id)
        )
      end

      wait_until_waiting_on_lock(consume_call.pid)
      release_row_lock(held_lock)
      held_lock = nil
      result = finish_database_call(consume_call)
      consume_call = nil

      assert_equal expected_outcome, result.outcome
      assert_equal status.to_s, grant.reload.status
      assert_nil grant.access_token_id
      assert_nil grant.refresh_token_id
    ensure
      release_row_lock(held_lock) if held_lock
      stop_database_call(consume_call) if consume_call
      DeviceAuthorization.where(id: grant&.id).delete_all
      User.where(id: member&.id).delete_all
    end
  end

  test "consume crossing its deadline while waiting for authority expires without minting" do
    identifier = "install-consume-deadline"
    member = new_agent(identifier: identifier)
    grant = connected_grant(
      member: member,
      display_name: "App",
      agent_identifier: identifier
    )
    deadline = 1.minute.from_now
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: deadline)
    held_lock = hold_row_lock(User, member.id)
    consume_call = start_database_call do
      DeviceAuthorizations::Consume.call(
        authorization: DeviceAuthorization.find(grant.id)
      )
    end

    wait_until_waiting_on_lock(consume_call.pid)
    travel_to(deadline + 1.second)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_database_call(consume_call)
    consume_call = nil

    assert_equal :expired_token, result.outcome
    assert grant.reload.expired?
    assert_nil grant.access_token_id
    assert_nil grant.refresh_token_id
    assert_empty member.access_tokens
    assert_empty member.refresh_token_families
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_database_call(consume_call) if consume_call
    access_token_id = DeviceAuthorization.where(id: grant&.id).pick(:access_token_id)
    family_id = AccessToken.where(id: access_token_id).pick(:refresh_token_family_id)
    DeviceAuthorization.where(id: grant&.id).delete_all
    if family_id
      RefreshToken.where(refresh_token_family_id: family_id).delete_all
      AccessToken.where(refresh_token_family_id: family_id).delete_all
      RefreshTokenFamily.where(id: family_id).delete_all
    end
    User.where(id: member&.id).delete_all
  end

  test "consume crossing its deadline while waiting for the agent address preserves the pairing" do
    member = new_agent(identifier: "install-address-deadline")
    executor = member.task_executors.create!(
      account: @account, executor_kind: :agent_application, display_name: "Original app"
    )
    epoch = executor.credential_epoch
    grant = connected_grant(member: member, agent_identifier: member.agent_identifier)
    deadline = 1.minute.from_now
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: deadline)
    held_lock = hold_row_lock(TaskExecutor, executor.id)
    consume_call = start_database_call do
      DeviceAuthorizations::Consume.call(authorization: DeviceAuthorization.find(grant.id))
    end

    wait_until_waiting_on_lock(consume_call.pid)
    travel_to(deadline + 1.second)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_database_call(consume_call)
    consume_call = nil

    assert_equal :expired_token, result.outcome
    assert_predicate grant.reload, :expired?
    assert_equal epoch, executor.reload.credential_epoch
    assert_equal "Original app", executor.display_name
    assert_empty member.access_tokens
    assert_empty member.refresh_token_families
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_database_call(consume_call) if consume_call
    DeviceAuthorization.where(id: grant&.id).delete_all
    member&.destroy!
  end

  test "authority drift terminalizes inside the mint transaction" do
    steward = users(:member)
    member = new_agent(identifier: "install-atomic-invalidation")
    member.update!(steward: steward)
    grant = connected_grant(
      member: member,
      display_name: "App",
      agent_identifier: member.agent_identifier,
      connected_by: steward
    )
    assert_equal :suspended, steward.suspend
    baseline_transactions = ApplicationRecord.connection_pool.with_connection(&:open_transactions)
    original_invalidate = DeviceAuthorization.method(:invalidate_connected)

    DeviceAuthorization.stub(:invalidate_connected, ->(id) {
      open_transactions = ApplicationRecord.connection_pool.with_connection(&:open_transactions)
      assert_operator open_transactions,
        :>, baseline_transactions,
        "drift invalidation must commit while the authorization lock is still held"
      original_invalidate.call(id)
    }) do
      result = DeviceAuthorizations::Consume.call(authorization: grant)
      assert_equal :access_denied, result.outcome
    end

    assert grant.reload.invalidated?
    assert_nil grant.access_token_id
    assert_nil grant.refresh_token_id
  ensure
    DeviceAuthorization.where(id: grant&.id).delete_all
    User.where(id: member&.id).delete_all
    steward&.reactivate if steward&.suspended?
  end

  # There is no connection shape that yields a member credential with no address to serve. The
  # endpoint refuses it, and the model refuses it too, so no later path has to carry a nil executor.
  test "an agent connection without a delivery address cannot be created" do
    authorization = DeviceAuthorization.new(
      account: @account, client_id: OAuth::DEVICE_CLIENT_ID,
      agent_identifier: "install-identity", agent_display_name: "Identity only",
      user_code: "AAAA-BBBB", interval: 5, expires_at: 10.minutes.from_now,
      device_code_lookup_id: "seed", device_code_digest: "seed"
    )

    assert_not authorization.valid?
    assert authorization.errors.of_kind?(:requested_executor_display_name, :blank)
  end

  # Every lineage the ceremony mints is executor-bound, which is what lets
  # rotation read the address as its whole authority.
  test "a winning consume always binds its lineage to an address" do
    result = DeviceAuthorizations::Consume.call(authorization: connected_grant(member: new_agent))

    assert_equal :minted, result.outcome
    assert_predicate result.refresh_token.refresh_token_family.task_executor, :present?
    assert_predicate result.executor_access_token, :present?
  end

  test "polling a pending grant classifies pending then slow_down" do
    grant = DeviceAuthorizations::Issue.call(
      account: @account, agent_identifier: "install-poll", agent_display_name: "Poller",
      requested_executor_display_name: "App").authorization

    assert_equal :authorization_pending, DeviceAuthorizations::Consume.call(authorization: grant).outcome
    # An immediate second poll is too fast.
    assert_equal :slow_down, DeviceAuthorizations::Consume.call(authorization: grant.reload).outcome
    assert_equal 10, grant.reload.interval
  end

  test "consumed replay is invalid_grant, classified before expiry" do
    member = new_agent(identifier: "install-replay")
    grant = connected_grant(member: member, agent_identifier: "install-replay")
    DeviceAuthorizations::Consume.call(authorization: grant)

    DeviceAuthorization.where(id: grant.id).update_all(expires_at: 1.minute.ago)
    assert_equal :invalid_grant, DeviceAuthorizations::Consume.call(authorization: grant.reload).outcome
  end

  test "canceled and expired grants return their outcomes" do
    canceled = connected_grant(
      member: new_agent(identifier: "install-canceled"),
      agent_identifier: "install-canceled"
    )
    canceled.record_cancellation
    assert_equal :access_denied,
      DeviceAuthorizations::Consume.call(authorization: canceled).outcome

    expired = connected_grant(
      member: new_agent(identifier: "install-expired"),
      agent_identifier: "install-expired"
    )
    DeviceAuthorization.where(id: expired.id).update_all(expires_at: 1.minute.ago)
    assert_equal :expired_token, DeviceAuthorizations::Consume.call(authorization: expired.reload).outcome
  end

  test "authority drift before mint invalidates the grant and mints nothing" do
    member = new_agent(identifier: "install-drift")
    grant = connected_grant(member: member, agent_identifier: "install-drift")
    member.remove # advances the generation past the frozen snapshot

    assert_no_difference -> { AccessToken.count } do
      result = DeviceAuthorizations::Consume.call(authorization: grant)
      assert_equal :access_denied, result.outcome
    end
    assert grant.reload.invalidated?
  end

  test "steward reassignment after connection invalidates the grant and mints nothing" do
    member = new_agent(identifier: "install-reassigned")
    grant = connected_grant(
      member: member,
      display_name: "App",
      agent_identifier: member.agent_identifier
    )
    assert_equal :changed, member.change_steward(to: users(:member))

    assert_no_difference -> { AccessToken.count } do
      result = DeviceAuthorizations::Consume.call(authorization: grant)
      assert_equal :access_denied, result.outcome
    end

    assert grant.reload.invalidated?
    assert_nil grant.access_token_id
    assert_nil grant.refresh_token_id
  end

  test "identifier drift before mint invalidates the grant and mints nothing" do
    member = new_agent(identifier: "install-member")
    grant = connected_grant(
      member: member,
      agent_identifier: "install-authorization"
    )

    assert_no_difference -> { AccessToken.count } do
      result = DeviceAuthorizations::Consume.call(authorization: grant)
      assert_equal :access_denied, result.outcome
    end
    assert grant.reload.invalidated?
    assert_equal 0, member.task_executors.count
  end

  test "consume automatically restores a removed Profile and re-pairs its address" do
    member = users(:agent)
    executor = task_executors(:address)
    old = create_bound_credential(executor: executor, name: "Old device")

    assert_equal :removed, member.remove
    removed_generation = member.reload.authority_generation

    grant = connected_grant(member: member, agent_identifier: member.agent_identifier)
    result = DeviceAuthorizations::Consume.call(authorization: grant)

    assert_equal :minted, result.outcome, "the reconnect must restore and mint, not access_denied"
    assert_predicate member.reload, :active?
    assert_equal removed_generation, member.authority_generation
    assert_equal 1, member.task_executors.count
    assert_equal executor, result.executor_access_token.task_executor,
      "the profile keeps the address it already had, at a new epoch"
    assert_equal "Consumer", member.display_name
    assert_equal "Consumer app", executor.reload.display_name
    assert_equal 3, executor.credential_epoch
    assert_nil AccessToken.authenticate_executor_token(old.secret)
  end

  test "a pending grant past its deadline reports expired_token on the next poll" do
    grant = DeviceAuthorizations::Issue.call(
      account: @account, agent_identifier: "install-timeout", agent_display_name: "T",
      requested_executor_display_name: "App").authorization
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: 1.minute.ago)

    assert_equal :expired_token, DeviceAuthorizations::Consume.call(authorization: grant).outcome
    assert grant.reload.expired?
  end

  test "a pending grant expires exactly at its deadline" do
    freeze_time do
      grant = DeviceAuthorizations::Issue.call(
        account: @account, agent_identifier: "install-pending-equality",
        agent_display_name: "Consumer", requested_executor_display_name: "App"
      ).authorization
      DeviceAuthorization.where(id: grant.id).update_all(expires_at: Time.current)

      result = DeviceAuthorizations::Consume.call(authorization: grant)

      assert_equal :expired_token, result.outcome
      assert_predicate grant.reload, :expired?
      assert_nil grant.last_polled_at
    end
  end

  test "a connected grant expires exactly at its deadline without minting" do
    freeze_time do
      grant = connected_grant(agent_identifier: "install-connected-equality")
      DeviceAuthorization.where(id: grant.id).update_all(expires_at: Time.current)

      result = nil
      assert_no_difference ["User.count", "TaskExecutor.count", "AccessToken.count", "RefreshTokenFamily.count"] do
        result = DeviceAuthorizations::Consume.call(authorization: grant)
      end

      assert_equal :expired_token, result.outcome
      assert_predicate grant.reload, :expired?
      assert_nil grant.access_token_id
      assert_nil grant.refresh_token_id
    end
  end

  test "two consumes of one grant: exactly one mints" do
    member = new_agent(identifier: "install-race")
    grant = connected_grant(member: member, agent_identifier: "install-race")

    first = DeviceAuthorizations::Consume.call(authorization: grant)
    second = DeviceAuthorizations::Consume.call(authorization: grant.reload)

    assert_equal :minted, first.outcome
    assert_equal :invalid_grant, second.outcome
    # One winning consume, one bundle: the member credential plus this
    # executor's transport credential, and nothing from the loser.
    assert_equal 2, member.access_tokens.count
    assert_equal 1, member.refresh_token_families.count
    assert_equal 1, member.task_executors.count
  end
end
