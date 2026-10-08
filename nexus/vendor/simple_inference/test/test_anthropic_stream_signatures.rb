require "json"
require "test_helper"

class TestAnthropicStreamSignatures < Minitest::Test
  def test_signature_fragments_append_and_replay_without_losing_bytes
    ["Plan", ""].each do |thought|
      events = [
        { type: "message_start", message: { id: "msg_fixture", content: [], usage: { input_tokens: 2 } } },
        { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "", signature: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: thought } },
        { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "first-" } },
        { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "" } },
        { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "last" } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 3 } },
        { type: "message_stop" },
      ]
      adapter = Class.new(SimpleInference::HTTPAdapter) do
        define_method(:call_stream) do |_request, &emit|
          events.each { |event| emit.call("event: #{event.fetch(:type)}\ndata: #{JSON.generate(event)}\n\n") }
          { status: 200, headers: { "content-type" => "text/event-stream" }, body: "" }
        end
      end.new
      protocol = SimpleInference::Protocols::AnthropicMessages.new(base_url: "https://provider.example", adapter: adapter)
      result = protocol.stream(model: "m", input: "Hi", max_output_tokens: 2048).final_result
      item = result.output_items.fetch(0)
      assert_equal "first-last", item.fetch("signature")
      native = { "type" => "thinking", "thinking" => thought, "signature" => "first-last" }
      assert_equal native, item.fetch("provider_payload")

      replay = JSON.parse(protocol.compile_create(model: "m", max_output_tokens: 2048, input: [
        { role: "assistant", content: [native] }, { role: "user", content: "Continue" },
      ]).payload)
      assert_equal native, replay.dig("messages", 0, "content", 0)
    end
  end
end
