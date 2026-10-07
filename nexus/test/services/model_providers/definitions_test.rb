require "test_helper"

class ModelProviders::DefinitionsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @definition = { "base_url" => "http://127.0.0.1:11434/v1", "api_format" => "openai_compatible_chat", "credentials" => "none" }
  end

  test "custom definitions are retained disabled until explicitly enabled and support versioned reset" do
    result = set_definition("local", @definition)
    assert_predicate result, :done?
    policy = result.policy
    refute policy.enabled?
    catalog = ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current)
    assert_equal @definition.fetch("base_url"), catalog.providers.dig("local", "base_url")
    assert_equal 2, catalog.providers.dig("local", "concurrency_limit")

    assert_predicate ModelProviders::EnableLane.call(account: @account, provider_id: "local", expected_lock_version: policy.lock_version), :done?
    result = ModelProviders::ResetDefinition.call(account: @account, provider_id: "local", expected_lock_version: policy.reload.lock_version)
    assert_predicate result, :done?
    assert_nil policy.reload.provider_definition
    refute policy.enabled?
    refute ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current).providers.key?("local")
  end

  test "resetting a preset restores its file endpoint while preserving the anchor and credentials" do
    original = ModelCatalog.current.providers.fetch("openai_api")
    result = set_definition("openai_api", original.merge("base_url" => "http://localhost:11434"))
    assert_predicate result, :done?
    policy = result.policy
    ModelProviders::SetAPIKey.call(account: @account, provider_id: "openai_api", api_key: "test-only-secret")
    result = ModelProviders::ResetDefinition.call(account: @account, provider_id: "openai_api", expected_lock_version: policy.lock_version)
    assert_predicate result, :done?
    assert_equal original, ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current).providers.fetch("openai_api")
    assert ModelProviderCredential.exists?(account: @account, provider_id: "openai_api")
    assert ModelProviderConfig.exists?(id: policy.id)
  end

  test "provider validation and reader both evaluate model replacements under the new protocol" do
    snapshot = ModelCatalog.current.with(
      providers: { "switchable" => @definition },
      models: { "switchable/model" => { "capabilities" => { "limits" => { "input_tokens" => 4096, "output_tokens" => 1024 } } } },
      selectors: {}
    )
    ModelCatalog.stub(:current, snapshot) do
      result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "switchable",
        model_ref: "switchable/model", model: {}, expected_lock_version: nil, validate_definition: true)
      assert_predicate result, :done?
      result = set_definition("switchable", @definition.merge("api_format" => "openai_images"), version: result.policy.lock_version)
      assert_predicate result, :done?
      catalog = ModelSelection::Resolver.effective_catalog(@account, snapshot)
      assert_equal "openai_images", catalog.providers.dig("switchable", "api_format")
      profile = ModelCatalog::ProfileBuilder.call(model_ref: "switchable/model", provider: catalog.providers.fetch("switchable"), model: catalog.models.fetch("switchable/model"))
      assert_equal "image_generation", profile.workload
    end
  end

  test "provider edits cannot silently drop currently effective models or invalidate selectors" do
    result = set_definition("local", @definition.merge("api_format" => "openai_responses"))
    model = { "capabilities" => { "reasoning" => { "efforts" => ["xhigh"], "default_effort" => "xhigh" } } }
    result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "local", model_ref: "local/reasoner",
      model: model, expected_lock_version: result.policy.lock_version, validate_definition: true)
    assert_predicate result, :done?
    changed = set_definition("local", @definition.merge("api_format" => "gemini_generate_content"), version: result.policy.lock_version)
    assert_equal :invalid, changed.outcome
    assert_equal "openai_responses", result.policy.reload.provider_definition.fetch("api_format")
    assert ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current).models.key?("local/reasoner")

    snapshot = ModelCatalog.current.with(providers: { "selected" => @definition },
      models: { "selected/model" => {} }, selectors: { "default" => [{ "model" => "selected/model" }] })
    ModelCatalog.stub(:current, snapshot) do
      result = set_definition("selected", @definition.merge("api_format" => "openai_embeddings"))
      assert_equal :invalid, result.outcome
      assert_nil ModelProviderConfig.find_by(account: @account, provider_id: "selected")
    end
  end

  test "provider reset cannot invalidate an effective custom model" do
    original = @definition.merge("api_format" => "gemini_generate_content")
    snapshot = ModelCatalog.current.with(providers: { "resettable" => original }, models: {}, selectors: {})
    ModelCatalog.stub(:current, snapshot) do
      result = set_definition("resettable", @definition.merge("api_format" => "openai_responses"))
      result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "resettable", model_ref: "resettable/reasoner",
        model: { "capabilities" => { "reasoning" => { "efforts" => ["xhigh"], "default_effort" => "xhigh" } } },
        expected_lock_version: result.policy.lock_version, validate_definition: true)
      assert_predicate result, :done?
      reset = ModelProviders::ResetDefinition.call(account: @account, provider_id: "resettable", expected_lock_version: result.policy.lock_version)
      assert_equal :invalid, reset.outcome
      assert_equal "openai_responses", result.policy.reload.provider_definition.fetch("api_format")
    end
  end

  test "a provider without models still validates the composed wire facts" do
    [{ "wire_options" => "not-a-mapping" }, { "native_cost_contract" => "not-a-mapping" },
      { "service_tiers" => "not-a-list" }, { "wire_options" => { "future_option" => true } }].each do |invalid|
      result = set_definition("local", @definition.merge(invalid))
      assert_equal :invalid, result.outcome, invalid.inspect
      assert_nil ModelProviderConfig.find_by(account: @account, provider_id: "local")
    end
  end

  test "provider display names are normalized scalar values at the shared boundary" do
    result = set_definition("local", @definition.merge("display_name" => { "label" => "bad" }))
    assert_equal :invalid, result.outcome
    assert_nil ModelProviderConfig.find_by(account: @account, provider_id: "local")
    result = set_definition("local", @definition.merge("display_name" => "  Local models  "))
    assert_predicate result, :done?
    assert_equal "Local models", result.policy.provider_definition.fetch("display_name")
  end

  test "authoring rejects invalid model semantics while inert internal storage remains supported" do
    result = set_definition("local", @definition)
    invalid = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "local",
      model_ref: "local/bad", model: { "future_contract" => true }, expected_lock_version: result.policy.lock_version,
      validate_definition: true)
    assert_equal :invalid, invalid.outcome
    assert_empty result.policy.reload.override_entries
  end

  test "an invalid stored provider definition is ignored without poisoning the base catalog" do
    result = set_definition("openai_api", ModelCatalog.current.providers.fetch("openai_api"))
    result.policy.update_column(:provider_definition, { "api_format" => "future_wire" })
    catalog = ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current)
    assert_equal ModelCatalog.current.providers.fetch("openai_api"), catalog.providers.fetch("openai_api")
  end

  private

    def set_definition(provider, definition, version: nil)
      ModelProviders::SetDefinition.call(account: @account, provider_id: provider, definition: definition, expected_lock_version: version)
    end
end
