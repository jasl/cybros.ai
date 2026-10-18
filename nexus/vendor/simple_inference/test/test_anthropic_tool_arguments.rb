require "json"
require "test_helper"

class TestAnthropicToolArguments < Minitest::Test
  def test_stream_without_argument_bytes_keeps_the_empty_input_object
    [[], [""], ["", ""]].each do |fragments|
      streamed_arguments(input: {}, fragments: fragments).each do |arguments|
        assert_equal "{}", arguments
        assert_equal({}, JSON.parse(arguments))
      end
    end
  end

  def test_empty_argument_delta_keeps_the_started_input
    input = { "scope" => "current" }

    streamed_arguments(input: input, fragments: [""]).each do |arguments|
      assert_equal input, JSON.parse(arguments)
    end
  end

  def test_nonempty_argument_deltas_replace_the_started_input
    fragments = ["", "{\"scope\":", "\"current\"}", ""]

    streamed_arguments(input: { "scope" => "old" }, fragments: fragments).each do |arguments|
      assert_equal({ "scope" => "current" }, JSON.parse(arguments))
    end
  end

  def test_nonempty_malformed_argument_deltas_remain_invalid
    ["{\"scope\":", " "].each do |partial|
      streamed_arguments(input: {}, fragments: [partial, ""]).each do |arguments|
        assert_equal partial, arguments
        assert_raises(JSON::ParserError) { JSON.parse(arguments) }
      end
    end
  end

  private

  def streamed_arguments(input:, fragments:)
    events = [
      { type: "message_start", message: { id: "msg_fixture", content: [], usage: { input_tokens: 2 } } },
      { type: "content_block_start", index: 0,
        content_block: { type: "tool_use", id: "toolu_fixture", name: "inspect_status", input: input } },
    ]
    fragments.each do |fragment|
      events << { type: "content_block_delta", index: 0,
                  delta: { type: "input_json_delta", partial_json: fragment } }
    end
    events.concat([
      { type: "content_block_stop", index: 0 },
      { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 3 } },
      { type: "message_stop" },
    ])
    adapter = Class.new(SimpleInference::HTTPAdapter) do
      define_method(:call_stream) do |_request, &emit|
        events.each { |event| emit.call("event: #{event.fetch(:type)}\ndata: #{JSON.generate(event)}\n\n") }
        { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
      end
    end.new
    protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://provider.example", adapter: adapter)
    received = protocol.stream(
      model: "messages-fixture", input: "Inspect the current status.", max_output_tokens: 128,
      tools: [{ type: "function", name: "inspect_status", parameters: { type: "object", properties: {} } }]
    ).to_a

    done = received.grep(SimpleInference::Responses::Events::ToolCallDone).fetch(0)
    result = received.last.result
    [done.arguments, result.tool_calls.fetch(0).fetch("arguments")]
  end
end
