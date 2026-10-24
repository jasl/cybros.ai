require "test_helper"

class ModelCatalog::RetentionTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @snapshot = ModelCatalog.current
    ModelProviderConfig.where(account: @account, provider_id: "test_api").delete_all
  end

  test "enabling preserves models across catalog retirement while current file facts win" do
    result = ModelProviders::EnableLane.call(account: @account, provider_id: "test_api", expected_lock_version: nil)
    assert result.done?

    replacement = @snapshot.models.fetch("test_api/text").deep_dup
    replacement["display_name"] = "Updated model"
    next_snapshot = @snapshot.with(models: @snapshot.models.except("test_api/alternate").merge("test_api/text" => replacement))
    catalog = ModelSelection::Resolver.effective_provider_catalog(@account, next_snapshot, "test_api")

    assert_equal replacement, catalog.models.fetch("test_api/text")
    assert_equal @snapshot.models.fetch("test_api/alternate"), catalog.models.fetch("test_api/alternate")

    retired = next_snapshot.with(providers: next_snapshot.providers.except("test_api"),
      models: next_snapshot.models.reject { |ref, _| ref.start_with?("test_api/") })
    catalog = ModelSelection::Resolver.effective_provider_catalog(@account, retired, "test_api")
    assert_equal @snapshot.providers.fetch("test_api"), catalog.providers.fetch("test_api")
    assert_equal @snapshot.models.fetch("test_api/text"), catalog.models.fetch("test_api/text")
  end

  test "refresh saves updated facts and new models without dropping retired ones or rewriting unchanged rows" do
    policy = enable
    replacement = @snapshot.models.fetch("test_api/text").merge("display_name" => "Updated model")
    current = @snapshot.with(models: @snapshot.models.except("test_api/alternate").merge(
      "test_api/text" => replacement, "test_api/new" => replacement))
    ModelCatalog.stub(:current, current) do
      result = ModelProviders::RetainCatalog.call(account: @account, provider_id: "test_api", expected_lock_version: policy.lock_version)
      assert_equal :applied, result.outcome
      version = result.policy.lock_version
      assert_equal :noop, ModelProviders::RetainCatalog.call(account: @account, provider_id: "test_api", expected_lock_version: version).outcome
      assert_equal :stale, ModelProviders::RetainCatalog.call(account: @account, provider_id: "test_api", expected_lock_version: nil).outcome
    end

    catalog = ModelSelection::Resolver.effective_provider_catalog(@account, retired_snapshot, "test_api")
    assert_equal replacement, catalog.models.fetch("test_api/text")
    assert_equal replacement, catalog.models.fetch("test_api/new")
    assert_equal @snapshot.models.fetch("test_api/alternate"), catalog.models.fetch("test_api/alternate")
  end

  test "retained models remain editable discoverable and explicitly removable after retirement" do
    policy = enable
    ModelProviders::SetModelVisibility.call(account: @account, provider_id: "test_api", model_ref: "test_api/text",
      visible: false, expected_lock_version: policy.lock_version)
    ModelCatalog.stub(:current, retired_snapshot) do
      metadata = ModelSelection::ProviderMetadata.read(account: @account, snapshot: retired_snapshot, provider_id: "test_api")
      assert_equal @snapshot.providers.fetch("test_api"), metadata.providers.fetch("test_api")
      assert_equal 2, metadata.model_counts.fetch("test_api")
      configuration = API::ModelProviderConfigurationPresenter.one(account: @account, provider_id: "test_api")
      assert_equal %w[test_api/alternate test_api/text], configuration.fetch(:models).pluck(:model)
      assert_equal "catalog", configuration.fetch(:source)

      result = ModelProviders::RemoveModelOverride.call(account: @account, provider_id: "test_api",
        model_ref: "test_api/alternate", expected_lock_version: policy.reload.lock_version, validate_definition: true)
      assert result.done?
      ModelProviders::RetainCatalog.call(account: @account, provider_id: "test_api", expected_lock_version: result.policy.lock_version)
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, retired_snapshot, "test_api")
      refute catalog.models.key?("test_api/alternate")
      assert_includes catalog.hidden_models, "test_api/text"

      result = ModelProviders::ResetModelOverride.call(account: @account, provider_id: "test_api",
        model_ref: "test_api/alternate", expected_lock_version: policy.reload.lock_version, validate_definition: true)
      assert result.done?
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, retired_snapshot, "test_api")
      assert_equal @snapshot.models.fetch("test_api/alternate"), catalog.models.fetch("test_api/alternate")
      assert_includes catalog.hidden_models, "test_api/text"
    end
  end

  test "custom inherited models retain their shared definition and accept edits after its removal" do
    definition = { "capabilities" => { "limits" => { "input_tokens" => 100_000 } } }
    initial = @snapshot.with(model_definitions: @snapshot.model_definitions.merge("retiring-base" => definition))
    ModelCatalog.stub(:current, initial) do
      result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "test_api",
        model_ref: "test_api/custom", model: { "inherit" => "retiring-base" },
        expected_lock_version: nil, validate_definition: true)
      assert result.done?
    end
    ModelCatalog.stub(:current, retired_snapshot) do
      policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
      result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "test_api",
        model_ref: "test_api/custom", model: { "inherit" => "retiring-base", "display_name" => "Edited" },
        expected_lock_version: policy.lock_version, validate_definition: true)
      assert result.done?
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, retired_snapshot, "test_api")
      assert_equal 100_000, catalog.models.fetch("test_api/custom").dig("capabilities", "limits", "input_tokens")
      assert_equal "Edited", catalog.models.fetch("test_api/custom").fetch("display_name")
      configuration = API::ModelProviderConfigurationPresenter.one(account: @account, provider_id: "test_api")
      assert_equal definition, configuration.fetch(:model_definitions).fetch("retiring-base")
    end
  end

  test "resetting a retired provider restores its saved definition without disabling it" do
    policy = enable
    policy.update!(provider_definition: @snapshot.providers.fetch("test_api").merge("display_name" => "Custom name"))
    ModelCatalog.stub(:current, retired_snapshot) do
      result = ModelProviders::ResetDefinition.call(account: @account, provider_id: "test_api",
        expected_lock_version: policy.lock_version)
      assert result.done?
      assert result.policy.enabled?
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, retired_snapshot, "test_api")
      assert_equal @snapshot.providers.fetch("test_api"), catalog.providers.fetch("test_api")
    end
  end

  test "retention uses the existing document bounds and rejects cross-provider refs" do
    policy = enable
    original = policy.model_overrides
    policy.model_overrides = original.deep_merge("retained_catalog" => { "models" => { "other/model" => {} } })
    refute policy.valid?
    policy.model_overrides = original.deep_merge("retained_catalog" => { "models" => {
      "test_api/oversized" => { "display_name" => "x" * ModelProviderConfig::MAX_OVERRIDES_BYTES },
    } })
    refute policy.valid?
    assert policy.errors.added?(:model_overrides, :too_many_bytes, limit: ModelProviderConfig::MAX_OVERRIDES_BYTES)
  end

  private

    def enable
      result = ModelProviders::EnableLane.call(account: @account, provider_id: "test_api", expected_lock_version: nil)
      assert result.done?
      result.policy
    end

    def retired_snapshot
      @snapshot.with(providers: @snapshot.providers.except("test_api"),
        models: @snapshot.models.reject { |ref, _| ref.start_with?("test_api/") },
        authored_models: @snapshot.authored_models.reject { |ref, _| ref.start_with?("test_api/") })
    end
end
