require "test_helper"

class ModelCatalog::PolicyOverlayTest < ActiveSupport::TestCase
  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    # The house line: `event=… key=value …`, read back as the pairs it is.
    def warn(message)
      raise "not the house line: #{message.inspect}" unless message.start_with?("event=model_catalog_policy_overlay_ignored ")

      @warnings << message.split(" ").to_h { |pair| pair.split("=", 2) }
    end
  end

  setup do
    @account = accounts(:cybros)
    @snapshot = ModelCatalog.current
    @models = @snapshot.models
    @logger = RecordingLogger.new
    @policy = ModelProviderPolicy.new(
      account: @account,
      provider_id: "test_api",
      enabled: true,
      model_overrides: ModelProviderPolicy.empty_overrides
    )
  end

  test "visibility leaves the definition intact even when another entry is invalid" do
    @policy.set_model_visibility("test_api/text", visible: false)
    @policy.put_entry("test_api/future", { "op" => "upsert", "model" => { "bad" => true } })

    effective = apply

    assert_equal @models.fetch("test_api/text"), effective.fetch("test_api/text")
    assert apply_policy.hidden_models.include?("test_api/text")
    assert_equal ["invalid_model"], @logger.warnings.pluck("reason").uniq
  end

  test "invalid stored visibility documents are warned and ignored" do
    [["anthropic/foreign"], ["test_api/x", "test_api/x"], "test_api/x", nil].each do |hidden|
      @policy.model_overrides = ModelProviderPolicy.empty_overrides.merge("hidden_models" => hidden)
      assert_same @models, apply
      refute apply_policy.hidden_models.include?("test_api/text")
      assert_equal "invalid_document", @logger.warnings.last.fetch("reason")
    end
  end

  test "valid siblings compose while an invalid complete replacement is warned and ignored" do
    @policy.put_entry("test_api/alternate", { "op" => "remove" })
    @policy.put_entry(
      "test_api/future-model",
      { "op" => "upsert", "model" => { "future_contract" => true } }
    )

    effective = apply

    refute effective.key?("test_api/alternate")
    assert effective.key?("test_api/text")
    refute effective.key?("test_api/future-model")
    assert effective.key?("dev/mock-text")
    assert_predicate effective, :frozen?
    assert_equal ["invalid_model"], @logger.warnings.pluck("reason")
  end

  test "a valid upsert wholesale replaces the file-base model" do
    replacement = @models.fetch("test_api/text").deep_dup
    replacement.dig("capabilities", "limits")["input_tokens"] = 1_000_000
    @policy.put_entry(
      "test_api/text",
      { "op" => "upsert", "model" => replacement }
    )

    # The lane is priced, so the replacement carries pricing and only installs
    # into an Account whose unit it echoes — which is the neighbouring test.
    effective = apply(account_unit: "USD")

    assert_equal replacement, effective.fetch("test_api/text")
    refute_same replacement, effective.fetch("test_api/text")
    assert effective.keys.all?(&:frozen?)
    assert_empty @logger.warnings
  end

  test "malformed operations are warned and ignored independently of valid siblings" do
    @policy.model_overrides = {
      "schema_version" => ModelProviderPolicy::OVERRIDES_SCHEMA_VERSION,
      "entries" => {
        "test_api/alternate" => { "op" => "remove" },
        "test_api/scalar" => "remove",
        "test_api/payload-tombstone" => { "op" => "remove", "model" => {} },
        "dev/mock-text" => { "op" => "remove" },
      },
    }

    effective = apply

    refute effective.key?("test_api/alternate")
    assert effective.key?("test_api/text")
    assert effective.key?("dev/mock-text")
    assert_equal(
      ["invalid_operation", "invalid_operation", "outside_provider_lane"],
      @logger.warnings.pluck("reason")
    )
  end

  # The selector is the test's OWN, not one it hopes the catalog still has.
  # The repository ships none, and a fixture selector that happened to name
  # this model would keep the test green while it stopped stating its
  # precondition.
  test "a tombstone that would invalidate a file selector is warned and ignored" do
    @policy.put_entry("test_api/text", { "op" => "remove" })

    effective = apply(selectors: { "routed" => [{ "model" => "test_api/text" }] })

    assert effective.key?("test_api/text")
    assert_equal ["invalid_composition"], @logger.warnings.pluck("reason")
  end

  test "a currently inapplicable tombstone is retained as data but hides nothing" do
    @policy.put_entry("test_api/future-model", { "op" => "remove" })

    effective = apply

    assert_equal @models, effective
    assert_equal ["model_not_present"], @logger.warnings.pluck("reason")
  end

  test "a future provider policy remains inert until the strict file base declares that provider" do
    @policy.provider_id = "future_provider"
    @policy.put_entry("future_provider/future-model", { "op" => "remove" })

    effective = apply

    assert_same @models, effective
    assert_equal ["provider_not_present"], @logger.warnings.pluck("reason")
  end

  test "an empty document does not traverse the already frozen catalog again" do
    ModelCatalog.stub(:deep_freeze, ->(*) { flunk "empty overlays must not re-freeze the catalog" }) do
      assert_same @models, apply
    end
  end

  test "an invalid document ignores the whole database overlay without exposing its payload" do
    secret = "do-not-log-this-value"
    @policy.model_overrides = {
      "schema_version" => "unknown",
      "entries" => { "test_api/future-model" => { "op" => "upsert", "model" => { "secret" => secret } } },
    }

    effective = apply

    assert_same @models, effective
    assert_equal ["invalid_document"], @logger.warnings.pluck("reason")
    refute_includes @logger.warnings.to_json, secret
  end

  # Administrators can leave estimates absent, declare a zero-cost schedule,
  # or retain rates in another unit; none controls whether a definition exists.
  test "an overlay may author optional or zero pricing independently of the Account unit" do
    [nil, { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only",
      "rates" => { "input_per_mtok" => "0", "output_per_mtok" => "0" } } },
      { "account_unit" => "EUR", "schedule" => { "kind" => "catalog_only",
        "rates" => { "input_per_mtok" => "1", "output_per_mtok" => "1" } } }].each do |pricing|
      model = @models.fetch("test_api/text").deep_dup
      model["pricing"] = pricing
      @policy.put_entry("test_api/text", { "op" => "upsert", "model" => model })

      effective = apply(account_unit: "USD")

      assert_equal model, effective.fetch("test_api/text")
      assert_empty @logger.warnings
    end
  end

  test "a null replacement is refused as a malformed entry, not read as no change" do
    # A removal leaves no key; an upsert leaves one even when its payload is
    # null — and user-authored JSON can hold that. Deciding on the VALUE
    # instead of key presence skipped the check that refuses it, and the
    # accept path raised NoMethodError on a database document.
    @policy.put_entry("test_api/alternate", { "op" => "upsert", "model" => nil })

    effective = apply

    assert_same @models, effective
    assert_equal ["invalid_model"], @logger.warnings.pluck("reason")
  end

  test "an overlay entry re-validates what it changed, never the whole catalog" do
    @policy.put_entry("test_api/alternate", { "op" => "remove" })
    @policy.put_entry(
      "test_api/future-model",
      { "op" => "upsert", "model" => { "future_contract" => true } }
    )

    whole_catalog_validations = 0
    ModelCatalog::CatalogValidation.stub(:validate, ->(_merged) { whole_catalog_validations += 1 }) do
      apply
    end

    # The file base carries a standing compile-time verdict and model
    # validation is per-entry, so re-deriving every unchanged model's validity
    # once per overlay entry is repetition — and it is repetition the accept
    # path pays, multiplied by the document's reference count.
    assert_equal 0, whole_catalog_validations
  end

  test "a document at the reference limit copies only the models it rewrites" do
    replacement = @models.fetch("test_api/text").deep_dup
    replacement.dig("capabilities", "limits")["input_tokens"] = 1_000_000
    entries = { "test_api/text" => { "op" => "upsert", "model" => replacement } }
    (1...ModelProviderPolicy::MAX_OVERRIDE_REFS).each do |index|
      entries["test_api/absent-#{index}"] = { "op" => "upsert", "model" => { "future_contract" => true } }
    end
    @policy.model_overrides = {
      "schema_version" => ModelProviderPolicy::OVERRIDES_SCHEMA_VERSION,
      "entries" => entries,
    }

    effective = apply(account_unit: "USD")

    assert_equal 1_000_000,
      effective.dig("test_api/text", "capabilities", "limits",
        "input_tokens")
    assert_equal @models.size, effective.size
    assert_equal ModelProviderPolicy::MAX_OVERRIDE_REFS - 1, @logger.warnings.size
    assert_equal ["invalid_model"], @logger.warnings.pluck("reason").uniq
    # The catalog binds every ref to an audited registry pin, so a document may
    # hold hundreds of refs that can never apply. Untouched models stay the
    # file base's own published objects — the copy is per rewrite, not per
    # entry.
    assert_same @models.fetch("dev/mock-text"), effective.fetch("dev/mock-text")
  end

  private

  def apply(**options) = apply_policy(**options).models

  def apply_policy(account_unit: @account.cost_unit, selectors: @snapshot.selectors)
    ModelCatalog::PolicyOverlay.apply(
      providers: @snapshot.providers,
      models: @models,
      selectors: selectors,
      policy: @policy,
      account_unit: account_unit,
      logger: @logger
    )
  end
end
