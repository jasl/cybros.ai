$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "simple_inference"

require "minitest/autorun"

# Profile values for unit tests. A profile is COMPOSED, not looked up — the
# gem ships no model rows — so the tests compose their own the same way a
# consumer does: take the format's defaults and state the handful of facts
# that belong to the model being exercised.
module TestProfiles
  DEFAULTS = {
    profile_id: "openai_api.openai_responses.text_generation.v1",
    provider_id: "openai_api",
    adapter_profile: "openai_responses",
    protocol_route: "responses_http_sse",
    workload: "text_generation",
    model_pin: "gpt-6-sol",
    credential_lane: "api_key",
    total_execution_deadline_seconds: 600,
    primary_execution_pair: SimpleInference::ExecutionProfile::MODEL_RUNNER_ASYNC_HTTP_PAIR,
    allowed_execution_pairs: SimpleInference::ExecutionProfile::EXECUTION_PAIRS,
    capabilities: %w[streaming tool_calls conversation_state provider_builtin_tools reasoning],
    input_modalities: %w[image],
    wire_options: { responses_path: "/v1/responses" },
  }.freeze

  def build_execution_profile(**overrides)
    SimpleInference::ExecutionProfile.new(**DEFAULTS.merge(overrides))
  end

  # The consumer-side composition, in miniature: the wire's defaults plus an
  # identity. Tests that exercise a specific wire build from this so they
  # inherit exactly what a deployment naming that format would inherit.
  def profile_for(format, provider_id: "test_provider", model_pin: "test-model", **overrides)
    defaults = SimpleInference::ApiFormat.defaults(format)
    workload = SimpleInference::ApiFormat.workload(format)
    SimpleInference::ExecutionProfile.new(
      **defaults,
      profile_id: "#{provider_id}/#{model_pin}@#{format}",
      provider_id: provider_id,
      adapter_profile: format,
      workload: workload,
      model_pin: model_pin,
      credential_lane: "api_key",
      # The wire's media bounds apply to what the MODEL accepts, so a test
      # profile that states no modality carries no bounds either.
      input_modalities: Hash(defaults[:input_media]).keys,
      total_execution_deadline_seconds: SimpleInference::ApiFormat.deadline_seconds(workload),
      **overrides
    )
  end
end

# Every test may compose a profile; none may look one up.
Minitest::Test.include(TestProfiles)
