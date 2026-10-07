require "json"
require "test_helper"

# Terminal-path conformance for the codex lane (register
# `codex_responses.usage.v1`). All stream payloads are deterministic
# constructions mirroring the register's pinned terminal taxonomy — not wire
# captures.
class TestCodexResponsesProtocol < Minitest::Test
  # response.incomplete no longer raises (the old codex behavior destroyed
  # usage, unlike the parent): status enum kept, cutoff reason distinct,
  # terminal usage retained.
  def test_stream_incomplete_terminal_keeps_status_reason_and_usage
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.output_text.delta","delta":"partial"}\n\n)
          sse << %(data: {"type":"response.incomplete","response":{"status":"incomplete",) <<
            %("incomplete_details":{"reason":"content_filter"},) <<
            %("output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}],) <<
            %("usage":{"input_tokens":5,"output_tokens":9}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = codex_protocol(adapter:)
    result = protocol.responses(model: "gpt-5-codex", input: "Hello", stream: true)

    assert_equal "incomplete", result.response.body.fetch("status") if result.response.body.is_a?(Hash)
    assert_equal "content_filter", result.incomplete_reason
    assert_equal "partial", result.output_text
    assert_equal({ "input_tokens" => 5, "output_tokens" => 9 }, result.usage)
  end

  def test_create_raises_typed_error_on_response_failed_terminal_event
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          sse = +""
          sse << %(data: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"provider exploded"}}}\n\n)
          sse << "data: [DONE]\n\n"

          yield sse
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = codex_protocol(adapter:)

    error =
      assert_raises(SimpleInference::Protocols::OpenAIResponses::ResponseFailedError) do
        protocol.create(model: "gpt-5-codex", input: "Hello")
      end

    assert_includes error.message, "response.failed"
    assert_includes error.message, "provider exploded"
    assert_nil error.usage, "no wire usage on this deterministic construction — none is fabricated"
  end

  def test_interrupted_stream_without_terminal_event_raises_stream_error
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call_stream(_env)
          # Deterministic interruption construction: deltas but no terminal.
          yield %(data: {"type":"response.output_text.delta","delta":"par"}\n\n)
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
        end
      end.new

    protocol = codex_protocol(adapter:)

    error =
      assert_raises(SimpleInference::StreamError) do
        protocol.create(model: "gpt-5-codex", input: "Hello")
      end

    assert_includes error.message, "terminal"
  end


  private

  def codex_protocol(adapter:)
    SimpleInference::Protocols::CodexResponses.new(
      base_url: "http://example.com",
      adapter:,
    )
  end
end
