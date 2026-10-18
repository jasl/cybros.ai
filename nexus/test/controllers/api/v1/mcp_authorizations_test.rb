require "test_helper"

class API::V1::McpAuthorizationsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    @connection = @owner.mcp_connections.create!(name: "Research", endpoint_url: "https://research.example.test/mcp", auth_type: "oauth")
    @token = create_access_token_fixture(user: @owner, name: "Personal settings", plane: :platform)
  end

  test "an ordinary Human starts authorization and receives only browser navigation material" do
    start = ->(connection:, expected_lock_version:, redirect_uri:) do
      assert_equal @connection, connection
      assert_equal 0, expected_lock_version
      assert_equal settings_mcp_connection_authorization_callback_url(@connection), redirect_uri
      result(:saved, authorization_url: "https://research.example.test/authorize?state=fixture-state", expires_at: 10.minutes.from_now)
    end
    McpConnections::OAuth::Start.stub(:call, start) do
      post path, params: { command: { lock_version: 0, redirect_uri: "https://ignored.example.test" } }, as: :json, headers: auth
    end
    assert_response :success
    row = response.parsed_body.fetch("authorization")
    assert_equal %w[authorization_url connection_public_id expires_at], row.keys.sort
    assert_equal @connection.public_id, row.fetch("connection_public_id")
    assert_equal "https://research.example.test/authorize?state=fixture-state", row.fetch("authorization_url")
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_not_includes response.body, "private-access-token"
  end

  test "authorization status reads stay local and preserve the owner projection" do
    McpConnections::OAuth::Start.stub(:call, ->(**) { flunk "GET started remote authorization" }) do
      get "/api/v1/mcp_connections/#{@connection.public_id}", headers: auth
    end
    assert_response :success
    row = response.parsed_body.fetch("mcp_connection")
    assert_equal "oauth", row.fetch("auth_type")
    assert_equal "not_authorized", row.fetch("authorization_status")
    assert_nil row.fetch("authorization_expires_at")
    assert_not row.fetch("credential_configured")
    assert_not row.fetch("available")
  end

  test "authorization creation requires a version before calling the service" do
    McpConnections::OAuth::Start.stub(:call, ->(**) { flunk "invalid command reached authorization" }) do
      post path, params: { command: { ignored: true } }, as: :json, headers: auth
      assert_response :bad_request
      post path, params: { command: { lock_version: -1 } }, as: :json, headers: auth
      assert_response :bad_request
    end
  end

  test "administration and browser cookies cannot substitute for the owner's Platform bearer" do
    other = create_access_token_fixture(user: users(:owner), name: "Administrator", plane: :platform)
    McpConnections::OAuth::Start.stub(:call, ->(**) { flunk "another principal reached authorization" }) do
      post path, params: { command: { lock_version: 0 } }, as: :json,
        headers: { "Authorization" => "Bearer #{other.secret}" }
      assert_response :not_found
      sign_in_as @owner
      post path, params: { command: { lock_version: 0 } }, as: :json
      assert_response :unauthorized
    end
  end

  test "Agent and executor credentials cannot start remote authorization" do
    grant = connect_agent_session(steward: @owner, agent_identifier: "mcp-oauth-boundary")
    McpConnections::OAuth::Start.stub(:call, ->(**) { flunk "wrong credential plane reached authorization" }) do
      [grant.access_secret, grant.executor_access_secret].each do |secret|
        post path, params: { command: { lock_version: 0 } }, as: :json, headers: { "Authorization" => "Bearer #{secret}" }
        assert_response :unauthorized
      end
    end
  end

  test "authorization refusals retain their public status and sanitized code" do
    { stale_object: :conflict, not_authorized: :forbidden, credential_not_applicable: :unprocessable_entity,
      authorization_pending: :unprocessable_entity, authorization_failed: :unprocessable_entity,
      authorization_timeout: :unprocessable_entity }.each do |outcome, status|
      McpConnections::OAuth::Start.stub(:call, result(outcome)) do
        post path, params: { command: { lock_version: 0 } }, as: :json, headers: auth
      end
      assert_response status
      assert_equal outcome.to_s, response.parsed_body.dig("error", "code")
      assert_not_includes response.body, "private-access-token"
    end
  end

  test "OAuth accepts local clearing but does not accept Bearer token replacement" do
    credential = "/api/v1/mcp_connections/#{@connection.public_id}/credential"
    put credential, params: { credential: { lock_version: 0, bearer_token: "must-not-install" } }, as: :json, headers: auth
    assert_response :unprocessable_entity
    assert_equal "credential_not_applicable", response.parsed_body.dig("error", "code")
    delete credential, params: { command: { lock_version: 0 } }, as: :json, headers: auth
    assert_response :success
    assert_equal "not_authorized", response.parsed_body.dig("mcp_connection", "authorization_status")
    assert_nil @connection.reload.bearer_token
  end

  private

    def auth = { "Authorization" => "Bearer #{@token.secret}" }
    def path = "/api/v1/mcp_connections/#{@connection.public_id}/authorization"

    def result(outcome, authorization_url: nil, expires_at: nil)
      McpConnections::OAuth::Result.new(outcome: outcome, connection: @connection,
        authorization_url: authorization_url, expires_at: expires_at, bearer_token: "private-access-token")
    end
end
