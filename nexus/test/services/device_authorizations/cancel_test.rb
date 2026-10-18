require "test_helper"

class DeviceAuthorizations::CancelTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  def mint
    DeviceAuthorizations::Issue.call(
      account: @account,
      agent_identifier: "install-cancel",
      agent_display_name: "Cancel",
      requested_executor_display_name: "App",
    ).authorization
  end

  test "an active human member may cancel a pending connection" do
    grant = mint

    result = DeviceAuthorizations::Cancel.call(
      authorization: grant,
      connector: users(:member)
    )

    assert_equal :canceled, result.outcome
    assert grant.reload.canceled?
    assert_nil grant.connected_by
  end

  test "an agent principal cannot cancel a browser-held device code" do
    grant = mint

    result = DeviceAuthorizations::Cancel.call(
      authorization: grant,
      connector: users(:agent)
    )

    assert_equal :not_authorized, result.outcome
    assert grant.reload.pending?
  end

  test "an expired connection materializes expiry instead of cancellation" do
    grant = mint
    DeviceAuthorization.where(id: grant.id).update_all(expires_at: 1.minute.ago)

    result = DeviceAuthorizations::Cancel.call(
      authorization: grant,
      connector: users(:member)
    )

    assert_equal :stale, result.outcome
    assert grant.reload.expired?
  end

  test "a connection at its deadline expires instead of being canceled" do
    grant = mint

    travel_to(grant.expires_at, with_usec: true) do
      result = DeviceAuthorizations::Cancel.call(
        authorization: grant,
        connector: users(:member)
      )

      assert_equal :stale, result.outcome
      assert grant.reload.expired?
    end
  end

  test "a connected, unconsumed request still cancels — no durable consequence exists to unwind" do
    grant = mint
    DeviceAuthorization.where(id: grant.id).update_all(status: "connected")

    result = DeviceAuthorizations::Cancel.call(
      authorization: grant,
      connector: users(:member)
    )

    assert_equal :canceled, result.outcome
    grant.reload
    assert grant.canceled?
    assert_nil grant.connected_by_id
    assert_nil grant.user_id
  end

  test "a terminal request is stale" do
    grant = mint
    DeviceAuthorization.where(id: grant.id).update_all(status: "consumed")

    result = DeviceAuthorizations::Cancel.call(
      authorization: grant,
      connector: users(:member)
    )

    assert_equal :stale, result.outcome
    assert grant.reload.consumed?
  end
end
