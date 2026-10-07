require "test_helper"

class Admin::ModelProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    sign_in_as users(:owner)
  end

  test "the operator can browse the catalog and direct resource pages without making changes" do
    pages = {
      admin_model_providers_path => nil,
      admin_model_provider_path("test_api") => [admin_model_providers_path, "Model providers"],
      admin_model_provider_path("codex_subscription") => [admin_model_providers_path, "Model providers"],
      admin_model_provider_lane_path("test_api") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_api_key_path("test_api") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_model_visibility_path("test_api") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_definition_path("test_api") => [admin_model_provider_path("test_api"), "Test API"],
      new_admin_model_provider_model_definition_path("test_api") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_model_definition_path("test_api", model: "test_api/text") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_model_discovery_path("test_api") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_model_test_path("test_api", model: "test_api/text") => [admin_model_provider_path("test_api"), "Test API"],
      admin_model_provider_authorization_path("codex_subscription") => [admin_model_provider_path("codex_subscription"), "OpenAI Codex"],
    }
    assert_no_enqueued_jobs do
      assert_no_difference [-> { ModelProviderConfig.count }, -> { ModelProviderCredential.count }, -> { ModelProviderOAuthSession.count }] do
        pages.each do |path, back_link|
          get path
          assert_response :success
          assert_includes response.headers.fetch("Cache-Control"), "no-store"
          if back_link
            destination, label = back_link
            assert_select "main header nav[aria-label=?]", "Back" do
              assert_select "a", count: 1
              assert_select "a[href=?][data-turbo-frame=_top]", destination, text: label
            end
            assert_select "main a", text: "Provider overview", count: 0
            assert_select "main a", text: "Back to models", count: 0
          end
        end
      end
    end
    get admin_model_provider_path("not-in-the-catalog")
    assert_response :not_found
  end

  test "enabling and disabling a lane uses the displayed version and preserves credentials" do
    path = admin_model_provider_lane_path("test_api")
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "test_api", api_key: "test-only-secret")
    patch path, params: { lane: { enabled: "1", expected_lock_version: "" } }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_response :see_other
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    assert_predicate policy, :enabled?
    version = policy.lock_version
    patch path, params: { lane: { enabled: "false", expected_lock_version: version } }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_not_predicate policy.reload, :enabled?
    assert ModelProviderCredential.exists?(account: @account, provider_id: "test_api")

    patch path, params: { lane: { enabled: "1", expected_lock_version: version } }
    assert_response :conflict
    assert_select "[role=alert]"
    assert_select "input[name=?][value=?]", "lane[expected_lock_version]", policy.lock_version.to_s
    assert_not_predicate policy.reload, :enabled?
    refute_includes response.body, "test-only-secret"
  end

  test "malformed and omitted lane versions cannot become an absent-row command" do
    path = admin_model_provider_lane_path("test_api")
    ["not-a-version", "-1", "2147483648"].each do |version|
      patch path, params: { lane: { enabled: "1", expected_lock_version: version } }
      assert_response :bad_request
    end
    patch path, params: { lane: { enabled: "1" } }
    assert_response :bad_request
    assert_not ModelProviderConfig.exists?(account: @account, provider_id: "test_api")
  end

  test "overview controls refresh every shared version after each independent write" do
    overview = admin_model_provider_path("test_api")
    model = "test_api/text"
    get overview
    assert_response :success
    assert_select "button[aria-label=?][aria-pressed=true][disabled]", "Disable provider"
    assert_select "section[aria-label=?] button:not([disabled])", "Provider models", count: 2
    assert_select "form[action=?]", admin_model_provider_api_key_path("test_api")

    patch admin_model_provider_lane_path("test_api"), params: { lane: { enabled: "true", expected_lock_version: "" } }
    assert_redirected_to overview
    follow_redirect!
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    assert_select "button[aria-label=?][aria-pressed=true][disabled]", "Enable provider"
    versions = css_select("input[name='lane[expected_lock_version]'], input[name='model_visibility[expected_lock_version]']")
    assert_operator versions.length, :>, 2
    assert_equal [policy.lock_version.to_s], versions.map { |input| input["value"] }.uniq

    patch admin_model_provider_model_visibility_path("test_api"), params: {
      model_visibility: { model: model, visible: "false", expected_lock_version: policy.lock_version },
    }
    assert_redirected_to overview
    follow_redirect!
    assert_select "button[aria-label=?][aria-pressed=true][disabled]", "Hide #{model} from agents"
    versions = css_select("input[name='lane[expected_lock_version]'], input[name='model_visibility[expected_lock_version]']")
    assert_equal [policy.reload.lock_version.to_s], versions.map { |input| input["value"] }.uniq
    assert_select "meta[name=turbo-refresh-scroll][content=preserve]"
  end

  test "model rows keep their visibility separate from provider availability and credentials" do
    2.times do |iteration|
      ModelProviders::EnableLane.call(account: @account, provider_id: "test_api", expected_lock_version: nil) if iteration == 1
      get admin_model_provider_path("test_api")
      assert_response :success
      assert_select "button[aria-label=?][aria-pressed=true]", iteration.zero? ? "Disable provider" : "Enable provider"
      assert_select "section[aria-label=?]", "Provider models" do |sections|
        refute_match(/Provider disabled|Credentials needed|Sign-in required|Enable this provider/, sections.first.text)
        assert_select "button[aria-label=?][aria-pressed=true]", "Make test_api/text visible"
        assert_select "button[aria-label=?]:not([disabled])", "Hide test_api/text from agents"
      end
    end
  end

  test "ordinary members cannot view or mutate provider settings" do
    sign_out
    sign_in_as users(:member)
    [admin_model_providers_path, admin_model_provider_path("test_api"),
     admin_model_provider_lane_path("test_api"), admin_model_provider_api_key_path("test_api"),
     admin_model_provider_model_visibility_path("test_api"),
     admin_model_provider_authorization_path("codex_subscription"), admin_model_provider_path("codex_subscription")].each do |path|
      get path
      assert_response :forbidden
    end
    patch admin_model_provider_lane_path("test_api"), params: { lane: { enabled: "1", expected_lock_version: "" } }
    assert_response :forbidden
    assert_not ModelProviderConfig.exists?(account: @account, provider_id: "test_api")
  end
end
