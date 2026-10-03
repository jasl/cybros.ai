require "test_helper"

# `scope` is accepted as an OAuth-library compatibility input, but it never
# participates in authorization. Credential authority comes only from the
# server-minted credential plane, and token responses expose no scope grant.
class OAuth::ScopeFreeProtocolTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:owner)
  end

  AGENT_REQUEST = {
    agent_identifier: "install-scope-free",
    agent_display_name: "Scope-free",
    executor_display_name: "App",
  }.freeze
  RUNNER_REQUEST = {
    runner_identifier: "install-scope-free-runner",
    runner_display_name: "Workshop laptop",
  }.freeze

  {
    "an agent connection" => AGENT_REQUEST,
    "a runner connection" => RUNNER_REQUEST,
  }.each do |description, base|
    test "#{description} accepts and ignores a scalar scope" do
      %w[api profile admin unknown].each do |value|
        assert_difference -> { DeviceAuthorization.count }, 1 do
          post oauth_device_authorization_path,
            params: base.merge(client_id: OAuth::DEVICE_CLIENT_ID, scope: value)
        end
        assert_response :success
      end
    end

    test "#{description} with an empty scope is treated as omitted" do
      post oauth_device_authorization_path,
        params: base.merge(client_id: OAuth::DEVICE_CLIENT_ID, scope: "")
      assert_response :success
    end
  end

  test "the token response carries no scope member on either branch" do
    post oauth_device_authorization_path,
      params: AGENT_REQUEST.merge(client_id: OAuth::DEVICE_CLIENT_ID)
    device_code = response.parsed_body.fetch("device_code")
    grant = DeviceAuthorization.find_by_device_code(device_code)
    DeviceAuthorizations::Connect.call(authorization: grant, connector: @owner)

    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::DEVICE_GRANT_TYPE,
      device_code: device_code,
    }

    assert_response :success
    body = response.parsed_body
    assert_not body.key?("scope")
    assert_equal "member", body["plane"], "the response names the plane it led with"
    assert body["access_token"].start_with?("sk-cybros-api-v1-")
    assert body["executor_access_token"].start_with?("sk-cybros-api-v1-")

    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::REFRESH_GRANT_TYPE,
      refresh_token: body["refresh_token"],
    }
    assert_response :success
    assert_not response.parsed_body.key?("scope")
  end

  test "a device_code poll accepts scope without granting or returning it" do
    post oauth_device_authorization_path,
      params: AGENT_REQUEST.merge(client_id: OAuth::DEVICE_CLIENT_ID)
    device_code = response.parsed_body.fetch("device_code")
    grant = DeviceAuthorization.find_by_device_code(device_code)
    DeviceAuthorizations::Connect.call(authorization: grant, connector: @owner)

    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::DEVICE_GRANT_TYPE,
      device_code: device_code,
      scope: "openid profile",
    }

    assert_response :success
    assert_equal "member", response.parsed_body["plane"]
    assert_not response.parsed_body.key?("scope")
  end

  test "a refresh request accepts scope without changing or returning authority" do
    post oauth_device_authorization_path,
      params: AGENT_REQUEST.merge(client_id: OAuth::DEVICE_CLIENT_ID)
    device_code = response.parsed_body.fetch("device_code")
    grant = DeviceAuthorization.find_by_device_code(device_code)
    DeviceAuthorizations::Connect.call(authorization: grant, connector: @owner)
    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::DEVICE_GRANT_TYPE,
      device_code: device_code,
    }
    refresh_secret = response.parsed_body.fetch("refresh_token")

    post oauth_token_path, params: {
      client_id: OAuth::DEVICE_CLIENT_ID,
      grant_type: OAuth::REFRESH_GRANT_TYPE,
      refresh_token: refresh_secret,
      scope: "openid profile",
    }

    assert_response :success
    assert_equal "member", response.parsed_body["plane"]
    assert_not response.parsed_body.key?("scope")
  end

  # Scope-free does not mean shape-free. An agent connection states which address it wants and
  # nothing else; omitting it is not a narrower grant, it is an incomplete request.
  test "an agent connection must name the address it wants, and asks for nothing else" do
    assert_no_difference -> { DeviceAuthorization.count } do
      post oauth_device_authorization_path, params: {
        client_id: OAuth::DEVICE_CLIENT_ID,
        agent_identifier: "install-identity-only",
        agent_display_name: "Identity only",
      }
    end

    assert_response :bad_request
    assert_equal "invalid_request", response.parsed_body["error"]
  end
end
