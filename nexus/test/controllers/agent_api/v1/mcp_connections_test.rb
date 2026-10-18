require "test_helper"

class AgentAPI::V1::McpConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @connection = mcp_connections(:notes)
    @agent = users(:agent)
    assert_equal :changed, @agent.change_steward(to: @connection.owner)
    @token = connect_agent_session(steward: @agent.steward, agent_identifier: @agent.agent_identifier).access_secret
  end

  test "an Agent reads its Human's complete catalog without endpoint or credential material" do
    @connection.update!(catalog: @connection.tools_catalog + [{ "name" => "write", "input_schema" => { "type" => "object" } }])
    get "/agent_api/v1/mcp_connections", headers: auth
    assert_response :success
    row = response.parsed_body.fetch("mcp_connections").sole
    assert_equal @connection.public_id, row.fetch("public_id")
    assert row.fetch("available")
    assert_equal %w[search write], row.fetch("tools").pluck("name")
    %w[endpoint_url auth_type bearer_token authorization_status authorization_expires_at agents owner_id lock_version].each do |key|
      assert_not_includes row.keys, key
    end
  end

  test "sharing a Workspace does not expose another Human's connection" do
    foreign = users(:owner).mcp_connections.create!(name: "Other Human", endpoint_url: "https://other.example.test/mcp", auth_type: "none")
    get "/agent_api/v1/mcp_connections", headers: auth
    assert_response :success
    assert_equal [@connection.public_id], response.parsed_body.fetch("mcp_connections").pluck("public_id")
    get "/agent_api/v1/mcp_connections/#{foreign.public_id}", headers: auth
    assert_response :not_found
  end

  test "an unavailable owned connection stays identifiable for repair without remote IO" do
    @connection.update!(enabled: false)
    Mcp::Client.stub(:open, ->(**) { flunk "a GET initiated network IO" }) do
      get "/agent_api/v1/mcp_connections/#{@connection.public_id}", headers: auth
    end
    assert_response :success
    assert_not response.parsed_body.dig("mcp_connection", "available")
    assert_equal @connection.public_id, response.parsed_body.dig("mcp_connection", "public_id")
  end

  test "Human member credentials cannot use the Agent catalog" do
    token = create_access_token_fixture(user: users(:member), name: "Human member")
    get "/agent_api/v1/mcp_connections", headers: { "Authorization" => "Bearer #{token.secret}" }
    assert_response :forbidden
    assert_equal "not_agent", response.parsed_body.dig("error", "code")
  end

  test "a named Agent and its declarer discover the same Human's connections without separate grants" do
    child = named_agent
    get "/agent_api/v1/mcp_connections", headers: auth, params: { agent_public_id: child.public_id }
    assert_response :success
    assert_equal [@connection.public_id], response.parsed_body.fetch("mcp_connections").pluck("public_id")
    get "/agent_api/v1/mcp_connections/#{@connection.public_id}", headers: auth, params: { agent_public_id: child.public_id }
    assert_response :success

    get "/agent_api/v1/mcp_connections", headers: auth, params: { agent_public_id: @agent.public_id }
    assert_response :success
    assert_equal [@connection.public_id], response.parsed_body.fetch("mcp_connections").pluck("public_id")
  end

  test "another application connected by the same Human discovers existing connections" do
    other = connect_agent_session(steward: @agent.steward, agent_identifier: "another-mcp-application")
    get "/agent_api/v1/mcp_connections", headers: { "Authorization" => "Bearer #{other.access_secret}" }
    assert_response :success
    assert_equal [@connection.public_id], response.parsed_body.fetch("mcp_connections").pluck("public_id")
  end

  test "the selector conceals unrelated inactive or transferred named Agents" do
    child = named_agent
    other = create_agent_member(steward: @agent.steward, display_name: "Other", agent_identifier: "other-catalog")
    [other.public_id, users(:member).public_id, SecureRandom.uuid_v7].each do |public_id|
      get "/agent_api/v1/mcp_connections", headers: auth, params: { agent_public_id: public_id }
      assert_response :not_found
    end
    assert_equal :removed, child.remove
    get "/agent_api/v1/mcp_connections", headers: auth, params: { agent_public_id: child.public_id }
    assert_response :not_found
    assert_equal :restored, child.restore
    child.update!(steward: users(:owner))
    get "/agent_api/v1/mcp_connections/#{@connection.public_id}", headers: auth, params: { agent_public_id: child.public_id }
    assert_response :not_found
  end

  private

    def auth = { "Authorization" => "Bearer #{@token}" }

    def named_agent
      put "/agent_api/v1/profile/agents/reviewer", headers: auth, as: :json,
        params: { scope: "steward", description: "Reviews notes", configuration: { approval_mode: "bypass" } }
      assert_response :created
      User.find_by!(public_id: response.parsed_body.dig("agent", "public_id"))
    end
end
