require "test_helper"

class RunnerConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    sign_in_as @human
  end

  test "onboarding offers independent machine deployment and device code entry" do
    get runner_connection_path
    assert_response :success
    assert_select "a[href=?]", oauth_device_path, text: "I have a device code"
    assert_select "a[href*='/private_runners']", count: 0
    assert_select "a[href*='guides/runners/deploy']"
    sign_out
    get runner_connection_path
    assert_redirected_to new_session_path(return_to: runner_connection_path)
  end



  test "Device Flow distinguishes approval from collection and links the captured address after replacement" do
    grant = DeviceAuthorizations::Issue.call(account: @human.account,
      registration_identifier: "onboarding", runner_display_name: "Laptop").authorization
    post oauth_device_verification_path, params: { verification: { user_code: grant.formatted_user_code } }
    post oauth_device_grant_connection_path(grant), params: {
      connection: { expected_live_runner: DeviceAuthorizations::Connect::ABSENT_LIVE_RUNNER },
    }
    get oauth_device_grant_path(grant)
    assert_response :success
    assert_select "a[href=?]", oauth_device_grant_path(grant), text: "Refresh connection status"
    assert_select "a", text: "View Runner", count: 0
    result = DeviceAuthorizations::Consume.call(authorization: grant.reload)
    runner = result.executor_access_token.executor
    get oauth_device_grant_path(grant)
    assert_select "a[href=?]", runner_path(runner), text: "View Runner"
    runner.revoke
    replacement = connect_runner(manager: @human, registration_identifier: "onboarding").executor_access_token.executor
    get oauth_device_grant_path(grant)
    assert_select "a[href=?]", runner_path(runner), text: "View Runner"
    assert_select "a[href=?]", runner_path(replacement), count: 0
    sign_out
    sign_in_as users(:owner)
    get oauth_device_grant_path(grant)
    assert_response :success
    assert_select "a", text: "View Runner", count: 0
    assert_select "a[href=?]", runners_path
    grant.destroy!
    get oauth_device_grant_path(grant)
    assert_redirected_to oauth_device_path
  end

  test "application grants never link their application executor as a managed machine" do
    grant = DeviceAuthorizations::Issue.call(account: @human.account,
      agent_identifier: "combined-onboarding", agent_display_name: "Program",
      requested_executor_display_name: "Program address").authorization
    post oauth_device_verification_path, params: { verification: { user_code: grant.formatted_user_code } }
    post oauth_device_grant_connection_path(grant)
    result = DeviceAuthorizations::Consume.call(authorization: grant.reload)
    get oauth_device_grant_path(grant)
    assert_response :success
    assert_select "a", text: "View Runner", count: 0
    assert_select "a[href=?]", runner_path(result.executor_access_token.executor), count: 0
  end



  test "ordinary OAuth Runner has no private Agent key route" do
    runner = connect_runner(manager: @human).executor_access_token.executor
    get runner_path(runner)
    assert_response :success
    assert_select "a[href*='/private_runners/']", count: 0
  end
end
