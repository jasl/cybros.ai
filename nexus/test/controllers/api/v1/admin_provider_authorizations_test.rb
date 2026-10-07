require "test_helper"

class API::V1::AdminProviderAuthorizationsTest < ActionDispatch::IntegrationTest
  PATH = "/api/v1/admin/model_providers/codex_subscription/authorization"
  AUTH = ModelProviders::CodexAuthorization

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @token = create_access_token_fixture(user: @owner, name: "Authorization operator", plane: :platform)
    @policy = ModelProviders::EnableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID,
      expected_lock_version: nil).policy
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  test "current reads missing state without starting authorization or queue work" do
    assert_no_enqueued_jobs do
      assert_no_difference -> { ModelProviderOAuthSession.count } do
        get PATH, headers: auth
      end
    end
    assert_response :success
    assert_equal({ "provider_id" => AUTH::PROVIDER_ID, "state" => "missing", "expires_at" => nil, "session" => nil },
      response.parsed_body.fetch("authorization"))
  end

  test "an API Session starts resumes and explicitly replaces a device ceremony" do
    post "/api/v1/session", params: { email: identities(:owner).email, password: "password" }, as: :json
    assert_response :created
    headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
    assert_enqueued_with(job: ModelProviderOAuthSessions::AdvanceJob) do
      post PATH, params: { command: { restart: false, provider_url: "https://ignored.test" } }, as: :json, headers: headers
    end
    assert_response :accepted
    first = response.parsed_body.fetch("authorization_session")
    assert_equal "pending", first.fetch("state")
    assert first.fetch("owned_by_current_user")
    assert_nil first.fetch("user_code")
    exact = response.location
    assert_equal "#{PATH}/sessions/#{first.fetch("public_id")}", URI(exact).path

    assert_no_difference -> { ModelProviderOAuthSession.count } do
      post PATH, params: { command: { restart: false } }, as: :json, headers: headers
    end
    assert_response :accepted
    assert_equal first, response.parsed_body.fetch("authorization_session")

    post PATH, params: { command: { restart: true } }, as: :json, headers: headers
    assert_response :accepted
    refute_equal first.fetch("public_id"), response.parsed_body.dig("authorization_session", "public_id")
    assert_no_enqueued_jobs do
      get exact, headers: headers
    end
    assert_response :success
    assert_equal "superseded", response.parsed_body.dig("authorization_session", "outcome")
  end

  test "omitted and cast false restart values resume the current session" do
    first = start_session
    [{}, { restart: false }, { restart: "false" }].each do |command|
      assert_no_difference -> { ModelProviderOAuthSession.count } do
        post PATH, params: { command: command }, as: :json, headers: auth
      end
      assert_response :accepted
      assert_equal first.public_id, response.parsed_body.dig("authorization_session", "public_id")
    end
  end

  test "only the issuing Human can read the live user code and another issuer must explicitly restart" do
    session = start_session
    session.update!(user_code: "VISIBLE-CODE", device_auth_id: "private-device-handle",
      verification_uri: AUTH.verification_url)
    get PATH, headers: auth
    assert_response :success
    assert_equal "VISIBLE-CODE", response.parsed_body.dig("authorization", "session", "user_code")
    refute_includes response.body, "private-device-handle"

    users(:member).update!(role: "admin")
    other = create_access_token_fixture(user: users(:member), name: "Other operator", plane: :platform)
    headers = { "Authorization" => "Bearer #{other.secret}" }
    get PATH, headers: headers
    assert_response :success
    refute response.parsed_body.dig("authorization", "session", "owned_by_current_user")
    assert_nil response.parsed_body.dig("authorization", "session", "user_code")
    assert_nil response.parsed_body.dig("authorization", "session", "verification_uri")

    assert_no_difference -> { ModelProviderOAuthSession.count } do
      post PATH, params: { command: { restart: false } }, as: :json, headers: headers
    end
    assert_response :conflict
    assert_equal "authorization_in_progress", response.parsed_body.dig("error", "code")
    assert_predicate session.reload, :pending?
    post PATH, params: { command: { restart: true } }, as: :json, headers: headers
    assert_response :accepted
    assert_predicate session.reload, :revoked?
  end

  test "clear removes local credentials and closes pending work without disabling the lane" do
    session = start_session
    ModelProviderCredential.create!(account: @account, provider_id: AUTH::PROVIDER_ID, material_kind: "oauth_tokens",
      secret: "private-access", refresh_secret: "private-refresh", authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: 4.hours.from_now)
    assert_no_enqueued_jobs do
      delete PATH, headers: auth
    end
    assert_response :success
    assert_equal "missing", response.parsed_body.dig("authorization", "state")
    assert_equal "operator_revoked", response.parsed_body.dig("authorization", "session", "outcome")
    assert_nil session.reload.user_code
    assert_predicate @policy.reload, :enabled?
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: AUTH::PROVIDER_ID)
    delete PATH, headers: auth
    assert_response :success
    refute_includes response.body, "private-access"
    refute_includes response.body, "private-refresh"
  end

  test "disabled providers accept connection while unsupported and unknown providers refuse" do
    ModelProviders::DisableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID,
      expected_lock_version: @policy.lock_version)
    post PATH, params: { command: { restart: false } }, as: :json, headers: auth
    assert_response :accepted
    refute_predicate @policy.reload, :enabled?
    [[PATH.sub("codex_subscription", "openrouter"), :conflict, "authorization_not_supported"],
     [PATH.sub("codex_subscription", "unknown"), :not_found, "not_found"]].each do |path, status, code|
      assert_no_enqueued_jobs do
        assert_no_difference -> { ModelProviderOAuthSession.count } do
          post path, params: { command: { restart: false } }, as: :json, headers: auth
        end
      end
      assert_response status
      assert_equal code, response.parsed_body.dig("error", "code")
    end
    get "#{PATH}/sessions/#{SecureRandom.uuid_v7}", headers: auth
    assert_response :not_found
    get "#{PATH.sub("codex_subscription", "openrouter")}/sessions/#{start_session_after_enable.public_id}", headers: auth
    assert_response :not_found
  end

  test "ordinary Human and Agent credentials cannot manage provider authorization" do
    post "/api/v1/session", params: { email: identities(:member).email, password: "password" }, as: :json
    assert_response :created
    member_headers = { "Authorization" => "Bearer #{response.parsed_body.fetch("token")}" }
    agent = connect_agent_session(steward: @owner, agent_identifier: "authorization-denied")
    [[member_headers, :forbidden], [{ "Authorization" => "Bearer #{agent.access_secret}" }, :unauthorized],
     [{}, :unauthorized]].each do |headers, status|
      get PATH, headers: headers
      assert_response status
      post PATH, params: { command: { restart: false } }, as: :json, headers: headers
      assert_response status
      delete PATH, headers: headers
      assert_response status
    end
  end

  test "cost unit reads null before configuration and the configured value afterwards" do
    get "/api/v1/admin/account/cost_unit", headers: auth
    assert_response :success
    assert_nil response.parsed_body.fetch("account").fetch("cost_unit")
    put "/api/v1/admin/account/cost_unit", params: { account: { cost_unit: "USD" } }, as: :json, headers: auth
    assert_response :success
    get "/api/v1/admin/account/cost_unit", headers: auth
    assert_response :success
    assert_equal "USD", response.parsed_body.dig("account", "cost_unit")
  end

  private

    def start_session
      AUTH::AcceptSession.call(account: @account, issuing_user: @owner, kind: "device_start").session
    end

    def start_session_after_enable
      ModelProviders::EnableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID,
        expected_lock_version: @policy.reload.lock_version)
      start_session
    end
end
