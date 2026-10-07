require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    sign_in_as users(:member)
  end

  test "rendering uses the identity already loaded for authentication" do
    assert_no_queries_match(/FROM "identities".*LIMIT/) do
      get root_path
    end

    assert_response :success
    assert_select "nav[aria-label='Primary']" do
      {
        "Dashboard" => root_path,
        "Workspaces" => workspaces_path,
        "Agents" => agents_path,
        "Runners" => runners_path,
        "Settings" => settings_path,
      }.each do |label, path|
        assert_select "a[href=?]", path, text: label
      end
    end
    assert_select "a[href=?]", admin_users_path, text: "Administration", count: 0
    assert_select "article[aria-label='Model provider setup']", count: 0
    assert_select "article[aria-label='Agent connection']", count: 1
  end

  test "administrators can enter administration from the account menu" do
    sign_out
    sign_in_as users(:owner)

    get root_path

    assert_response :success
    assert_select "aside a[href=?]", admin_users_path, text: "Administration"
    assert_select "article[aria-label='Model provider setup']", count: 1
    assert_select "article[aria-label='Agent connection']", count: 1
  end

  test "model setup disappears when a text model is available regardless of cost estimates" do
    sign_out
    sign_in_as users(:owner)
    enable_models

    get root_path
    assert_select "article[aria-label='Model provider setup']", count: 0

    Accounts::ConfigureCostUnit.call(account: accounts(:cybros), cost_unit: "USD")
    get root_path
    assert_select "article[aria-label='Model provider setup']", count: 0
    assert_select "article[aria-label='Agent connection']", count: 1

    policy = ModelProviderConfig.find_by!(account: accounts(:cybros), provider_id: "test_api")
    ModelProviders::DisableLane.call(account: accounts(:cybros), provider_id: "test_api", expected_lock_version: policy.lock_version)
    get root_path
    assert_select "article[aria-label='Model provider setup']", count: 1
  end

  test "a connected agent completes only its steward's task even while offline" do
    connection = connect_agent_session(steward: users(:owner), agent_identifier: "dashboard-agent")
    address = connection.executor_access_token.task_executor
    assert_nil address.last_seen_at

    get root_path
    assert_select "article[aria-label='Agent connection']", count: 1

    sign_out
    sign_in_as users(:owner)
    get root_path
    assert_select "article[aria-label='Agent connection']", count: 0

    address.agent.revoke_connection
    get root_path
    assert_select "article[aria-label='Agent connection']", count: 1
  end

  test "a runner and an agent definition without a connection do not complete the agent task" do
    connect_runner(manager: users(:member))
    create_agent_member(steward: users(:member), agent_identifier: "not-connected")

    get root_path
    assert_select "article[aria-label='Agent connection']", count: 1
  end

  test "an expired credential without a refresh token no longer completes the task" do
    sign_out
    sign_in_as users(:owner)
    credential = create_bound_credential(executor: task_executors(:address))
    get root_path
    assert_select "article[aria-label='Agent connection']", count: 0

    travel_to credential.token.expires_at + 1.second do
      get root_path
      assert_select "article[aria-label='Agent connection']", count: 1
    end
  end

  test "a rotatable connection stays complete and no todo section remains after both tasks" do
    sign_out
    sign_in_as users(:owner)
    enable_models
    Accounts::ConfigureCostUnit.call(account: accounts(:cybros), cost_unit: "USD")
    connection = connect_agent_session(steward: users(:owner), agent_identifier: "dashboard-refresh")
    travel_to connection.executor_access_token.expires_at + 1.second do
      get root_path
      assert_response :success
      assert_select "section[aria-labelledby='dashboard-todo-heading']", count: 0
      assert_select "nav[aria-label='Primary'] a[href=?]", agents_path, text: "Agents"
    end
  end

  private

    def enable_models
      ModelProviders::SetAPIKey.call(account: accounts(:cybros), provider_id: "test_api", api_key: "readiness-test-key")
      ModelProviders::EnableLane.call(account: accounts(:cybros), provider_id: "test_api", expected_lock_version: nil)
    end
end
