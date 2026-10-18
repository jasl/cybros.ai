require "json"
require "test_helper"

class TestProtocolContract < Minitest::Test
  class SequencedAdapter < SimpleInference::HTTPAdapter
    def initialize
      @call_index = 0
    end

    def call(_env)
      @call_index += 1

      case @call_index
      when 1
        json(
          {
            choices: [
              { message: { role: "assistant", content: "hello" }, finish_reason: "stop" },
            ],
          },
        )
      when 2
        json(
          {
            choices: [
              { message: { role: "assistant", content: "hi" }, finish_reason: "stop" },
            ],
            usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
          },
        )
      when 3
        json({ error: { message: "nope" } }, status: 401)
      when 4
        sse = +""

        sse << "data: #{JSON.generate(sse_chunk(content: "Hel", finish_reason: nil))}\n\n"
        sse << "data: #{JSON.generate(sse_chunk(content: "lo", finish_reason: nil))}\n\n"
        sse << "data: #{JSON.generate(sse_chunk(content: nil, finish_reason: "stop", include_usage: true))}\n\n"
        sse << "data: [DONE]\n\n"

        { status: 200, headers: { "content-type" => "text/event-stream" }, body: sse }
      else
        raise "Unexpected request (call_index=#{@call_index})"
      end
    end

    private

    def json(body, status: 200)
      {
        status: status,
        headers: { "content-type" => "application/json" },
        body: JSON.generate(body),
      }
    end

    def sse_chunk(content:, finish_reason:, include_usage: false)
      chunk =
        {
          "id" => "evt_#{@call_index}",
          "object" => "chat.completion.chunk",
          "created" => 1,
          "model" => "test-model",
          "choices" => [
            {
              "index" => 0,
              "delta" => {},
              "finish_reason" => finish_reason,
            },
          ],
        }

      if content
        chunk["choices"][0]["delta"]["role"] = "assistant"
        chunk["choices"][0]["delta"]["content"] = content
      end

      if include_usage
        chunk["usage"] = { "prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3 }
      end

      chunk
    end
  end

  class CapturingChatAdapter < SimpleInference::HTTPAdapter
    attr_reader :last_request

    def call(env)
      @last_request = env

      {
        status: 200,
        headers: { "content-type" => "application/json" },
        body: JSON.generate(
          {
            choices: [
              { message: { role: "assistant", content: "hello" }, finish_reason: "stop" },
            ],
          },
        ),
      }
    end
  end

  def assert_protocol_contract(instance)
    assert_equal StandardError, SimpleInference::Error.superclass

    assert_respond_to instance, :chat_completions
    assert_respond_to instance, :chat

    response = instance.chat_completions(model: "foo", messages: [])
    assert_instance_of SimpleInference::Response, response
    assert response.raw_body.is_a?(String)
    assert_includes response.raw_body, "hello"

    body = response.body
    assert body.is_a?(Hash)

    msg = body.dig("choices", 0, "message")
    assert msg.is_a?(Hash)
    assert_equal "assistant", msg.fetch("role")
    assert_equal "hello", msg.fetch("content")

    result = instance.chat(model: "foo", messages: [])
    assert_instance_of SimpleInference::OpenAI::ChatResult, result
    assert_equal "hi", result.content
    assert_equal({ "prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3 }, result.usage)
    assert_equal "stop", result.finish_reason
    assert_instance_of SimpleInference::Response, result.response
    assert result.response.raw_body.is_a?(String)
    assert_includes result.response.raw_body, "hi"

    error = assert_raises(SimpleInference::HTTPError) { instance.chat_completions(model: "foo", messages: []) }
    assert_equal 401, error.status
    assert error.body.is_a?(Hash)
    assert_includes error.message, "nope"
    assert_includes error.raw_body, "nope"

    deltas = []
    streamed =
      instance.chat(model: "foo", messages: [], stream: true) do |delta|
        deltas << delta
      end

    assert_equal ["Hel", "lo"], deltas
    assert_equal "Hello", streamed.content
    assert_equal "stop", streamed.finish_reason
    assert_equal({ "prompt_tokens" => 1, "completion_tokens" => 2, "total_tokens" => 3 }, streamed.usage)
    assert_instance_of SimpleInference::Response, streamed.response
  end

  def test_openai_compatible_protocol_satisfies_contract
    adapter = SequencedAdapter.new
    protocol = SimpleInference::Protocols::OpenAICompatible.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)

    assert_protocol_contract(protocol)
  end

  # The declared-vocabulary contract: option spelling is normalized ONCE at
  # the request boundary, so the string and symbol spellings of a declared
  # option behave IDENTICALLY (here: instructions becomes the system message).
  # Raw wire fields ride extra_body instead — the old "string-keyed options
  # bypass internal controls onto the wire" behavior is deliberately gone.
  def test_openai_compatible_protocol_normalizes_option_spellings_and_routes_wire_fields_via_extra_body
    adapter = CapturingChatAdapter.new
    protocol = SimpleInference::Protocols::OpenAICompatibleResponses.new(base_url: "http://example.com", api_key: "secret", adapter: adapter)

    protocol.create(
      model: "chat-model",
      input: "Hello",
      extra_body: { "instructions" => "A raw wire field, verbatim." },
      **{ "instructions" => "Spelled as a string, same declared option." },
    )

    body = JSON.parse(adapter.last_request.fetch(:body))
    assert_equal(
      [
        { "role" => "system", "content" => "Spelled as a string, same declared option." },
        { "role" => "user", "content" => "Hello" },
      ],
      body.fetch("messages"),
      "a string-spelled declared option behaves exactly like its symbol spelling"
    )
    assert_equal "A raw wire field, verbatim.", body.fetch("instructions"),
                 "raw wire fields reach the body only through extra_body"
  end
end
