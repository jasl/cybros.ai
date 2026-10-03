require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# Branch B of the device flow: the same browser ceremony, a second consequence shape. A runner
# connection is identity-less — it resolves no Agent Profile, and its winning consume materializes a
# machine plus one transport credential.
class DeviceAuthorizations::RunnerConnectionTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_a_runner_consume_crossing_its_deadline_while_contended_expires_without_minting,
    :test_a_runner_consume_crossing_its_deadline_while_waiting_for_its_address_preserves_the_pairing,
    :test_connect_and_reap_serialize_the_terminal_pairing_marker

  setup do
    @account = accounts(:cybros)
    @manager = users(:owner)
  end

  def runner_grant(identifier: "workshop-install", kind: "runner")
    DeviceAuthorizations::Issue.call(
      account: @account,
      runner_identifier: identifier,
      runner_display_name: "Workshop laptop",
      requested_executor_kind: kind
    ).authorization
  end

  def connect(grant, connector: @manager, account_wide: false)
    existing = TaskExecutor.runner_for(
      account_id: grant.account_id,
      manager_id: connector.id,
      runner_identifier: grant.runner_identifier
    )
    DeviceAuthorizations::Connect.call(
      authorization: grant,
      connector: connector,
      account_wide: account_wide,
      expected_live_runner:
        DeviceAuthorizations::Connect.live_runner_precondition(existing)
    )
  end

  test "connecting a runner freezes the consequence and materializes nothing" do
    grant = runner_grant

    assert_no_difference -> { TaskExecutor.count } do
      assert_equal :connected, connect(grant).outcome
    end

    grant.reload
    assert grant.connected?
    assert_equal @manager, grant.connected_by
    assert_equal @manager.authority_generation,
      grant.connected_by_authority_generation
    assert_predicate grant, :selects_user_private?
    assert_nil grant.user, "a runner connection resolves no Agent Profile"
    assert_nil grant.task_executor
  end

  test "a Runner connection requires the browser's live-registration precondition" do
    grant = runner_grant(identifier: "missing-browser-precondition")

    result = DeviceAuthorizations::Connect.call(
      authorization: grant,
      connector: @manager
    )

    assert_equal :registration_changed, result.outcome
    assert_predicate grant.reload, :pending?
    assert_nil grant.selected_assignment_scope
  end

  test "an administrator explicitly freezes account-wide placement at Connect" do
    grant = runner_grant(identifier: "farm-install")

    assert_equal :connected, connect(grant, account_wide: true).outcome

    assert_predicate grant.reload, :selects_account_wide?
  end

  test "an ordinary member cannot forge account-wide placement" do
    grant = runner_grant(identifier: "farm-install")

    assert_equal :administrator_required,
      connect(grant, connector: users(:member), account_wide: true).outcome

    assert_predicate grant.reload, :pending?
    assert_nil grant.selected_assignment_scope
  end

  test "the first browser Connect freezes assignment against a conflicting retry" do
    grant = runner_grant(identifier: "first-choice")

    assert_equal :connected, connect(grant, account_wide: true).outcome
    assert_equal :stale, connect(grant.reload, account_wide: false).outcome

    assert_predicate grant.reload, :selects_account_wide?
  end

  test "an account-wide reconnect keeps the registration scope when the checkbox is absent" do
    original_grant = runner_grant(identifier: "fixed-scope")
    connect(original_grant, account_wide: true)
    original = DeviceAuthorizations::Consume.call(
      authorization: original_grant.reload
    )
    runner = original.executor_access_token.task_executor
    assert_predicate runner, :account_wide?

    replacement_grant = runner_grant(identifier: "fixed-scope")
    assert_equal :connected, connect(replacement_grant).outcome
    assert_predicate replacement_grant.reload, :selects_account_wide?
    replacement = DeviceAuthorizations::Consume.call(
      authorization: replacement_grant
    )

    assert_equal :minted, replacement.outcome
    assert_equal runner, replacement.executor_access_token.task_executor
    assert_equal 1,
      @manager.managed_runners.where(runner_identifier: "fixed-scope").count
    assert_predicate runner.reload, :account_wide?
    assert_equal 2, runner.credential_epoch
    assert_nil AccessToken.authenticate_executor_token(original.executor_access_secret)
  end

  test "a winning consume creates the runner and issues only a transport credential" do
    grant = runner_grant
    connect(grant)

    result = DeviceAuthorizations::Consume.call(authorization: grant.reload)

    assert_equal :minted, result.outcome
    runner = @manager.managed_runners.sole
    assert_equal "workshop-install", runner.runner_identifier
    assert_equal "Workshop laptop", runner.display_name
    assert_predicate runner, :user_private?
    assert_equal @manager, runner.manager
    assert_nil runner.agent_profile

    # A runner is not a principal: no member credential, no Agent Profile.
    assert_nil result.access_token
    assert_nil AccessToken.authenticate_token(result.executor_access_secret)
    transport = result.executor_access_token
    assert_nil transport.user
    assert_equal runner, transport.task_executor
    assert_equal transport, AccessToken.authenticate_executor_token(result.executor_access_secret)
    assert_equal 0, User.where(kind: :agent).where.not(id: users(:agent, :system).map(&:id)).count
  end

  # The provider's twin: the same branch, the requested kind minted on a fresh registration, and
  # still nothing but transport.
  test "a winning consume of a tools-provider grant creates the provider and issues only a transport credential" do
    grant = runner_grant(kind: "tools_provider")
    assert_equal "tools_provider", grant.requested_executor_kind
    connect(grant)

    result = DeviceAuthorizations::Consume.call(authorization: grant.reload)

    assert_equal :minted, result.outcome
    provider = @manager.managed_runners.sole
    assert_predicate provider, :tools_provider?
    assert_predicate provider, :machine?
    assert_equal "workshop-install", provider.runner_identifier
    assert_predicate provider, :user_private?
    assert_equal @manager, provider.manager
    assert_nil provider.agent_profile

    assert_nil result.access_token
    transport = result.executor_access_token
    assert_nil transport.user
    assert_equal provider, transport.task_executor
    assert_equal transport, AccessToken.authenticate_executor_token(result.executor_access_secret)
    assert_equal "Tools provider connection — Workshop laptop", transport.refresh_token_family.access_token_name
  end

  test "reconnecting a provider registration re-pairs it under its kind" do
    first = runner_grant(kind: "tools_provider")
    connect(first)
    DeviceAuthorizations::Consume.call(authorization: first.reload)
    provider = @manager.managed_runners.sole

    second = runner_grant(kind: "tools_provider")
    connect(second)
    result = DeviceAuthorizations::Consume.call(authorization: second.reload)

    assert_equal :minted, result.outcome
    assert_equal provider, result.executor_access_token.task_executor
    assert_predicate provider.reload, :tools_provider?
    assert_equal 2, provider.credential_epoch
  end

  # The kind is the registration's, frozen at creation like its scope: the
  # key is kind-blind, so a grant naming the other kind for a live key is
  # invalidated at consume the way a forged scope is.
  test "a live runner key requested as a provider invalidates, and the reverse" do
    [%w[runner tools_provider], %w[tools_provider runner]].each_with_index do |(first_kind, second_kind), i|
      identifier = "kind-frozen-#{i}"
      first = runner_grant(identifier: identifier, kind: first_kind)
      connect(first)
      assert_equal :minted, DeviceAuthorizations::Consume.call(authorization: first.reload).outcome
      machine = @manager.managed_runners.find_by!(runner_identifier: identifier)

      second = runner_grant(identifier: identifier, kind: second_kind)
      connect(second)
      result = DeviceAuthorizations::Consume.call(authorization: second.reload)

      assert_equal :access_denied, result.outcome
      assert_predicate second.reload, :invalidated?
      assert_equal first_kind, machine.reload.executor_kind, "the live registration keeps its kind"
      assert_equal 1, machine.credential_epoch, "and its epoch: nothing was re-paired"
      assert_equal 1, @manager.managed_runners.where(runner_identifier: identifier).count
    end
  end

  test "an absent Runner grant connected before Human remove and restore cannot create" do
    manager = users(:member)
    grant = runner_grant(identifier: "pre-shutdown-absent-runner")
    assert_equal :connected, connect(grant, connector: manager).outcome
    frozen_generation = grant.reload.connected_by_authority_generation

    assert_equal :removed, manager.remove
    assert_equal :restored, manager.restore
    assert_operator manager.authority_generation, :>, frozen_generation

    assert_no_difference -> { TaskExecutor.count } do
      assert_no_difference -> { AccessToken.count } do
        assert_no_difference -> { RefreshTokenFamily.count } do
          assert_equal :access_denied,
            DeviceAuthorizations::Consume.call(authorization: grant).outcome
        end
      end
    end
    assert_predicate grant.reload, :invalidated?
  end

  test "an existing Runner grant connected before Human remove and restore cannot re-pair" do
    manager = users(:member)
    first = runner_grant(identifier: "pre-shutdown-existing-runner")
    connect(first, connector: manager)
    original = DeviceAuthorizations::Consume.call(authorization: first.reload)
    runner = original.executor_access_token.task_executor
    original_epoch = runner.credential_epoch

    stale = runner_grant(identifier: runner.runner_identifier)
    assert_equal :connected, connect(stale, connector: manager).outcome
    assert_equal :removed, manager.remove
    assert_equal :restored, manager.restore

    assert_no_difference -> { AccessToken.count } do
      assert_no_difference -> { RefreshTokenFamily.count } do
        assert_equal :access_denied,
          DeviceAuthorizations::Consume.call(authorization: stale.reload).outcome
      end
    end
    assert_predicate stale.reload, :invalidated?
    assert_equal original_epoch, runner.reload.credential_epoch
  end

  test "a restored manager cannot start a new re-pair until Runner shutdown converges" do
    manager = users(:member)
    initial = runner_grant(identifier: "pending-runner-repair")
    connect(initial, connector: manager)
    DeviceAuthorizations::Consume.call(authorization: initial.reload)

    assert_equal :removed, manager.remove
    assert_equal :restored, manager.restore
    replacement = runner_grant(identifier: "pending-runner-repair")

    assert_equal :shutdown_pending,
      connect(replacement, connector: manager).outcome
    assert_predicate replacement.reload, :pending?

    TaskExecutor.converge
    assert_equal :connected,
      connect(replacement.reload, connector: manager).outcome
    assert_equal :minted,
      DeviceAuthorizations::Consume.call(
        authorization: replacement.reload
      ).outcome
  end

  test "reconnecting the same registration re-pairs it and fences the old credential" do
    first = runner_grant
    connect(first)
    original = DeviceAuthorizations::Consume.call(authorization: first.reload)
    runner = @manager.managed_runners.sole

    second = runner_grant
    connect(second)
    result = DeviceAuthorizations::Consume.call(authorization: second.reload)

    assert_equal :minted, result.outcome
    assert_equal 1, @manager.managed_runners.count, "a reconnect re-pairs, never duplicates"
    assert_equal runner, result.executor_access_token.task_executor
    assert_equal 2, runner.reload.credential_epoch
    assert_nil AccessToken.authenticate_executor_token(original.executor_access_secret)
    assert result.executor_access_token.executor_usable?
  end

  test "a connected runner grant cannot take the machine back after another grant wins" do
    first = runner_grant(identifier: "runner-pairing-winner")
    connect(first)
    DeviceAuthorizations::Consume.call(authorization: first.reload)
    runner = @manager.managed_runners.find_by!(runner_identifier: "runner-pairing-winner")

    older = runner_grant(identifier: "runner-pairing-winner")
    newer = runner_grant(identifier: "runner-pairing-winner")
    connect(older)
    connect(newer)

    winner = DeviceAuthorizations::Consume.call(authorization: newer.reload)
    loser = DeviceAuthorizations::Consume.call(authorization: older.reload)

    assert_equal :minted, winner.outcome
    assert_equal :access_denied, loser.outcome
    assert older.reload.invalidated?
    assert_equal winner.executor_access_token,
      AccessToken.authenticate_executor_token(winner.executor_access_secret)
    assert_equal "Workshop laptop", runner.reload.display_name
  end

  test "an absent-machine snapshot cannot revive a replacement after it is revoked" do
    stale = runner_grant(identifier: "runner-absent-pairing")
    newer = runner_grant(identifier: "runner-absent-pairing")
    connect(stale)
    connect(newer)

    winner = DeviceAuthorizations::Consume.call(authorization: newer.reload)
    assert_equal :minted, winner.outcome
    assert_equal :revoked, winner.executor_access_token.task_executor.revoke

    assert_no_difference -> { TaskExecutor.count } do
      loser = DeviceAuthorizations::Consume.call(authorization: stale.reload)
      assert_equal :access_denied, loser.outcome
    end
    assert stale.reload.invalidated?

    fresh = runner_grant(identifier: "runner-absent-pairing")
    connect(fresh)
    replacement = DeviceAuthorizations::Consume.call(authorization: fresh.reload)
    assert_equal :minted, replacement.outcome
    assert_equal replacement.executor_access_token,
      AccessToken.authenticate_executor_token(replacement.executor_access_secret)
  end

  test "reaping retains a terminal pairing marker until its connected grant decides" do
    marker = @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Retained marker",
      runner_identifier: "runner-retained-marker",
      assignment_scope: :user_private,
      manager: @manager
    )
    marker.revoke
    grant = runner_grant(identifier: "runner-retained-marker")
    assert_equal :connected, connect(grant).outcome
    assert_equal marker.public_id, grant.reload.expected_task_executor_public_id

    assert_equal 0, TaskExecutor.where(id: marker.id).reap
    assert TaskExecutor.exists?(marker.id)

    replacement = DeviceAuthorizations::Consume.call(authorization: grant)
    assert_equal :minted, replacement.outcome
    assert_not_equal marker, replacement.executor_access_token.task_executor
  end

  test "connect and reap serialize the terminal pairing marker" do
    identifier = "runner-marker-race-#{SecureRandom.hex(8)}"
    marker = @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Contended marker",
      runner_identifier: identifier,
      assignment_scope: :user_private,
      manager: @manager
    )
    marker.revoke
    grant = runner_grant(identifier: identifier)

    marker_selected = Queue.new
    marker_release = Queue.new
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:pairing_marker_selection_barrier]
      next unless terminal_pairing_marker_query?(payload[:sql])

      Thread.current[:pairing_marker_selection_barrier] = false
      marker_selected << true
      marker_release.pop
    end

    connect_call = start_database_call do
      begin
        Thread.current[:pairing_marker_selection_barrier] = true
        DeviceAuthorizations::Connect.call(
          authorization: DeviceAuthorization.find(grant.id),
          connector: User.find(@manager.id),
          expected_live_runner:
            DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER
        )
      ensure
        Thread.current[:pairing_marker_selection_barrier] = false
      end
    end
    Timeout.timeout(RowLockTestHelper::ROW_LOCK_WAIT_TIMEOUT) { marker_selected.pop }

    reaped = TaskExecutor.where(id: marker.id).reap
    marker_release << true
    result = finish_database_call(connect_call)
    connect_call = nil

    assert_equal :connected, result.outcome
    assert_equal 0, reaped
    assert TaskExecutor.exists?(marker.id)
    assert_equal marker.public_id,
      DeviceAuthorization.find(grant.id).expected_task_executor_public_id
  ensure
    marker_release << true if marker_release
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    stop_database_call(connect_call) if connect_call
    DeviceAuthorization.where(id: grant&.id).delete_all
    TaskExecutor.where(id: marker&.id).delete_all
  end

  test "another human reusing the identifier gets their own runner registration" do
    first = runner_grant
    connect(first)
    DeviceAuthorizations::Consume.call(authorization: first.reload)

    second = runner_grant
    connect(second, connector: users(:member))
    DeviceAuthorizations::Consume.call(authorization: second.reload)

    assert_equal 1, @manager.managed_runners.count
    assert_equal 1, users(:member).managed_runners.count
  end

  # Branch parity with the agent side, restored: the original deadline stays
  # authoritative while the account, connector, and machine rows are
  # contended. Before the recheck, this exact harness minted a machine and a
  # live transport credential from a code the product promises dead at
  # fifteen minutes.
  test "a runner consume crossing its deadline while contended expires without minting" do
    grant = runner_grant(identifier: "deadline-install")
    connect(grant)
    deadline = 1.minute.from_now
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: deadline)
    held_lock = hold_row_lock(User, @manager.id)
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
    assert_equal 0, TaskExecutor.where(runner_identifier: "deadline-install").count,
      "no machine may exist past the deadline the product promises"
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_database_call(consume_call) if consume_call
    TaskExecutor.where(runner_identifier: "deadline-install").delete_all
    DeviceAuthorization.where(id: grant&.id).delete_all
  end

  test "a runner consume crossing its deadline while waiting for its address preserves the pairing" do
    runner = @account.task_executors.create!(
      executor_kind: :runner, display_name: "Original runner", runner_identifier: "runner-address-deadline",
      assignment_scope: :user_private, manager: @manager
    )
    epoch = runner.credential_epoch
    grant = runner_grant(identifier: runner.runner_identifier)
    assert_equal :connected, connect(grant).outcome
    deadline = 1.minute.from_now
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: deadline)
    held_lock = hold_row_lock(TaskExecutor, runner.id)
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
    assert_equal epoch, runner.reload.credential_epoch
    assert_equal "Original runner", runner.display_name
    assert_empty runner.access_tokens
    assert_empty runner.refresh_token_families
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_database_call(consume_call) if consume_call
    DeviceAuthorization.where(id: grant&.id).delete_all
    family_ids = RefreshTokenFamily.where(task_executor_id: runner&.id).pluck(:id)
    RefreshToken.where(refresh_token_family_id: family_ids).delete_all
    AccessToken.where(refresh_token_family_id: family_ids).delete_all
    RefreshTokenFamily.where(id: family_ids).delete_all
    runner&.destroy!
  end

  test "a connector suspended after connecting a runner invalidates at consume" do
    grant = runner_grant
    connect(grant, connector: users(:member))
    assert_equal :suspended, users(:member).suspend

    assert_no_difference -> { TaskExecutor.count } do
      assert_equal :access_denied, DeviceAuthorizations::Consume.call(authorization: grant.reload).outcome
    end
    assert grant.reload.invalidated?
  end

  test "a new account-wide grant loses if its administrator is demoted before consume" do
    grant = runner_grant(identifier: "farm-install")
    users(:member).change_role(to: :admin)
    connect(grant, connector: users(:member).reload, account_wide: true)
    users(:member).reload.change_role(to: :member)

    assert_no_difference -> { TaskExecutor.count } do
      assert_equal :access_denied, DeviceAuthorizations::Consume.call(authorization: grant.reload).outcome
    end
    assert grant.reload.invalidated?
  end

  test "a demoted manager may reconnect an existing account-wide Runner" do
    manager = users(:member)
    assert_equal :role_changed, manager.change_role(to: :admin)
    first = runner_grant(identifier: "demoted-manager-reconnect")
    connect(first, connector: manager.reload, account_wide: true)
    original = DeviceAuthorizations::Consume.call(authorization: first.reload)
    runner = original.executor_access_token.task_executor
    assert_equal :role_changed, manager.reload.change_role(to: :member)

    replacement = runner_grant(identifier: runner.runner_identifier)
    assert_equal :connected,
      connect(replacement, connector: manager.reload).outcome
    assert_predicate replacement.reload, :selects_account_wide?
    result = DeviceAuthorizations::Consume.call(authorization: replacement)

    assert_equal :minted, result.outcome
    assert_equal runner, result.executor_access_token.task_executor
    assert_predicate runner.reload, :account_wide?
  end

  test "revoking a Runner makes the next connection a new registration with a new scope" do
    first = runner_grant(identifier: "terminal-new-scope")
    connect(first, account_wide: true)
    original = DeviceAuthorizations::Consume.call(authorization: first.reload)
    old_runner = original.executor_access_token.task_executor
    old_runner.revoke

    replacement = runner_grant(identifier: old_runner.runner_identifier)
    assert_equal :connected, connect(replacement).outcome
    assert_predicate replacement.reload, :selects_user_private?
    result = DeviceAuthorizations::Consume.call(authorization: replacement)

    assert_equal :minted, result.outcome
    assert_not_equal old_runner, result.executor_access_token.task_executor
    assert_predicate result.executor_access_token.task_executor, :user_private?
  end

  test "an account-wide Runner requires an administrator and still records its Human manager" do
    grant = runner_grant(identifier: "farm-install")

    assert_equal :administrator_required,
      connect(grant, connector: users(:member), account_wide: true).outcome
    assert grant.reload.pending?

    assert_equal :connected, connect(grant, connector: @manager, account_wide: true).outcome
    DeviceAuthorizations::Consume.call(authorization: grant.reload)

    runner = TaskExecutor.find_by(runner_identifier: "farm-install")
    assert_predicate runner, :account_wide?
    assert_equal @manager, runner.manager
  end

  private

    def terminal_pairing_marker_query?(sql)
      sql.include?('FROM "task_executors"') &&
        sql.include?('ORDER BY "task_executors"."created_at" DESC')
    end
end
