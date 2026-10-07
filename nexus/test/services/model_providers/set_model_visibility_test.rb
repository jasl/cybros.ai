require "test_helper"

class ModelProviders::SetModelVisibilityTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "the first hidden choice creates a disabled policy without changing models or credentials" do
    before = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, "test_api")

    result = change(false)

    assert_equal :applied, result.outcome
    policy = result.policy
    assert_equal 0, policy.lock_version
    refute_predicate policy, :enabled?
    assert_nil policy.provider_definition
    assert_empty policy.override_entries
    assert_equal ["test_api/text"], policy.model_overrides.fetch("hidden_models")
    refute ModelProviderCredential.exists?(account: @account, provider_id: "test_api")
    after = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, "test_api")
    assert_equal before.models, after.models
    assert_equal before.providers, after.providers

    assert_equal :noop, change(false, version: policy.lock_version).outcome
    assert_equal 0, policy.reload.lock_version
    assert_equal :stale, change(true).outcome
    assert_equal ["test_api/text"], policy.reload.model_overrides.fetch("hidden_models")
  end

  test "the first visible choice creates a disabled empty policy and preserves any credential" do
    credential = ModelProviders::SetAPIKey.call(account: @account, provider_id: "test_api", api_key: "synthetic-visibility-key").credential
    before = credential.attributes

    result = change(true)

    assert_equal :applied, result.outcome
    assert_equal 0, result.policy.lock_version
    refute_predicate result.policy, :enabled?
    assert_nil result.policy.provider_definition
    assert_equal ModelProviderConfig.empty_overrides, result.policy.model_overrides
    assert_equal before, credential.reload.attributes
  end

  test "a non-null initial version or invalid model ref cannot create a policy" do
    assert_no_difference "ModelProviderConfig.count" do
      assert_equal :stale, change(false, version: 0).outcome
      assert_equal :stale, change(true, version: 0).outcome
      assert_equal :invalid, change(false, ref: "another/text").outcome
    end
  end

  private

    def change(visible, version: nil, ref: "test_api/text")
      ModelProviders::SetModelVisibility.call(account: @account, provider_id: "test_api", model_ref: ref,
        visible: visible, expected_lock_version: version)
    end
end
