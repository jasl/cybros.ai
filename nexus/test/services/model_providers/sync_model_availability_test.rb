require "test_helper"

class ModelProviders::SyncModelAvailabilityTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @refs = %w[dev/mock-text dev/mock-image]
  end

  test "sync replaces current observations once while preserving manual visibility and historical refs" do
    policy = create_policy
    policy.set_model_visibility(@refs.first, visible: false)
    policy.set_model_availability(@refs.first, available: false)
    policy.set_model_availability("dev/historical", available: false)
    policy.save!
    version = policy.lock_version
    original_entries = policy.override_entries

    result = sync(missing: [@refs.last], version: version)

    assert_equal :applied, result.outcome
    assert_equal version + 1, policy.reload.lock_version
    assert_equal [@refs.first], policy.model_overrides.fetch("hidden_models")
    assert_equal ["dev/historical", @refs.last].sort, policy.model_overrides.fetch("unavailable_models")
    assert_equal original_entries, policy.override_entries
    refute_predicate policy, :enabled?
    assert_equal :noop, sync(missing: [@refs.last], version: policy.lock_version).outcome
    assert_equal version + 1, policy.reload.lock_version
  end

  test "a missing policy is created disabled with the final document in its first save" do
    result = sync(missing: @refs)

    assert_equal :applied, result.outcome
    policy = result.policy
    assert_equal 0, policy.lock_version
    refute_predicate policy, :enabled?
    assert_nil policy.provider_definition
    assert_equal @refs.sort, policy.model_overrides.fetch("unavailable_models")
  end

  test "an entirely available directory needs no new anchor" do
    assert_no_difference "ModelProviderConfig.count" do
      assert_equal :noop, sync(missing: []).outcome
    end
    assert_equal :stale, sync(missing: [], version: 0).outcome
  end

  test "a stale observation cannot change availability even when its desired state matches" do
    policy = create_policy
    version = policy.lock_version
    policy.update!(enabled: true)
    before = policy.attributes

    [nil, version].each do |stale_version|
      [[], @refs].each do |missing|
        assert_equal :stale, sync(missing: missing, version: stale_version).outcome
        assert_equal before, policy.reload.attributes
      end
    end
  end

  test "the shared ref bound refuses both new anchors and existing documents atomically" do
    refs = (0..ModelProviderConfig::MAX_OVERRIDE_REFS).map { |index| "dev/model-#{index}" }
    assert_no_difference "ModelProviderConfig.count" do
      assert_equal :invalid, sync(missing: refs, refs: refs).outcome
    end
    policy = create_policy
    before = policy.attributes
    assert_equal :invalid, sync(missing: refs, refs: refs, version: policy.lock_version).outcome
    assert_equal before, policy.reload.attributes
  end

  test "the shared document byte bound refuses new anchors without leaving an empty policy" do
    ref = "dev/#{"x" * ModelProviderConfig::MAX_OVERRIDES_BYTES}"
    assert_no_difference "ModelProviderConfig.count" do
      assert_equal :invalid, sync(missing: [ref], refs: [ref]).outcome
    end
  end

  test "foreign duplicate and outside-current model refs are invalid" do
    [[%w[other/model], %w[other/model]], [[@refs.first, @refs.first], @refs],
      [["dev/"], ["dev/"]], [["dev/absent"], @refs]].each do |missing, refs|
      assert_equal :invalid, sync(missing: missing, refs: refs).outcome
    end
    assert_empty ModelProviderConfig.where(account: @account)
  end

  private

    def sync(missing:, version: nil, refs: @refs)
      ModelProviders::SyncModelAvailability.call(account: @account, provider_id: "dev",
        expected_lock_version: version, model_refs: refs, unavailable_model_refs: missing)
    end

    def create_policy
      ModelProviderConfig.create!(account: @account, provider_id: "dev", enabled: false,
        model_overrides: ModelProviderConfig.empty_overrides)
    end
end
