require "test_helper"

class DeviceAuthorizationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  def mint(**overrides)
    DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: "install-#{SecureRandom.hex(4)}",
      agent_display_name: "Helper",
      requested_executor_display_name: "Helper app",
      **overrides
    )
  end

  def mint_runner
    DeviceAuthorizations::Issue.call(
      account: @account,
      registration_identifier: "runner-#{SecureRandom.hex(4)}",
      runner_display_name: "Workshop laptop"
    )
  end

  test "application and machine registrations are disjoint" do
    assert_predicate mint.authorization, :agent_connection?
    assert_predicate mint_runner.authorization, :runner_only_connection?
    assert_no_difference -> { DeviceAuthorization.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        mint(registration_identifier: "old-runner", runner_display_name: "Old runner")
      end
    end
  end

  test "the published interval is the product default with the env unset" do
    assert_equal 5, DeviceAuthorization.default_interval
    assert_equal 5, mint.authorization.interval
  end

  test "NEXUS_DEVICE_FLOW_INTERVAL sets the interval, never below one" do
    previous = ENV["NEXUS_DEVICE_FLOW_INTERVAL"]
    ENV["NEXUS_DEVICE_FLOW_INTERVAL"] = "1"
    assert_equal 1, DeviceAuthorization.default_interval
    assert_equal 1, mint.authorization.interval
    ENV["NEXUS_DEVICE_FLOW_INTERVAL"] = "0"
    assert_equal 1, DeviceAuthorization.default_interval
  ensure
    ENV["NEXUS_DEVICE_FLOW_INTERVAL"] = previous
  end







  test "the raw device code round-trips through the strict finder" do
    result = mint

    assert_equal result.authorization, DeviceAuthorization.find_by_device_code(result.device_code)
    assert_nil DeviceAuthorization.find_by_device_code(result.device_code.sub(/.\z/, "x"))
    assert_nil DeviceAuthorization.find_by_device_code("garbage")
  end

  test "user-code entry normalizes case, hyphens, and spaces, and rejects other shapes" do
    authorization = mint.authorization

    formatted = authorization.formatted_user_code
    assert_equal authorization, DeviceAuthorization.find_live_by_user_code(formatted.downcase)
    assert_equal authorization, DeviceAuthorization.find_live_by_user_code(" #{authorization.user_code[0, 4]} #{authorization.user_code[4, 4]} ")
    assert_nil DeviceAuthorization.find_live_by_user_code("AAAA-0000")
    assert_nil DeviceAuthorization.find_live_by_user_code("")
  end

  test "the exposure budget charges to the cap and then the code stops resolving" do
    authorization = mint.authorization

    DeviceAuthorization::EXPOSURE_BUDGET.times do
      assert authorization.charge_exposure
    end
    assert_not authorization.charge_exposure
    assert_equal DeviceAuthorization::EXPOSURE_BUDGET, authorization.reload.exposure_count,
      "a refused charge must not have counted"
  end

  test "clock expiry materializes from either live state" do
    pending = mint.authorization
    connected = mint.authorization
    connected.update_column(:status, "connected")
    DeviceAuthorization.where(id: [pending.id, connected.id])
      .update_all(expires_at: 1.minute.ago)

    pending.reload.materialize_expiry
    connected.reload.materialize_expiry
    assert pending.reload.expired?
    assert connected.reload.expired?
  end

  test "connection freezes the exact address identity and epoch" do
    authorization = mint.authorization
    member = users(:agent)
    address = executors(:address)

    authorization.record_connection(
      user: member,
      connector: users(:owner),
      expected_executor: address
    )

    assert_equal address.public_id, authorization.expected_executor_public_id
    assert_equal address.credential_epoch, authorization.expected_credential_epoch
    assert_equal address.status, authorization.expected_executor_status
    assert authorization.pairing_matches?(address)

    advance_credential_epoch(address)
    assert_not authorization.pairing_matches?(address.reload)
  end

  test "runner assignment is absent while pending and frozen by browser connection" do
    authorization = mint_runner.authorization

    assert_nil authorization.selected_assignment_scope
    authorization.record_connection(
      user: nil,
      connector: users(:owner),
      expected_executor: nil,
      selected_assignment_scope: :account_wide
    )

    assert_predicate authorization, :connected?
    assert_predicate authorization, :selects_account_wide?
  end

  test "canceling a connected runner clears its selected assignment" do
    authorization = mint_runner.authorization
    authorization.record_connection(
      user: nil,
      connector: users(:owner),
      expected_executor: nil,
      selected_assignment_scope: :user_private
    )

    authorization.record_cancellation

    assert_nil authorization.selected_assignment_scope
  end

  test "selected Runner assignment cannot be edited outside its model transition" do
    authorization = mint_runner.authorization
    authorization.record_connection(
      user: nil,
      connector: users(:owner),
      expected_executor: nil,
      selected_assignment_scope: :user_private
    )

    authorization.selected_assignment_scope = :account_wide

    assert_not authorization.save
    assert authorization.errors.of_kind?(:selected_assignment_scope, :readonly)
  end

  test "cancellation clears the frozen consequence and closes further live transitions" do
    authorization = mint.authorization
    authorization.record_connection(
      user: users(:agent),
      connector: users(:owner),
      expected_executor: executors(:address)
    )

    authorization.record_cancellation

    assert_predicate authorization, :canceled?
    assert_nil authorization.connected_by_id
    assert_nil authorization.connected_by_authority_generation
    assert_nil authorization.user_id
    assert_nil authorization.user_authority_generation
    assert_nil authorization.expected_executor_public_id
    assert_nil authorization.expected_credential_epoch
    assert_nil authorization.expected_executor_status
    assert_raises(ArgumentError) do
      authorization.record_connection(
        user: nil,
        connector: users(:owner),
        expected_executor: nil
      )
    end
    assert_raises(ArgumentError) { authorization.record_cancellation }
    assert_raises(ArgumentError) do
      authorization.record_consumption(
        executor: executors(:address),
        access_token: nil,
        refresh_token: nil
      )
    end
  end

  test "connected authority requires the connector and its frozen generation together" do
    authorization = mint.authorization

    authorization.status = :connected
    assert_not authorization.valid?
    assert authorization.errors.of_kind?(:connected_by, :incomplete)

    authorization.connected_by = users(:owner)
    assert_not authorization.valid?
    assert authorization.errors.of_kind?(
      :connected_by_authority_generation,
      :incomplete
    )
  end

  test "pairing precondition identity and epoch are all or none" do
    authorization = mint.authorization
    authorization.expected_executor_public_id = executors(:address).public_id

    assert_not authorization.valid?
    assert authorization.errors.of_kind?(:expected_executor_public_id, :incomplete)
    assert authorization.errors.of_kind?(:expected_credential_epoch, :incomplete)
    assert authorization.errors.of_kind?(:expected_executor_status, :incomplete)
  end

  test "a terminal row frees the user-code slot for a new transaction" do
    authorization = mint.authorization
    DeviceAuthorization.where(id: authorization.id).update_all(status: "expired")

    duplicate = DeviceAuthorization.new(authorization.attributes.except("id", "created_at", "updated_at"))
    duplicate.device_code_lookup_id = "x" * 24
    duplicate.public_id = SecureRandom.uuid_v7
    assert duplicate.save
  end
end
