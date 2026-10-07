require "test_helper"

# THE ONE WALK: a round replays its output items where the model produced
# them — every reasoning item before the item it produced, each call at
# its place, a labelled message at its own — and a round whose messages
# carry no label keeps the one spelling every lane already caches: the
# body's message ahead of its calls. Both lanes read this Round.
class AgentRuns::RoundReplayTest < ActiveSupport::TestCase
  Target = ModelReasoning::ReplayLadder::Target
  Body = Data.define(:effective_text)
  Node = Data.define(:output_body)
  TracedResult = Data.define(:output_items, :assistant_message, :usage)

  ORIGIN = { "provider_id" => "openai_api", "model_id" => "gpt-6-sol", "api_format" => "openai_responses" }.freeze

  test "a round replays its output items in the wire's order" do
    round = round_for(
      trace([reasoning("A", "one", "two"), said("commentary"), call("call_1"), reasoning("B", "three"),
             call("call_2")]),
      text: "I'll read both.", calls: %w[call_1 call_2], replay: responses_replay
    )

    assert_equal [["reasoning", "A"], ["message", "commentary", "I'll read both."], ["call", "call_1"],
                  ["reasoning", "B"], ["call", "call_2"], ["result", "call_1"], ["result", "call_2"]],
      shape(round.elements)
    assert_equal [{ "type" => "summary_text", "text" => "one" }, { "type" => "summary_text", "text" => "two" }],
      round.elements.first.payload.fetch("summary"), "each item replays its own summary parts"
    assert_equal ORIGIN, round.elements.second.native_origin, "the phase rides with its licence"
    assert_equal %w[call_1 call_2], round.call_items.map { |item| item.payload.fetch("call_id") }
    assert_equal 1, round.first_slot
    assert_equal 1, round.leading.length
    assert_nil round.message, "a labelled round's words ride at their own place"
  end

  test "a later message follows the reasoning that produced it" do
    round = round_for(
      trace([reasoning("R1"), said("commentary", "On it."), call("call_x"), reasoning("R2"),
             said("commentary", "Next one."), call("call_y")]),
      text: "On it.Next one.", calls: %w[call_x call_y], replay: responses_replay
    )

    assert_equal [["reasoning", "R1"], ["message", "commentary", "On it."], ["call", "call_x"],
                  ["reasoning", "R2"], ["message", "commentary", "Next one."], ["call", "call_y"],
                  ["result", "call_x"], ["result", "call_y"]],
      shape(round.elements), "the second message after the thought that produced it, never beside the first"
  end

  test "compacted pairs retain native reasoning order without the replaced phased messages" do
    round = round_for(
      trace([reasoning("R1"), said("commentary", "Old introduction"), call("call_x"), reasoning("R2"),
             said("commentary", "Old middle"), call("call_y"), said("final_answer", "Old final")]),
      text: "Old introductionOld middleOld final", calls: %w[call_x call_y], replay: responses_replay, only_pairs: true
    )

    assert_equal [["reasoning", "R1"], ["call", "call_x"], ["reasoning", "R2"], ["call", "call_y"],
                  ["result", "call_x"], ["result", "call_y"]], shape(round.elements)
    assert_nil round.message
  end

  test "a call before the message keeps its place on a phased round, and the message leads on a phase-less one" do
    phased = round_for(trace([reasoning("R"), call("call_1"), said("final_answer")]),
      text: "Done.", calls: %w[call_1], replay: responses_replay)
    assert_equal [["reasoning", "R"], ["call", "call_1"], ["message", "final_answer", "Done."], ["result", "call_1"]],
      shape(phased.elements)

    plain = round_for(trace([reasoning("R"), call("call_1"), said(nil)]),
      text: "Done.", calls: %w[call_1], replay: responses_replay)
    assert_equal [["reasoning", "R"], ["message", nil, "Done."], ["call", "call_1"], ["result", "call_1"]],
      shape(plain.elements), "no label: the body's one message ahead of its calls, today's bytes"
  end

  # The Anthropic wire's assistant turn starts with the thinking block: a
  # round that thought and called without a word still sends its signed
  # thinking, as a parts-only message ahead of the call.
  test "signed thinking ahead of a call survives an empty body" do
    thinking = { "type" => "thinking", "thinking" => "plan", "signature" => "sig" }
    envelope = trace([{ "kind" => "reasoning_text", "text" => "plan", "signature" => "sig",
                        "signature_kind" => "anthropic_signature", "provider_payload" => thinking },
                      call("call_1")],
      provider: "anthropic", model: "claude-opus-5-5", api_format: "anthropic_messages", variant: "anthropic_thinking")
    replay = replay_for(provider: "anthropic", model: "claude-opus-5-5", format: "anthropic_thinking")

    round = round_for(envelope, text: nil, calls: %w[call_1], replay: replay)

    host = round.elements.first
    assert_equal "assistant", host.role
    assert_equal [thinking], host.parts.map(&:payload)
    assert_equal [["call", "call_1"], ["result", "call_1"]], shape(round.elements.drop(1))

    compacted = round_for(envelope, text: "Replaced answer", calls: %w[call_1], replay: replay, only_pairs: true)
    assert_equal [thinking], compacted.elements.first.parts.map(&:payload)
    assert_equal [["call", "call_1"], ["result", "call_1"]], shape(compacted.elements.drop(1))
  end

  test "without markers every native item leads and the calls keep the envelope order" do
    round = round_for(trace([reasoning("A"), reasoning("B")]),
      text: "Both.", calls: %w[call_1 call_2], replay: responses_replay)

    assert_equal [["reasoning", "A"], ["reasoning", "B"], ["message", nil, "Both."], ["call", "call_1"],
                  ["call", "call_2"], ["result", "call_1"], ["result", "call_2"]], shape(round.elements)
    assert_nil round.first_slot
  end

  test "a call the trace did not mark trails last" do
    round = round_for(trace([reasoning("R"), said("commentary"), call("call_1")]),
      text: "Reading.", calls: %w[call_1 call_2], replay: responses_replay)

    assert_equal [["reasoning", "R"], ["message", "commentary", "Reading."], ["call", "call_1"], ["call", "call_2"],
                  ["result", "call_1"], ["result", "call_2"]], shape(round.elements)
    assert_equal %w[call_1 call_2], round.call_items.map { |item| item.payload.fetch("call_id") }
  end

  test "a round without a trace replays today's order: the body's one message, no phase, then the calls" do
    round = round_for(nil, text: "Reading.", calls: %w[call_1], replay: responses_replay)

    assert_equal [["message", nil, "Reading."], ["call", "call_1"], ["result", "call_1"]], shape(round.elements)
    assert_empty round.leading
    assert_nil round.first_slot
    assert_nil round.message.native_origin
  end

  test "a preamble and a final answer replay as two messages, each with its phase" do
    round = round_for(trace([said("commentary", "On it."), said("final_answer", "Done: 42")]),
      text: "On it.Done: 42", calls: [])

    assert_nil round.message
    messages = round.trailing.map(&:last)
    assert_equal %w[commentary final_answer], messages.map(&:phase)
    assert_equal ["On it.", "Done: 42"], messages.map { |message| message.parts.sole.text }
    assert_equal [ORIGIN, ORIGIN], messages.map(&:native_origin)
  end

  # Built through the writer, so the envelope is the builder's own shape: a
  # split answer stores each message's words, and a blank message stores
  # none — which reads as blank, never as the single message's body.
  test "adjacent markers of one phase are one message, and a blank run is none" do
    joined = round_for(built(output_message("commentary", "One. "), output_message("commentary", "Two.")),
      text: "One. Two.", calls: [])
    assert_equal [["message", "commentary", "One. Two."]], shape(joined.elements)

    blank = round_for(built(output_message("commentary", " "), output_message("final_answer", "Done.")),
      text: " Done.", calls: [])
    assert_equal [["message", "final_answer", "Done."]], shape(blank.elements),
      "the wire rejects an empty message item, and the answer's words ride once, under their own phase"
  end

  private

    def round_for(envelope, text:, calls:, replay: nil, only_pairs: false)
      composition = AgentRuns::RoundReplay.allocate
      composition.instance_variable_set(:@node, Node.new(output_body: Body.new(effective_text: text)))
      composition.instance_variable_set(:@fan_by_call_id, {})
      composition.instance_variable_set(:@tips_by_call_key, {})
      composition.instance_variable_set(:@cleared, false)
      composition.instance_variable_set(:@replay, replay)
      composition.instance_variable_set(:@trace_envelope, envelope)
      composition.instance_variable_set(:@round_calls,
        calls.map { |id| { "id" => id, "name" => "read_file", "arguments" => "{}" } })
      composition.call(only_pairs: only_pairs)
    end

    def trace(items, provider: "openai_api", model: "gpt-6-sol", api_format: "openai_responses",
              variant: "responses_reasoning")
      { "type" => "reasoning_trace", "format" => "nexus.reasoning_trace.v1", "trace_version" => 2,
        "origin_provider_id" => provider, "origin_model_id" => model, "origin_api_format" => api_format,
        "origin_format_variant" => variant,
        "items" => items.each_with_index.map { |item, ordinal| item.merge("ordinal" => ordinal) } }
    end

    # The envelope TraceBuilder writes for a response of these output items.
    def built(*output_items)
      ModelReasoning::TraceBuilder.call(
        result: TracedResult.new(output_items: output_items, assistant_message: nil, usage: {}),
        origin: { provider_id: "openai_api", model_id: "gpt-6-sol", api_format: "openai_responses",
                  invocation_id: "inv-1" },
        normalized_tool_calls: []
      )
    end

    def output_message(phase, text)
      { "type" => "message", "role" => "assistant", "phase" => phase,
        "content" => [{ "type" => "output_text", "text" => text }] }
    end

    def reasoning(blob, *summaries)
      { "kind" => "reasoning_text", "summary_text" => summaries.join, "encrypted_content" => blob,
        "summary" => summaries.map { |text| { "type" => "summary_text", "text" => text } } }
    end

    def said(phase, text = nil)
      { "kind" => "assistant_message", "phase" => phase, "text" => text }.compact
    end

    def call(id) = { "kind" => "tool_call", "item_id" => id }

    def responses_replay = replay_for(provider: "openai_api", model: "gpt-6-sol", format: "responses_reasoning")

    def replay_for(provider:, model:, format:)
      Conversations::ContextAssembly::Replay.new(mode: "last_turn", target: Target.new(
        provider_id: provider, model_id: model, reasoning_enabled: true,
        capability: Nexus::ReasoningReplayCapability.new(format: format)
      ))
    end

    # Each element as the wire would name it: a reasoning item by its blob,
    # a message by its phase and words, a call or result by its pairing id.
    def shape(elements)
      elements.map do |element|
        case element
        in Nexus::ReasoningInputItem then ["reasoning", element.payload.fetch("encrypted_content")]
        in Nexus::TextInputMessage then ["message", element.phase, element.parts.map(&:text).join]
        in Nexus::ToolCallInputItem then ["call", element.payload.fetch("call_id")]
        in Nexus::ToolResultInputItem then ["result", element.payload.fetch("call_id")]
        end
      end
    end
end
