require "test_helper"

# The continuation's replay half — the part a mock CAN prove: which rung
# reaches the request, and whether a signature lands on the call it was
# bound to. (Whether a provider ACCEPTS it is the live lane's business.)
class Runs::ReasoningReplayCompositionTest < ActiveSupport::TestCase
  NATIVE_SIGNATURES = { "call_1" => "sig-for-call-1", "call_2" => "sig-for-call-2" }.freeze
  IMPORTED_SIGNATURES = { "call_1" => "skip_thought_signature_validator", "call_2" => nil }.freeze
  Target = ModelReasoning::ReplayLadder::Target

  # A Gemini turn as TraceBuilder stamps it: the call's marker is NOT at
  # the call's own ordinal, because the trace numbers every item it holds
  # while the calls are numbered within their own array.
  GEMINI_TRACE = {
    "type" => "reasoning_trace", "format" => "nexus.reasoning_trace.v1",
    "trace_version" => 2, "origin_provider_id" => "gemini",
    "origin_model_id" => "gemini-4-hydrogen",
    "origin_api_format" => "gemini_generate_content", "origin_format_variant" => "gemini_thought",
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

  def target(model_id: "gemini-4-hydrogen", provider_id: "gemini", format: "gemini_thought", enabled: true)
    capability = Nexus::ReasoningReplayCapability.new(
      format: format
    )
    Target.new(provider_id: provider_id, model_id: model_id,
      reasoning_enabled: enabled, capability: capability)
  end

  test "a signature is keyed by the CALL it was bound to, not by a trace ordinal" do
    assert_equal(NATIVE_SIGNATURES, wire_signatures(target),
      "the trace numbers every item it holds and the calls are numbered " \
        "within their own array - joining on that number dropped the " \
        "signature with one call and handed the WRONG one over with two")
  end

  test "a cross-model replay keeps native signatures in the sealed round and sends imported calls" do
    ladder = ModelReasoning::ReplayLadder.call(
      trace: ModelReasoning::Trace.new(envelope: GEMINI_TRACE),
      target: target(model_id: "gemini-4.0-pro")
    )
    assert_equal :native_parts, ladder.kind,
      "this wire's UNSIGNED thought parts are deliberately cross-model safe"
    destination = target(model_id: "gemini-4.0-pro")
    round = composed_round(destination)
    assert_equal NATIVE_SIGNATURES, round.call_items.to_h { |call|
      [call.payload.fetch("call_id"), call.payload.dig("provider_payload", "thoughtSignature")]
    }
    assert_equal IMPORTED_SIGNATURES, wire_signatures(destination, round: round)
  end

  test "tool signatures never cross the provider, wire format or replay policy boundary" do
    assert_equal IMPORTED_SIGNATURES, wire_signatures(target(provider_id: "another-provider"))
    assert_equal IMPORTED_SIGNATURES, wire_signatures(target(format: "none"))
    assert_equal IMPORTED_SIGNATURES, wire_signatures(target, mode: "none")
    # GenerateContent itself refuses reasoning_enabled: false. A round
    # composed under that policy stays unsigned when later compiled for Gemini.
    disabled = composed_round(target(enabled: false))
    assert_equal IMPORTED_SIGNATURES, wire_signatures(target, round: disabled)
  end

  private

    def composed_round(destination, mode: "last_turn")
      replay = Conversations::ContextAssembly::Replay.new(mode: mode, target: destination)
      composition = Runs::RoundReplay.new(Tasks::ModelTask.new, fan_by_call_id: {}, replay: replay)
      calls = GEMINI_TRACE.fetch("items").filter_map do |item|
        next unless item["kind"] == "tool_call"

        call = item.fetch("provider_payload").fetch("functionCall")
        { "id" => call.fetch("id"), "name" => call.fetch("name"), "arguments" => call.fetch("args").to_json }
      end
      composition.stub(:round_calls, calls) do
        composition.stub(:trace_envelope, GEMINI_TRACE) { composition.call }
      end
    end

    def wire_signatures(destination, mode: "last_turn", round: composed_round(destination, mode: mode))
      profile = ModelCatalog::ProfileBuilder.call(model_ref: "#{destination.provider_id}/#{destination.model_id}",
        provider: { "api_format" => "gemini_generate_content" }, model: {})
      inference = InferenceRequest.create!(account: accounts(:cybros), workspace: workspaces(:shared),
        creating_user: users(:member), workload: "text_generation")
      invocation = ModelInvocation.create!(inference_request: inference, provider_id: destination.provider_id,
        model_ref: destination.model_id, reasoning_enabled: destination.reasoning_enabled,
        admission_deadline_seconds: profile.total_execution_deadline_seconds)
      body = ContentBodies::Replace.call(owner: invocation, role: "request",
        entries: Nexus::InputEntries.for(round.elements), seal: true)
      assert body.accepted?, body.refusal.inspect
      built = ModelRequests::Build.call(invocation: invocation, profile: profile, base_url: "https://lane.example",
        host: "solid_queue")
      assert built.built?, built.refusal.inspect

      parts = JSON.parse(built.request.payload).fetch("contents").flat_map { |content| content.fetch("parts") }
      parts.select { |part| part.key?("functionCall") }.to_h do |part|
        [part.fetch("functionCall").fetch("id"), part["thoughtSignature"]]
      end
    end
end
