require "test_helper"

class OAuth::ApplicationAuthorizationTest < ActionDispatch::IntegrationTest
  VERIFIER = "v" * 43
  CALLBACK = "http://127.0.0.1:7777/auth/callback".freeze
  CLAIMS = {
    client_id: OAuth::APPLICATION_CLIENT_ID,
    agent_identifier: "application-installation",
    agent_display_name: "Application",
    executor_display_name: "Application executor",
  }.freeze

  setup do
    sign_in_as users(:member)
  end

  test "native code consent retains same-origin request context without caching or cross-origin referrers" do
    get oauth_authorize_path, params: code_request(return_to: oauth_authorize_path)

    assert_response :success
    assert_equal "same-origin", response.headers["Referrer-Policy"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
    assert_select "meta[name='turbo-visit-control'][content='reload']"
    assert_select "form[action=?][data-turbo='false']", oauth_authorize_path
  end

  test "code login mints distinct Human Agent and Runner planes after consent" do
    code = approve_code(registration_identifier: "application-runner", runner_display_name: "Application runner")
    assert_no_difference -> { AccessToken.count } do
      exchange(code, code_verifier: "wrong" * 10)
    end
    assert_equal "invalid_grant", response.parsed_body.fetch("error")

    assert_difference -> { RefreshTokenFamily.count }, 3 do
      exchange(code)
    end
    assert_response :success
    credentials = response.parsed_body
    assert_equal "platform", credentials.fetch("plane")
    assert_equal "application", credentials.fetch("scope")
    assert_equal users(:member).public_id, credentials.dig("user", "public_id")
    assert_equal "member", credentials.dig("agent", "plane")
    assert_equal "executor_transport", credentials.dig("runner", "plane")
    agent = User.find_by!(public_id: credentials.fetch("agent_public_id"))
    assert_equal users(:member), agent.steward
    assert_equal "no-store", response.headers["Cache-Control"]

    get api_v1_profile_path, headers: bearer(credentials.fetch("access_token"))
    assert_response :success
    get "/api/v1/admin/model_providers", headers: bearer(credentials.fetch("access_token"))
    assert_response :forbidden
    get agent_api_v1_profile_path, headers: bearer(credentials.fetch("access_token"))
    assert_response :unauthorized

    assert_no_difference -> { AccessToken.count } do
      exchange(code)
    end
    assert_equal "invalid_grant", response.parsed_body.fetch("error")
  end

  test "registered callbacks PKCE and state are required before redirect or issuance" do
    [
      { redirect_uri: "https://elsewhere.example/callback" },
      { redirect_uri: "http://127.0.0.1:7777/auth/callback/extra" },
      { code_challenge_method: "plain" },
      { state: "" },
    ].each do |overrides|
      assert_no_difference -> { DeviceAuthorization.count } do
        get oauth_authorize_path, params: code_request(overrides)
      end
      assert_response :bad_request
      assert_nil response.headers["Location"]
    end
  end

  test "LAN HTTP callbacks require exact registration and the explicit deployment exception" do
    with_oauth_environment(
      "NEXUS_OAUTH_REDIRECT_URIS" => '["http://10.0.0.115:7777/auth/callback"]',
      "NEXUS_OAUTH_ALLOW_HTTP" => nil
    ) do
      get oauth_authorize_path, params: code_request(redirect_uri: "http://10.0.0.115:7777/auth/callback")
      assert_response :bad_request
      ENV["NEXUS_OAUTH_ALLOW_HTTP"] = "true"
      get oauth_authorize_path, params: code_request(redirect_uri: "http://10.0.0.115:7777/auth/callback")
      assert_response :success
    end
  end

  test "code exchange is bound to the client redirect and grant type" do
    code = approve_code
    [
      { redirect_uri: "http://localhost:7777/auth/callback" },
      { grant_type: OAuth::DEVICE_GRANT_TYPE, device_code: code },
    ].each do |overrides|
      assert_no_difference -> { AccessToken.count } do
        exchange(code, **overrides)
      end
      assert_equal "invalid_grant", response.parsed_body.fetch("error")
    end
    exchange(code)
    assert_response :success
  end

  test "routine login preserves the existing Agent credential epoch and credentials" do
    exchange(approve_code)
    original = response.parsed_body
    agent = User.find_by!(public_id: original.fetch("agent_public_id"))
    executor = agent.task_executors.sole
    epoch = executor.credential_epoch

    assert_difference -> { RefreshTokenFamily.count }, 1 do
      exchange(approve_code(connection_mode: "login"))
    end
    assert_response :success
    login = response.parsed_body
    assert_equal agent.public_id, login.fetch("agent_public_id")
    refute login.key?("agent")
    refute login.key?("runner")
    assert_equal epoch, executor.reload.credential_epoch
    assert AccessToken.authenticate_token(original.dig("agent", "access_token"))
    assert AccessToken.authenticate_executor_token(original.dig("agent", "executor_access_token"))
  end

  test "an instance already bound through the connector cannot authorize another Human" do
    assert_no_difference [-> { User.count }, -> { AccessToken.count }, -> { RefreshTokenFamily.count }] do
      post oauth_authorize_path, params: code_request(agent_identifier: users(:agent).agent_identifier)
    end
    assert_response :see_other
    query = URI.decode_www_form(URI(response.location).query).to_h
    assert_equal "access_denied", query.fetch("error")
    assert_equal "agent_already_bound", query.fetch("error_description")
    assert_equal users(:owner), users(:agent).reload.steward
  end

  test "Human role changes affect admin requests while personal settings stay available" do
    assert_equal :role_changed, users(:member).change_role(to: :admin)
    exchange(approve_code)
    credentials = response.parsed_body
    get "/api/v1/admin/model_providers", headers: bearer(credentials.fetch("access_token"))
    assert_response :success
    assert_equal :role_changed, users(:member).reload.change_role(to: :member)
    get api_v1_profile_path, headers: bearer(credentials.fetch("access_token"))
    assert_response :success
    get "/api/v1/admin/model_providers", headers: bearer(credentials.fetch("access_token"))
    assert_response :forbidden
  end

  test "a stale Human refresh revokes its successor without revoking the Agent" do
    exchange(approve_code)
    original = response.parsed_body
    refresh(original.fetch("refresh_token"))
    successor = response.parsed_body
    refresh(original.fetch("refresh_token"))
    assert_equal "invalid_grant", response.parsed_body.fetch("error")
    get api_v1_profile_path, headers: bearer(successor.fetch("access_token"))
    assert_response :unauthorized
    assert AccessToken.authenticate_token(original.dig("agent", "access_token"))
  end

  test "authorization codes and verifiers are filtered from request and redirect logs" do
    code = approve_code
    assert response.filtered_location.include?("code=[FILTERED]")
    exchange(code)
    assert_equal "[FILTERED]", request.filtered_parameters.fetch("code")
    assert_equal "[FILTERED]", request.filtered_parameters.fetch("code_verifier")
  end

  test "Human refresh rotates alone and family revocation fences all its credentials" do
    exchange(approve_code)
    original = response.parsed_body
    refresh(original.fetch("refresh_token"))
    assert_response :success
    rotated = response.parsed_body
    assert_equal "platform", rotated.fetch("plane")
    refute rotated.key?("agent")
    refute rotated.key?("runner")

    post oauth_revoke_path, params: { client_id: OAuth::APPLICATION_CLIENT_ID, token: rotated.fetch("refresh_token") }
    assert_response :success
    get api_v1_profile_path, headers: bearer(rotated.fetch("access_token"))
    assert_response :unauthorized
    refresh(rotated.fetch("refresh_token"))
    assert_equal "invalid_grant", response.parsed_body.fetch("error")
    assert AccessToken.authenticate_token(original.dig("agent", "access_token"))
  end

  test "steward transfer immediately fences the previous Human application session and refresh" do
    exchange(approve_code)
    credentials = response.parsed_body
    agent = User.find_by!(public_id: credentials.fetch("agent_public_id"))
    assert_equal :changed, agent.change_steward(to: users(:owner))

    get api_v1_profile_path, headers: bearer(credentials.fetch("access_token"))
    assert_response :unauthorized
    refresh(credentials.fetch("refresh_token"))
    assert_equal "invalid_grant", response.parsed_body.fetch("error")
  end

  test "identity recovery cannot revive a Human refresh" do
    exchange(approve_code)
    credentials = response.parsed_body
    identity = users(:member).identity
    identity.update!(credential_recovery_generation: identity.credential_recovery_generation + 1)
    get api_v1_profile_path, headers: bearer(credentials.fetch("access_token"))
    assert_response :unauthorized
    refresh(credentials.fetch("refresh_token"))
    assert_equal "invalid_grant", response.parsed_body.fetch("error")
  end

  test "Device Flow grants the same Human login and Agent bundle" do
    post oauth_device_authorization_path, params: CLAIMS
    issued = response.parsed_body
    post oauth_device_verification_path, params: { verification: { user_code: issued.fetch("user_code") } }
    grant = DeviceAuthorization.find_by_device_code(issued.fetch("device_code"))
    post oauth_device_grant_connection_path(grant)
    post oauth_token_path, params: {
      client_id: OAuth::APPLICATION_CLIENT_ID, grant_type: OAuth::DEVICE_GRANT_TYPE,
      device_code: issued.fetch("device_code"),
    }
    assert_response :success
    assert_equal "platform", response.parsed_body.fetch("plane")
    assert_equal "member", response.parsed_body.dig("agent", "plane")
  end

  test "runner-only application code login keeps the Runner transport separate" do
    claims = code_request.except(:agent_identifier, :agent_display_name, :executor_display_name)
      .merge(registration_identifier: "standalone-runner", runner_display_name: "Runner", expected_live_runner: "absent")
    post oauth_authorize_path, params: claims
    code = URI.decode_www_form(URI(response.location).query).to_h.fetch("code")
    exchange(code)
    assert_response :success
    credentials = response.parsed_body
    assert_equal "platform", credentials.fetch("plane")
    assert_equal "executor_transport", credentials.dig("runner", "plane")
    refute credentials.key?("agent")
    refute credentials.key?("agent_public_id")
  end

  test "first boot retains the authorization request without exposing the setup capability" do
    sign_out
    Account.destroy_all
    with_oauth_environment("NEXUS_SETUP_SECRET" => "synthetic-private-setup") do
      get oauth_authorize_path, params: code_request
      assert_response :redirect
      target = URI.decode_www_form(URI(response.location).query).to_h.fetch("return_to")
      assert target.start_with?(oauth_authorize_path)
      follow_redirect!
      assert_response :success
      refute_includes response.body, "synthetic-private-setup"
      assert_select "input[name=return_to][value=?]", target
      setup = {
        display_name: "Founder", email: "founder@example.test",
        password: "long-enough-password", password_confirmation: "long-enough-password",
      }
      assert_no_difference -> { Account.count } do
        post setup_path, params: { setup: setup, return_to: target }
      end
      assert_response :unprocessable_entity
      post setup_path, params: { setup: setup, return_to: target, setup_secret: "synthetic-private-setup" }
      assert_redirected_to target
      follow_redirect!
      assert_response :success
      assert_select "button", text: "Continue"
      post oauth_authorize_path, params: code_request
      code = URI.decode_www_form(URI(response.location).query).to_h.fetch("code")
      exchange(code)
      assert_response :success
      assert_equal Account.sole.owner.public_id, response.parsed_body.dig("user", "public_id")
    end
  end

  test "Device initiation before first boot returns a public setup URL and no capability" do
    sign_out
    Account.destroy_all
    with_oauth_environment("NEXUS_SETUP_SECRET" => "synthetic-private-setup") do
      post oauth_device_authorization_path, params: CLAIMS
      assert_response :conflict
      assert_equal "initialization_required", response.parsed_body.fetch("error")
      assert_equal setup_url, response.parsed_body.fetch("initialization_uri")
      refute_includes response.body, "synthetic-private-setup"
    end
  end

  private

    def code_request(overrides = {})
      CLAIMS.merge(
        response_type: "code", redirect_uri: CALLBACK, state: "browser-transaction",
        code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(VERIFIER), padding: false),
        code_challenge_method: "S256"
      ).merge(overrides)
    end

    def approve_code(**overrides)
      get oauth_authorize_path, params: code_request(overrides)
      assert_response :success
      post oauth_authorize_path, params: code_request(overrides)
      assert_response :see_other
      query = URI.decode_www_form(URI(response.location).query).to_h
      assert_equal "browser-transaction", query.fetch("state")
      query.fetch("code")
    end

    def exchange(code, **overrides)
      post oauth_token_path, params: {
        client_id: OAuth::APPLICATION_CLIENT_ID, grant_type: "authorization_code",
        code: code, code_verifier: VERIFIER, redirect_uri: CALLBACK,
      }.merge(overrides)
    end

    def refresh(token)
      post oauth_token_path, params: {
        client_id: OAuth::APPLICATION_CLIENT_ID, grant_type: "refresh_token", refresh_token: token,
      }
    end

    def bearer(token)
      { "Authorization" => "Bearer #{token}" }
    end

    def with_oauth_environment(values)
      previous = values.to_h { |key, _| [key, ENV[key]] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
end
