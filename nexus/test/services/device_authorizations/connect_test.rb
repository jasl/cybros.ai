require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class DeviceAuthorizations::ConnectTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_connection_rechecks_connector_authority_after_waiting_for_its_row_lock,
    :test_reconnect_loses_to_member_removal_without_updating_the_program_name,
    :test_connection_crossing_its_deadline_while_waiting_for_authority_expires_without_side_effects,
    :test_reconnect_reaching_its_deadline_while_waiting_for_the_address_leaves_no_connection

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
  end

  def mint(agent_identifier: "install-new", name: "Helper app")
    DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: agent_identifier,
      agent_display_name: "Helper",
      requested_executor_display_name: name,
    ).authorization
  end

  def connect(grant, connector: @owner)
    DeviceAuthorizations::Connect.call(
      authorization: grant,
      connector: connector
    )
  end

  test "connection freezes a create intent and materializes nothing durable" do
    grant = mint

    assert_no_difference -> { User.count } do
      result = connect(grant)
      assert_equal :connected, result.outcome
    end

    grant.reload
    assert grant.connected?
    # The create intent is frozen as the absence of a mapped profile; the
    # member, its name, and every executor row wait for a winning consume.
    assert_nil grant.user
    assert_nil grant.user_authority_generation
    assert_equal @owner, grant.connected_by
    assert_equal @owner.authority_generation,
      grant.connected_by_authority_generation
    assert_nil grant.task_executor
  end

  test "reconnect freezes only the profile mapping; the address waits for consume" do
    member = users(:agent)
    original_name = member.display_name
    grant = mint(agent_identifier: member.agent_identifier)

    result = connect(grant)

    assert_equal :connected, result.outcome
    grant.reload
    assert_equal member, grant.user
    assert_equal member.authority_generation, grant.user_authority_generation
    assert_equal original_name, member.reload.display_name
    # No executor selection happens at connection: the winning consume is what creates or re-pairs
    # the address.
    assert_nil grant.task_executor
  end

  test "connection freezes the removed profile for restore at consume" do
    identifier = "install-removed"
    member = create_agent_member(
      steward: @owner,
      display_name: "Removed",
      agent_identifier: identifier
    )
    member.remove

    result = connect(mint(agent_identifier: identifier))

    assert_equal :connected, result.outcome
    assert_equal member, result.authorization.user
    # The restore itself waits for a winning consume: connection freezes the
    # choice and changes no profile state.
    assert member.reload.removed?
    assert_equal "Removed", member.display_name
  end

  test "another Human cannot claim the same exact instance identifier" do
    existing = users(:agent)
    existing_name = existing.display_name
    existing_address = TaskExecutor.address_for(existing)
    grant = mint(agent_identifier: existing.agent_identifier)

    assert_no_difference [-> { User.count }, -> { AccessToken.count }] do
      assert_equal :agent_already_bound, connect(grant, connector: users(:member)).outcome
    end
    assert_predicate grant.reload, :pending?
    assert_nil grant.connected_by
    assert_equal existing_name, existing.reload.display_name
    assert_equal existing_address, TaskExecutor.address_for(existing)
  end

  test "an agent principal cannot connect a browser-held device code" do
    grant = mint

    assert_equal :not_authorized, connect(grant, connector: users(:agent)).outcome
    assert grant.reload.pending?
  end

  test "an expired connection loses and materializes expiry" do
    grant = mint
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: 1.minute.ago)

    assert_equal :stale, connect(grant).outcome
    assert grant.reload.expired?
  end

  test "connection rechecks connector authority after waiting for its row lock" do
    connector = users(:member)
    grant = mint(
      agent_identifier: "install-connector-race",
      name: "App",
    )
    held_lock = hold_row_lock(
      User,
      connector.id,
      before_commit: ->(locked) {
        outcome = locked.suspend
        raise "connector suspension failed: #{outcome}" unless outcome == :suspended
      }
    )
    connection = start_connection(grant, connector: connector)

    wait_until_waiting_on_lock(connection.pid)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_connection(connection)
    connection = nil

    assert_equal :not_authorized, result.outcome
    assert grant.reload.pending?
    assert_nil grant.user_id
    assert_nil grant.connected_by_id
    assert_equal 0, User.where(agent_identifier: "install-connector-race").count
  ensure
    release_row_lock(held_lock) if held_lock
    stop_connection(connection) if connection
    DeviceAuthorization.where(id: grant&.id).delete_all
  end

  test "connection crossing its deadline while waiting for authority expires without side effects" do
    connector = users(:member)
    identifier = "install-connection-deadline"
    grant = mint(
      agent_identifier: identifier,
      name: "App",
    )
    deadline = 1.minute.from_now
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: deadline)
    held_lock = hold_row_lock(User, connector.id)
    connection = start_connection(grant, connector: connector)

    wait_until_waiting_on_lock(connection.pid)
    travel_to(deadline + 1.second)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_connection(connection)
    connection = nil

    assert_equal :stale, result.outcome
    assert grant.reload.expired?
    assert_nil grant.user_id
    assert_nil grant.connected_by_id
    assert_not User.exists?(agent_identifier: identifier)
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_connection(connection) if connection
    DeviceAuthorization.where(id: grant&.id).delete_all
    User.where(agent_identifier: identifier).delete_all if identifier
  end

  test "reconnect reaching its deadline while waiting for the address leaves no connection" do
    member = users(:agent)
    executor = task_executors(:address)
    grant = mint(agent_identifier: member.agent_identifier)
    held_lock = hold_row_lock(TaskExecutor, executor.id)
    connection = start_connection(grant)

    wait_until_waiting_on_lock(connection.pid)
    travel_to(grant.expires_at, with_usec: true)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_connection(connection)
    connection = nil

    assert_equal :stale, result.outcome
    assert grant.reload.expired?
    assert_nil grant.user_id
    assert_nil grant.connected_by_id
    assert_nil grant.expected_task_executor_public_id
    assert_equal executor.credential_epoch, executor.reload.credential_epoch
  ensure
    travel_back
    release_row_lock(held_lock) if held_lock
    stop_connection(connection) if connection
    DeviceAuthorization.where(id: grant&.id).delete_all
  end

  test "reconnect loses to member removal without updating the program name" do
    member = users(:agent)
    original_name = member.display_name
    grant = mint(agent_identifier: member.agent_identifier)
    held_lock = hold_row_lock(
      User,
      member.id,
      before_commit: ->(locked) {
        outcome = locked.remove
        raise "member removal failed: #{outcome}" unless outcome == :removed
      }
    )
    connection = start_connection(grant)

    wait_until_waiting_on_lock(connection.pid)
    release_row_lock(held_lock)
    held_lock = nil
    result = finish_connection(connection)
    connection = nil

    assert_equal :stale, result.outcome
    assert member.reload.removed?
    assert_equal original_name, member.display_name
    assert grant.reload.pending?
    assert_nil grant.user_id
    assert_nil grant.connected_by_id
  ensure
    release_row_lock(held_lock) if held_lock
    stop_connection(connection) if connection
    DeviceAuthorization.where(id: grant&.id).delete_all
  end

  test "a second connection of one grant is stale, and neither creates anything durable" do
    grant = mint

    assert_equal :connected, connect(grant).outcome
    assert_equal :stale, connect(grant.reload).outcome
    assert_equal 0, User.where(kind: :agent, agent_identifier: "install-new").count
  end

  private

    def start_connection(grant, connector: @owner)
      grant_id = grant.id
      connector_id = connector.id
      start_database_call do
        DeviceAuthorizations::Connect.call(
          authorization: DeviceAuthorization.find(grant_id),
          connector: User.find(connector_id)
        )
      end
    end

    def finish_connection(connection)
      finish_database_call(connection)
    end

    def stop_connection(connection)
      stop_database_call(connection)
    end
end
