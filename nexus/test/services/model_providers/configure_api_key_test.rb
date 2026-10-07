require "test_helper"

class ModelProviders::ConfigureAPIKeyTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @policy = ModelProviderConfig.create!(account: @account, provider_id: "openai_api",
      model_overrides: ModelProviderConfig.empty_overrides.merge("hidden_models" => ["openai_api/gpt-5"]))
  end

  test "saving enables availability while preserving the provider overlay" do
    before = @policy.model_overrides
    result = ModelProviders::ConfigureAPIKey.call(account: @account, provider_id: "openai_api", api_key: "test-key")

    assert_predicate result, :done?
    assert_predicate @policy.reload, :enabled?
    assert_equal before, @policy.model_overrides
  end

  test "blank and conflicting material never enable a disabled provider" do
    version = @policy.lock_version
    result = ModelProviders::ConfigureAPIKey.call(account: @account, provider_id: "openai_api", api_key: " ")
    assert_equal :invalid, result.outcome
    refute_predicate @policy.reload, :enabled?

    ModelProviders::InstallOAuthPair.call(account: @account, provider_id: "openai_api",
      access_token: "test-access", refresh_token: "test-refresh", lineage_id: SecureRandom.uuid_v7,
      expected_generation: nil, expires_at: 1.hour.from_now)
    result = ModelProviders::ConfigureAPIKey.call(account: @account, provider_id: "openai_api", api_key: "wrong-kind")

    assert_equal :material_kind_conflict, result.outcome
    refute_predicate @policy.reload, :enabled?
    assert_equal version, @policy.lock_version
    assert_equal "test-access", ModelProviderCredential.find_by!(account: @account, provider_id: "openai_api").secret
  end

  test "refused enablement leaves the credential untouched" do
    @policy.update_columns(model_overrides: {})
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "existing-key")

    result = ModelProviders::ConfigureAPIKey.call(account: @account, provider_id: "openai_api", api_key: "replacement-key")

    assert_equal :invalid, result.outcome
    refute_predicate @policy.reload, :enabled?
    assert_equal "existing-key", ModelProviderCredential.find_by!(account: @account, provider_id: "openai_api").secret
  end
end
