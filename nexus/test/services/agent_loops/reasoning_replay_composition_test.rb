require "test_helper"

# The continuation's replay half — the part a mock CAN prove: which rung
# reaches the request, and whether a signature lands on the call it was
# bound to. (Whether a provider ACCEPTS it is the live lane's business.)
class AgentLoops::ReasoningReplayCompositionTest < ActiveSupport::TestCase
  Composition = AgentLoops::RoundReplay
  Target = ModelReasoning::ReplayLadder::Target

  # A Gemini turn as TraceBuilder stamps it: the call's marker is NOT at
  # the call's own ordinal, because the trace numbers every item it holds
  # while the calls are numbered within their own array.
  GEMINI_TRACE = {
    "type" => "reasoning_trace", "format" => "nexus.reasoning_trace.v1",
    "trace_version" => 2, "origin_provider_id" => "gemini",
    "origin_model_id" => "gemini-3.7-flash",
    "origin_format_variant" => "gemini_thought",
    "items" => [
      { "kind" => "reasoning_text", "text" => "thinking", "ordinal" => 0 },
      { "kind" => "tool_call", "signature" => "sig-for-call-1",
        "item_id" => "call_1", "ordinal" => 1,
        "provider_payload" => { "thoughtSignature" => "sig-for-call-1",
                                "functionCall" => { "id" => "call_1", "name" => "read", "args" => { "path" => "one" } } } },
      { "kind" => "tool_call", "signature" => "sig-for-call-2",
        "item_id" => "call_2", "ordinal" => 2,
        "provider_payload" => { "thoughtSignature" => "sig-for-call-2",
                                "functionCall" => { "id" => "call_2", "name" => "read", "args" => { "path" => "two" } } } },
    ],
  }.freeze

  def target(model_id: "gemini-3.7-flash", provider_id: "gemini", format: "gemini_thought", effort: "medium")
    capability = Nexus::ReasoningReplayCapability.new(
      format: format
    )
    Target.new(provider_id: provider_id, model_id: model_id,
      reasoning_effort: effort, capability: capability)
  end

  def signatures_for(target_model, mode: "last_turn", **target_options)
    composition = Composition.allocate
    composition.instance_variable_set(:@trace_envelope, GEMINI_TRACE)
    composition.instance_variable_set(
      :@replay,
      Conversations::ContextAssembly::Replay.new(mode: mode,
        target: target(model_id: target_model, **target_options))
    )
    payloads = composition.send(:replay_decision)&.call_payloads || {}
    payloads.transform_values { |payload| payload.fetch("thoughtSignature") }
  end

  test "a signature is keyed by the CALL it was bound to, not by a trace ordinal" do
    assert_equal({ "call_1" => "sig-for-call-1", "call_2" => "sig-for-call-2" },
      signatures_for("gemini-3.7-flash"),
      "the trace numbers every item it holds and the calls are numbered " \
        "within their own array - joining on that number dropped the " \
        "signature with one call and handed the WRONG one over with two")
  end

  test "a cross-model replay re-emits no signature, even though its rung is allowed" do
    ladder = ModelReasoning::ReplayLadder.call(
      trace: ModelReasoning::Trace.new(envelope: GEMINI_TRACE),
      target: target(model_id: "gemini-4.0-pro")
    )
    assert_equal :native_parts, ladder.kind,
      "this wire's UNSIGNED thought parts are deliberately cross-model safe"
    assert_equal({}, signatures_for("gemini-4.0-pro"),
      "but a SIGNATURE is not: re-emitting one to a foreign model is the " \
        "exact 400 that relaxation was careful to avoid"
  )
  end

  test "tool signatures never cross the provider, wire format or replay policy boundary" do
    assert_empty signatures_for("gemini-3.7-flash", provider_id: "another-provider")
    assert_empty signatures_for("gemini-3.7-flash", format: "none")
    assert_empty signatures_for("gemini-3.7-flash", mode: "none")
    assert_empty signatures_for("gemini-3.7-flash", effort: "none")
  end
end
