require "test_helper"

class ModelCatalog::OutputTokenControlsTest < ActiveJob::TestCase
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
    @account.reload
    %w[openai_api gemini deepseek xai openrouter].each do |provider|
      ModelProviders::SetAPIKey.call(account: @account, provider_id: provider, api_key: "test-only-key")
      ModelProviders::EnableLane.call(account: @account, provider_id: provider, expected_lock_version: nil)
    end
  end

  test "every shipped adapted API text model accepts an explicit output cap and omission keeps its provider default" do
    shipped = ModelCatalog::FileBase.compile(root: Rails.root.join("config/model_catalog"), override_dir: nil)
    refs = shipped.models.keys.select do |ref|
      %w[openai_api gemini deepseek xai openrouter].include?(ref.split("/", 2).first) &&
        DevModelLane.profile_for(ref).workload == "text_generation"
    end
    assert_equal 21, refs.length
    refs.each do |ref|
      explicit = resolve(ref, max_output_tokens: 512)
      assert_predicate explicit, :resolved?, "#{ref}: #{explicit.refusal}"
      assert_equal 512, explicit.selection.generation_config.to_h.fetch("max_output_tokens"), ref
      assert_equal :invalid_generation_parameter, resolve(ref, max_output_tokens: 0).refusal, ref
      assert_equal :invalid_generation_parameter, resolve(ref, max_output_tokens: "512").refusal, ref
      omitted = resolve(ref)
      assert_predicate omitted, :resolved?, ref
      assert_not omitted.selection.generation_config.to_h.key?("max_output_tokens"), ref
      maximum = explicit.selection.capabilities.generation_parameters.fetch(:max_output_tokens).maximum
      if maximum
        assert_predicate resolve(ref, max_output_tokens: maximum), :resolved?, ref
        assert_equal :invalid_generation_parameter, resolve(ref, max_output_tokens: maximum + 1).refusal, ref
      end
    end
  end

  test "each provider lowers the accepted cap onto its native wire and sends no invented default" do
    {
      "openai_api/gpt-6-luna" => ["max_output_tokens"],
      "gemini/gemini-3.8-flash" => %w[generationConfig maxOutputTokens],
      "deepseek/deepseek-flash" => ["max_output_tokens"],
      "xai/grok-4.7" => ["max_output_tokens"],
      "openrouter/google/gemini-3.7-flash:exacto" => ["max_tokens"],
    }.each do |ref, path|
      assert_equal 512, build_payload(resolve(ref, max_output_tokens: 512).selection).dig(*path), ref
      assert_nil build_payload(resolve(ref).selection).dig(*path), ref
    end
  end

  test "direct-provider output caps retain documented bounds rather than rounded context figures" do
    {
      "openai_api/gpt-6-astra" => 128_000,
      "openai_api/gpt-6.1-sol" => 128_000,
      "openai_api/gpt-6-luna" => 128_000,
      "gemini/gemini-3.8-flash" => 65_536,
      "deepseek/deepseek-flash" => 393_216,
      "deepseek/deepseek-v4-pro" => 393_216,
    }.each do |ref, cap|
      selection = resolve(ref).selection
      assert_equal cap, selection.capabilities.generation_parameters.fetch(:max_output_tokens).maximum, ref
      assert_equal cap, selection.capabilities.limits.output_tokens, ref
    end
    %w[deepseek/deepseek-flash deepseek/deepseek-v4-pro].each do |ref|
      assert_equal 1_048_576, resolve(ref).selection.capabilities.limits.input_token_bound, ref
    end
  end

  test "Codex subscription still rejects a requested output cap" do
    ModelProviders::EnableLane.call(account: @account, provider_id: "codex_subscription", expected_lock_version: nil)
    ModelProviders::InstallOAuthPair.call(account: @account, provider_id: "codex_subscription",
      access_token: "test-only-access", refresh_token: "test-only-refresh", lineage_id: SecureRandom.uuid_v7,
      expected_generation: nil, expires_at: 3.hours.from_now)
    %w[gpt-6-astra gpt-6.1-sol gpt-6-luna].each do |model|
      ref = "codex_subscription/#{model}"
      assert_predicate resolve(ref), :resolved?, ref
      assert_equal :unsupported_generation_parameter, resolve(ref, max_output_tokens: 512).refusal, ref
      assert_not DevModelLane.profile_for(ref).generation_parameters.key?("max_output_tokens"), ref
    end
  end

  test "OpenAI Responses rejects a cap below its protocol minimum instead of spending a request" do
    %w[gpt-6-astra gpt-6.1-sol gpt-6-luna].each do |model|
      ref = "openai_api/#{model}"
      assert_equal :invalid_generation_parameter, resolve(ref, max_output_tokens: 15).refusal, ref
      result = resolve(ref, max_output_tokens: 16)
      assert_predicate result, :resolved?, ref
      assert_equal 16, build_payload(result.selection).fetch("max_output_tokens"), ref
    end
  end

  test "Gemini 3.8 is the native model and its thinking vocabulary excludes minimal" do
    assert_equal :unknown_model, resolve("gemini/gemini-3.7-flash").refusal
    assert_equal :unsupported_reasoning_effort, resolve("gemini/gemini-3.8-flash", effort: "minimal").refusal
    %w[low medium high].each do |effort|
      result = resolve("gemini/gemini-3.8-flash", effort: effort)
      assert_predicate result, :resolved?
      body = build_payload(result.selection)
      assert_equal effort, body.dig("generationConfig", "thinkingConfig", "thinkingLevel")
    end
  end

  test "xAI's optional cap has no invented hard maximum and its input planning and admission remain bounded" do
    %w[xai/grok-4.6 xai/grok-4.7].each do |ref|
      selection = resolve(ref, max_output_tokens: 128_001).selection
      assert_nil selection.capabilities.generation_parameters.fetch(:max_output_tokens).maximum
      assert_nil selection.capabilities.limits.output_tokens
      assert_equal 500_000, selection.capabilities.limits.input_token_bound
      assert_equal 199_999, selection.capabilities.limits.planning_input_bound
      assert_equal 128_001, build_payload(selection).fetch("max_output_tokens")
      attempt = admitted_attempt(model: ref)
      assert_equal "prepared", attempt.status
      assert_equal "running", attempt.model_invocation.status
    end
  end

  private

    def resolve(ref, effort: nil, **configuration)
      DevModelLane.resolve(workload: "text_generation", account: @account,
        model: ref, reasoning_effort: effort, configuration: configuration)
    end

    def build_payload(selection)
      inference_request = InferenceRequest.create!(account: @account, workspace: workspaces(:shared),
        creating_user: @human, workload: "text_generation")
      invocation = DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
      stored = ContentBodies::Replace.call(owner: invocation, role: "request",
        entries: Nexus::InputEntries.for("Say hello"), seal: true)
      assert_predicate stored, :accepted?
      built = ModelRequests::Build.call(invocation: invocation, profile: selection.execution_profile,
        base_url: "https://example.test", host: "solid_queue")
      assert_predicate built, :built?, built.refusal.inspect
      JSON.parse(built.request.payload)
    end
end
