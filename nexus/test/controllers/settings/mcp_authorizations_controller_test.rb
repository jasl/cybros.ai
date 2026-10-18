require "test_helper"

class Settings::McpAuthorizationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @connection = users(:member).mcp_connections.create!(name: "Research", endpoint_url: "https://research.example.test/mcp", auth_type: "oauth")
    sign_in_as users(:member)
  end

  test "the owner starts OAuth through a plain browser navigation" do
    start = ->(connection:, expected_lock_version:, redirect_uri:) do
      assert_equal @connection, connection
      assert_equal 0, expected_lock_version
      assert_equal callback_url, redirect_uri
      result(:saved, authorization_url: "https://research.example.test/authorize?state=fixture-state")
    end
    McpConnections::OAuth::Start.stub(:call, start) do
      post settings_mcp_connection_authorization_path(@connection), params: { command: { lock_version: 0 } }
    end
    assert_response :see_other
    assert_redirected_to "https://research.example.test/authorize?state=fixture-state"
    assert_equal "https://research.example.test/authorize?state=[FILTERED]", response.filtered_location
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "the callback forwards complete OAuth fields and excludes unrelated input" do
    fields = { "code" => "fixture-code", "state" => "fixture-state", "iss" => "https://research.example.test",
      "error" => "access_denied", "error_description" => "private-provider-detail" }
    finish = ->(connection:, callback_params:) do
      assert_equal @connection, connection
      assert_equal fields, callback_params
      result(:authorization_failed)
    end
    McpConnections::OAuth::Finish.stub(:call, finish) do
      get callback_url, params: fields.merge("redirect_uri" => "https://ignored.example.test")
    end
    assert_response :see_other
    assert_redirected_to settings_mcp_connection_path(@connection)
    assert_equal I18n.t("mcp_connections.errors.authorization_failed"), flash[:alert]
    assert_not_includes flash[:alert], "private-provider-detail"
    logged_fields = fields.merge("code" => "[FILTERED]", "state" => "[FILTERED]", "error_description" => "[FILTERED]")
    assert_equal logged_fields, request.filtered_parameters.slice(*fields.keys)
    assert_equal logged_fields, URI.decode_www_form(URI.parse(request.filtered_path).query).to_h.slice(*fields.keys)
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "the same owner can sign in again before finishing the callback" do
    sign_out
    sign_in_as users(:member)
    McpConnections::OAuth::Finish.stub(:call, result(:saved)) do
      get callback_url, params: { code: "fixture-code", state: "fixture-state" }
    end
    assert_response :see_other
    assert_redirected_to settings_mcp_connection_path(@connection)
    assert_equal I18n.t("mcp_connections.authorized"), flash[:notice]
  end

  test "a Platform bearer alone cannot redeem the browser callback" do
    sign_out
    token = create_access_token_fixture(user: users(:member), name: "Personal settings", plane: :platform)
    McpConnections::OAuth::Finish.stub(:call, ->(**) { flunk "Bearer authenticated the browser callback" }) do
      get callback_url, params: { code: "fixture-code", state: "fixture-state" }, headers: { "Authorization" => "Bearer #{token.secret}" }
    end
    assert_response :redirect
    assert_equal new_session_path, URI(response.location).path
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "another signed-in Human cannot redeem or start the owner's authorization" do
    sign_out
    sign_in_as users(:owner)
    McpConnections::OAuth::Start.stub(:call, ->(**) { flunk "another owner started authorization" }) do
      post settings_mcp_connection_authorization_path(@connection), params: { command: { lock_version: 0 } }
      assert_response :not_found
    end
    McpConnections::OAuth::Finish.stub(:call, ->(**) { flunk "another owner finished authorization" }) do
      get callback_url, params: { code: "fixture-code", state: "fixture-state" }
      assert_response :not_found
    end
  end

  private

    def callback_url = settings_mcp_connection_authorization_callback_url(@connection)

    def result(outcome, authorization_url: nil)
      McpConnections::OAuth::Result.new(outcome: outcome, connection: @connection,
        authorization_url: authorization_url, expires_at: nil, bearer_token: nil)
    end
end
