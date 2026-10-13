require "json"
require "test_helper"

# Authored HTTP/SSE responses from the documented FinishReason semantics,
# not live provider captures: https://ai.google.dev/api/generate-content#FinishReason
class TestGeminiFinishErrors < Minitest::Test
  REASONS = %w[OTHER NO_IMAGE IMAGE_OTHER MALFORMED_FUNCTION_CALL UNEXPECTED_TOOL_CALL
               TOO_MANY_TOOL_CALLS MISSING_THOUGHT_SIGNATURE MALFORMED_RESPONSE].freeze

  class Adapter < SimpleInference::HTTPAdapter
    def initialize(reason)
      @reason = reason
    end

    def call(_env)
      { status: 200, headers: { "content-type" => "application/json" },
        body: JSON.generate(partial.merge("candidates" => [{ "finishReason" => @reason }])) }
    end

    def call_stream(_env)
      yield "data: #{JSON.generate(partial)}\n\n"
      yield "data: #{JSON.generate("candidates" => [{ "finishReason" => @reason }])}\n\n"
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end

    private

      def partial
        { "candidates" => [{ "content" => { "parts" => [{ "text" => "partial" }] } }],
          "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 4, "totalTokenCount" => 7 } }
      end
  end

  def test_empty_unary_candidates_and_partial_streams_preserve_error_finish_and_usage
    REASONS.each do |reason|
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "test-only", adapter: Adapter.new(reason)
      )
      unary = protocol.create(model: "gemini-3.8-flash", input: "Hello")
      stream = protocol.stream(model: "gemini-3.8-flash", input: "Hello").final_result
      assert_equal "", unary.output_text, reason
      assert_equal "partial", stream.output_text, "the consumer decides whether to adopt it"
      [unary, stream].each do |result|
        assert_equal reason, result.finish_detail
        assert_nil result.refusal, "an error does not imply a policy refusal"
        assert_equal "error", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: result.finish_detail)
        assert_equal 3, result.usage.fetch("input_tokens")
        assert_equal 7, result.usage.fetch("total_tokens"), "the bare terminal must retain earlier usage"
      end
    end
  end

  def test_unknown_and_unsupported_finishes_still_fail_closed
    %w[FUTURE_UNKNOWN_FINISH ESCALATION PUP_LIMITED_DISABLED].each do |reason|
      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "test-only", adapter: Adapter.new(reason)
      )
      assert_raises(SimpleInference::Protocols::GeminiGenerateContent::UnknownFinishReasonError) do
        protocol.create(model: "gemini-3.8-flash", input: "Hello")
      end
      assert_raises(SimpleInference::Protocols::GeminiGenerateContent::UnknownFinishReasonError) do
        protocol.stream(model: "gemini-3.8-flash", input: "Hello").final_result
      end
    end
  end
end
