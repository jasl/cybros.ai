require "test_helper"
require "minitest/mock"

# C2-2 WP7a: the real accept-time resolver. It composes the published file
# base with the Account's policy and credential state and refuses with the
# typed acceptance vocabulary. Serving control is the enabled policy; a
# registry row's presence is the adaptation claim.
class ModelSelection::ResolverTest < ActiveSupport::TestCase
  TEXT_MODEL = "test_api/text".freeze

  setup do
    @account = accounts(:cybros)
    @resolver = ModelSelection::Resolver.new
  end

  def enable_lane(provider_id = "test_api")
    ModelProviders::EnableLane.call(
      account: @account, provider_id: provider_id, expected_lock_version: nil
    )
  end

  # A priced model's overlay replacement carries pricing, and pricing only installs into an Account
  # whose unit it echoes. Every override test therefore configures one first — the alternative is an
  # overlay that is silently warned and ignored, which is a different test.
  def configure_unit(unit = "USD")
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: unit)
    # `update_all` writes past the in-memory object the resolver is handed.
    @account.reload
  end

  def install_key(provider_id = "test_api")
    ModelProviders::SetAPIKey.call(
      account: @account, provider_id: provider_id, api_key: "sk-resolver"
    )
  end

  def resolve(model: TEXT_MODEL, workload: "text_generation", effort: nil, enabled: nil, configuration: {})
    @resolver.resolve(
      account: @account, workload: workload,
      submitted: Nexus::SubmittedModelSelection.new(model: model, reasoning_effort: effort, reasoning_enabled: enabled),
      configuration: configuration
    )
  end

  test "unknown provider, disabled lane, unknown model, and wrong workload refuse typed" do
    assert_equal :unknown_provider, resolve(model: "mystery/model").refusal
    assert_equal :provider_disabled, resolve.refusal

    enable_lane
    assert_equal :unknown_model, resolve(model: "test_api/mystery").refusal
    assert_equal :unsupported_workload, resolve(workload: "embedding").refusal
  end

  test "an enabled lane still requires a usable credential" do
    enable_lane

    assert_equal :missing_credential, resolve.refusal
  end

  test "a hidden model refuses direct selection and a selector skips it without losing its definition" do
    enable_lane
    install_key
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    ModelProviders::SetModelVisibility.call(
      account: @account, provider_id: "test_api", model_ref: TEXT_MODEL,
      visible: false, expected_lock_version: policy.lock_version
    )

    assert_equal :model_hidden, resolve.refusal
    assert_equal :no_selectable_candidate, resolve(model: "model_selector:chat-walk").refusal
    catalog = ModelSelection::Resolver.effective_catalog(@account, ModelCatalog.current)
    assert_equal ModelCatalog.current.models.fetch(TEXT_MODEL), catalog.models.fetch(TEXT_MODEL)
  end

  test "an unavailable model cannot be selected until its retained mark is cleared" do
    enable_lane
    install_key
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    policy.set_model_availability(TEXT_MODEL, available: false)
    policy.save!

    assert_equal :model_hidden, resolve.refusal
    assert_equal :no_selectable_candidate, resolve(model: "model_selector:chat-walk").refusal

    policy.set_model_availability(TEXT_MODEL, available: true)
    policy.save!
    assert_predicate resolve, :resolved?
  end

  test "an unavailable catalog refuses model_plane_unavailable" do
    ModelCatalog.stub(:current, -> { raise ModelCatalog::Unavailable, "unavailable" }) do
      assert_equal :model_plane_unavailable, resolve.refusal
    end
  end

  test "the resolve path freezes a complete selection" do
    enable_lane
    install_key

    result = resolve

    assert_predicate result, :resolved?
    selection = result.selection
    assert_predicate selection, :frozen?
    assert_equal "test_api", selection.provider_id
    assert_equal "text", selection.model_ref

    profile = selection.execution_profile
    assert_equal "test_api/text@openai_responses", profile.profile_id
    assert_equal "text", profile.model_pin
    assert_equal "api_key", profile.credential_lane
    assert_equal SimpleInference::ApiFormat::WORKLOAD_DEADLINE_SECONDS.fetch("text_generation"),
      profile.total_execution_deadline_seconds
    assert_equal "model_runner", profile.primary_execution_pair.execution_host_kind

    assert_equal 8192, selection.capabilities.limits.input_tokens
    assert_equal %w[image], selection.capabilities.input_modalities
  end

  test "an empty model entry compiles and resolves from its execution profile defaults" do
    enable_lane
    install_key

    Dir.mktmpdir do |override_dir|
      Pathname(override_dir).join("audit.yml").write(<<~YAML)
        schema_version: cybros.model_catalog.v1
        models:
          test_api/audit-empty: {}
      YAML
      candidate = ModelCatalog::FileBase.compile(
        root: Rails.root.join("test/support/model_catalog"), override_dir: override_dir, env: "test"
      )
      snapshot = ModelCatalog::Snapshot.new(
        providers: candidate.providers,
        models: candidate.models,
        selectors: candidate.selectors
      ).freeze

      result = ModelCatalog.stub(:current, snapshot) do
        resolve(model: "test_api/audit-empty")
      end

      assert_predicate result, :resolved?
      selection = result.selection
      profile = selection.execution_profile
      capabilities = selection.capabilities
      assert_equal profile.input_modalities, capabilities.input_modalities
      assert_equal profile.output_modalities, capabilities.output_modalities
      assert_equal profile.local_safety_limits.input_tokens,
        capabilities.limits.input_tokens
      assert_equal profile.generation_parameters.keys.map(&:to_sym).sort,
        capabilities.generation_parameters.keys.sort
    end
  end

  test "a provider-scoped catalog composes only that provider policy" do
    enable_lane
    enable_lane("anthropic")
    applied_providers = []
    apply = ModelCatalog::ModelOverlay.method(:apply)

    catalog = ModelCatalog::ModelOverlay.stub(
      :apply,
      ->(**arguments) do
        applied_providers << arguments.fetch(:policy).provider_id
        apply.call(**arguments)
      end
    ) do
      ModelSelection::Resolver.effective_provider_catalog(
        @account, ModelCatalog.current, "test_api"
      )
    end

    assert_equal ["test_api"], applied_providers
    assert_equal ["test_api"], catalog.policies.keys
  end

  test "reasoning derives the catalog default and refuses out-of-vocabulary efforts" do
    enable_lane
    install_key

    derived = resolve
    assert_predicate derived, :resolved?
    assert_equal "medium", derived.selection.reasoning.effort
    assert derived.selection.reasoning.enabled

    assert_equal :unsupported_reasoning_effort, resolve(effort: "ultra").refusal
  end

  test "an unknown selector refuses and an exhausted candidate walk refuses typed" do
    assert_equal :unknown_model_selector,
      resolve(model: "model_selector:mystery").refusal

    # No provider lane is enabled, so every candidate refuses
    # provider_disabled and the walk exhausts.
    assert_equal :no_selectable_candidate,
      resolve(model: "model_selector:chat-walk").refusal
  end

  test "the selector walk skips gated candidates and freezes the first passing one" do
    enable_lane
    install_key

    result = resolve(model: "model_selector:chat-walk")

    assert_predicate result, :resolved?
    selection = result.selection
    # Candidate 0 (dev) fails provider_disabled; test_api passes every gate.
    assert_equal "test_api", selection.provider_id
    assert_equal "text", selection.model_ref
    assert_equal "chat-walk", selection.submitted.model_selector
    assert_equal "medium", selection.reasoning.effort
  end

  test "an enabled overlay upsert reshapes the effective model and is recorded as evidence" do
    enable_lane
    policy = ModelProviderConfig.find_by!(account: @account, provider_id: "test_api")
    override = ModelCatalog.current.models.fetch(TEXT_MODEL).deep_dup
    override["capabilities"]["limits"]["input_tokens"] = 400_000
    configure_unit
    ModelProviders::UpsertModelOverride.call(
      account: @account, provider_id: "test_api", model_ref: TEXT_MODEL,
      model: override, expected_lock_version: policy.lock_version
    )
    install_key

    result = resolve

    assert_predicate result, :resolved?
    assert_equal 400_000, result.selection.capabilities.limits.input_tokens
  end

  # --- review round pins (2026-08-14): honest reasoning and applied overrides

  test "the deepseek switch disables reasoning while preserving its default effort" do
    enable_lane("deepseek")
    install_key("deepseek")

    result = resolve(model: "deepseek/deepseek-flash", enabled: false)

    assert_predicate result, :resolved?
    reasoning = result.selection.reasoning
    assert_equal "low", reasoning.effort
    refute reasoning.enabled, "the documented disable value must not enable reasoning"
    assert_nil reasoning.mode, "a mode-less lane declares no mode; nothing is invented"
  end

  test "the declared mode vocabulary rides the capability snapshot, never a fabricated selection" do
    enable_lane("openai_api")
    install_key("openai_api")

    selection = resolve(model: "openai_api/gpt-6.1-sol").selection
    assert selection.reasoning.enabled
    # gpt-6.1-sol's row authors `all_turns` as the kernel's own request — it
    # replays every earlier turn's reasoning items — while the vendor's
    # default stays unauthored.
    assert_equal "all_turns", selection.reasoning.context_policy
    # Nothing SELECTS a mode (no submission channel, no reviewed default_mode),
    # so the durable field stays empty while the declared vocabulary rides the
    # capability snapshot — YAML list order can never decide a durable fact.
    assert_nil selection.reasoning.mode
    assert_equal %w[standard pro], selection.capabilities.reasoning_modes
  end

  test "catalog silence on a capability keeps the registry claim instead of manufacturing false" do
    enable_lane("codex_subscription")
    ModelProviders::InstallOAuthPair.call(
      account: @account, provider_id: "codex_subscription",
      access_token: "at-resolver", refresh_token: "rt-resolver",
      lineage_id: SecureRandom.uuid_v7, expected_generation: nil,
      expires_at: 3.hours.from_now
    )

    selection = resolve(model: "codex_subscription/gpt-6.1-sol").selection

    # The shipped fragment writes no streaming line — streaming is the wire's
    # fact — and this lane's wire accepts ONLY streaming: reading that
    # silence as false froze a durable lie.
    assert selection.capabilities.streaming
  end

  test "a default-enabled lane carries its declared default effort" do
    enable_lane("deepseek")
    install_key("deepseek")

    reasoning = resolve(model: "deepseek/deepseek-flash").selection.reasoning

    assert reasoning.enabled, "the lane declares reasoning on by default"
    assert_equal "low", reasoning.effort
    assert_nil reasoning.mode
  end

  test "a switch-only lane without explicit enablement defaults on" do
    enable_lane
    install_key
    stripped = ModelCatalog.current.models.fetch(TEXT_MODEL).deep_dup
    stripped["capabilities"]["reasoning"] = { "disable_supported" => true }
    models = ModelCatalog.current.models.merge(TEXT_MODEL => stripped)

    ModelCatalog::ModelOverlay.stub(:apply, ->(**) { ModelCatalog::ModelOverlay::Result.new(models: models, hidden_models: [], unavailable_models: []) }) do
      reasoning = resolve.selection.reasoning
      assert reasoning.enabled
      assert_nil reasoning.effort
    end
  end

  # --- class pins (2026-08-14 flow re-examination) ---------------------------

  test "a model whose catalog declares no reasoning freezes a not-selected value, never a false claim" do
    enable_lane
    install_key
    silent = ModelCatalog.current.models.fetch(TEXT_MODEL).deep_dup
    silent["capabilities"].delete("reasoning")
    models = ModelCatalog.current.models.merge(TEXT_MODEL => silent)

    reasoning = ModelCatalog::ModelOverlay.stub(:apply, ->(**) { ModelCatalog::ModelOverlay::Result.new(models: models, hidden_models: [], unavailable_models: []) }) do
      resolve.selection.reasoning
    end

    # nil is "Nexus selected nothing; the provider default governs" — false
    # would be a claim about the provider that catalog silence cannot support.
    assert_nil reasoning.enabled
    assert_nil reasoning.effort
  end

  # The one derivation is shared with compile-time selector validation, so a
  # candidate the catalog compiler accepts always resolves, for EVERY shipped
  # text model — this is the drift the two copies produced.
  test "compile-time selector validation and accept-time resolution never disagree" do
    enable_lane
    enable_lane("deepseek")
    install_key
    install_key("deepseek")
    snapshot = ModelCatalog.current

    snapshot.models.each do |model_ref, entry|
      provider = snapshot.providers.fetch(model_ref.split("/", 2).first)
      format = entry["api_format"] || provider["api_format"]
      next unless SimpleInference::ApiFormat.workload(format) == "text_generation"

      _value, refusal = Nexus::EffectiveReasoning.derive(
        entry.dig("capabilities", "reasoning"), nil
      )
      next if refusal

      # The compiler accepts an effort-less candidate here, so resolution must
      # not refuse it for a reasoning reason.
      result = resolve(model: model_ref)
      next if result.resolved?

      refute_includes %i[missing_reasoning_effort unsupported_reasoning_effort], result.refusal,
        "#{model_ref} compiles as a selector candidate but refuses at accept time"
    end
  end
end
