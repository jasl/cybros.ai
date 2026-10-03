require "test_helper"

class API::V1::SessionsTest < ActionDispatch::IntegrationTest
  test "api login reveals the bearer once and it authenticates subsequent requests" do
    post api_v1_session_path, params: { email: identities(:member).email, password: "password" }, as: :json

    assert_response :created
    body = response.parsed_body
    assert body["token"].start_with?("sk-cybros-session-v1-")
    assert_equal "Bearer", body["token_type"]
    assert_equal "api", body.dig("session", "kind")

    get api_v1_session_path, headers: bearer(body["token"])
    assert_response :success
    assert_equal body.dig("session", "public_id"), response.parsed_body.dig("session", "public_id")
  end

  test "invalid credentials and policy failures render their stable codes" do
    post api_v1_session_path, params: { email: identities(:member).email, password: "wrong" }, as: :json
    assert_response :unauthorized
    assert_equal "invalid_credentials", response.parsed_body.dig("error", "code")

    identities(:member).update!(password_change_required: true)
    post api_v1_session_path, params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :forbidden
    assert_equal "password_change_required", response.parsed_body.dig("error", "code")

    identities(:member).update!(password_change_required: false)
    MemberRecoveryAuthorizations::Issue.call(user: users(:member))
    post api_v1_session_path, params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :forbidden
    assert_equal "local_recovery_required", response.parsed_body.dig("error", "code")
  end

  test "credentials containing a null byte are rejected as invalid" do
    [
      { email: "#{identities(:member).email}\0", password: "password" },
      { email: identities(:member).email, password: "password\0" },
    ].each do |credentials|
      assert_no_difference -> { Session.count } do
        post api_v1_session_path, params: credentials, as: :json
      end

      assert_response :unauthorized
      assert_equal "invalid_credentials", response.parsed_body.dig("error", "code")
    end
  end

  test "api login fails fast for an unknown session-start outcome" do
    unexpected = Sessions::Start::Result.new(
      outcome: :unexpected,
      session: nil,
      secret: nil
    )

    Sessions::Start.stub(:call, unexpected) do
      error = assert_raises(ArgumentError) do
        post api_v1_session_path,
          params: { email: identities(:member).email, password: "password" },
          as: :json
      end

      assert_match ":unexpected", error.message
    end
  end

  test "the login rate limit renders the JSON envelope" do
    11.times { post api_v1_session_path, params: { email: "x@example.com", password: "wrong" }, as: :json }

    assert_response :too_many_requests
    assert_match(/\A[1-9]\d*\z/, response.headers["Retry-After"])
    assert_equal "rate_limited", response.parsed_body.dig("error", "code")
  end

  test "destroy revokes the presented bearer immediately" do
    post api_v1_session_path, params: { email: identities(:member).email, password: "password" }, as: :json
    token = response.parsed_body["token"]

    delete api_v1_session_path, headers: bearer(token)
    assert_response :success
    assert response.parsed_body["revoked"]

    get api_v1_session_path, headers: bearer(token)
    assert_response :unauthorized
  end

  test "unauthenticated requests get the stable unauthorized envelope" do
    get api_v1_profile_path
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    assert_equal 'Bearer realm="Nexus"', response.headers["WWW-Authenticate"]
  end

  private

    def bearer(token)
      { "Authorization" => "Bearer #{token}" }
    end
end
