require "test_helper"

# The per-turn replay ladder: the native shape where the target can read
# it, else nothing — a trace whose origin misses the target contributes no
# bytes, never a fence in content. Every miss names its gate, and nothing
# here ever raises.
class ModelReasoning::ReplayLadderTest < ActiveSupport::TestCase
  def trace(format:, provider: "prov", model: "m-1", items: [])
    ModelReasoning::Trace.new(envelope: {
      "origin_format_variant" => format, "origin_provider_id" => provider,
      "origin_model_id" => model, "items" => items,
    })
  end

  def target(format:, provider: "prov", model: "m-1", enabled: true)
    ModelReasoning::ReplayLadder::Target.new(
      provider_id: provider, model_id: model, reasoning_enabled: enabled,
      capability: Nexus::ReasoningReplayCapability.new(format: format)
    )
  end

  def decide(trace, target)
    ModelReasoning::ReplayLadder.call(trace: trace, target: target)
  end

  test "anthropic same-model: signed blocks and redacted data replay verbatim" do
    signed = trace(format: "anthropic_thinking", items: [
      { "text" => "chain", "signature" => "sig", "signature_kind" => "anthropic_signature" },
      { "encrypted_content" => "blob", "redacted" => true },
    ])

    decision = decide(signed, target(format: "anthropic_thinking"))

    assert_equal :native_parts, decision.kind
    thinking, redacted = decision.payloads
    assert_equal({ "type" => "thinking", "thinking" => "chain", "signature" => "sig" }, thinking)
    assert_equal({ "type" => "redacted_thinking", "data" => "blob" }, redacted)
  end

  test "unsigned Anthropic-compatible thinking needs a declared target and exact provider and model" do
    block = { "type" => "thinking", "thinking" => "Reasoned", "signature" => "" }
    captured = trace(format: "anthropic_thinking", items: [{ "text" => "Reasoned", "provider_payload" => block }])
    ordinary = target(format: "anthropic_thinking")
    compatible = ordinary.with(allow_empty_thinking_signature: true)

    assert_equal "missing_signature", decide(captured, ordinary).reason
    assert_equal [block], decide(captured, compatible).payloads
    assert_equal :drop, decide(captured, compatible.with(provider_id: "other")).kind
    assert_equal :drop, decide(captured, compatible.with(model_id: "other")).kind
    assert_equal :drop, decide(captured, compatible.with(reasoning_enabled: false)).kind
  end

  test "Pi thinking and Bedrock reasoning keep native payloads within their provider and model" do
    cases = {
      "pi_messages" => ["pi_thinking", { "type" => "thinking", "thinking" => "Thought", "thinkingSignature" => "sig" }],
      "bedrock_converse" => ["bedrock_reasoning", { "reasoningContent" => { "reasoningText" => { "text" => "Thought", "signature" => "sig" } } }],
    }
    cases.each do |api, (format, block)|
      result = SimpleInference::Responses::Result.new(output_text: "", tool_calls: [],
        output_items: [{ "type" => "reasoning", "text" => "Thought", "signature" => "sig", "provider_payload" => block }],
        usage: {}, finish_reason: "stop", finish_detail: "stop", provider_response: nil, provider_format: "responses")
      envelope = ModelReasoning::TraceBuilder.call(result: result,
        origin: { provider_id: "prov", model_id: "m-1", api_format: api }, normalized_tool_calls: [])
      captured = ModelReasoning::Trace.new(envelope: envelope)
      assert_equal format, captured.origin_format_variant, api
      same = target(format: format)
      expected = api == "pi_messages" ? block : { "type" => "bedrock_reasoning", "provider_payload" => block }
      assert_equal [expected], decide(captured, same).payloads, api
      assert_equal "origin_provider_mismatch", decide(captured, same.with(provider_id: "other")).reason, api
      assert_equal "cross_model_mismatch", decide(captured, same.with(model_id: "other")).reason, api
      assert_equal "reasoning_disabled", decide(captured, same.with(reasoning_enabled: false)).reason, api
    end
  end

  test "the verbatim block wins: Claude 5's signature-only thinking replays exactly as received" do
    signature_only = trace(format: "anthropic_thinking", items: [
      { "signature" => "sig-348", "signature_kind" => "anthropic_signature",
        "provider_payload" => {
          "type" => "thinking", "thinking" => "", "signature" => "sig-348",
        } },
    ])

    decision = decide(signature_only, target(format: "anthropic_thinking"))

    assert_equal :native_parts, decision.kind
    assert_equal(
      { "type" => "thinking", "thinking" => "", "signature" => "sig-348" },
      decision.payloads.sole,
      "live-measured 2026-08-29: the wire returns no thinking text on this " \
      "family; the continuation contract is replay-exactly-what-came-back"
    )
  end

  # Anthropic's own rule: keep sending the full history and let the API drop
  # what the current model cannot read — silently, and unbilled. A block
  # therefore passes unchanged to another model of the provider.
  test "anthropic across its models: the blocks pass unchanged for the API to keep or drop" do
    signed = trace(format: "anthropic_thinking", items: [
      { "text" => "the full chain", "signature" => "sig",
        "signature_kind" => "anthropic_signature" },
    ])

    decision = decide(signed, target(format: "anthropic_thinking", model: "m-2"))

    assert_equal :native_parts, decision.kind
    assert_nil decision.reason
    assert_equal [{ "type" => "thinking", "thinking" => "the full chain", "signature" => "sig" }], decision.payloads
  end

  test "responses same-model replays the encrypted item; another model reads nothing of it" do
    blob = trace(format: "responses_reasoning", items: [
      { "text" => "hidden", "summary_text" => "the plan", "encrypted_content" => "gAAA",
        "summary" => [{ "type" => "summary_text", "text" => "the plan" }], "ordinal" => 0 },
    ])

    native = decide(blob, target(format: "responses_reasoning"))
    assert_equal :native_item, native.kind
    assert_equal "gAAA", native.payloads.sole["encrypted_content"]
    assert_equal [{ "type" => "summary_text", "text" => "the plan" }],
      native.payloads.sole["summary"]
    assert_equal [0], native.ordinals, "the decision names the trace item it replays"

    crossed = decide(blob, target(format: "responses_reasoning", model: "other"))
    assert_equal :drop, crossed.kind
    assert_equal "cross_model_mismatch", crossed.reason
    assert_empty crossed.payloads, "no summary crosses as text either"
  end

  # A round that thinks between its calls leaves one reasoning item per thought, each with its
  # own blob and its own summary parts; folding them into the first lost every later blob.
  test "responses same-model replays EVERY encrypted item in wire order, each with its own summary parts" do
    one_two = [{ "type" => "summary_text", "text" => "one" }, { "type" => "summary_text", "text" => "two" }]
    three = [{ "type" => "summary_text", "text" => "three" }]
    round = trace(format: "responses_reasoning", items: [
      { "kind" => "reasoning_text", "encrypted_content" => "A", "summary_text" => "onetwo",
        "summary" => one_two, "ordinal" => 0 },
      { "kind" => "assistant_message", "phase" => "commentary", "ordinal" => 1 },
      { "kind" => "tool_call", "item_id" => "call_1", "ordinal" => 2 },
      { "kind" => "reasoning_text", "encrypted_content" => "B", "summary_text" => "three",
        "summary" => three, "ordinal" => 3 },
      { "kind" => "tool_call", "item_id" => "call_2", "ordinal" => 4 },
    ])

    decision = decide(round, target(format: "responses_reasoning"))

    assert_equal :native_item, decision.kind
    assert_equal [
      { "type" => "reasoning", "encrypted_content" => "A", "summary" => one_two },
      { "type" => "reasoning", "encrypted_content" => "B", "summary" => three },
    ], decision.payloads, "two parts stay two parts, and each item keeps only its own"
    assert_equal [0, 3], decision.ordinals
  end

  test "an item without encrypted content is display-only and never rides another item's blob" do
    mixed = trace(format: "responses_reasoning", items: [
      { "kind" => "reasoning_text", "summary_text" => "s",
        "summary" => [{ "type" => "summary_text", "text" => "s" }], "ordinal" => 0 },
      { "kind" => "reasoning_text", "encrypted_content" => "B", "ordinal" => 1 },
    ])

    decision = decide(mixed, target(format: "responses_reasoning"))

    assert_equal [{ "type" => "reasoning", "encrypted_content" => "B", "summary" => [] }], decision.payloads,
      "the display-only summary never rides on another item's blob"
    assert_equal [1], decision.ordinals
  end

  test "gemini replays unsigned thought text with no same-model gate" do
    thought = trace(format: "gemini_thought", model: "gem-old", items: [
      { "text" => "thought text", "signature" => "gsig",
        "signature_kind" => "gemini_thought_signature" },
    ])

    decision = decide(thought, target(format: "gemini_thought", model: "gem-new"))

    assert_equal :native_parts, decision.kind
    assert_equal({ "type" => "thought", "text" => "thought text" }, decision.payloads.sole,
      "unsigned always accepted; a foreign signature is a 400 — so no signature ever rides")
  end

  test "every miss names its gate" do
    open_trace = trace(format: "chatcompletions_reasoning_content",
      items: [{ "text" => "open chain" }])

    assert_equal "origin_format_mismatch",
      decide(open_trace, target(format: "anthropic_thinking")).reason
    assert_equal "origin_provider_mismatch",
      decide(trace(format: "anthropic_thinking", provider: "other",
        items: [{ "text" => "t" }]), target(format: "anthropic_thinking")).reason
    assert_equal "reasoning_disabled",
      decide(trace(format: "anthropic_thinking", items: [{ "text" => "t" }]),
        target(format: "anthropic_thinking", enabled: false)).reason
    assert_equal "missing_signature",
      decide(trace(format: "anthropic_thinking", items: [{ "text" => "unsigned" }]),
        target(format: "anthropic_thinking")).reason
    assert_equal "missing_encrypted_content",
      decide(trace(format: "responses_reasoning", items: [{ "summary_text" => "s" }]),
        target(format: "responses_reasoning")).reason
  end

  test "the drop rung: a miss carries its gate, a disabled format drops silently, junk never raises" do
    redacted_only = trace(format: "anthropic_thinking",
      items: [{ "encrypted_content" => "b", "redacted" => true }])
    decision = decide(redacted_only, target(format: "anthropic_thinking", provider: "other"))
    assert_equal :drop, decision.kind
    assert_equal "origin_provider_mismatch", decision.reason

    off = decide(redacted_only, target(format: "none"))
    assert_equal :drop, off.kind
    assert_equal "replay_disabled", off.reason

    junk = ModelReasoning::Trace.new(envelope: { "items" => "not-a-list" })
    assert_equal :drop, decide(junk, target(format: "anthropic_thinking")).kind,
      "a malformed trace never breaks a request — it just doesn't ride"
  end

  test "an open-weight trace never rides into another wire's field" do
    open_trace = trace(format: "chat_reasoning", items: [{ "kind" => "reasoning_text", "text" => "k3 chain" }])

    decision = decide(open_trace, target(format: "anthropic_thinking"))

    assert_equal :drop, decision.kind
    assert_equal "origin_format_mismatch", decision.reason
  end

  # The chat wire's own field: the broker's detail blocks verbatim, in their
  # order (they may be encrypted or signed, and the sequence must match what
  # the model produced), else the plain reasoning text — never an answer's
  # words, which a marker holds.
  test "chat_reasoning replays the broker's detail blocks verbatim, else the reasoning text" do
    blocks = [
      { "type" => "reasoning.text", "text" => "first thought", "index" => 0 },
      { "type" => "reasoning.encrypted", "data" => "opaque", "id" => "d2" },
    ]
    detailed = trace(format: "chat_reasoning", items: [
      { "kind" => "reasoning.text", "text" => "first thought", "provider_payload" => blocks[0], "ordinal" => 0 },
      { "kind" => "reasoning_encrypted", "encrypted_content" => "opaque", "provider_payload" => blocks[1], "ordinal" => 1 },
      { "kind" => "assistant_message", "text" => "the answer", "ordinal" => 2 },
    ])

    decision = decide(detailed, target(format: "chat_reasoning"))
    assert_equal :native_parts, decision.kind
    assert_equal [{ "type" => "reasoning_details", "blocks" => blocks }], decision.payloads

    plain = trace(format: "chat_reasoning", items: [
      { "kind" => "reasoning_text", "text" => "plan a", "ordinal" => 0 },
      { "kind" => "reasoning_text", "text" => "plan b", "ordinal" => 1 },
      { "kind" => "assistant_message", "text" => "the answer", "ordinal" => 2 },
      { "kind" => "token_accounting", "reasoning_tokens" => 40, "ordinal" => 3 },
    ])
    decision = decide(plain, target(format: "chat_reasoning"))
    assert_equal [{ "type" => "reasoning_content", "text" => "plan a\n\nplan b" }], decision.payloads

    assert_equal "cross_model_mismatch", decide(plain, target(format: "chat_reasoning", model: "m-2")).reason,
      "the sequence must be the model's own"
    assert_equal "reasoning_disabled", decide(plain, target(format: "chat_reasoning", enabled: false)).reason
    assert_equal "missing_native_text",
      decide(trace(format: "chat_reasoning", items: [{ "kind" => "token_accounting", "reasoning_tokens" => 9 }]),
        target(format: "chat_reasoning")).reason
  end

  # DeepSeek's Responses route takes plain-text reasoning items back and
  # merges each into its assistant message: one item per thought, at the
  # place it was thought.
  test "responses_reasoning_text replays each thought as a plain-text reasoning item at its ordinal" do
    round = trace(format: "responses_reasoning_text", items: [
      { "kind" => "reasoning_text", "text" => "look first", "ordinal" => 0 },
      { "kind" => "tool_call", "item_id" => "call_1", "ordinal" => 1 },
      { "kind" => "reasoning_text", "text" => "then answer", "ordinal" => 2 },
      { "kind" => "assistant_message", "ordinal" => 3 },
    ])

    decision = decide(round, target(format: "responses_reasoning_text"))

    assert_equal :native_item, decision.kind
    assert_equal [
      { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "look first" }] },
      { "type" => "reasoning", "content" => [{ "type" => "reasoning_text", "text" => "then answer" }] },
    ], decision.payloads
    assert_equal [0, 2], decision.ordinals
    assert_equal "cross_model_mismatch",
      decide(round, target(format: "responses_reasoning_text", model: "m-2")).reason
    assert_equal "reasoning_disabled",
      decide(round, target(format: "responses_reasoning_text", enabled: false)).reason
  end
end
