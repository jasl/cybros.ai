require "test_helper"
require "minitest/mock"

# C2-2 WP3b: the neutral provider-policy command set — lane enable/disable plus model
# upsert/remove/reset. Every mutation supplies the expected lock_version, validates the bounded
# replacement document before SQL, then commits the policy mutation in one transaction; semantic
# validity of the composed model belongs to the reader, and no file-base digest echo or
# catalog-health gate rides the write path. Same-value replay is a no-op; a stale version is a
# stable conflict; the command owns the unique concurrent-create winner.
class ModelProviders::ConfigCommandsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  def model_entry(ref)
    ModelCatalog.current.models.fetch(ref).deep_dup
  end

  test "enabling an absent lane creates the row as the unique winner" do
    result = ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: nil
    )

    assert_predicate result, :done?
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    assert policy.enabled
  end

  test "hiding and restoring a database-only model preserves its replacement and pricing" do
    @account.update!(cost_unit: "USD")
    ModelProviders::EnableLane.call(account: @account, provider_id: "test_api", expected_lock_version: nil)
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    ref = "test_api/private-model"
    replacement = model_entry("test_api/text")
    ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: ref, model: replacement,
      expected_lock_version: policy.lock_version
    )

    [false, true].each do |visible|
      result = ModelProviders::SetModelVisibility.call(
        account: @account, provider_id: "test_api", model_ref: ref, visible: visible,
        expected_lock_version: policy.reload.lock_version
      )
      assert_predicate result, :done?
      catalog = ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current)
      assert_equal replacement, catalog.models.fetch(ref)
      assert_equal !visible, catalog.hidden_models.include?(ref)
    end
  end

  test "a same-value enable is a no-op that does not bump lock_version" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    before = policy.lock_version

    result = ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: policy.lock_version
    )

    assert_predicate result, :done?
    assert_equal :noop, result.outcome
    assert_equal before, policy.reload.lock_version
  end

  test "disable mutates the retained row in place and never deletes it" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")

    result = ModelProviders::DisableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: policy.lock_version
    )

    assert_predicate result, :done?
    assert_not policy.reload.enabled
    assert_equal 1, ModelProviderConfig.count
  end

  test "disabling an absent lane is not_found" do
    result = ModelProviders::DisableLane.call(
      account: @account, provider_id: "mystery",
      expected_lock_version: 0
    )

    assert_predicate result, :blocked?
    assert_equal :not_found, result.outcome
  end

  test "a stale lock_version is a stable conflict changing nothing" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    stale_version = ModelProviders::DisableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: policy.lock_version + 7
    )

    assert_equal :stale, stale_version.outcome
    assert policy.reload.enabled
  end

  # Overlay writes carry no file-base digest echo and no catalog-availability
  # gate. Boot validates the file base, the reader warn-ignores an inapplicable
  # entry, and a policy write does not need a runtime snapshot.
  test "overlay writes do not depend on catalog runtime availability" do
    ModelCatalog.stub(:current, -> { raise ModelCatalog::Unavailable, "unavailable" }) do
      result = ModelProviders::EnableLane.call(
        account: @account, provider_id: "test_api",
        expected_lock_version: nil
      )

      assert_predicate result, :done?
    end
    assert ModelProviderConfig.find_by!(account: @account, provider_id: "test_api").enabled
  end

  test "upsert stores a bounded structural overlay and defers catalog semantics to composition" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    future_model = { "future_contract" => { "shape" => "not-yet-supported" } }
    applied = ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/future-model",
      model: future_model, expected_lock_version: policy.lock_version
    )

    assert_predicate applied, :done?
    assert_equal(
      { "op" => "upsert", "model" => future_model },
      policy.reload.override_entries.fetch("test_api/future-model")
    )
  end

  test "remove stores a future-model tombstone without consulting the file base" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api", expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")

    removed = ModelProviders::RemoveModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/future-model",
      expected_lock_version: policy.lock_version
    )

    assert_predicate removed, :done?
    assert_equal(
      { "op" => "remove" },
      policy.reload.override_entries.fetch("test_api/future-model")
    )
  end

  test "the provider-row partition and bounded operation grammar still reject invalid structure" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api", expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    foreign_lane = ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "anthropic/future-model",
      model: {}, expected_lock_version: policy.lock_version
    )
    scalar_model = ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/future-model",
      model: "invalid", expected_lock_version: policy.lock_version
    )
    foreign_remove = ModelProviders::RemoveModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "anthropic/future-model",
      expected_lock_version: policy.lock_version
    )
    non_string_ref = ModelProviders::ResetModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: 123,
      expected_lock_version: policy.lock_version
    )

    assert_equal :invalid, foreign_lane.outcome
    assert_equal :invalid, scalar_model.outcome
    assert_equal :invalid, foreign_remove.outcome
    assert_equal :invalid, non_string_ref.outcome
  end

  # Boundary values normalize through to_s; only blank or over-length
  # identities refuse (duck typing, not a type gate).
  test "a blank or over-length provider identity rejects before creating a lane" do
    [nil, " ", "x" * 65].each do |provider_id|
      result = ModelProviders::EnableLane.call(
        account: @account, provider_id: provider_id, expected_lock_version: nil
      )

      assert_equal :invalid, result.outcome
    end

    assert_empty ModelProviderConfig.where(account: @account)
  end

  test "same-value upsert is a no-op; remove writes the tombstone; reset restores file inheritance" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api",
      expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    complete_model = model_entry("test_api/text")
    ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      model: complete_model,
      expected_lock_version: policy.reload.lock_version
    )
    before = policy.reload.lock_version

    replay = ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      model: complete_model,
      expected_lock_version: policy.reload.lock_version
    )
    assert_equal :noop, replay.outcome
    assert_equal before, policy.reload.lock_version

    removed = ModelProviders::RemoveModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      expected_lock_version: policy.reload.lock_version
    )
    assert_predicate removed, :done?
    assert_equal({ "op" => "remove" }, policy.reload.override_entries.fetch("test_api/text"))

    reset = ModelProviders::ResetModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      expected_lock_version: policy.reload.lock_version
    )
    assert_predicate reset, :done?
    refute policy.reload.override_entries.key?("test_api/text")

    noop_reset = ModelProviders::ResetModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      expected_lock_version: policy.reload.lock_version
    )
    assert_equal :noop, noop_reset.outcome
  end

  test "pricing facts are stored as overlay data and validated only after composition" do
    priced_model = model_entry("test_api/text")
    mismatched = priced_model.deep_dup
    mismatched.dig("pricing")["account_unit"] = "EUR"

    ModelProviders::EnableLane.call(
      account: @account, provider_id: "test_api", expected_lock_version: nil
    )
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    result = ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: "test_api/text",
      model: mismatched, expected_lock_version: policy.lock_version
    )

    assert_predicate result, :done?
    assert_equal "EUR", policy.reload.override_entries
      .dig("test_api/text", "model", "pricing", "account_unit")
  end
end
