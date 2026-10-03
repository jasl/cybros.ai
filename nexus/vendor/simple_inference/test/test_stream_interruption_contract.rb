require "json"
require "test_helper"

# A provider-STARTED stream (HTTP 2xx, SSE) that ends WITHOUT its lane's
# terminal event is one shared typed failure. Every streaming lane must raise
# SimpleInference::ProviderStreamInterruptedError from that path.
#
# All SSE bodies below are DETERMINISTIC CONSTRUCTIONS of truncated streams
# (no terminal event) — none is a wire capture.
class TestStreamInterruptionContract < Minitest::Test
  SLUG = "amazon-bedrock/test-full-endpoint-slug".freeze

  # One row per streaming lane: the adapter profile the register names, a
  # protocol builder, and a truncated SSE body that STARTS the stream (at
  # least one event arrives) but ends before the lane's terminal
  # (response.completed/incomplete/failed, message_stop, finishReason,
  # finish_reason chunk + [DONE]).
  LANES = [
    {
      adapter_profile: "openai_responses",
      sse: %(data: {"type":"response.output_text.delta","delta":"par"}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::OpenAIResponses.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
      },
    },
    {
      adapter_profile: "codex_responses",
      sse: %(data: {"type":"response.output_text.delta","delta":"par"}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::CodexResponses.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
      },
    },
    {
      adapter_profile: "deepseek_responses",
      sse: %(data: {"type":"response.output_text.delta","delta":"par"}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::DeepSeekResponses.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
      },
    },
    {
      adapter_profile: "xai_responses",
      sse: %(data: {"type":"response.output_text.delta","delta":"par"}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::XAIResponses.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
      },
    },
    {
      adapter_profile: "anthropic_messages",
      # max_tokens is a required Messages field (F1, 2026-09-16).
      options: { max_output_tokens: 4096 },
      sse: %(event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}\n\n) +
           %(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"par"}}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::AnthropicMessages.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
      },
    },
    {
      adapter_profile: "gemini_generate_content",
      sse: %(data: {"candidates":[{"content":{"parts":[{"text":"par"}],"role":"model"}}]}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::GeminiGenerateContent.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)
      },
    },
    {
      adapter_profile: "openrouter_chat",
      sse: %(data: {"choices":[{"delta":{"content":"par"},"finish_reason":null}]}\n\n),
      build: ->(adapter) {
        SimpleInference::Protocols::OpenRouterResponses.new(
          base_url: "http://example.com", api_key: "secret", adapter: adapter,
          stream_include_usage: false
        )
      },
    },
  ].freeze

  def test_every_streaming_lane_raises_the_shared_typed_interruption
    LANES.each do |lane|
      profile = lane.fetch(:adapter_profile)
      protocol = lane.fetch(:build).call(truncated_sse_adapter(lane.fetch(:sse)))

      error =
        assert_raises(SimpleInference::ProviderStreamInterruptedError, "#{profile}: truncated stream must raise the shared typed interruption") do
          protocol.stream(model: "test-model", input: "Hello", **lane.fetch(:options, {})).final_result
        end

      assert_operator error.events_seen, :>=, 1
    end
  end

  # The typed error carries adapter-observable diagnostics — how far the
  # stream got before it broke off — as evidence, never classification input.
  def test_interruption_error_carries_events_seen_diagnostics
    lane = LANES.fetch(0)
    protocol = lane.fetch(:build).call(truncated_sse_adapter(lane.fetch(:sse)))

    error =
      assert_raises(SimpleInference::ProviderStreamInterruptedError) do
        protocol.stream(model: "test-model", input: "Hello", **lane.fetch(:options, {})).final_result
      end

    assert_equal 1, error.events_seen
    assert_equal "response.output_text.delta", error.last_event_type
  end

  private

  def truncated_sse_adapter(sse)
    Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call_stream) do |_env, &on_chunk|
        on_chunk.call(sse)
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
  end
end
