require "test_helper"

class API::V1::McpConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:member)
    @connection = mcp_connections(:notes)
    @token = create_access_token_fixture(user: @owner, name: "Personal settings", plane: :platform)
  end

  test "an ordinary Human creates a private connection with encrypted write-only credentials" do
    assert_difference "McpConnection.count", 1 do
      post "/api/v1/mcp_connections", params: { mcp_connection: {
        name: "Personal notes", account_label: "My notes account", endpoint_url: "https://personal.example.test/mcp",
        auth_type: "bearer", bearer_token: "fixture-new-secret",
      } }, as: :json, headers: auth
    end
    assert_response :created
    row = response.parsed_body.fetch("mcp_connection")
    assert row.fetch("credential_configured")
    assert_equal [], row.fetch("tools")
    assert_not_includes response.body, "fixture-new-secret"
    assert_not_includes row.keys, "bearer_token"
    assert_not_includes row.keys, "id"
    connection = @owner.mcp_connections.find_by!(public_id: row.fetch("public_id"))
    assert_not_includes connection.bearer_token_before_type_cast, "fixture-new-secret"
  end

  test "connection discovery reads are local and expose only the owner's rows" do
    Mcp::Client.stub(:open, ->(**) { flunk "a GET initiated remote discovery" }) do
      get "/api/v1/mcp_connections", headers: auth
      assert_response :success
      assert_equal [@connection.public_id], response.parsed_body.fetch("mcp_connections").pluck("public_id")
      get path, headers: auth
      assert_response :success
      assert_equal "search", response.parsed_body.dig("mcp_connection", "tools", 0, "name")
    end
  end

  test "administrator status grants no takeover of another Human's connection" do
    other = create_access_token_fixture(user: users(:owner), name: "Admin", plane: :platform)
    get path, headers: { "Authorization" => "Bearer #{other.secret}" }
    assert_response :not_found
    patch path, params: { mcp_connection: { lock_version: 0, enabled: false } }, as: :json,
      headers: { "Authorization" => "Bearer #{other.secret}" }
    assert_response :not_found
    assert @connection.reload.enabled?
  end

  test "Agent member and executor credentials cannot manage connections" do
    member = connect_agent_session(steward: users(:owner), agent_identifier: users(:agent).agent_identifier)
    get "/api/v1/mcp_connections", headers: { "Authorization" => "Bearer #{member.access_secret}" }
    assert_response :unauthorized
    get "/api/v1/mcp_connections", headers: { "Authorization" => "Bearer #{member.executor_access_secret}" }
    assert_response :unauthorized
  end

  test "partial edits require a version and reject stale writes" do
    patch path, params: { mcp_connection: { name: "Missing version" } }, as: :json, headers: auth
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")

    patch path, params: { mcp_connection: { name: "Renamed", lock_version: 0 } }, as: :json, headers: auth
    assert_response :success
    patch path, params: { mcp_connection: { enabled: false, lock_version: 0 } }, as: :json, headers: auth
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")
    assert @connection.reload.enabled?
  end

  test "immutable service selectors and unknown fields are ignored on update" do
    patch path, params: { mcp_connection: { lock_version: 0, name: "Same target", endpoint_url: "https://other.example.test/mcp",
      auth_type: "bearer", bearer_token: "must-not-install", account_id: 999, legacy: true } }, as: :json, headers: auth
    assert_response :success
    assert_equal "https://notes.example.test/mcp", @connection.reload.endpoint_url
    assert_equal "none", @connection.auth_type
    assert_nil @connection.bearer_token
  end

  test "credential rotation and clearing use the same target and never return token material" do
    connection = @owner.mcp_connections.create!(name: "Authenticated", endpoint_url: "https://token.example.test/mcp", auth_type: "bearer")
    credential_path = "/api/v1/mcp_connections/#{connection.public_id}/credential"
    put credential_path, params: { credential: { lock_version: 0, bearer_token: "fixture-rotated-secret" } }, as: :json, headers: auth
    assert_response :success
    assert response.parsed_body.dig("mcp_connection", "credential_configured")
    assert_not_includes response.body, "fixture-rotated-secret"
    delete credential_path, params: { command: { lock_version: connection.reload.lock_version } }, as: :json, headers: auth
    assert_response :success
    assert_not response.parsed_body.dig("mcp_connection", "credential_configured")
    assert_nil connection.reload.bearer_token
  end

  test "explicit catalog refresh publishes a complete directory through the protocol boundary" do
    client = Object.new
    client.define_singleton_method(:list_tools) { [] }
    Mcp::Client.stub(:open, ->(**, &block) { block.call(client) }) do
      post "#{path}/catalog_refresh", params: { command: { lock_version: 0 } }, as: :json, headers: auth
    end
    assert_response :success
    assert_equal [], @connection.reload.tools_catalog
    assert_not @connection.tool_available?(agent: users(:agent), name: "search")
  end

  test "keyset lists are bounded ordered and have opaque continuations" do
    @owner.mcp_connections.create!(name: "Another", endpoint_url: "https://another.example.test/mcp", auth_type: "none")
    get "/api/v1/mcp_connections", params: { limit: 1 }, headers: auth
    assert_response :success
    first = response.parsed_body.fetch("mcp_connections").sole.fetch("public_id")
    after = response.parsed_body.dig("pagination", "next_after")
    assert after.present?
    assert_not_equal first, after
    get "/api/v1/mcp_connections", params: { limit: 1, after: after }, headers: auth
    assert_response :success
    assert_not_equal first, response.parsed_body.fetch("mcp_connections").sole.fetch("public_id")
    assert_nil response.parsed_body.dig("pagination", "next_after")
    get "/api/v1/mcp_connections", params: { limit: 101 }, headers: auth
    assert_response :bad_request
  end

  private

    def auth = { "Authorization" => "Bearer #{@token.secret}" }
    def path = "/api/v1/mcp_connections/#{@connection.public_id}"
end
