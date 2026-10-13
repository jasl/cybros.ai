require "json"
require "test_helper"
require "gemini_protocol_helpers"

class TestGeminiUsage < Minitest::Test
  include GeminiProtocolHelpers

  # --- usage presence-vs-zero and non-coercion (C3) ---
  # An ABSENT candidatesTokenCount keeps output_tokens absent: thoughts alone
  # never fabricate an output count. A summand that IS on the wire contributes
  # only when it is a nonnegative Integer. Bad accounting metadata is omitted
  # from canonical usage; it never discards an otherwise valid answer.

  def test_absent_candidates_token_count_keeps_output_tokens_absent_even_with_thoughts
    adapter = usage_metadata_adapter(promptTokenCount: 2, thoughtsTokenCount: 4, totalTokenCount: 6)
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.5-flash", input: "Hello")

    refute result.usage.key?("output_tokens"),
           "thoughtsTokenCount alone must never fabricate output_tokens"
    assert_equal 4, result.usage.fetch("reasoning_tokens")
  end

  def test_non_integer_candidates_token_count_is_omitted_without_discarding_output
    adapter = usage_metadata_adapter(promptTokenCount: 2, candidatesTokenCount: "3", totalTokenCount: 5)
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.5-flash", input: "Hello")

    assert_equal "ok", result.output_text
    assert_equal 2, result.usage.fetch("input_tokens")
    assert_equal 5, result.usage.fetch("total_tokens")
    refute result.usage.key?("output_tokens")
    assert_equal "3", result.provider_response.body.dig("usageMetadata", "candidatesTokenCount")
  end

  def test_non_integer_thoughts_token_count_is_omitted_without_discarding_output
    adapter = usage_metadata_adapter(promptTokenCount: 2, candidatesTokenCount: 3, thoughtsTokenCount: "4", totalTokenCount: 9)
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.5-flash", input: "Hello")

    assert_equal "ok", result.output_text
    assert_equal 3, result.usage.fetch("output_tokens"),
                 "the valid candidate count survives a bad auxiliary thoughts count"
    refute result.usage.key?("reasoning_tokens")
    assert_equal "4", result.provider_response.body.dig("usageMetadata", "thoughtsTokenCount")
  end

  def test_stream_bad_auxiliary_usage_still_completes_with_provider_output
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          payload = {
            candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
            usageMetadata: {
              promptTokenCount: 2,
              candidatesTokenCount: 3,
              thoughtsTokenCount: "bad",
              totalTokenCount: 5,
            },
          }
          yield "data: #{JSON.generate(payload)}\n\n"
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    result = gemini_protocol(adapter: adapter)
             .stream(model: "gemini-3.5-flash", input: "Hello")
             .final_result

    assert_equal "ok", result.output_text
    assert_equal 3, result.usage.fetch("output_tokens")
    refute result.usage.key?("reasoning_tokens")
  end

  # --- gemini_generate_content.usage.v1 conformance (deterministic
  # constructions built from the register's wire matrix — NOT wire captures;
  # the 2026-08-09 probe truth they encode lives in the frozen register). ---

  # Per-chunk snapshot progression: usageMetadata rides every chunk and each
  # snapshot REPLACES the previous one; the final chunk is authoritative.
  def test_stream_usage_snapshots_replace_per_chunk_and_final_chunk_wins
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hel" }] } }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 2, totalTokenCount: 9 } })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "lo" }] }, finishReason: "STOP" }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 110, totalTokenCount: 117 } })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal 7, result.usage.fetch("input_tokens")
    assert_equal 110, result.usage.fetch("output_tokens")
    assert_equal 117, result.usage.fetch("total_tokens")
  end

  # No usage destruction: a terminal chunk WITHOUT usageMetadata must not wipe
  # the last snapshot an earlier chunk carried (deterministic construction).
  def test_stream_retains_last_usage_snapshot_when_terminal_chunk_lacks_usage_metadata
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hello" }] } }], usageMetadata: { promptTokenCount: 7, candidatesTokenCount: 5, totalTokenCount: 12 } })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "!" }] }, finishReason: "STOP" }] })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    refute_nil result.usage, "the last usageMetadata snapshot must survive a bare terminal chunk"
    assert_equal 7, result.usage.fetch("input_tokens")
    assert_equal 12, result.usage.fetch("total_tokens")
  end

  # Modality-detail rows and serviceTier are bounded evidence: IMAGE/AUDIO
  # rows promote to canonical subcounts, every row plus serviceTier and
  # toolUsePromptTokenCount is retained verbatim, and nothing is fabricated.
  def test_usage_retains_modality_detail_rows_and_service_tier_as_bounded_evidence
    prompt_tokens_details = [
      { "modality" => "TEXT", "tokenCount" => 4 },
      { "modality" => "IMAGE", "tokenCount" => 258 },
      { "modality" => "AUDIO", "tokenCount" => 32 },
      { "modality" => "VIDEO", "tokenCount" => 99 },
    ]
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: {
                promptTokenCount: 393,
                candidatesTokenCount: 3,
                totalTokenCount: 396,
                promptTokensDetails: prompt_tokens_details,
                toolUsePromptTokenCount: 11,
                serviceTier: "standard",
              },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal 258, result.usage.fetch("image_input_tokens")
    assert_equal 32, result.usage.fetch("audio_input_tokens")
    assert_equal prompt_tokens_details, result.usage.fetch("promptTokensDetails")
    assert_equal "standard", result.usage.fetch("serviceTier")
    assert_equal 11, result.usage.fetch("toolUsePromptTokenCount")
    refute result.usage.key?("video_input_tokens"), "VIDEO has no canonical subcount — bounded evidence only"
  end

  # Presence-vs-zero: a field absent on the wire stays absent — the parser
  # never fabricates a 0 (deterministic construction).
  def test_usage_preserves_presence_versus_zero
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: { promptTokenCount: 5, totalTokenCount: 5 },
            }
          ),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal 5, result.usage.fetch("input_tokens")
    refute result.usage.key?("output_tokens"), "absent candidatesTokenCount must not become 0"
    refute result.usage.key?("reasoning_tokens")
    refute result.usage.key?("cache_read_input_tokens")
    refute result.usage.key?("serviceTier")
  end

  private

  # Terminal body whose usageMetadata is exactly the given fields — used to
  # pin presence-vs-zero and non-coercion at the parse seam.
  def usage_metadata_adapter(**usage_metadata)
    Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            {
              candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "STOP" }],
              usageMetadata: usage_metadata,
            }
          ),
        }
      end
    end.new
  end
end
