require "test_helper"

class API::V1::ProfilesTest < ActionDispatch::IntegrationTest
  test "a session principal introspects the acting member with a null credential plane" do
    post api_v1_session_path, params: { email: identities(:owner).email, password: "password" }, as: :json
    token = response.parsed_body["token"]

    get api_v1_profile_path, headers: { "Authorization" => "Bearer #{token}" }

    assert_response :success
    body = response.parsed_body
    assert_equal users(:owner).public_id, body.dig("member", "public_id")
    assert_equal "owner", body.dig("member", "role")
    assert_nil body["credential_plane"]
    assert_not body.key?("task_executor")
  end

  test "a platform-plane token reaches the platform family" do
    credential = create_access_token_fixture(user: users(:owner), name: "Ops", plane: :platform)

    freeze_time do
      assert_changes -> { credential.token.reload.last_used_at }, from: nil, to: Time.current do
        get api_v1_profile_path, headers: { "Authorization" => "Bearer #{credential.secret}" }
      end
    end

    assert_response :success
    assert_equal "platform", response.parsed_body["credential_plane"]
  end

  test "a member-plane token is an agent-family credential and never authenticates here" do
    credential = create_access_token_fixture(user: users(:member), name: "Agent")

    assert_no_changes -> { credential.token.reload.last_used_at } do
      get api_v1_profile_path, headers: { "Authorization" => "Bearer #{credential.secret}" }
    end
    assert_response :unauthorized
  end

  test "an explicit authorization failure never falls back to a browser cookie" do
    sign_in_as users(:owner)
    credential = create_access_token_fixture(user: users(:member), name: "Agent")

    get api_v1_profile_path, headers: { "Authorization" => "Bearer #{credential.secret}" }

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "a demoted admin's platform token loses platform reach immediately" do
    # The mint-frozen plane never outlives the live role — and the reverse promotion can never
    # upgrade an old member token, because the plane is frozen at mint.
    users(:member).change_role(to: :admin)
    credential = create_access_token_fixture(user: users(:member).reload, name: "Ops", plane: :platform)

    get api_v1_profile_path, headers: { "Authorization" => "Bearer #{credential.secret}" }
    assert_response :success

    users(:member).reload.change_role(to: :member)
    get api_v1_profile_path, headers: { "Authorization" => "Bearer #{credential.secret}" }
    assert_response :unauthorized
  end

  test "a forced-change identity's cookie reaches nothing on the platform family" do
    identities(:member).update!(password_change_required: true)
    sign_in_as users(:member)

    get api_v1_profile_path
    assert_response :unauthorized
  end

  test "a token principal asking for the current session gets not_found" do
    credential = create_access_token_fixture(user: users(:owner), name: "Ops", plane: :platform)

    get api_v1_session_path, headers: { "Authorization" => "Bearer #{credential.secret}" }
    assert_response :not_found
  end

  test "malformed JSON renders the stable bad_request envelope" do
    post api_v1_session_path, params: "{not json", headers: { "Content-Type" => "application/json" }
    assert_response :bad_request
    assert_equal "bad_request", response.parsed_body.dig("error", "code")
  end

  test "the browser cookie reaches reads but never mutations" do
    sign_in_as users(:member)

    get api_v1_profile_path
    assert_response :success

    delete api_v1_session_path
    assert_response :unauthorized
  end
end
