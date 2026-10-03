require "test_helper"

# The plain OpenAI-compatible translator's own identity. Everything here is
# deterministic: no live call or credential.
class TestOpenAICompatibleIdentity < Minitest::Test
  ADAPTER_PROFILE = "openai_compatible_chat".freeze

  class UnreachableAdapter < SimpleInference::HTTPAdapter
    def call(_env) = raise "validation is stateless: no request may be emitted"
    def call_stream(_env) = raise "validation is stateless: no request may be emitted"
  end

  def config
    SimpleInference::Config.new(base_url: "http://example.com", adapter: UnreachableAdapter.new)
  end

  def test_the_identity_is_addressable_everywhere_a_lane_needs_to_be
    assert SimpleInference::ApiFormat::PROTOCOL_CLASSES.fetch(ADAPTER_PROFILE)
             .equal?(SimpleInference::Protocols::OpenAICompatibleResponses)
    assert_includes SimpleInference::ExecutionProfile::ADAPTER_PROFILES, ADAPTER_PROFILE
  end

  # A third-party OpenAI-compatible host can now be declared as an ordinary
  # audited row — the registry ships none yet, but the shape validates.
  def test_a_third_party_compatible_host_row_validates
    profile = SimpleInference::ExecutionProfile.new(
      profile_id: "examplehost.openai_compatible_chat.text_generation.v1",
      provider_id: "examplehost",
      adapter_profile: ADAPTER_PROFILE,
      protocol_route: "chat_completions_http_sse",
      workload: "text_generation",
      model_pin: "example-model",
      credential_lane: "api_key",
      total_execution_deadline_seconds: 600,
      primary_execution_pair: SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR,
      allowed_execution_pairs: [SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR],
      capabilities: %w[streaming],
      output_modalities: %w[text],
      local_safety_limits: { input_tokens: 8_192, output_tokens: 2_048 },
    )

    assert_equal ADAPTER_PROFILE, profile.adapter_profile
    built = SimpleInference::ApiFormat.protocol_for(profile: profile, config: config)
    assert_instance_of SimpleInference::Protocols::OpenAICompatibleResponses, built
  end
end
