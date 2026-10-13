require "test_helper"

class API::V1::AdminRetentionTest < ActionDispatch::IntegrationTest
  PATH = "/api/v1/admin/account/retention"

  setup do
    @account = accounts(:cybros)
    @token = create_access_token_fixture(user: users(:owner), name: "Retention operator", plane: :platform)
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  test "an operator reads changes disables and restores the one Account setting" do
    get PATH, headers: auth
    assert_response :success
    assert_equal({ "account" => { "execution_details_retention_days" => 90 } }, response.parsed_body)

    [30, nil, 90].each do |days|
      patch PATH, params: { account: { execution_details_retention_days: days, name: "Ignored rename" } },
        as: :json, headers: auth
      assert_response :success
      if days.nil?
        assert_nil response.parsed_body.fetch("account").fetch("execution_details_retention_days")
        assert_nil @account.reload.execution_details_retention_days
      else
        assert_equal days, response.parsed_body.fetch("account").fetch("execution_details_retention_days")
        assert_equal days, @account.reload.execution_details_retention_days
      end
      assert_equal "Cybros", @account.name
    end
  end

  test "invalid days and a missing envelope leave the setting unchanged" do
    [0, -3, 1.5, "not days"].each do |invalid|
      patch PATH, params: { account: { execution_details_retention_days: invalid } }, as: :json, headers: auth
      assert_response :unprocessable_entity
      assert_equal "validation_failed", response.parsed_body.dig("error", "code")
      assert_equal 90, @account.reload.execution_details_retention_days
    end
    patch PATH, params: {}, as: :json, headers: auth
    assert_response :bad_request
    assert_equal 90, @account.reload.execution_details_retention_days
  end

  test "ordinary Human sessions cannot read or change the global policy" do
    post "/api/v1/session", params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :created
    headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
    get PATH, headers: headers
    assert_response :forbidden
    patch PATH, params: { account: { execution_details_retention_days: nil } }, as: :json, headers: headers
    assert_response :forbidden
    assert_equal 90, @account.reload.execution_details_retention_days
  end

  test "an Agent credential has no settings plane and an anonymous request is unauthenticated" do
    get PATH
    assert_response :unauthorized
    agent = connect_agent_session(steward: users(:owner), agent_identifier: "retention-denied")
    headers = { "Authorization" => "Bearer #{agent.access_secret}" }
    get PATH, headers: headers
    assert_response :unauthorized
    patch PATH, params: { account: { execution_details_retention_days: nil } }, as: :json, headers: headers
    assert_response :unauthorized
    assert_equal 90, @account.reload.execution_details_retention_days
  end
end
