# Small authored provider responses based on Google's finish descriptions,
# not captured failures: https://ai.google.dev/api/generate-content#FinishReason
module GeminiFinishTestHelper
  ERROR_REASONS = %w[OTHER NO_IMAGE IMAGE_OTHER MALFORMED_FUNCTION_CALL UNEXPECTED_TOOL_CALL
                     TOO_MANY_TOOL_CALLS MISSING_THOUGHT_SIGNATURE MALFORMED_RESPONSE].freeze

  private

    def gemini_error_response(reason, empty: false)
      parts = empty ? [] : [
        { "thought" => true, "text" => "unfinished thought" },
        { "text" => "unfinished answer" },
        { "thoughtSignature" => "test-signature",
          "functionCall" => { "id" => "call_unusable", "name" => "read_file", "args" => { "path" => "a" } } },
      ]
      json_response(200, {
        "candidates" => [{ "content" => { "parts" => parts }, "finishReason" => reason }],
        "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 4, "thoughtsTokenCount" => 2, "totalTokenCount" => 9 },
      })
    end

    def gemini_error_result(reason, empty: false)
      SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "test-only-key",
        adapter: InvocationHarness::FakeAdapter.new(gemini_error_response(reason, empty: empty))
      ).create(model: "gemini-3.8-flash", input: "Hello")
    end
end
