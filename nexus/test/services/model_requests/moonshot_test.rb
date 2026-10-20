require "test_helper"

class ModelRequests::MoonshotTest < ActiveSupport::TestCase
  MODELS = %w[kimi-k3 kimi-k2.6 kimi-k2.7-code kimi-k2.7-code-highspeed].freeze

  setup do
    @account = accounts(:cybros)
    result = ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "moonshot", api_key: "moonshot-test-material"
    )
    assert_predicate result, :done?
    enabled = ModelProviders::EnableLane.call(
      account: @account, provider_id: "moonshot", expected_lock_version: nil
    )
    assert_predicate enabled, :done?
  end

  test "the platform exposes four independent model ids and their own windows" do
    rows = ModelCatalog.current.models.keys.grep(%r{\Amoonshot/})
    assert_equal MODELS.map { "moonshot/#{_1}" }.sort, rows.sort

    MODELS.each do |model|
      profile = DevModelLane.profile_for("moonshot/#{model}")
      limit = model == "kimi-k3" ? 1_048_576 : 262_144

      assert_equal model, profile.model_pin
      assert_equal "moonshot", profile.provider_id
      assert_equal "openai_compatible_chat", profile.adapter_profile
      assert_equal %w[image], profile.input_modalities
      assert_equal limit, profile.local_safety_limits.combined_input_output_tokens
      assert_equal limit, profile.local_safety_limits.output_tokens
      assert_equal limit, profile.generation_parameters.fetch("max_output_tokens").maximum
      assert_equal "chat_reasoning", ModelCatalog.current.models.fetch("moonshot/#{model}").dig("capabilities", "reasoning_replay", "format")
    end
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: "kimi_code")
    assert_not ModelProviderConfig.exists?(account: @account, provider_id: "kimi_code")
  end

  test "K3 sends its efforts without a thinking switch even when disabling is requested" do
    [nil, "high", "max"].each do |effort|
      body = payload("kimi-k3", effort: effort)

      assert_equal effort || "low", body.fetch("reasoning_effort")
      assert_not body.key?("thinking")
    end
    assert_equal "low", payload("kimi-k3", enabled: false).fetch("reasoning_effort")
  end

  test "K2.6 opts into preserved thinking and can independently disable reasoning" do
    body = payload("kimi-k2.6")
    assert_equal({ "type" => "enabled", "keep" => "all" }, body.fetch("thinking"))
    assert_not body.key?("reasoning_effort")

    body = payload("kimi-k2.6", enabled: false)
    assert_equal({ "type" => "disabled" }, body.fetch("thinking"))
    assert_not body.key?("reasoning_effort")
    assert_nil DevModelLane.profile_for("kimi_code/kimi-for-coding").wire_option(:thinking_keep)
  end

  test "both K2.7 speeds always reason without sending unsupported controls" do
    %w[kimi-k2.7-code kimi-k2.7-code-highspeed].each do |model|
      [nil, false].each do |enabled|
        body = payload(model, enabled: enabled)
        assert_not body.key?("thinking")
        assert_not body.key?("reasoning_effort")
      end
    end
  end

  test "each platform model prices its own cache and output counts independently of the subscription" do
    tokens = UsageRecords::Tokens.read({
      "prompt_tokens" => 1_000_000, "completion_tokens" => 100_000,
      "prompt_tokens_details" => { "cached_tokens" => 200_000, "cache_write_tokens" => 100_000 },
      "completion_tokens_details" => { "reasoning_tokens" => 60_000 },
    }, adapter_profile: "openai_compatible_chat")
    expected = { "kimi-k3" => "3.96", "kimi-k2.6" => "1.192",
                 "kimi-k2.7-code" => "1.198", "kimi-k2.7-code-highspeed" => "2.396" }

    expected.each do |model, amount|
      pricing = ModelCatalog::EffectivePricing.project(
        entry: ModelCatalog.current.models.fetch("moonshot/#{model}"), account_unit: "USD"
      )
      assert_predicate pricing, :priced?
      assert_equal BigDecimal(amount), UsageRecords::Pricing.formula(
        tokens: tokens, rates: pricing.rates, tier_multipliers: pricing.tier_multipliers, service_tier: nil
      ), model
    end
    subscription = ModelCatalog::EffectivePricing.project(
      entry: ModelCatalog.current.models.fetch("kimi_code/kimi-for-coding"), account_unit: "USD"
    )
    assert_predicate subscription, :unmetered?
  end

  private

    def payload(model, effort: nil, enabled: nil)
      ref = "moonshot/#{model}"
      command = InferenceRequests::Create::Command.new(
        workspace: workspaces(:shared), creating_user: users(:member), workload: "text_generation",
        submitted: Nexus::SubmittedModelSelection.new(model: ref,
          reasoning_effort: effort, reasoning_enabled: enabled),
        configuration: { "max_output_tokens" => 128 },
        input: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "hello" }] }],
        upload_public_ids: [], billing_subject: nil, idempotency_key: SecureRandom.uuid
      )
      accepted = InferenceRequests::Create.call(command: command, port: ModelSelection::Resolver.new)
      assert_predicate accepted, :created?, accepted.refusal.inspect
      invocation = InferenceRequest.find_by!(public_id: accepted.accepted.fetch("inference_request_public_id")).model_invocation
      built = ModelRequests::Build.call(
        invocation: invocation, profile: DevModelLane.profile_for(ref),
        base_url: ModelCatalog.provider_base_url("moonshot"), host: "solid_queue"
      )
      assert_predicate built, :built?, built.refusal.inspect
      assert_predicate built.request, :stream?
      assert_equal "/v1/chat/completions", built.request.path
      JSON.parse(built.request.payload).tap do |body|
        assert_equal model, body.fetch("model")
        assert_equal 128, body.fetch("max_tokens")
        assert_equal true, body.dig("stream_options", "include_usage")
      end
    end
end
