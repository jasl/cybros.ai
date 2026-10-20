require "test_helper"

class ModelRequests::KimiCodeTest < ActiveSupport::TestCase
  MODEL = "kimi_code/kimi-for-coding".freeze

  setup do
    @account = accounts(:cybros)
    result = ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "kimi_code", api_key: "kimi-test-material"
    )
    assert_predicate result, :done?
    enabled = ModelProviders::EnableLane.call(
      account: @account, provider_id: "kimi_code", expected_lock_version: nil
    )
    assert_predicate enabled, :done?
  end

  test "the coding subscription exposes its own model window, vision and native replay" do
    profile = DevModelLane.profile_for(MODEL)

    assert_equal "kimi-for-coding", profile.model_pin
    assert_equal "openai_compatible_chat", profile.adapter_profile
    assert_equal "api_key", profile.credential_lane
    assert_equal %w[image], profile.input_modalities
    assert_equal 1_048_576, profile.local_safety_limits.combined_input_output_tokens
    assert_equal 32_768, profile.local_safety_limits.output_tokens
    assert_equal 32_768, profile.generation_parameters.fetch("max_output_tokens").maximum
    assert_equal "chat_reasoning", ModelCatalog.current.models.fetch(MODEL).dig("capabilities", "reasoning_replay", "format")
    assert_nil ModelCatalog.current.models.fetch(MODEL)["pricing"]
  end

  test "accepted Kimi requests compile the default, selected efforts and disabled thinking" do
    [nil, "high", "max"].each do |effort|
      request = compile(effort: effort)
      body = JSON.parse(request.payload)

      assert_predicate request, :stream?
      assert_equal "/v1/chat/completions", request.path
      assert_equal "kimi-for-coding", body.fetch("model")
      assert_equal({ "type" => "enabled" }, body.fetch("thinking"))
      assert_equal effort || "low", body.fetch("reasoning_effort")
      assert_equal 128, body.fetch("max_tokens")
      assert_equal [{ "type" => "text", "text" => "hello" }], body.fetch("messages").sole.fetch("content")
    end

    body = JSON.parse(compile(enabled: false).payload)
    assert_equal({ "type" => "disabled" }, body.fetch("thinking"))
    assert_not body.key?("reasoning_effort")
  end

  test "developer instructions become system messages in place on the coding wire" do
    input = [
      ["system", "Base instructions."], ["developer", "Environment."],
      ["user", "First question."], ["assistant", "First answer."],
      ["developer", "Updated environment."], ["user", "Next question."],
    ].map { |role, text| { "role" => role, "parts" => [{ "type" => "text", "text" => text }] } }
    messages = JSON.parse(compile(input: input).payload).fetch("messages")

    assert_equal %w[system system user assistant system user], messages.map { |message| message.fetch("role") }
    assert_equal input.map { |message| message.dig("parts", 0, "text") },
      messages.map { |message| message.dig("content", 0, "text") }
    assert_equal %w[system developer user assistant developer user], input.map { |message| message.fetch("role") }
  end

  private

    def compile(effort: nil, enabled: nil, input: nil)
      command = InferenceRequests::Create::Command.new(
        workspace: workspaces(:shared), creating_user: users(:member), workload: "text_generation",
        submitted: Nexus::SubmittedModelSelection.new(model: MODEL,
          reasoning_effort: effort, reasoning_enabled: enabled),
        configuration: { "max_output_tokens" => 128 },
        input: input || [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "hello" }] }],
        upload_public_ids: [], billing_subject: nil, idempotency_key: SecureRandom.uuid
      )
      accepted = InferenceRequests::Create.call(command: command, port: ModelSelection::Resolver.new)
      assert_predicate accepted, :created?, accepted.refusal.inspect
      inference_request = InferenceRequest.find_by!(public_id: accepted.accepted.fetch("inference_request_public_id"))
      built = ModelRequests::Build.call(
        invocation: inference_request.model_invocation, profile: DevModelLane.profile_for(MODEL),
        base_url: ModelCatalog.provider_base_url("kimi_code"), host: "solid_queue"
      )
      assert_predicate built, :built?, built.refusal.inspect
      built.request
    end
end
