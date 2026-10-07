require "test_helper"
require "test_helpers/log_capture"

# The one share→budget mapping both surfaces call (the estimate and the
# drain): the caller's ratio onto the model's own window — and the refusal
# when no window exists to share, because silence would unbound exactly
# what the caller asked to bound.
class Conversations::ContextAssemblyHistoryBudgetTest < ActiveSupport::TestCase
  include LogCapture

  def map(share:, advisory: nil, hard: nil)
    Conversations::ContextAssembly::HistoryBudget.call(
      share: share,
      limits: LimitsOf.bounds(advisory: advisory, hard: hard)
    )
  end

  test "no share is no bound, whatever the window" do
    result = map(share: nil)

    assert_predicate result, :accepted?
    assert_nil result.value
  end

  test "the share maps onto the advisory bound first, else the hard bound, floored" do
    assert_equal 50, map(share: 0.5, advisory: 100, hard: 8000).value
    assert_equal 4000, map(share: 0.5, hard: 8000).value
    assert_equal 3, map(share: 0.0004, hard: 8192).value
  end

  test "a share against a windowless model refuses instead of silently unbounding" do
    result = map(share: 0.5)

    assert_not result.accepted?
    assert_equal :history_budget_unavailable, result.outcome
  end

  # ELIGIBILITY IS REASONING, NEVER AN ENVELOPE: an answer that thought nothing still carries a
  # trace when the provider reported its verdict on the replayed history, and that turn must not
  # take the last-turn slot from the older turn whose thinking is the replay.
  test "a last turn with no thinking keeps the previous turn's reasoning replay" do
    target = ModelReasoning::ReplayLadder::Target.new(
      provider_id: "anthropic", model_id: "claude-opus-5-5", reasoning_enabled: true,
      capability: Nexus::ReasoningReplayCapability.new(format: "anthropic_thinking")
    )
    reasoning = Conversations::ContextAssembly::Replay.new(mode: "last_turn", target: target)
    origin = {
      "origin_format_variant" => "anthropic_thinking", "origin_api_format" => "anthropic_messages",
      "origin_provider_id" => "anthropic", "origin_model_id" => "claude-opus-5-5",
    }
    block = { "type" => "thinking", "thinking" => "plan the read", "signature" => "sig-1" }
    thought = ModelReasoning::Trace.new(envelope: origin.merge("items" => [
      { "kind" => "reasoning_text", "text" => "plan the read", "signature" => "sig-1",
        "signature_kind" => "anthropic_signature", "provider_payload" => block, "ordinal" => 0 },
    ]))
    # The envelope the builder writes for a thought-less answer: its message's
    # place in the walk and the verdict — an envelope with items, none of them
    # replay material.
    verdict_only = ModelReasoning::Trace.new(envelope: origin.merge(
      "items" => [{ "kind" => "assistant_message", "ordinal" => 0 }], "input_transformations" => []
    ))
    segments = [
      Conversations::ContextAssembly::Segment.plain("user", "read a.txt"),
      Conversations::ContextAssembly::Segment.plain("assistant", "Reading it.", trace: thought),
      Conversations::ContextAssembly::Segment.plain("user", "and now?"),
      Conversations::ContextAssembly::Segment.plain("assistant", "Done.", trace: verdict_only),
      Conversations::ContextAssembly::Segment.plain("user", "thanks"),
    ]

    replayed, reasons = Conversations::ContextAssembly::Replayed.decide(segments, replay: reasoning, profile: nil)

    assert_equal [block], replayed[1].reasoning_parts.map(&:payload), "the older turn's thinking still rides"
    assert_empty replayed[3].reasoning_parts
    assert_empty reasons, "a turn that thought nothing is no degradation"
  end

  test "signature-only Gemini replay is priced by its captured reasoning count" do
    profile = DevModelLane.profile_with(DevModelLane.profile_for("dev/mock-text"), token_counter: nil)
    target = ModelReasoning::ReplayLadder::Target.new(
      provider_id: "gemini", model_id: "model", reasoning_enabled: true,
      capability: Nexus::ReasoningReplayCapability.new(format: "gemini_thought")
    )
    replay = Conversations::ContextAssembly::Replay.new(mode: "all", target: target)
    trace = ModelReasoning::Trace.new(envelope: {
      "origin_format_variant" => "gemini_thought", "origin_api_format" => "gemini_generate_content",
      "origin_provider_id" => "gemini", "origin_model_id" => "model",
      "items" => [
        { "kind" => "tool_call", "item_id" => "read-call", "signature" => "opaque-signature",
          "signature_kind" => "gemini_thought_signature", "ordinal" => 0,
          "provider_payload" => { "thoughtSignature" => "opaque-signature",
            "functionCall" => { "id" => "read-call", "name" => "read_file", "args" => {} } } },
        { "kind" => "token_accounting", "reasoning_tokens" => 20, "ordinal" => 1 },
      ],
    })
    call = Nexus::ToolCallInputItem.new(type: "tool_call_item", payload: {
      "type" => "function_call", "call_id" => "read-call", "name" => "read_file", "arguments" => "{}",
    })
    segment = Conversations::ContextAssembly::Segment.round("assistant", "", calls: [call], trailing: [[0, call]],
      first_slot: 0, results: [], trace: trace)
    base = Conversations::ContextAssembly::FillCost.segment(segment, profile)

    replayed, = Conversations::ContextAssembly::Replayed.decide([segment], replay: replay, profile: profile)
    assert_equal "opaque-signature", replayed.first.call_items.first.payload.dig("provider_payload", "thoughtSignature")
    assert_equal base + 20, Conversations::ContextAssembly::FillCost.segment(replayed.first, profile),
      "opaque native replay is not free merely because it has no readable thought: it costs its captured count"
  end

  # A signed call is replay material on its own: the signature rides its call even when the
  # provider reported no thought and no count, so such a turn keeps its replay slot.
  test "a turn whose only native material is a signed call is still replayed" do
    target = ModelReasoning::ReplayLadder::Target.new(
      provider_id: "gemini", model_id: "model", reasoning_enabled: true,
      capability: Nexus::ReasoningReplayCapability.new(format: "gemini_thought")
    )
    replay = Conversations::ContextAssembly::Replay.new(mode: "last_turn", target: target)
    trace = ModelReasoning::Trace.new(envelope: {
      "origin_format_variant" => "gemini_thought", "origin_api_format" => "gemini_generate_content",
      "origin_provider_id" => "gemini", "origin_model_id" => "model",
      "items" => [
        { "kind" => "tool_call", "item_id" => "read-call", "signature" => "opaque-signature",
          "signature_kind" => "gemini_thought_signature", "ordinal" => 0,
          "provider_payload" => { "thoughtSignature" => "opaque-signature",
            "functionCall" => { "id" => "read-call", "name" => "read_file", "args" => {} } } },
      ],
    })
    call = Nexus::ToolCallInputItem.new(type: "tool_call_item", payload: {
      "type" => "function_call", "call_id" => "read-call", "name" => "read_file", "arguments" => "{}",
    })
    segment = Conversations::ContextAssembly::Segment.round("assistant", "", calls: [call], trailing: [[0, call]],
      first_slot: 0, results: [], trace: trace)

    replayed, = Conversations::ContextAssembly::Replayed.decide([segment], replay: replay, profile: nil)

    assert_equal "opaque-signature", replayed.first.call_items.first.payload.dig("provider_payload", "thoughtSignature")
    assert_equal replayed.first.call_items, replayed.first.trailing.map(&:last),
      "the signed call replaces its original where the round placed it, too"
  end

  # THE STARVATION PIN: slots, memory and inline all fund AHEAD of history, so three full slots and
  # a full block on a small window drive the history budget to zero — an answer (nothing selected,
  # `budget_exceeded`), never a negative budget and never a raise; the window gate, not the
  # assembler, refuses a prompt that cannot fit. Pinned before the BudgetAllocator port.
  test "slots and memory can starve history to a zero budget, never below and never a raise" do
    profile = DevModelLane.profile_with(DevModelLane.profile_for("dev/mock-text"), token_counter: nil)
    limits = LimitsOf.bounds(advisory: nil, hard: 8_000)
    slot = Conversations::ContextAssembly::Segment.plain("system", "s" * 65_536)
    memory = Conversations::ContextAssembly::Segment.plain("user", "m" * 16_384)
    prompt = Conversations::ContextAssembly::Segment.plain("user", "x")

    budget = history_budget(profile, limits, prompt, slot, slot, slot, memory)

    assert_equal 0, budget, "three 64 KiB slots + a 16 KiB block outfund an 8k window: zero, not negative"
    assert_equal 7_000 - 1 - 16_384 / 4, history_budget(profile, limits, prompt, memory),
      "and with headroom the funded segments are charged at fill cost, the answer room left aside"
  end

  def history_budget(profile, limits, *funded)
    floors = funded.each_with_index.to_h { |segment, index| ["funded:#{index}", Conversations::ContextAssembly::FillCost.segment(segment, profile)] }
    Conversations::ContextAssembly.send(:size, floors: floors, history: {}, profile: profile, limits: limits).history_budget
  end

  # The FILL estimator: exact counters speak tokens; everything else falls
  # to the predecessor's bytes/4 — an upper-bound count is a gate's
  # conservatism, not a filler's (one token per byte would waste roughly
  # three quarters of every counter-less window).
  test "fill cost counts exactly when it can and at bytes/4 when it cannot" do
    exact_profile = DevModelLane.profile_for("dev/mock-text")
    counted = ModelRequests::TokenCount.count(
      profile: exact_profile, segments: ["hello there world"]
    )
    assert_predicate counted, :exact?, "the dev lane's declared counter is the exact arm"
    assert_equal counted.tokens,
      Conversations::ContextAssembly::FillCost.call("hello there world", exact_profile)

    counterless = DevModelLane.profile_with(exact_profile, token_counter: nil)
    assert_equal 10,
      Conversations::ContextAssembly::FillCost.call("x" * 40, counterless),
      "40 bytes fill as 10 tokens — the predecessor's heuristic, not 40"
    assert_equal 0, Conversations::ContextAssembly::FillCost.call(nil, exact_profile)
  end
end
