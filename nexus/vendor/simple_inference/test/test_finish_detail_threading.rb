require "test_helper"

# THE PIN THAT WAS MISSING, and its absence is why a whole lane shipped dark.
#
# Round E threaded the typed finish fact through the Result assemblers, and
# every test asserted what the CLASSIFIER does with a value — none asserted
# that a protocol actually PRODUCES one. OpenRouter, then the one lane that
# overrode the shared chat assembler, quietly passed nothing; the keyword's
# nil default made that silent, and the suite stayed green while every
# truncated answer on the largest text lane read as a clean finish.
#
# This drives each family's real assembly path and asserts the value arrives.
# The keyword is required now, so a NEW site cannot repeat the omission — but
# a site could still pass a wrong-shaped nil, which is what this catches.
class TestFinishDetailThreading < Minitest::Test
  def test_every_family_carries_its_own_typed_finish_fact
    assert_equal "max_output_tokens", responses_family_detail,
      "the Responses family's status is a lifecycle word; the reason lives in " \
      "incomplete_details and must reach the result"
    assert_equal "max_tokens", anthropic_detail
    assert_equal "MAX_TOKENS", gemini_detail
    assert_equal "length", chat_detail(SimpleInference::Protocols::OpenAICompatibleResponses)
    assert_equal "length", chat_detail(SimpleInference::Protocols::OpenRouterResponses),
      "the broker lane assembles through the shared chat assembler and must carry it too"
  end

  # STREAMING IS THE PRODUCTION PATH for text, and Gemini is the one family
  # whose stream assembles at its OWN site rather than sharing the unary
  # builder — so the unary assertions above prove nothing about it. The
  # required keyword catches an OMITTED argument there; only this catches a
  # wrong one.
  def test_the_gemini_stream_assembles_its_own_typed_finish_fact
    chunk = {
      "responseId" => "r1",
      "candidates" => [{
        "content" => { "parts" => [{ "text" => "partial" }], "role" => "model" },
        "finishReason" => "MAX_TOKENS",
      }],
      "usageMetadata" => { "promptTokenCount" => 1, "candidatesTokenCount" => 1,
                           "totalTokenCount" => 2 },
    }
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call_stream) do |_request, &block|
        block.call("data: #{JSON.generate(chunk)}\n\n")
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new

    stream = SimpleInference::Protocols::GeminiGenerateContent
      .new(base_url: "http://x", api_key: "k", adapter: adapter)
      .stream(model: "m", input: "hi")
    stream.each { |_event| }

    assert_equal "MAX_TOKENS", stream.final_result.finish_detail
  end

  private

    def json_adapter(body)
      Class.new(SimpleInference::HTTPAdapter) do
        define_method(:call) do |_env|
          { status: 200, headers: { "content-type" => "application/json" },
            body: JSON.generate(body) }
        end
      end.new
    end

    def responses_family_detail
      body = {
        "id" => "resp_1", "status" => "incomplete",
        "incomplete_details" => { "reason" => "max_output_tokens" },
        "output" => [{ "type" => "message", "role" => "assistant",
                       "content" => [{ "type" => "output_text", "text" => "partial" }] }],
        "usage" => { "input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2 },
      }
      SimpleInference::Protocols::OpenAIResponses
        .new(base_url: "http://x", api_key: "k", adapter: json_adapter(body))
        .create(model: "m", input: "hi").finish_detail
    end

    def anthropic_detail
      body = {
        "id" => "msg_1", "type" => "message", "role" => "assistant",
        "content" => [{ "type" => "text", "text" => "partial" }],
        "stop_reason" => "max_tokens",
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 },
      }
      SimpleInference::Protocols::AnthropicMessages
        .new(base_url: "http://x", api_key: "k", adapter: json_adapter(body))
        .create(model: "m", input: "hi", max_output_tokens: 8).finish_detail
    end

    def gemini_detail
      body = {
        "responseId" => "r1",
        "candidates" => [{
          "content" => { "parts" => [{ "text" => "partial" }], "role" => "model" },
          "finishReason" => "MAX_TOKENS",
        }],
        "usageMetadata" => { "promptTokenCount" => 1, "candidatesTokenCount" => 1,
                             "totalTokenCount" => 2 },
      }
      SimpleInference::Protocols::GeminiGenerateContent
        .new(base_url: "http://x", api_key: "k", adapter: json_adapter(body))
        .create(model: "m", input: "hi").finish_detail
    end

    def chat_detail(protocol_class)
      body = {
        "id" => "chat_1", "object" => "chat.completion",
        "choices" => [{ "index" => 0, "finish_reason" => "length",
                        "message" => { "role" => "assistant", "content" => "partial" } }],
        # OpenRouter's usage carries its own required discriminators; the
        # plain compat lane ignores the extra keys.
        "usage" => { "prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2,
                     "cost" => 0, "is_byok" => false },
      }
      options = { base_url: "http://x", api_key: "k", adapter: json_adapter(body) }
      options[:stream_include_usage] = false if
        protocol_class == SimpleInference::Protocols::OpenRouterResponses
      protocol_class.new(**options).create(model: "m", input: "hi").finish_detail
    end
end
