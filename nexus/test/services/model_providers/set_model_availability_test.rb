require "test_helper"

class ModelProviders::SetModelAvailabilityTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
    @policy = ModelProviderConfig.find_by!(account: @account, provider_id: "dev")
    @ref = "dev/custom-text"
    @definition = ModelCatalog.current.models.fetch("dev/mock-text").deep_dup
    result = ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "dev", model_ref: @ref, model: @definition,
      expected_lock_version: @policy.lock_version
    )
    assert_predicate result, :done?
    @policy = result.policy
  end

  test "unavailable models retain their definition and pricing while restoration preserves manual hiding" do
    before = model_row
    assert_predicate change(false), :done?

    unavailable = model_row
    assert_equal before.merge(visible: false, available: false, unavailable_reason: "model_unavailable"), unavailable
    catalog = ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current)
    assert_equal @definition, catalog.models.fetch(@ref)

    @policy.reload.set_model_visibility(@ref, visible: false)
    @policy.save!
    assert_predicate change(true), :done?
    assert_equal before.merge(visible: false, available: false, unavailable_reason: "model_hidden"), model_row
    assert_equal @definition, @policy.reload.override_entries.fetch(@ref).fetch("model")

    @policy.set_model_visibility(@ref, visible: true)
    @policy.save!
    assert_equal before, model_row
  end

  test "same value is a no-op and a stale result cannot replace newer model availability" do
    version = @policy.reload.lock_version
    assert_predicate change(false, version: version), :done?
    marked_version = @policy.reload.lock_version
    assert_equal :noop, change(false, version: marked_version).outcome
    assert_equal marked_version, @policy.reload.lock_version

    assert_equal :stale, change(true, version: version).outcome
    assert_equal "model_unavailable", model_row.fetch(:unavailable_reason)
  end

  test "availability configuration neither enables a disabled lane nor creates a missing policy" do
    @policy.update!(enabled: false)
    assert_predicate change(false), :done?
    refute_predicate @policy.reload, :enabled?
    assert_includes @policy.model_overrides.fetch("unavailable_models"), @ref

    result = ModelProviders::SetModelAvailability.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      available: false, expected_lock_version: nil
    )
    assert_equal :not_found, result.outcome
    refute ModelProviderConfig.exists?(account: @account, provider_id: "test_api")
  end

  test "invalid availability and refs leave the policy unchanged" do
    before = @policy.reload.attributes
    [[nil, @ref], ["false", @ref], [false, "test_api/text"], [false, "dev/"]].each do |available, ref|
      result = ModelProviders::SetModelAvailability.call(
        account: @account, provider_id: "dev", model_ref: ref,
        available: available, expected_lock_version: @policy.lock_version
      )
      assert_equal :invalid, result.outcome
      assert_equal before, @policy.reload.attributes
    end
  end

  private

    def change(available, version: @policy.reload.lock_version)
      ModelProviders::SetModelAvailability.call(
        account: @account, provider_id: "dev", model_ref: @ref,
        available: available, expected_lock_version: version
      )
    end

    def model_row
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, "dev")
      AgentAPI::ModelPresenter.index(account: @account, catalog: catalog).find { |row| row.fetch(:ref) == @ref }
    end
end
