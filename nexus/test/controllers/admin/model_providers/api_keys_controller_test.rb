require "test_helper"

class Admin::ModelProviders::APIKeysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @path = admin_model_provider_api_key_path("test_api")
    sign_in_as users(:owner)
  end

  test "keys install and rotate with availability enabled without rendering the secret" do
    patch @path, params: { credential: { api_key: "first-private-key" } }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_response :see_other
    credential = ModelProviderCredential.find_by!(account: @account, provider_id: "test_api")
    assert_equal "first-private-key", credential.secret
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    assert_predicate policy, :enabled?
    follow_redirect!
    assert_response :success
    refute_includes response.body, "first-private-key"
    assert_select "input[type=password][name=?]", "credential[api_key]"
    assert_select "section[aria-label='API key']", count: 1 do
      assert_select "h2", text: "API key saved"
      assert_select "button", text: "Update", count: 1
      assert_select "button", text: "Remove", count: 1
    end

    ModelProviders::DisableLane.call(account: @account, provider_id: "test_api", expected_lock_version: policy.lock_version)

    patch @path, params: { credential: { api_key: "second-private-key" } }
    assert_redirected_to admin_model_provider_path("test_api")
    assert_equal "second-private-key", credential.reload.secret
    assert_predicate policy.reload, :enabled?
    delete @path
    assert_redirected_to admin_model_provider_path("test_api")
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: "test_api")
    assert_predicate policy.reload, :enabled?
    delete @path
    assert_redirected_to admin_model_provider_path("test_api")
  end

  test "blank keys render their own page and never replace existing material" do
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "test_api", api_key: "existing-private-key")
    patch @path, params: { credential: { api_key: " " } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]"
    assert_select "form[action=?]", @path
    refute_includes response.body, "existing-private-key"
    assert_equal "existing-private-key", ModelProviderCredential.find_by!(account: @account, provider_id: "test_api").secret
    assert_not ModelProviderConfig.exists?(account: @account, provider_id: "test_api")
  end

  test "key forms cannot install a key into an OAuth or credentialless lane" do
    %w[codex_subscription dev].each do |provider_id|
      path = admin_model_provider_api_key_path(provider_id)
      get path
      assert_response :not_found
      patch path, params: { credential: { api_key: "wrong-material" } }
      assert_response :not_found
      assert_not ModelProviderCredential.exists?(account: @account, provider_id: provider_id)
    end
  end

  test "ordinary members cannot install or delete credentials" do
    sign_out
    sign_in_as users(:member)
    patch @path, params: { credential: { api_key: "not-allowed" } }
    assert_response :forbidden
    delete @path
    assert_response :forbidden
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: "test_api")
  end
end
