require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class DeviceAuthorizations::MachineCancelTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_machine_cancel_wins_when_it_queues_before_consume,
    :test_consume_wins_when_it_queues_before_machine_cancel

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  test "pending and connected authorizations cancel and clear their frozen consequence" do
    pending = mint(identifier: "machine-cancel-pending").authorization
    assert_equal :canceled,
      DeviceAuthorizations::MachineCancel.call(authorization: pending).outcome
    assert_canceled_without_frozen_consequence(pending)

    member = create_agent_member(
      steward: @owner,
      display_name: "Connected agent",
      agent_identifier: "machine-cancel-connected"
    )
    executor = member.task_executors.create!(
      account: @account,
      executor_kind: :agent_application,
      display_name: "Connected app"
    )
    connected = mint(identifier: member.agent_identifier).authorization
    connected.record_connection(
      user: member,
      connector: @owner,
      expected_task_executor: executor
    )

    assert_equal :canceled,
      DeviceAuthorizations::MachineCancel.call(authorization: connected).outcome
    assert_canceled_without_frozen_consequence(connected)
  end

  test "canceling a connected Runner also clears the browser-selected scope" do
    existing = @account.task_executors.create!(
      executor_kind: :runner,
      display_name: "Account-wide Runner",
      registration_identifier: "machine-cancel-wide",
      assignment_scope: :account_wide,
      manager: @owner
    )
    grant = DeviceAuthorizations::Issue.call(
      account: @account,
      registration_identifier: existing.registration_identifier,
      runner_display_name: "Account-wide Runner"
    ).authorization
    result = DeviceAuthorizations::Connect.call(
      authorization: grant,
      connector: @owner,
      account_wide: true,
      expected_live_runner:
        DeviceAuthorizations::Connect.live_runner_precondition(existing)
    )
    assert_equal :connected, result.outcome
    assert_equal "account_wide", grant.reload.selected_assignment_scope

    assert_equal :canceled,
      DeviceAuthorizations::MachineCancel.call(authorization: grant).outcome
    assert_canceled_without_frozen_consequence(grant)
    assert_nil grant.selected_assignment_scope
  end

  test "terminal states without a credential consequence are idempotently safe" do
    canceled = mint(identifier: "machine-cancel-idempotent").authorization
    assert_equal :canceled,
      DeviceAuthorizations::MachineCancel.call(authorization: canceled).outcome
    assert_equal :canceled,
      DeviceAuthorizations::MachineCancel.call(authorization: canceled).outcome

    %w[expired invalidated].each do |status|
      grant = mint(identifier: "machine-cancel-#{status}").authorization
      DeviceAuthorization.where(id: grant.id).update_all(status: status)

      result = DeviceAuthorizations::MachineCancel.call(authorization: grant)

      assert_equal :canceled, result.outcome
      assert_equal status, grant.reload.status
    end
  end

  test "a consumed authorization is too late and keeps its evidence" do
    grant = connected_grant(identifier: "machine-cancel-consumed")
    consumed = DeviceAuthorizations::Consume.call(authorization: grant)
    assert_equal :minted, consumed.outcome

    result = DeviceAuthorizations::MachineCancel.call(authorization: grant)

    assert_equal :consumed, result.outcome
    assert_predicate grant.reload, :consumed?
    assert_not_nil grant.access_token_id
    assert_not_nil grant.refresh_token_id
  end

  # Both operations take the DeviceAuthorization row as their first winner
  # lock. Queue cancel first and prove Consume observes its terminal result
  # without creating a Profile, address, or credential.
  test "machine cancel wins when it queues before consume" do
    identifier = "machine-cancel-wins"
    grant = connected_grant(identifier: identifier)
    held = hold_row_lock(DeviceAuthorization, grant.id)
    cancel_call = start_database_call do
      DeviceAuthorizations::MachineCancel.call(
        authorization: DeviceAuthorization.find(grant.id)
      )
    end
    wait_until_waiting_on_lock(cancel_call.pid)
    consume_call = start_database_call do
      DeviceAuthorizations::Consume.call(
        authorization: DeviceAuthorization.find(grant.id)
      )
    end
    wait_until_waiting_on_lock(cancel_call.pid, consume_call.pid)

    release_row_lock(held)
    held = nil
    cancel_result = finish_database_call(cancel_call)
    cancel_call = nil
    consume_result = finish_database_call(consume_call)
    consume_call = nil

    assert_equal :canceled, cancel_result.outcome
    assert_equal :access_denied, consume_result.outcome
    assert_predicate grant.reload, :canceled?
    assert_nil User.find_by(agent_identifier: identifier)
    assert_nil grant.task_executor_id
    assert_nil grant.access_token_id
    assert_nil grant.refresh_token_id
  ensure
    release_row_lock(held) if held
    stop_database_call(cancel_call) if cancel_call
    stop_database_call(consume_call) if consume_call
  end

  # Queue Consume first and prove Machine Cancel cannot erase a credential
  # bundle that has already won. Its typed loser tells the client to let the
  # token response finish and adopt that bundle.
  test "consume wins when it queues before machine cancel" do
    grant = connected_grant(identifier: "machine-consume-wins")
    held = hold_row_lock(DeviceAuthorization, grant.id)
    consume_call = start_database_call do
      DeviceAuthorizations::Consume.call(
        authorization: DeviceAuthorization.find(grant.id)
      )
    end
    wait_until_waiting_on_lock(consume_call.pid)
    cancel_call = start_database_call do
      DeviceAuthorizations::MachineCancel.call(
        authorization: DeviceAuthorization.find(grant.id)
      )
    end
    wait_until_waiting_on_lock(consume_call.pid, cancel_call.pid)

    release_row_lock(held)
    held = nil
    consume_result = finish_database_call(consume_call)
    consume_call = nil
    cancel_result = finish_database_call(cancel_call)
    cancel_call = nil

    assert_equal :minted, consume_result.outcome
    assert_equal :consumed, cancel_result.outcome
    assert_predicate grant.reload, :consumed?
    assert_equal consume_result.access_token, grant.access_token
    assert_equal consume_result.refresh_token, grant.refresh_token
  ensure
    release_row_lock(held) if held
    stop_database_call(consume_call) if consume_call
    stop_database_call(cancel_call) if cancel_call
  end

  private

    def mint(identifier:)
      DeviceAuthorizations::Issue.call(
        account: @account,
        agent_identifier: identifier,
        agent_display_name: "Machine cancel",
        requested_executor_display_name: "Machine cancel app"
      )
    end

    def connected_grant(identifier:)
      grant = mint(identifier: identifier).authorization
      grant.record_connection(
        user: nil,
        connector: @owner,
        expected_task_executor: nil
      )
      grant
    end

    def assert_canceled_without_frozen_consequence(grant)
      grant.reload
      assert_predicate grant, :canceled?
      assert_nil grant.user_id
      assert_nil grant.connected_by_id
      assert_nil grant.user_authority_generation
      assert_nil grant.expected_task_executor_public_id
      assert_nil grant.expected_credential_epoch
      assert_nil grant.expected_task_executor_status
    end
end
