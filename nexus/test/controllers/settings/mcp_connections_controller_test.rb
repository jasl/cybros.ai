require "test_helper"

class Settings::McpConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @connection = mcp_connections(:notes)
    sign_in_as users(:member)
  end

  test "the owner can inspect the catalog and manage the connection and credential" do
    get settings_mcp_connections_path
    assert_response :success
    assert_select "a", text: "Work notes"
    get settings_mcp_connection_path(@connection)
    assert_response :success
    assert_select "input[name='mcp_connection[lock_version]']"
    assert_select "h3", text: "Available tools"
    assert_select "span", text: "search"
    assert_select "input[name='mcp_connection[allowed_tool_names][]']", count: 0
    assert_select "a", text: "Manage Agent access", count: 0
    get settings_mcp_connection_credential_path(@connection)
    assert_response :success
    assert_select "input[type='password'][value]", count: 0
  end

  test "creating without authentication ignores the empty browser password field" do
    post settings_mcp_connections_path, params: { mcp_connection: {
      name: "Public service", endpoint_url: "https://public.example.test/mcp", auth_type: "none", bearer_token: "",
    } }
    assert_response :redirect
    connection = users(:member).mcp_connections.find_by!(name: "Public service")
    assert_equal "none", connection.auth_type
    assert_nil connection.bearer_token
  end

  test "OAuth connection pages replace a prior document's referrer policy before native authorization" do
    connection = users(:member).mcp_connections.create!(name: "OAuth service",
      endpoint_url: "https://oauth.example.test/mcp", auth_type: "oauth")

    get settings_mcp_connection_path(connection)

    assert_response :success
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_select "meta[name='turbo-visit-control'][content='reload']"
    assert_select "form[action='#{settings_mcp_connection_authorization_path(connection)}'][data-turbo='false']"

    patch settings_mcp_connection_path(connection), params: { mcp_connection: { lock_version: 0, name: "" } }

    assert_response :unprocessable_entity
    assert_select "meta[name='turbo-visit-control'][content='reload']", count: 0
    assert_select "input[name='mcp_connection[name]'][value='']"
  end

  test "OAuth notices survive the Turbo fetch and are consumed by the document reload" do
    post settings_mcp_connections_path, params: { mcp_connection: {
      name: "OAuth service", endpoint_url: "https://oauth.example.test/mcp", auth_type: "oauth",
    } }
    assert_response :redirect
    location = response.location

    get location, headers: { "X-Turbo-Request-Id" => "oauth-connection-created" }
    assert_response :success
    assert_select ".alert-success", text: I18n.t("mcp_connections.saved")

    get location
    assert_response :success
    assert_select ".alert-success", text: I18n.t("mcp_connections.saved")

    get location
    assert_response :success
    assert_select ".alert-success", count: 0
  end

  test "disabling a connection preserves its catalog" do
    tools = @connection.tools_catalog
    patch settings_mcp_connection_path(@connection), params: { mcp_connection: { lock_version: 0, enabled: "0" } }
    assert_response :redirect
    assert_not @connection.reload.enabled?
    assert_equal tools, @connection.tools_catalog
  end

  test "a different Human cannot read the owner's settings" do
    sign_out
    sign_in_as users(:owner)
    get settings_mcp_connection_path(@connection)
    assert_response :not_found
  end
end
