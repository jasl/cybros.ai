require "test_helper"

class OAuth::TerminalLoginTest < ActionDispatch::IntegrationTest
  test "browser approval in SSO-only mode issues one separately revocable API session" do
    sign_in_as users(:owner)
    accounts(:cybros).update!(sso_only: true)
    grant = start_terminal
    verify(grant)
    assert_select "p", text: /This terminal will sign in as/
    assert_no_difference ["Executor.count", "User.count", "RefreshTokenFamily.count", "AccessToken.count"] do
      post oauth_device_grant_connection_path(@grant_public_id)
      assert_difference -> { Session.where(kind: :api).count }, 1 do
        poll(grant)
        assert_response :success
      end
    end
    token = response.parsed_body.fetch("access_token")
    assert_equal ["access_token", "expires_in", "session", "token_type"], response.parsed_body.keys.sort
    assert_equal "api", response.parsed_body.fetch("session").fetch("kind")
    assert_equal Session::LIFETIME.to_i, response.parsed_body.fetch("expires_in")
    poll(grant)
    assert_equal "invalid_grant", response.parsed_body.fetch("error")

    machine = open_session
    headers = { "Authorization" => "Bearer #{token}" }
    machine.get "/api/v1/session", headers: headers
    assert_equal 200, machine.response.status
    machine.delete "/api/v1/session", headers: headers
    assert_equal 200, machine.response.status
    machine.get "/api/v1/session", headers: headers
    assert_equal 401, machine.response.status
    get oauth_device_path
    assert_response :success
  end

  test "a pending or canceled terminal authorization gives no session" do
    grant = start_terminal
    assert_no_difference -> { Session.where(kind: :api).count } do
      poll(grant)
      assert_equal "authorization_pending", response.parsed_body.fetch("error")
      post oauth_device_authorization_cancellation_path, params: { client_id: OAuth::TERMINAL_CLIENT_ID, device_code: grant.fetch("device_code") }
      assert_response :success
      poll(grant)
      assert_equal "access_denied", response.parsed_body.fetch("error")
    end
  end

  test "terminal rejects machine claims, scopes and refresh grants" do
    assert_no_difference -> { DeviceAuthorization.count } do
      post oauth_device_authorization_path, params: { client_id: OAuth::TERMINAL_CLIENT_ID, registration_identifier: "mine" }
      assert_equal "invalid_request", response.parsed_body.fetch("error")
      post oauth_device_authorization_path, params: { client_id: OAuth::TERMINAL_CLIENT_ID, scope: "application" }
      assert_equal "invalid_scope", response.parsed_body.fetch("error")
    end
    post oauth_token_path, params: { client_id: OAuth::TERMINAL_CLIENT_ID, grant_type: "refresh_token" }
    assert_equal "unsupported_grant_type", response.parsed_body.fetch("error")
  end

  test "recovery after approval fences the terminal grant" do
    owner = users(:owner)
    sign_in_as owner
    grant = start_terminal
    verify(grant)
    post oauth_device_grant_connection_path(@grant_public_id)
    owner.identity.increment!(:credential_recovery_generation)
    assert_no_difference -> { Session.where(kind: :api).count } do
      poll(grant)
      assert_equal "access_denied", response.parsed_body.fetch("error")
    end
  end

  private

    def start_terminal
      post oauth_device_authorization_path, params: { client_id: OAuth::TERMINAL_CLIENT_ID }
      assert_response :success
      response.parsed_body
    end

    def verify(grant)
      post oauth_device_verification_path, params: { verification: { user_code: grant.fetch("user_code") } }
      @grant_public_id = response.location.split("/").last
      follow_redirect!
      assert_response :success
    end

    def poll(grant)
      post oauth_token_path, params: {
        client_id: OAuth::TERMINAL_CLIENT_ID, grant_type: OAuth::DEVICE_GRANT_TYPE,
        device_code: grant.fetch("device_code"),
      }
    end
end
