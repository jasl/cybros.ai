require "json"
require "test_helper"
require "gemini_protocol_helpers"

class TestGeminiTermination < Minitest::Test
  include GeminiProtocolHelpers

  # --- Terminal recognition: the frozen 18-value released-SDK FinishReason
  # enum, and interruption on streams that never carry one. ---

  FULL_FINISH_REASON_ENUM = %w[
    FINISH_REASON_UNSPECIFIED STOP MAX_TOKENS SAFETY RECITATION LANGUAGE OTHER
    BLOCKLIST PROHIBITED_CONTENT SPII MALFORMED_FUNCTION_CALL IMAGE_SAFETY
    UNEXPECTED_TOOL_CALL TOO_MANY_TOOL_CALLS IMAGE_PROHIBITED_CONTENT NO_IMAGE
    IMAGE_RECITATION IMAGE_OTHER
  ].freeze

  def test_create_recognizes_the_full_18_value_finish_reason_enum
    assert_equal 18, FULL_FINISH_REASON_ENUM.length

    FULL_FINISH_REASON_ENUM.each do |reason|
      adapter = Class.new(SimpleInference::HTTPAdapter) do
        define_method(:call) do |_env|
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: reason }] }),
          }
        end
      end.new

      protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
      )
      result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

      assert_equal reason, result.finish_reason
    end
  end

  def test_stream_accepts_extended_enum_terminals
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "TOO_MANY_TOOL_CALLS" }] })}\n\n"

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "TOO_MANY_TOOL_CALLS", result.finish_reason
  end

  # A finishReason outside the frozen enum cannot be silently classified as a
  # clean terminal — fail closed (deterministic malformed construction).
  def test_unknown_finish_reason_fails_closed
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: "BANANA" }] }),
        }
      end
    end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )

    error =
      assert_raises(SimpleInference::Protocols::GeminiGenerateContent::UnknownFinishReasonError) do
        protocol.create(model: "gemini-3.7-flash", input: "Hello")
      end

    assert_includes error.message, "BANANA"
  end

  # The JSON fallback (a gateway ignored Accept and returned one plain body;
  # no SSE events fired) still recognizes its terminal and usage snapshot
  # (deterministic construction).
  def test_stream_json_fallback_recognizes_terminal_and_usage
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          {
            status: 200,
            headers: { "content-type" => "application/json" },
            body: JSON.generate(
              {
                candidates: [{ content: { parts: [{ text: "Hello" }] }, finishReason: "STOP" }],
                usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 3, totalTokenCount: 5 },
              }
            ),
          }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "Hello", result.output_text
    assert_equal "STOP", result.finish_reason
    assert_equal 5, result.usage.fetch("total_tokens")
  end

  # A PROMPT BLOCK IS A FINISH, NOT A TRANSPORT FAILURE: Google answers no
  # candidate by design, so the Result has no items; its typed detail says
  # the PROMPT was declined (distinct from a candidate's word of the same
  # name), the block reason rides Result#refusal verbatim as the category,
  # and the billed prompt work stays on the usage.
  def test_create_prompt_block_is_a_typed_refusal_with_usage
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({
            promptFeedback: { blockReason: "SAFETY" },
            usageMetadata: { promptTokenCount: 7, totalTokenCount: 7 },
          }),
        }
      end
    end.new
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "PROMPT_SAFETY", result.finish_detail
    assert_equal SimpleInference::Responses::Refusal.new(category: "SAFETY", explanation: nil), result.refusal
    assert_equal "", result.output_text
    assert_empty result.output_items
    assert_empty result.tool_calls
    assert_equal 7, result.usage.fetch("input_tokens")
    assert_equal 7, result.usage.fetch("total_tokens")
    assert_equal "refused", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: result.finish_detail)
  end

  def test_stream_prompt_block_is_a_typed_block_not_an_interruption
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield "data: #{JSON.generate({
          promptFeedback: { blockReason: "PROHIBITED_CONTENT" },
          usageMetadata: { promptTokenCount: 9, totalTokenCount: 9 },
        })}\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = gemini_protocol(adapter: adapter)

    result = protocol.stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "PROMPT_PROHIBITED_CONTENT", result.finish_detail
    assert_equal "PROHIBITED_CONTENT", result.refusal.category
    assert_equal 9, result.usage.fetch("input_tokens")
    assert_equal "blocked", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: result.finish_detail)
  end

  def test_the_prompt_blocked_error_is_retired
    refute SimpleInference::Protocols::GeminiGenerateContent.const_defined?(:PromptBlockedError, false),
      "a prompt block is a Result now; nothing raises it"
  end

  # Fail closed on a block reason outside the released SDK's frozen
  # BlockedReason enum, exactly as on an unknown finishReason: an
  # unclassified block must never read as a clean, empty finish.
  def test_an_unknown_prompt_block_reason_is_refused_loudly
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call(_env)
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ promptFeedback: { blockReason: "SOMETHING_NEW" } }),
        }
      end
    end.new

    assert_raises(SimpleInference::Protocols::GeminiGenerateContent::UnknownFinishReasonError) do
      gemini_protocol(adapter: adapter).create(model: "gemini-3.7-flash", input: "Hello")
    end
  end

  # A SAFETY-class candidate stop is a typed refusal whose category IS
  # Google's word; a content-protection stop carries its word the same way
  # and types as blocked.
  def test_a_safety_finish_is_a_typed_refusal_with_its_category
    result = gemini_protocol(adapter: finish_adapter("SAFETY")).create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "SAFETY", result.finish_detail
    assert_equal SimpleInference::Responses::Refusal.new(category: "SAFETY", explanation: nil), result.refusal
  end

  def test_an_spii_finish_is_a_typed_block
    result = gemini_protocol(adapter: finish_adapter("SPII")).create(model: "gemini-3.7-flash", input: "Hello")

    assert_equal "SPII", result.finish_detail
    assert_equal "SPII", result.refusal.category
    assert_equal "blocked", SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: "SPII")
  end

  def test_a_streamed_safety_finish_carries_the_refusal
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      def call_stream(_env)
        yield "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "par" }] } }] })}\n\n"
        yield "data: #{JSON.generate({ candidates: [{ content: { parts: [] }, finishReason: "SAFETY" }],
                                       usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 1, totalTokenCount: 3 } })}\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new

    result = gemini_protocol(adapter: adapter).stream(model: "gemini-3.7-flash", input: "Hello").final_result

    assert_equal "SAFETY", result.finish_detail
    assert_equal "SAFETY", result.refusal.category
  end

  def test_unclassified_finishes_carry_no_refusal
    %w[STOP MAX_TOKENS OTHER].each do |reason|
      result = gemini_protocol(adapter: finish_adapter(reason)).create(model: "gemini-3.7-flash", input: "Hello")

      assert_nil result.refusal, reason
    end
  end

  # A stream that runs to HTTP completion without ANY candidate carrying a
  # finishReason is an INTERRUPTION — an explicit typed marker, never a silent
  # normal Result (deterministic interruption construction, not a capture).
  def test_stream_without_a_terminal_chunk_is_an_explicit_interruption
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "Hel" }] } }], usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 1, totalTokenCount: 3 } })}\n\n"
          sse << "data: #{JSON.generate({ candidates: [{ content: { parts: [{ text: "lo" }] } }], usageMetadata: { promptTokenCount: 2, candidatesTokenCount: 2, totalTokenCount: 4 } })}\n\n"

          yield sse

          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
    stream = protocol.stream(model: "gemini-3.7-flash", input: "Hello")

    error =
      assert_raises(SimpleInference::Protocols::GeminiGenerateContent::InterruptedStreamError) do
        stream.to_a
      end

    assert_includes error.message, "finishReason"
    assert_kind_of SimpleInference::StreamError, error
  end

  private

  def finish_adapter(reason)
    Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call) do |_env|
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate({ candidates: [{ content: { parts: [{ text: "ok" }] }, finishReason: reason }] }),
        }
      end
    end.new
  end
end
