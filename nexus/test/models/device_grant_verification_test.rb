require "test_helper"
require_relative "../test_helpers/row_lock_test_helper"

class DeviceGrantVerificationTest < ActiveSupport::TestCase
  include RowLockTestHelper

  uses_transaction :test_two_tabs_recording_one_context_converge_on_one_charge_and_one_row

  def authorization
    @authorization ||= DeviceAuthorizations::Issue.call(
      account: accounts(:cybros),
      agent_identifier: "browser-context-agent",
      agent_display_name: "Browser context agent",
      requested_executor_display_name: "Browser context app"
    ).authorization
  end

  test "one browser context is idempotent and charges exposure once" do
    raw_context = derived_browser_context
    context_digest = DeviceGrantVerification.digest_browser_context(raw_context)

    assert_difference -> { authorization.device_grant_verifications.count }, 1 do
      assert DeviceGrantVerification.record(
        authorization: authorization,
        browser_context_digest: context_digest
      )
      assert DeviceGrantVerification.record(
        authorization: authorization,
        browser_context_digest: context_digest
      )
    end

    assert_equal 1, authorization.reload.exposure_count
    verification = authorization.device_grant_verifications.sole
    assert_equal 64, verification.browser_context_digest.length
    assert_not_equal raw_context, verification.browser_context_digest
  end

  test "browser context is stable and opaque per server-resolved browser session" do
    session = track_browser_session(create_browser_session(identities(:owner)))
    another_session = track_browser_session(create_browser_session(identities(:owner)))

    context = DeviceGrantVerification.browser_context_for(session: session)

    assert_equal context,
      DeviceGrantVerification.browser_context_for(session: session)
    assert_match DeviceGrantVerification::BROWSER_CONTEXT_FORMAT, context
    assert_not_includes context, session.public_id
    assert_not_equal context,
      DeviceGrantVerification.browser_context_for(session: another_session)
    assert_not_equal DeviceGrantVerification::BROWSER_CONTEXT_DIGEST_SALT,
      DeviceGrantVerification::SESSION_CONTEXT_DERIVATION_SALT
    assert_raises(ArgumentError) do
      DeviceGrantVerification.browser_context_for(
        session: Session.new(kind: :api, public_id: SecureRandom.uuid_v7)
      )
    end
  end

  test "distinct contexts stop exactly at the authorization exposure budget" do
    DeviceAuthorization::EXPOSURE_BUDGET.times do
      assert DeviceGrantVerification.record(
        authorization: authorization,
        browser_context_digest: context_digest
      )
    end

    assert_no_difference -> { authorization.device_grant_verifications.count } do
      assert_not DeviceGrantVerification.record(
        authorization: authorization,
        browser_context_digest: context_digest
      )
    end

    assert_equal DeviceAuthorization::EXPOSURE_BUDGET,
      authorization.reload.exposure_count
    assert_equal DeviceAuthorization::EXPOSURE_BUDGET,
      authorization.device_grant_verifications.count
  end

  test "a terminal authorization cannot gain another browser context" do
    authorization.update!(status: :canceled)

    assert_no_difference -> { authorization.device_grant_verifications.count } do
      assert_not DeviceGrantVerification.record(
        authorization: authorization,
        browser_context_digest: context_digest
      )
    end
    assert_equal 0, authorization.reload.exposure_count
  end

  test "two tabs recording one context converge on one charge and one row" do
    digest = context_digest
    held = hold_row_lock(DeviceAuthorization, authorization.id)
    calls = 2.times.map do
      start_database_call do
        DeviceGrantVerification.record(
          authorization: DeviceAuthorization.find(authorization.id),
          browser_context_digest: digest
        )
      end
    end
    wait_until_waiting_on_lock(*calls.map(&:pid))

    release_row_lock(held)
    held = nil
    results = calls.map { |call| finish_database_call(call) }
    calls = []

    assert_equal 1, results.map(&:id).uniq.length
    assert_equal 1, authorization.reload.exposure_count
    assert_equal 1, authorization.device_grant_verifications.count
  ensure
    release_row_lock(held) if held
    calls&.each { |call| stop_database_call(call) }
    if @authorization
      DeviceGrantVerification.where(device_authorization_id: @authorization.id).delete_all
      DeviceAuthorization.where(id: @authorization.id).delete_all
    end
    Session.where(id: @created_browser_session_ids).delete_all if @created_browser_session_ids
  end

  test "verification rows cascade with convergence-style parent deletion" do
    verification = DeviceGrantVerification.record(
      authorization: authorization,
      browser_context_digest: context_digest
    )

    DeviceAuthorization.where(id: authorization.id).delete_all

    assert_not DeviceGrantVerification.exists?(verification.id)
  end

  private

    def context_digest
      DeviceGrantVerification.digest_browser_context(derived_browser_context)
    end

    def derived_browser_context
      session = track_browser_session(create_browser_session(identities(:owner)))
      DeviceGrantVerification.browser_context_for(session: session)
    end

    def track_browser_session(session)
      (@created_browser_session_ids ||= []) << session.id
      session
    end
end
