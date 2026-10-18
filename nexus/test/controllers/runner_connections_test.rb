require "test_helper"

class RunnerConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    sign_in_as @human
  end

  test "onboarding offers deployment and only currently stewarded independent active Agents" do
    owned = @human.build_agent(display_name: "My program").tap(&:save!)
    removed = @human.build_agent(display_name: "Removed program").tap(&:save!)
    removed.remove
    other = users(:owner).build_agent(display_name: "Other program").tap(&:save!)
    get runner_connection_path
    assert_response :success
    assert_select "a[href=?]", oauth_device_path, text: "I have a device code"
    assert_select "a[href=?]", new_agent_private_runner_path(owned)
    [removed, other].each do |agent|
      assert_select "a[href=?]", new_agent_private_runner_path(agent), count: 0
    end
    assert_select "a[href*='guides/runners/deploy']"
    sign_out
    get runner_connection_path
    assert_redirected_to new_session_path(return_to: runner_connection_path)
  end

  test "private Runner creation and one-time key reveal return to the same managed resource" do
    agent = @human.build_agent(display_name: "My program").tap(&:save!)
    get runner_connection_path
    get new_agent_private_runner_path(agent)
    assert_response :success
    post agent_private_runners_path(agent), params: { private_runner: { display_name: "Private laptop" } }
    runner = agent.private_runners.sole
    follow_redirect!
    assert_select "a[href=?]", runner_path(runner)
    post agent_private_runner_api_keys_path(agent, runner), params: { api_key: { name: "Laptop" } }
    assert_response :created
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    secret = css_select("input[name=api_key_secret]").sole["value"]
    assert_select "a[href=?]", runner_path(runner)
    get runner_path(runner)
    assert_response :success
    assert_not_includes response.body, secret
    assert_select "a[href=?]", agent_private_runner_api_keys_path(agent, runner)
    get agent_private_runners_path(agent)
    assert_select "a[href=?]", runner_path(runner), text: "Private laptop"
    agent.change_steward(to: users(:owner))
    get runner_path(runner)
    assert_response :success
    assert_select "a[href=?]", agent_private_runner_api_keys_path(agent, runner), count: 0
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

  test "combined grants never link their application executor as a Runner" do
    grant = DeviceAuthorizations::Issue.call(account: @human.account,
      agent_identifier: "combined-onboarding", agent_display_name: "Program",
      requested_executor_display_name: "Program address", registration_identifier: "combined-runner",
      runner_display_name: "Bundled Runner").authorization
    post oauth_device_verification_path, params: { verification: { user_code: grant.formatted_user_code } }
    post oauth_device_grant_connection_path(grant)
    result = DeviceAuthorizations::Consume.call(authorization: grant.reload)
    get oauth_device_grant_path(grant)
    assert_response :success
    assert_select "a", text: "View Runner", count: 0
    assert_select "a[href=?]", runner_path(result.executor_access_token.executor), count: 0
  end

  test "onboarding Agent choices paginate on their own URL and exclude named Agents" do
    parent = @human.build_agent(display_name: "Application 00").tap(&:save!)
    named = Users::DeclareNamedAgent.call(caller: parent, name: "reviewer", scope: "steward",
      description: "Review changes", configuration: { prompt_mechanism: "default", approval_mode: "bypass",
        tool_definitions: [], approval_rules: nil, prompt_template: nil, compaction_policy: nil,
        default_model: nil, kernel_tools: [] }).user
    10.times { |index| @human.build_agent(display_name: "Application #{index + 1}").save! }
    get runner_connection_path
    assert_response :success
    assert_select "a[href$='/private_runners/new']", 10
    assert_select "a[href=?]", new_agent_private_runner_path(named), count: 0
    get runner_connection_path(page: 2)
    assert_response :success
    assert_select "a[href$='/private_runners/new']", 1
    assert_select "a[href=?]", new_agent_private_runner_path(named), count: 0
  end

  test "ordinary OAuth Runner has no private Agent key route" do
    runner = connect_runner(manager: @human).executor_access_token.executor
    get runner_path(runner)
    assert_response :success
    assert_select "a[href*='/private_runners/']", count: 0
  end
end
