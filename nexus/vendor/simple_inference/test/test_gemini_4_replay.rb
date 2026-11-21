require "json"
require "test_helper"
require "gemini_protocol_helpers"

class TestGemini4Replay < Minitest::Test
  include GeminiProtocolHelpers

  class Adapter < SimpleInference::HTTPAdapter
    attr_reader :request

    def initialize(chunks = [], finish: "STOP")
      @chunks = chunks
      @finish = finish
    end

    def call(env)
      @request = JSON.parse(env.fetch(:body))
      { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(candidate(@chunks.flatten(1), @finish)) }
    end

    def call_stream(_env)
      @chunks.each { |parts| yield "data: #{JSON.generate(candidate(parts))}\n\n" }
      yield "data: #{JSON.generate(candidate([], @finish))}\n\n"
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end

    private

    def candidate(parts, finish = nil)
      { candidates: [{ content: { parts: parts }, finishReason: finish }.compact] }
    end
  end

  def test_single_hop_cutoff_and_filtered_stops_keep_their_provider_reason
    { "CONTINUATION" => "output_budget_exhausted", "ESCALATION" => "blocked", "PUP_LIMITED_DISABLED" => "error" }.each do |reason, quality|
      protocol = gemini_protocol(adapter: Adapter.new([], finish: reason))
      [protocol.create(model: "gemini-4-carbon", input: "go"),
       protocol.stream(model: "gemini-4-carbon", input: "go").final_result].each do |result|
        assert_equal reason, result.finish_detail
        assert_equal quality, SimpleInference::FinishQuality.for(adapter_profile: "gemini_generate_content", detail: result.finish_detail)
      end
    end
  end

  def test_signed_answer_and_summary_parts_survive_in_order_including_the_empty_trailer
    summary = [
      { "thought" => true, "text" => "Step 1", "thoughtSignature" => "s1" },
      { "thought" => true, "text" => "Step 2", "thoughtSignature" => "s2" },
    ]
    answer = [{ "text" => "A", "thoughtSignature" => "a1" }, { "text" => "", "thoughtSignature" => "a2" }]
    adapter = Adapter.new((summary + answer).map { |part| [part] })
    protocol = gemini_protocol(adapter: adapter)

    [protocol.stream(model: "gemini-4-neon", input: "go").final_result,
     protocol.create(model: "gemini-4-neon", input: "go")].each do |result|
      thought, message = result.output_items
      assert_equal "A", result.output_text
      assert_equal summary, thought.dig("provider_payload", "parts")
      assert_equal answer, message.dig("provider_payload", "parts")
    end

    history = (summary + answer).map { |part| part.merge("type" => part["thought"] ? "thought" : "text") }
    protocol.create(model: "gemini-4-hydrogen",
      input: [{ role: "user", content: "go" }, { role: "assistant", content: history }, { role: "user", content: "next" }])
    assert_equal summary + answer, adapter.request.dig("contents", 1, "parts")
  end

  def test_stream_keeps_repeated_fragments_and_parallel_calls_across_chunk_boundaries
    call = { "functionCall" => { "name" => "roll", "args" => {} } }
    adapter = Adapter.new([[{ "text" => "ha" }], [{ "text" => "ha" }], [call.merge("thoughtSignature" => "first")], [call]])
    result = gemini_protocol(adapter: adapter).stream(model: "gemini-4-carbon", input: "go").final_result

    assert_equal "haha", result.output_text
    assert_equal "haha", result.output_items.first.dig("content", 0, "text")
    assert_equal [call.merge("thoughtSignature" => "first"), call], result.tool_calls.map { |item| item.fetch("provider_payload") }
  end

  def test_imported_calls_keep_the_first_transfer_marker_as_more_context_is_appended
    call = ->(id) { { type: "function_call", name: "lookup", arguments: "{}", call_id: id } }
    result = ->(id) { { type: "function_call_output", call_id: id, output: "ok" } }
    native = { functionCall: { name: "lookup", args: {}, id: "native" } }
    adapter = Adapter.new
    protocol = gemini_protocol(adapter: adapter)
    history = [
      { role: "user", content: "prior turn" }, call.call("old"), result.call("old"),
      { role: "user", content: "continue" }, call.call("one"), call.call("two"), result.call("one"), result.call("two"),
      call.call("three"), result.call("three"),
      call.call("native").merge(provider_payload: native), result.call("native"),
    ]
    protocol.create(model: "gemini-4-argon", input: history)
    before = adapter.request.fetch("contents")
    protocol.create(model: "gemini-4-argon", input: history + [{ role: "user", content: "another question" }])
    after = adapter.request.fetch("contents")
    assert_equal before[0...-1], after[0...-1]
    assert_equal before.last.fetch("parts") + [{ "text" => "another question" }], after.last.fetch("parts")
    groups = adapter.request.fetch("contents").select { |c| c.fetch("role") == "model" }
    marker = "skip_thought_signature_validator"
    assert_equal [[marker], [marker, nil], [marker], [nil]],
      groups.map { |c| c.fetch("parts").map { |part| part["thoughtSignature"] } }
    assert_equal [%w[old], %w[one two], %w[three], %w[native]],
      groups.map { |c| c.fetch("parts").map { |part| part.dig("functionCall", "id") } }
    assert_equal %w[old one two three native], adapter.request.fetch("contents")
      .flat_map { |c| c.fetch("parts").filter_map { |part| part.dig("functionResponse", "id") } }
  end
end
