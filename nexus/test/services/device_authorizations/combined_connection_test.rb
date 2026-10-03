require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# One combined device grant pairs an agent application and a private runner: one browser approval
# and consume produce two credential lineages. The agent lineage supplies member and transport
# credentials; the runner lineage supplies transport only. Exercise both halves together because
# success on one branch alone cannot prove atomic pairing.
class DeviceAuthorizations::CombinedConnectionTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_two_combined_consumes_take_the_agent_address_before_the_runner_row_and_never_deadlock,
    :test_a_combined_consume_crossing_its_deadline_while_contended_expires_without_minting_either_half,
    :test_a_combined_consume_crossing_its_deadline_at_the_runner_address_mints_neither_half

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  def issue(agent_identifier: "install-full", runner_identifier: "rho",
            display_name: "rho on laptop", connector: nil)
    DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: agent_identifier,
      agent_display_name: "rho",
      requested_executor_display_name: display_name,
      runner_identifier: runner_identifier,
      runner_display_name: display_name
    ).authorization
  end

  def connect(grant, connector: @owner)
    DeviceAuthorizations::Connect.call(authorization: grant, connector: connector)
  end

  def consume(grant)
    DeviceAuthorizations::Consume.call(authorization: grant.reload)
  end

  def connected(agent_identifier: "install-full", connector: @owner)
    grant = issue(agent_identifier: agent_identifier)
    assert_equal :connected, connect(grant, connector: connector).outcome
    grant.reload
  end

  def new_agent(identifier: "install-full", steward: @owner)
    @account.users.create!(
      kind: :agent, role: :member, steward: steward, display_name: "rho", agent_identifier: identifier
    )
  end

  def runner_row(manager: @owner, identifier: "rho")
    TaskExecutor.runner_for(
      account_id: @account.id, manager_id: manager.id, runner_identifier: identifier
    )
  end

  # A live machine row under the manager, the way an earlier ceremony or a
  # branch-B registration leaves it.
  def register_machine(identifier: "rho", kind: :runner, manager: @owner)
    @account.task_executors.create!(
      executor_kind: kind, display_name: "rho on laptop", runner_identifier: identifier,
      assignment_scope: :user_private, manager: manager
    )
  end

  test "Issue fixes the runner kind and the private scope on a combined row" do
    grant = issue

    assert_predicate grant, :combined_connection?
    refute_predicate grant, :runner_only_connection?
    refute_predicate grant, :agent_connection?
    assert_equal "runner", grant.requested_executor_kind
    assert_predicate grant, :selects_user_private?
    assert_predicate grant, :pending?
  end

  # The connect_test sibling: the agent marker is frozen exactly as branch A
  # freezes it; the runner half is NOT looked up, locked or recorded here
  # (the recorded asymmetry — it rides the agent triple's fence), and no
  # browser precondition is posted for it.
  test "connecting a combined grant freezes the agent marker only and materializes nothing" do
    member = users(:agent)
    address = task_executors(:address)
    grant = issue(agent_identifier: member.agent_identifier)

    assert_no_difference -> { TaskExecutor.count } do
      assert_no_difference -> { User.count } do
        assert_equal :connected, connect(grant).outcome
      end
    end

    grant.reload
    assert_equal member, grant.user
    assert_equal address.public_id, grant.expected_task_executor_public_id
    assert_equal address.credential_epoch, grant.expected_credential_epoch
    assert_predicate grant, :selects_user_private?, "the scope fixed at Issue survives Connect"
    assert_nil grant.task_executor
    assert_nil runner_row, "the runner half waits for the winning consume"
  end

  test "canceling a combined grant keeps its fixed scope" do
    grant = connected(agent_identifier: users(:agent).agent_identifier)

    grant.record_cancellation

    assert_predicate grant, :canceled?
    assert_predicate grant, :selects_user_private?
  end

  # The consume_test sibling: two families, three access tokens, the runner
  # row private under the connector, and the nested runner Bundle.
  test "a winning consume mints the agent's bundle and a private runner's lineage" do
    member = new_agent
    grant = connected

    result = consume(grant)

    assert_equal :minted, result.outcome
    address = member.task_executors.sole
    assert_equal "agent_application", address.executor_kind
    assert_predicate result.access_token, :member_plane?
    assert_equal result.access_token, AccessToken.authenticate_token(result.access_secret)
    assert_equal address, result.executor_access_token.task_executor
    assert_equal result.executor_access_token,
      AccessToken.authenticate_executor_token(result.executor_access_secret)

    runner = runner_row
    assert_predicate runner, :runner?
    assert_equal "rho on laptop", runner.display_name
    assert_predicate runner, :user_private?
    assert_equal @owner, runner.manager
    assert_nil runner.agent_profile
    assert runner.eligible_for?(member), "the private runner serves the loops of the agent it came with"

    bundle = result.runner
    assert_instance_of RefreshTokens::Bundle, bundle
    assert_nil bundle.access_token, "the runner half is transport-led: no member plane"
    assert_nil bundle.access_secret
    assert_equal runner, bundle.executor_access_token.task_executor
    assert_equal bundle.executor_access_token,
      AccessToken.authenticate_executor_token(bundle.executor_access_secret)
    assert_nil AccessToken.authenticate_token(bundle.executor_access_secret)
    assert_predicate bundle.refresh_token, :current?
    assert_equal runner, bundle.refresh_token.refresh_token_family.task_executor
    refute_equal result.refresh_token.refresh_token_family, bundle.refresh_token.refresh_token_family,
      "two lineages: the unique (executor, epoch) family index forces the second"

    grant.reload
    assert_predicate grant, :consumed?
    assert_equal address, grant.task_executor, "the ONE evidence pointer is the agent's"
    assert_equal result.access_token, grant.access_token
    assert_equal result.refresh_token, grant.refresh_token
    assert_equal 1, RefreshTokenFamily.where(task_executor: runner).count
  end

  test "a second combined connection fences both previous lineages" do
    member = new_agent
    first = consume(connected)
    address = member.task_executors.sole
    runner = runner_row

    second = consume(connected)

    assert_equal :minted, second.outcome
    assert_equal address, second.executor_access_token.task_executor
    assert_equal runner, second.runner.executor_access_token.task_executor, "the rho row re-pairs in place"
    assert_equal 2, address.reload.credential_epoch
    assert_equal 2, runner.reload.credential_epoch
    assert_equal 1, @owner.managed_runners.where(runner_identifier: "rho").count

    assert_nil AccessToken.authenticate_executor_token(first.executor_access_secret),
      "the agent transport credential is fenced by the address epoch"
    assert_nil AccessToken.authenticate_executor_token(first.runner.executor_access_secret),
      "the runner transport credential is fenced by the runner row's epoch"
    assert_equal :invalid_grant,
      RefreshTokens::Rotate.call(presented: RefreshToken.find_by_secret(first.refresh_secret)).outcome,
      "the agent lineage is superseded"
    assert_equal :invalid_grant,
      RefreshTokens::Rotate.call(presented: RefreshToken.find_by_secret(first.runner.refresh_secret)).outcome,
      "the runner lineage is behind the epoch"
    assert second.runner.executor_access_token.executor_usable?
  end

  test "two consumes of one combined grant: exactly one mints both halves" do
    member = new_agent
    grant = connected

    first = consume(grant)
    second = consume(grant)

    assert_equal :minted, first.outcome
    assert_equal :invalid_grant, second.outcome
    assert_nil second.runner
    assert_equal 2, member.access_tokens.count
    assert_equal 1, member.refresh_token_families.count
    assert_equal 1, @owner.managed_runners.count
    assert_equal 1, RefreshTokenFamily.where(task_executor: runner_row).count
  end

  test "a revoked rho marker between connect and consume yields a fresh runner row" do
    new_agent
    consume(connected)
    old_runner = runner_row
    grant = connected
    assert_equal :revoked, old_runner.revoke

    result = consume(grant)

    assert_equal :minted, result.outcome, "degraded — a fresh row — never corrupt"
    fresh = runner_row
    refute_equal old_runner, fresh
    assert_predicate fresh, :user_private?
    assert_equal fresh, result.runner.executor_access_token.task_executor
    assert_predicate old_runner.reload, :revoked?
  end

  # The drift siblings (consume_test's steward, connector, identifier and
  # authority cases), connected by an ordinary member (the owner fixture is
  # protected from suspension and removal): every refusal of the AGENT half
  # leaves the runner row untouched — the check-before-write pin from the
  # runner's side.
  {
    "a steward change" => ->(test, member) {
      test.assert_equal :changed, member.change_steward(to: test.users(:owner))
    },
    "a connector suspension" => ->(test, _member) {
      test.assert_equal :suspended, test.users(:member).suspend
    },
    "an authority drift" => ->(_test, member) {
      member.remove
    },
    "a Human remove and restore" => ->(test, _member) {
      test.assert_equal :removed, test.users(:member).remove
      test.assert_equal :restored, test.users(:member).restore
    },
  }.each do |name, drift|
    test "#{name} after connection invalidates the grant and leaves the runner row untouched" do
      connector = users(:member)
      member = new_agent(steward: connector)
      runner = register_machine(manager: connector)
      grant = connected(connector: connector)
      drift.call(self, member)

      assert_no_difference -> { AccessToken.count } do
        assert_no_difference -> { RefreshTokenFamily.count } do
          assert_no_difference -> { TaskExecutor.count } do
            assert_equal :access_denied, consume(grant).outcome
          end
        end
      end
      assert_predicate grant.reload, :invalidated?
      assert_equal 1, runner.reload.credential_epoch, "the runner row is never re-paired by a losing consume"
      assert_equal "rho on laptop", runner.display_name
    ensure
      users(:member).reactivate if users(:member).reload.suspended?
    end
  end

  # Risk 1 of the step brief, written first: a runner-half refusal must run
  # BEFORE materialize_member, or `next Result.access_denied` inside the lock
  # commits a restored member and an advanced agent epoch behind an invalidated
  # grant. A live `rho` key of the other machine kind is a runner-only refusal
  # (the agent half is mintable), so it isolates the order.
  {
    "a live rho key of the other kind" => ->(test) { test.register_machine(kind: :tools_provider) },
    "a rho row whose manager's shutdown is pending" => ->(test) {
      test.register_machine.tap do |runner|
        runner.update_columns(
          applied_human_shutdown_generation:
            test.users(:owner).managed_resource_shutdown_generation + 1
        )
      end
    },
  }.each do |name, drift|
    test "#{name} refuses the whole grant and leaves the member unrestored and the agent epoch unadvanced" do
      member = users(:agent)
      address = task_executors(:address)
      assert_equal :removed, member.remove
      removed_epoch = address.reload.credential_epoch
      grant = connected(agent_identifier: member.agent_identifier)
      assert_equal member, grant.user
      machine = drift.call(self)

      assert_no_difference -> { AccessToken.count } do
        assert_no_difference -> { RefreshTokenFamily.count } do
          assert_equal :access_denied, consume(grant).outcome
        end
      end

      assert_predicate grant.reload, :invalidated?
      assert_predicate member.reload, :removed?, "the member was not restored by a losing consume"
      assert_equal removed_epoch, address.reload.credential_epoch, "the losing grant did not advance the epoch again"
      assert_equal 1, machine.reload.credential_epoch
      assert_equal 1, @owner.managed_runners.where(runner_identifier: "rho").count
    end
  end

  # Branch parity for the shape (runner_connection_test's deadline case): the
  # original deadline stays authoritative while the member row is contended,
  # and neither half exists past it.
  test "a combined consume crossing its deadline while contended expires without minting either half" do
    identifier = "install-combined-deadline"
    member = new_agent(identifier: identifier)
    grant = connected(agent_identifier: identifier)
    deadline = 1.minute.from_now
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: deadline)
    held_lock = hold_row_lock(User, member.id)
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
    assert grant.reload.expired?
    assert_empty member.access_tokens
    assert_empty member.refresh_token_families
    assert_equal 0, TaskExecutor.where(runner_identifier: "rho", manager_id: @owner.id).count,
      "no runner row may exist past the deadline the product promises"
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_database_call(consume_call) if consume_call
    DeviceAuthorization.where(id: grant&.id).delete_all
    TaskExecutor.where(runner_identifier: "rho", manager_id: @owner.id).delete_all
    User.where(id: member&.id).delete_all
  end

  test "a combined consume crossing its deadline at the runner address mints neither half" do
    member = new_agent(identifier: "install-combined-address-deadline")
    runner = register_machine
    epoch = runner.credential_epoch
    grant = connected(agent_identifier: member.agent_identifier)
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
    assert_empty member.access_tokens
    assert_empty member.refresh_token_families
    assert_empty member.task_executors
    assert_equal epoch, runner.reload.credential_epoch
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
    member&.destroy!
  end

  # The within-table order: inside task_executors a combined consume takes the AGENT address before
  # the runner row, explicitly, so both rows are held when the checks run and two consumes never
  # cross. The winner waits on the held runner row already holding the address; the loser queues
  # behind the member lock and reads the winner's epoch.
  test "two combined consumes take the agent address before the runner row and never deadlock" do
    member = users(:agent)
    address = task_executors(:address)
    runner = register_machine
    first = connected(agent_identifier: member.agent_identifier)
    second = connected(agent_identifier: member.agent_identifier)
    held_lock = hold_row_lock(TaskExecutor, runner.id)
    first_call = start_database_call do
      DeviceAuthorizations::Consume.call(authorization: DeviceAuthorization.find(first.id))
    end

    wait_until_waiting_on_lock(first_call.pid)
    assert_raises(ActiveRecord::LockWaitTimeout, "the agent address must already be held") do
      ApplicationRecord.connection_pool.with_connection do
        ApplicationRecord.transaction do
          TaskExecutor.lock("FOR UPDATE NOWAIT").find(address.id)
        end
      end
    end
    second_call = start_database_call do
      DeviceAuthorizations::Consume.call(authorization: DeviceAuthorization.find(second.id))
    end
    wait_until_waiting_on_lock(first_call.pid, second_call.pid)

    release_row_lock(held_lock)
    held_lock = nil
    first_result = finish_database_call(first_call)
    first_call = nil
    second_result = finish_database_call(second_call)
    second_call = nil

    assert_equal :minted, first_result.outcome
    assert_equal :access_denied, second_result.outcome, "the loser's frozen agent marker is behind the winner's epoch"
    assert_equal 2, address.reload.credential_epoch
    assert_equal 2, runner.reload.credential_epoch, "one re-pair, by the winner alone"
    assert DeviceAuthorization.find(first.id).consumed?
    assert DeviceAuthorization.find(second.id).invalidated?
  ensure
    release_row_lock(held_lock) if held_lock
    stop_database_call(first_call) if first_call
    stop_database_call(second_call) if second_call
    DeviceAuthorization.where(id: [first&.id, second&.id].compact).delete_all
    family_ids = [
      first_result&.access_token&.refresh_token_family_id,
      first_result&.runner&.refresh_token&.refresh_token_family_id,
    ].compact
    if family_ids.any?
      RefreshToken.where(refresh_token_family_id: family_ids).delete_all
      AccessToken.where(refresh_token_family_id: family_ids).delete_all
      RefreshTokenFamily.where(id: family_ids).delete_all
    end
    TaskExecutor.where(id: runner&.id).delete_all
  end
end
