require "test_helper"

class Admin::ModelProviders::AuthorizationsControllerTest < ActionDispatch::IntegrationTest
  AUTH = ModelProviders::CodexAuthorization

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @path = admin_model_provider_authorization_path(AUTH::PROVIDER_ID)
    @policy = ModelProviders::EnableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID, expected_lock_version: nil).policy
    sign_in_as @owner
  end

  test "starting resumes the same ceremony and redirects to its exact read-only resource" do
    assert_enqueued_with(job: ModelProviderOAuthSessions::AdvanceJob) do
      post @path, params: { authorization: { restart: "false" } }
    end
    first = ModelProviderOAuthSession.sole
    exact = admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, first.public_id)
    assert_redirected_to exact
    assert_response :see_other
    assert_no_enqueued_jobs do
      get exact
      assert_response :success
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
    end
    assert_no_difference -> { ModelProviderOAuthSession.count } do
      post @path, params: { authorization: { restart: "0" } }
    end
    assert_redirected_to exact
    post @path, params: { authorization: { restart: "true" } }
    assert_response :see_other
    assert_predicate first.reload, :revoked?
    assert_equal "superseded", first.outcome
    refute_equal URI(response.location).path, exact
    assert_no_enqueued_jobs do
      get exact
      assert_response :success
    end
  end

  test "only the issuing Human sees the active device code" do
    session = start_session
    session.update!(user_code: "TEST-CODE-ONLY", device_auth_id: "private-device-handle",
      verification_uri: AUTH.verification_url)
    exact = admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, session.public_id)
    assert_no_enqueued_jobs do
      get exact
    end
    assert_response :success
    assert_includes response.body, "TEST-CODE-ONLY"
    refute_includes response.body, "private-device-handle"

    other = users(:member)
    other.update!(role: "admin")
    sign_out
    sign_in_as other
    get exact
    assert_response :success
    refute_includes response.body, "TEST-CODE-ONLY"
    refute_includes response.body, AUTH.verification_url
    assert_select "section[aria-label=Subscription] form[data-turbo-confirm]" do
      assert_select "button", text: "Connect"
      assert_select "input[name=?][value=true]", "authorization[restart]"
    end
    assert_no_enqueued_jobs do
      assert_no_difference -> { ModelProviderOAuthSession.count } do
        post @path, params: { authorization: { restart: "false" } }
      end
    end
    assert_response :conflict
    assert_select "[role=alert]"
    assert_predicate session.reload, :pending?
    post @path, params: { authorization: { restart: "true" } }
    assert_response :see_other
    assert_predicate session.reload, :revoked?
  end

  test "polling an exact ceremony does not report its route parameters as unpermitted" do
    session = start_session
    exact = admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, session.public_id)
    unpermitted = []
    subscriber = ->(*, payload) { unpermitted.concat(payload.fetch(:keys)) }

    ActionController::Parameters.stub(:action_on_unpermitted_parameters, :log) do
      ActiveSupport::Notifications.subscribed(subscriber, "unpermitted_parameters.action_controller") do
        get exact
      end
    end

    assert_response :success
    assert_empty unpermitted
  end

  test "overview starts authorization inside one frame and follows its exact resource" do
    get admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_response :success
    assert_select "turbo-frame#provider_authorization", count: 1 do
      assert_select "form[action=?]:not([data-turbo-frame])", @path do
        assert_select "button", text: "Connect"
      end
    end
    post @path, params: { authorization: { restart: "false" } }, headers: { "Turbo-Frame" => "provider_authorization" }
    session = ModelProviderOAuthSession.sole
    exact = admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, session.public_id)
    assert_redirected_to exact
    get exact, headers: { "Turbo-Frame" => "provider_authorization" }
    assert_response :success
    assert_select "turbo-frame#provider_authorization", count: 1
    assert_select "[data-provider-authorization-url-value=?]", exact
    assert_select "turbo-stream[action=refresh]", count: 0
    assert_select "section[aria-label=Subscription]", count: 1 do
      assert_select "h2", text: "No subscription connected"
      assert_select "[data-provider-authorization-url-value=?]", exact
      assert_select "button", text: "Connect", count: 1
      assert_select "input[name=?][value=false]", "authorization[restart]"
      assert_select "button", text: "Disconnect", count: 0
      assert_select "h2", text: "Sign-in status", count: 0
    end
    assert_select "a[href=?][data-turbo-frame=_top]", root_path, text: "Back to dashboard"
    assert_select "a", text: "Continue setup", count: 0
  end

  test "a competing issuer frame refusal remains visible without starting a ceremony" do
    AUTH::AcceptSession.call(account: @account, issuing_user: users(:member), kind: "device_start")
    assert_no_difference -> { ModelProviderOAuthSession.count } do
      post @path, params: { authorization: { restart: "false" } }, headers: { "Turbo-Frame" => "provider_authorization" }
    end
    assert_response :conflict
    assert_select "turbo-frame#provider_authorization [role=alert]", count: 1
  end

  test "only the current completed ceremony refreshes the containing provider page" do
    session = start_session
    session.terminalize(state: "completed", outcome: "authorized")
    ModelProviderCredential.create!(account: @account, provider_id: AUTH::PROVIDER_ID, material_kind: "oauth_tokens",
      secret: "private-access", refresh_secret: "private-refresh", authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: 4.hours.from_now)
    exact = admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, session.public_id)
    get exact, headers: { "Turbo-Frame" => "provider_authorization", "X-Turbo-Request-Id" => "completed-frame-request" }
    assert_response :success
    assert_select "turbo-frame#provider_authorization turbo-stream[action=refresh]", count: 1
    assert_select "turbo-stream[action=refresh][request-id]", count: 0
    assert_select "h2", text: "Sign-in status", count: 0
    assert_select "a", text: "Manage models", count: 0
    assert_select "section[aria-label=Subscription]", count: 1 do
      assert_select "button", text: "Disconnect", count: 1
      assert_select "button", text: "Connect", count: 0
      assert_select "button", text: "Start over", count: 0
    end

    [exact, admin_model_provider_path(AUTH::PROVIDER_ID)].each do |path|
      get path
      assert_response :success
      assert_select "turbo-stream[action=refresh]", count: 0
      assert_select "h2", text: "Subscription connected", count: 1
      assert_select "h2", text: "Sign-in status", count: 0
      assert_select "a", text: "Manage models", count: path == exact ? 1 : 0
    end

    get @path
    assert_select "h2", text: "Sign-in status", count: 0
    assert_select "a[href=?]", admin_model_provider_path(AUTH::PROVIDER_ID, anchor: "provider-models"), text: "Manage models"

    AUTH::AcceptSession.call(account: @account, issuing_user: @owner, kind: "device_start", restart: true)
    get exact, headers: { "Turbo-Frame" => "provider_authorization" }
    assert_response :success
    assert_select "turbo-stream[action=refresh]", count: 0
    assert_select "h2", text: "Sign-in status", count: 0
    assert_select "p", text: "This sign-in finished. The current subscription status is shown above."
    assert_predicate session.reload, :completed?
  end

  test "failed and expired sign-ins keep their feedback even while a subscription remains connected" do
    ModelProviderCredential.create!(account: @account, provider_id: AUTH::PROVIDER_ID, material_kind: "oauth_tokens",
      secret: "private-access", refresh_secret: "private-refresh", authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: 4.hours.from_now)
    { "failed" => "Sign-in did not complete.",
      "expired" => "This sign-in expired." }.each do |state, description|
      session = start_session
      session.terminalize(state: state, outcome: "test-#{state}")
      get admin_model_provider_path(AUTH::PROVIDER_ID)
      assert_response :success
      assert_select "h2", text: "Subscription connected"
      assert_select "h2", text: "Sign-in status", count: 0
      assert_select "p", text: description
      assert_select "section[aria-label=Subscription]" do
        assert_select "button", text: "Disconnect", count: 1
        assert_select "button", text: "Connect", count: 0
        assert_select "button", text: "Start over", count: 0
      end
    end
  end

  test "disconnect keeps only Connect even when the latest sign-in completed" do
    session = start_session
    session.terminalize(state: "completed", outcome: "authorized")
    ModelProviderCredential.create!(account: @account, provider_id: AUTH::PROVIDER_ID, material_kind: "oauth_tokens",
      secret: "private-access", refresh_secret: "private-refresh", authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: 4.hours.from_now)

    delete @path
    follow_redirect!

    assert_response :success
    assert_select "section[aria-label=Subscription]", count: 1 do
      assert_select "h2", text: "No subscription connected"
      assert_select "button", text: "Connect", count: 1
      assert_select "button", text: "Disconnect", count: 0
    end
    assert_select "p", text: /This sign-in finished/, count: 0
    assert_select "turbo-stream[action=refresh]", count: 0
    assert_predicate session.reload, :completed?
  end

  test "clear removes local OAuth credentials and pending work without disabling the lane" do
    session = start_session
    ModelProviderCredential.create!(account: @account, provider_id: AUTH::PROVIDER_ID, material_kind: "oauth_tokens",
      secret: "private-access", refresh_secret: "private-refresh", authorization_lineage_id: SecureRandom.uuid_v7,
      expires_at: 4.hours.from_now)
    assert_no_enqueued_jobs do
      delete @path
    end
    assert_redirected_to admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: AUTH::PROVIDER_ID)
    assert_equal "operator_revoked", session.reload.outcome
    assert_predicate @policy.reload, :enabled?
    follow_redirect!
    assert_response :success
    refute_includes response.body, "private-access"
    refute_includes response.body, "private-refresh"
  end

  test "disabled lanes accept connection while unsupported and unknown lanes refuse" do
    ModelProviders::DisableLane.call(account: @account, provider_id: AUTH::PROVIDER_ID, expected_lock_version: @policy.lock_version)
    get admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_select "button:not([disabled])", text: "Connect"
    post @path, params: { authorization: { restart: "false" } }
    assert_response :see_other
    refute_predicate @policy.reload, :enabled?
    assert_no_enqueued_jobs do
      assert_no_difference -> { ModelProviderOAuthSession.count } do
        %w[deepseek unknown].each do |id|
          post admin_model_provider_authorization_path(id), params: { authorization: { restart: "false" } }
          assert_response :not_found
        end
      end
    end
    get admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, SecureRandom.uuid_v7)
    assert_response :not_found
  end

  test "ordinary members cannot start clear or read an exact ceremony" do
    session = start_session
    sign_out
    sign_in_as users(:member)
    get admin_model_provider_authorization_session_path(AUTH::PROVIDER_ID, session.public_id)
    assert_response :forbidden
    post @path, params: { authorization: { restart: "true" } }
    assert_response :forbidden
    delete @path
    assert_response :forbidden
    assert_predicate session.reload, :pending?
  end

  private

    def start_session
      AUTH::AcceptSession.call(account: @account, issuing_user: @owner, kind: "device_start").session
    end
end
