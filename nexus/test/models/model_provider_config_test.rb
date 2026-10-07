require "test_helper"

# C2-2 WP3a: the sole database catalog overlay. One row per (Account,
# provider lane); `model_overrides` is a bounded versioned document — at most
# 256 exact model refs and 2 MiB canonical JSON, each entry exactly one
# replacement-map `upsert` or one `remove` tombstone. The row is the stable
# lane lock anchor: disable mutates in place and no physical-delete writer
# exists in C2.
class ModelProviderConfigTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  def policy(overrides = {})
    ModelProviderConfig.new(
      account: @account, provider_id: "dev", enabled: true,
      model_overrides: {
        "schema_version" => ModelProviderConfig::OVERRIDES_SCHEMA_VERSION,
        "entries" => overrides,
      }
    )
  end

  def model_entry(ref)
    ModelCatalog.current.models.fetch(ref).deep_dup
  end

  test "a valid policy row with upsert and remove entries persists" do
    complete_model = model_entry("dev/mock-text")
    row = policy(
      "dev/mock-text" => { "op" => "upsert", "model" => complete_model },
      "dev/mock-image" => { "op" => "remove" }
    )

    assert_predicate row, :valid?
    row.save!
    assert_equal 2, row.reload.model_overrides.fetch("entries").length
  end

  test "visibility is bounded and separate from a replacement definition" do
    row = policy("dev/mock-text" => { "op" => "upsert", "model" => model_entry("dev/mock-text") })
    before = row.override_entries.deep_dup
    row.set_model_visibility("dev/mock-text", visible: false)
    assert_predicate row, :valid?
    assert row.model_overrides.fetch("hidden_models", []).include?("dev/mock-text")
    assert_equal before, row.override_entries
    row.set_model_visibility("dev/mock-text", visible: true)
    assert_equal before, row.override_entries
    refute row.model_overrides.fetch("hidden_models", []).include?("dev/mock-text")

    [["other/foreign"], ["dev/x", "dev/x"], nil, "dev/x",
      (0..256).map { |i| "dev/m#{i}" }].each do |hidden|
      row.model_overrides = ModelProviderConfig.empty_overrides.merge("hidden_models" => hidden)
      refute_predicate row, :valid?
    end
  end

  test "availability preserves visibility and shares the document's distinct ref limit" do
    ref = "dev/mock-text"
    row = policy(ref => { "op" => "upsert", "model" => model_entry(ref) })
    row.set_model_visibility(ref, visible: false)
    row.set_model_availability(ref, available: false)
    before = row.model_overrides.deep_dup

    assert_predicate row, :valid?
    row.set_model_availability(ref, available: true)
    assert_equal before.except("unavailable_models"), row.model_overrides

    refs = (1..ModelProviderConfig::MAX_OVERRIDE_REFS).map { |i| "dev/m#{i}" }
    row.model_overrides = ModelProviderConfig.empty_overrides.merge(
      "hidden_models" => refs, "unavailable_models" => [refs.first]
    )
    assert_predicate row, :valid?
    row.set_model_availability("dev/one-more", available: false)
    refute_predicate row, :valid?
    assert row.errors.added?(:model_overrides, :too_many_refs, limit: ModelProviderConfig::MAX_OVERRIDE_REFS)
  end

  test "unavailable models are unique complete refs from their provider" do
    row = policy
    [["other/foreign"], ["dev/x", "dev/x"], ["dev/"], nil, "dev/x"].each do |refs|
      row.model_overrides = ModelProviderConfig.empty_overrides.merge("unavailable_models" => refs)
      refute_predicate row, :valid?
      assert row.errors.added?(:model_overrides, :invalid_unavailable_models)
    end
  end

  test "put_entry and delete_entry replace the document rather than mutating it in place" do
    row = policy(
      "dev/mock-text" => {
        "op" => "upsert", "model" => model_entry("dev/mock-text"),
      }
    )
    row.save!
    stored = row.model_overrides

    row.put_entry("dev/mock-image", { "op" => "remove" })

    assert_not stored.fetch("entries").key?("dev/mock-image")
    assert_predicate row, :model_overrides_changed?

    row.delete_entry("dev/mock-image")

    assert_not row.override_entries.key?("dev/mock-image")
  end

  test "the provider lane is unique per account and the account binding is create-frozen" do
    policy.save!

    assert_raises(ActiveRecord::RecordNotUnique) do
      ModelProviderConfig.new(account: @account, provider_id: "dev", enabled: false,
        model_overrides: ModelProviderConfig.empty_overrides).save!
    end

    row = ModelProviderConfig.first
    assert_raises(ActiveRecord::ReadonlyAttributeError) { row.update!(account_id: nil) }
  end

  test "an unknown op, a payload-free upsert, and a payload-carrying remove are invalid" do
    refute_predicate policy("dev/x" => { "op" => "merge" }), :valid?
    refute_predicate policy("dev/x" => { "op" => "upsert" }), :valid?
    refute_predicate policy(
      "dev/x" => { "op" => "remove", "model" => {} }
    ), :valid?
  end

  test "a model ref outside the row's own provider lane is invalid" do
    refute_predicate policy("other/text" => { "op" => "remove" }), :valid?
  end

  test "the wrong document schema version is invalid" do
    row = policy
    row.model_overrides = { "schema_version" => "v0", "entries" => {} }

    refute_predicate row, :valid?
  end

  test "more than 256 refs or a document above two mebibytes is invalid" do
    too_many = (0..256).to_h { |i| ["dev/m#{i}", { "op" => "remove" }] }
    refute_predicate policy(too_many), :valid?

    huge = policy(
      "dev/big" => { "op" => "upsert", "model" => { "blob" => "x" * (2 * 1024 * 1024) } }
    )
    refute_predicate huge, :valid?
  end

  test "unsupported canonical JSON values are stable validation errors rather than exceptions" do
    unsupported_value = policy(
      "dev/x" => { "op" => "upsert", "model" => { "value" => 1e100 } }
    )
    refute_predicate unsupported_value, :valid?
  end
end
