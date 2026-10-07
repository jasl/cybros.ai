require "json"
require "test_helper"

class TestOpenAIResponsesOutputReconciliation < Minitest::Test
  class Adapter < SimpleInference::HTTPAdapter
    def initialize(events)
      @events = events
    end

    def call_stream(_env)
      @events.each { |event| yield "data: #{JSON.generate(event)}\n\n" }
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end
  end

  def test_terminal_only_reasoning_survives_beside_a_streamed_tool_call
    reasoning = reasoning_item("rs_1")
    call = call_item("fc_1", "call_1")
    events = [
      { "type" => "response.reasoning_summary_text.delta", "item_id" => "rs_1", "delta" => "Use a tool." },
      { "type" => "response.function_call_arguments.done", "item_id" => "fc_1", "output_index" => 1,
        "name" => "echo", "arguments" => "{}" },
    ]

    result = stream_result(events, [reasoning, call])

    assert_equal [reasoning, call], result.output_items
    assert_equal ["call_1"], result.tool_calls.map { |item| item.fetch("call_id") }
    assert_equal({ "input_tokens" => 3, "output_tokens" => 4 }, result.usage)
  end

  def test_streamed_non_call_items_are_enriched_once_in_terminal_order
    reasoning = reasoning_item("rs_1")
    message = { "type" => "message", "id" => "msg_1", "role" => "assistant",
                "content" => [{ "type" => "output_text", "text" => "Answer." }] }
    events = [
      { "type" => "response.output_item.added", "output_index" => 1, "item" => message.merge("content" => []) },
      { "type" => "response.output_item.added", "output_index" => 0, "item" => reasoning.merge("summary" => []) },
    ]

    result = stream_result(events, [reasoning, message])

    assert_equal [reasoning, message], result.output_items
    assert_equal "Answer.", result.output_text
  end

  def test_identical_calls_match_identity_before_shape_and_keep_terminal_order
    first = call_item("fc_1", "call_1")
    second = call_item("fc_2", "call_2")
    events = [
      { "type" => "response.output_item.added", "output_index" => 0,
        "item" => second.merge("call_id" => nil, "status" => "in_progress") },
      { "type" => "response.output_item.added", "output_index" => 1,
        "item" => first.merge("call_id" => nil, "status" => "completed") },
    ]

    result = stream_result(events, [first, reasoning_item("rs_1"), second])

    assert_equal [first.merge("status" => "completed"), reasoning_item("rs_1"), second.merge("status" => "in_progress")],
                 result.output_items
    assert_equal %w[call_1 call_2], result.tool_calls.map { |item| item.fetch("call_id") }
  end

  def test_sparse_terminal_call_preserves_streamed_identifiers_name_and_arguments
    call = call_item("fc_1", "call_1")
    events = [{ "type" => "response.output_item.done", "output_index" => 0, "item" => call }]
    sparse = { "type" => "function_call", "id" => "fc_1", "name" => "", "arguments" => "" }

    result = stream_result(events, [sparse])

    assert_equal [call], result.output_items
  end

  def test_stream_only_items_remain_when_terminal_output_is_sparse
    call = call_item("fc_1", "call_1")
    events = [{ "type" => "response.output_item.done", "output_index" => 1, "item" => call }]
    reasoning = reasoning_item("rs_1")

    result = stream_result(events, [reasoning])

    assert_equal [reasoning, call], result.output_items
  end

  private

    def stream_result(events, output)
      terminal = { "type" => "response.completed", "response" => {
        "output" => output, "usage" => { "input_tokens" => 3, "output_tokens" => 4 },
      } }
      protocol = SimpleInference::Protocols::OpenAIResponses.new(
        base_url: "http://example.com", adapter: Adapter.new(events + [terminal])
      )
      protocol.stream(model: "m", input: "Hello").final_result
    end

    def reasoning_item(id)
      { "type" => "reasoning", "id" => id, "encrypted_content" => "opaque-test-content",
        "summary" => [{ "type" => "summary_text", "text" => "Use a tool." }] }
    end

    def call_item(id, call_id)
      { "type" => "function_call", "id" => id, "call_id" => call_id, "name" => "echo", "arguments" => "{}" }
    end
end
