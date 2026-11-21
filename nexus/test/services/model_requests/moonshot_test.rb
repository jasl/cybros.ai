require "test_helper"

class ModelRequests::MoonshotTest < ActiveSupport::TestCase
  PRO_MODELS = %w[kimi-k3.1-pro kimi-k3.1-pro-highspeed].freeze

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

  test "the China platform exposes both K3.1 Pro model IDs with a shared one-million-token window" do
    rows = ModelCatalog.current.models.keys.grep(%r{\Amoonshot/})
    assert_equal PRO_MODELS.map { "moonshot/#{_1}" }.sort, rows.sort

    PRO_MODELS.each do |model|
      profile = DevModelLane.profile_for("moonshot/#{model}")

      assert_equal model, profile.model_pin
      assert_equal "moonshot", profile.provider_id
      assert_equal "openai_compatible_chat", profile.adapter_profile
      assert_equal %w[image], profile.input_modalities
      assert_equal 1_048_576, profile.local_safety_limits.combined_input_output_tokens
      replay = ModelCatalog.current.models.fetch("moonshot/#{model}").fetch("capabilities").fetch("reasoning_replay")
      assert_equal "chat_reasoning", replay.fetch("format")
      assert replay.fetch("required_for_tool_rounds")
    end
    assert_not ModelProviderCredential.exists?(account: @account, provider_id: "kimi_code")
    assert_not ModelProviderConfig.exists?(account: @account, provider_id: "kimi_code")
  end

  test "an explicit output cap is unavailable on the China platform" do
    PRO_MODELS.each do |model|
      ref = "moonshot/#{model}"
      assert_nil DevModelLane.profile_for(ref).local_safety_limits.output_tokens
      selection = DevModelLane.resolve(workload: "text_generation", account: @account,
        model: ref, configuration: { max_output_tokens: 128 })
      assert_equal :unsupported_generation_parameter, selection.refusal, ref
    end
  end

  test "both K3.1 Pro speeds default to max and honor explicit reasoning efforts" do
    PRO_MODELS.each do |model|
      [nil, "low", "high", "max"].each do |effort|
        body = payload(model, effort: effort)
        assert_equal effort || "max", body.fetch("reasoning_effort")
        assert_not body.key?("thinking")
        assert_not body.key?("max_tokens")
      end
      body = payload(model, enabled: false)
      assert_equal "max", body.fetch("reasoning_effort")
      assert_not body.key?("thinking")
    end
  end

  test "both regional API speeds and the coding subscription can run without a catalog price" do
    %w[moonshot/kimi-k3.1-pro moonshot/kimi-k3.1-pro-highspeed moonshot_global/kimi-k3.1-pro
      moonshot_global/kimi-k3.1-pro-highspeed kimi_code/k3.1-pro kimi_code/k3.1-pro-highspeed].each do |ref|
      pricing = ModelCatalog::EffectivePricing.project(entry: ModelCatalog.current.models.fetch(ref), account_unit: "USD")
      assert_predicate pricing, :unmetered?, ref
    end
  end

  private

    def payload(model, effort: nil, enabled: nil)
      ref = "moonshot/#{model}"
      command = InferenceRequests::Create::Command.new(
        workspace: workspaces(:shared), creating_user: users(:member), workload: "text_generation",
        submitted: Nexus::SubmittedModelSelection.new(model: ref,
          reasoning_effort: effort, reasoning_enabled: enabled),
        configuration: {},
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
        assert_equal true, body.dig("stream_options", "include_usage")
      end
    end
end
