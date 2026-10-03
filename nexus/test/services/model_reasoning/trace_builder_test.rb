require "test_helper"

# The capture half of cross-model reasoning: the builder freezes every
# provider's native material — signatures, encrypted blobs, redacted data,
# item ids, order — into one provenance envelope at the execution
# boundary. Provenance cannot be backfilled; what this misses is lost.
class ModelReasoning::TraceBuilderTest < ActiveSupport::TestCase
  FakeResult = Data.define(:output_items, :assistant_message, :usage) do
    def self.empty = new(output_items: [], assistant_message: nil, usage: {})
  end

  def build(result, api_format:, provider_id: "prov", model_id: "wire-model")
    ModelReasoning::TraceBuilder.call(
      result: result,
      normalized_tool_calls: Nexus::ModelToolCalls.normalize(
        result.output_items.select { |item| item["type"] == "function_call" }
      ),
      origin: { provider_id: provider_id, model_id: model_id,
                api_format: api_format, invocation_id: "inv-1" }
    )
  end

  test "anthropic thinking blocks keep their signatures and redacted data" do
    result = FakeResult.new(
      output_items: [
        { "type" => "reasoning", "text" => "let me think", "signature" => "sig-abc" },
        { "type" => "redacted_thinking", "data" => "opaque-blob" },
      ],
      assistant_message: { "content" => "answer" }, usage: {}
    )

    envelope = build(result, api_format: "anthropic_messages", provider_id: "anthropic")

    assert_equal "anthropic_thinking", envelope["origin_format_variant"]
    assert_equal "anthropic", envelope["origin_provider_id"]
    assert_equal "wire-model", envelope["origin_model_id"]
    signed, redacted = envelope["items"]
    assert_equal "sig-abc", signed["signature"]
    assert_equal "anthropic_signature", signed["signature_kind"],
      "the signature binds to its origin family at capture"
    assert_equal "opaque-blob", redacted["encrypted_content"]
    assert redacted["redacted"], "redacted material never text-replays"
    assert_equal [0, 1], envelope["items"].map { |i| i["ordinal"] }
  end

  test "responses reasoning items keep encrypted content, summaries, and ids" do
    result = FakeResult.new(
      output_items: [
        { "type" => "reasoning", "id" => "rs_123",
          "summary" => [{ "type" => "summary_text", "text" => "planned x" }],
          "encrypted_content" => "gAAAA-blob" },
      ],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "openai_responses")

    assert_equal "responses_reasoning", envelope["origin_format_variant"]
    item = envelope["items"].sole
    assert_equal "rs_123", item["item_id"]
    assert_equal "planned x", item["summary_text"]
    assert_equal "gAAAA-blob", item["encrypted_content"]
    assert_nil item["signature_kind"], "responses items carry blobs, not family signatures"
  end

  test "gemini thoughts and tool-call thought signatures both capture in order" do
    result = FakeResult.new(
      output_items: [
        { "type" => "reasoning", "text" => "thought", "signature" => "gsig" },
        { "type" => "function_call", "id" => "call-1", "name" => "look",
          "provider_payload" => { "thoughtSignature" => "toolsig",
                                  "functionCall" => { "id" => "call-1" } } },
      ],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "gemini_generate_content")

    assert_equal "gemini_thought", envelope["origin_format_variant"]
    thought, tool = envelope["items"]
    assert_equal "gemini_thought_signature", thought["signature_kind"]
    assert_equal "tool_call", tool["kind"], "one item per call, one kind: the call's marker carries its signature"
    assert_equal "toolsig", tool["signature"]
    assert_equal "gemini_thought_signature", tool["signature_kind"]
    assert_equal "call-1", tool["item_id"]
  end

  # Responses keeps a reasoning item's summary as PARTS: the wire's array rides verbatim for
  # the native replay, and the joined text stays the display and fence text.
  test "a responses reasoning item keeps its summary parts apart" do
    parts = [{ "type" => "summary_text", "text" => "one" }, { "type" => "summary_text", "text" => "two" }]
    result = FakeResult.new(
      output_items: [{ "type" => "reasoning", "id" => "rs_1", "summary" => parts, "encrypted_content" => "A" }],
      assistant_message: nil, usage: {}
    )

    item = build(result, api_format: "openai_responses")["items"].sole

    assert_equal parts, item["summary"], "two parts stay two parts"
    assert_equal "onetwo", item["summary_text"]
  end

  # POSITION IS THE FACT A REPLAY PLACES BY: every output item the wire sent holds its place in
  # the walk — the reasoning, the answer's message (a marker, with its phase) and each call (a
  # marker keyed by the normalized call id), numbered in encounter order.
  test "responses output items are traced in wire order: reasoning, the phased message, the calls" do
    result = FakeResult.new(
      output_items: [
        { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "A",
          "summary" => [{ "type" => "summary_text", "text" => "plan" }] },
        { "type" => "message", "id" => "msg_1", "role" => "assistant", "phase" => "commentary",
          "content" => [{ "type" => "output_text", "text" => "I'll read a.txt" }] },
        { "type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "read", "arguments" => "{}" },
        { "type" => "reasoning", "id" => "rs_2", "encrypted_content" => "B" },
        { "type" => "function_call", "id" => "fc_2", "call_id" => "call_2", "name" => "read", "arguments" => "{}" },
      ],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "openai_responses")

    assert_equal 2, envelope["trace_version"]
    items = envelope["items"]
    assert_equal %w[reasoning_text assistant_message tool_call reasoning_text tool_call], items.map { |i| i["kind"] }
    assert_equal [0, 1, 2, 3, 4], items.map { |i| i["ordinal"] }
    assert_equal({ "kind" => "assistant_message", "phase" => "commentary", "ordinal" => 1 }, items[1],
      "one message item reads its words from the body: no text, and no wire id to replay")
    assert_equal %w[call_1 call_2], items.values_at(2, 4).map { |i| i["item_id"] }
    assert items.values_at(2, 4).none? { |i| i.key?("signature") }, "an unsigned call carries no signature"
    trace = ModelReasoning::Trace.new(envelope: envelope)
    assert_equal [1, 2, 4], trace.markers.map { |i| i["ordinal"] }
    assert_equal [0, 3], trace.reasoning_items.map { |i| i["ordinal"] }
  end

  # A preamble and a final answer in one response are two messages: each marker keeps its own
  # words so a replay can send them apart, and they join back into the answer's text.
  test "a split answer stores each message's own words" do
    result = FakeResult.new(
      output_items: [
        { "type" => "message", "phase" => "commentary", "content" => [{ "type" => "output_text", "text" => "On it." }] },
        { "type" => "message", "phase" => "final_answer", "content" => [{ "type" => "output_text", "text" => "Done: 42" }] },
      ],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "openai_responses")

    markers = ModelReasoning::Trace.new(envelope: envelope).markers
    assert_equal ["On it.", "Done: 42"], markers.map { |m| m["text"] }
    assert_equal "On it.Done: 42", markers.map { |m| m["text"] }.join,
      "the body joins its message items with nothing between"
    assert_equal "final_answer", ModelReasoning::Trace.new(envelope: envelope).assistant_phase,
      "the answer's label is its last message's phase"
  end

  # Anthropic's text block normalizes to a message item without a phase: still a place in the
  # walk, never a label.
  test "a message item without a phase is still a positional marker" do
    result = FakeResult.new(
      output_items: [
        { "type" => "reasoning", "text" => "let me think", "signature" => "sig-abc" },
        { "type" => "message", "content" => [{ "type" => "output_text", "text" => "answer" }] },
      ],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "anthropic_messages", provider_id: "anthropic")

    assert_equal({ "kind" => "assistant_message", "ordinal" => 1 }, envelope["items"].last)
    trace = ModelReasoning::Trace.new(envelope: envelope)
    assert_nil trace.assistant_phase
    assert_equal ["let me think"], trace.reasoning_items.map { |i| i["text"] }
  end

  test "the chat family reads both spellings and the openrouter detail list" do
    unary = FakeResult.new(
      output_items: [],
      assistant_message: {
        "reasoning" => "unary chain",
        "reasoning_details" => [
          { "type" => "reasoning.summary", "summary" => "s", "id" => "d1" },
          { "type" => "reasoning.encrypted", "data" => "blob", "id" => "d2" },
        ],
      }, usage: {}
    )

    envelope = build(unary, api_format: "openrouter_chat")

    assert_equal "chat_reasoning", envelope["origin_format_variant"]
    kinds = envelope["items"].map { |i| i["kind"] }
    assert_equal %w[reasoning_text reasoning_summary reasoning_encrypted], kinds,
      "the unary `reasoning` spelling is read — the one-place-read lesson's second spelling"
    assert_equal %w[d1 d2], envelope["items"].last(2).map { |i| i["item_id"] }
    assert_equal [
      { "type" => "reasoning.summary", "summary" => "s", "id" => "d1" },
      { "type" => "reasoning.encrypted", "data" => "blob", "id" => "d2" },
    ], envelope["items"].last(2).map { |i| i["provider_payload"] },
      "each detail keeps its block verbatim: the broker takes the sequence back only as it came"
  end

  test "a text-bearing detail list supersedes the joined display string — never both" do
    doubled = FakeResult.new(
      output_items: [],
      assistant_message: {
        "reasoning" => "chunk1\n\nchunk2",
        "reasoning_details" => [
          { "type" => "reasoning.text", "text" => "chunk1", "id" => "d1" },
          { "type" => "reasoning.text", "text" => "chunk2", "id" => "d2" },
        ],
      }, usage: {}
    )

    envelope = build(doubled, api_format: "openrouter_chat")

    texts = envelope["items"].map { |i| i["text"] }
    assert_equal %w[chunk1 chunk2], texts,
      "OpenRouter's `reasoning` is the joined convenience of the details — captured once"
  end

  # A CHUNK BOUNDARY IS NOT AN ITEM BOUNDARY. The openrouter lane collects one `reasoning_details`
  # entry per SSE chunk; three deltas of one thought are one item, or the fenced replay reads
  # "The\n\n test suite finished\n\n: 20 runs" back to the model.
  test "adjacent text deltas of one thought coalesce into one item, nothing between" do
    streamed = FakeResult.new(
      output_items: [],
      assistant_message: {
        "reasoning_content" => "The test suite finished: 20 runs",
        "reasoning_details" => [
          { "type" => "reasoning.text", "text" => "The", "format" => "moonshot", "index" => 0 },
          { "type" => "reasoning.text", "text" => " test suite finished", "format" => "moonshot", "index" => 0 },
          { "type" => "reasoning.text", "text" => ": 20 runs", "format" => "moonshot", "index" => 0 },
        ],
      }, usage: {}
    )

    envelope = build(streamed, api_format: "openrouter_chat")

    assert_equal ["The test suite finished: 20 runs"], envelope["items"].map { |i| i["text"] },
      "three chunks of one thought are one item whose text is their concatenation"
    assert_equal "reasoning.text", envelope["items"].sole["kind"]
    assert_equal({ "type" => "reasoning.text", "text" => "The test suite finished: 20 runs", "format" => "moonshot",
                   "index" => 0 }, envelope["items"].sole["provider_payload"], "the coalesced block, as one block")
  end

  test "deltas of distinct blocks stay distinct items" do
    blocks = FakeResult.new(
      output_items: [],
      assistant_message: {
        "reasoning_details" => [
          { "type" => "reasoning.text", "text" => "first ", "index" => 0 },
          { "type" => "reasoning.text", "text" => "thought", "index" => 0 },
          { "type" => "reasoning.summary", "summary" => "a summary", "index" => 1 },
          { "type" => "reasoning.text", "text" => "second", "index" => 2 },
        ],
      }, usage: {}
    )

    envelope = build(blocks, api_format: "openrouter_chat")

    assert_equal %w[reasoning.text reasoning_summary reasoning.text], envelope["items"].map { |i| i["kind"] }
    assert_equal ["first thought", nil, "second"], envelope["items"].map { |i| i["text"] }
  end

  test "token accounting rides ALONGSIDE material that carries no count of its own" do
    blob = FakeResult.new(
      output_items: [
        { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "gAAA" },
      ],
      assistant_message: nil,
      usage: { "output_tokens_details" => { "reasoning_tokens" => 512 } }
    )

    envelope = build(blob, api_format: "openai_responses")

    kinds = envelope["items"].map { |i| i["kind"] }
    assert_equal %w[reasoning_text token_accounting], kinds,
      "the budget half prices the native blob with the captured count"
    assert_equal 512, envelope["items"].last["reasoning_tokens"]
  end

  test "token accounting is a trace fact; nothing at all is nil" do
    tokens_only = FakeResult.new(
      output_items: [], assistant_message: nil,
      usage: { "output_tokens_details" => { "reasoning_tokens" => 42 } }
    )
    envelope = build(tokens_only, api_format: "deepseek_responses")
    assert_equal "responses_reasoning_text", envelope["origin_format_variant"]
    assert_equal 42, envelope["items"].sole["reasoning_tokens"]

    assert_nil build(FakeResult.empty, api_format: "openai_responses"),
      "no output at all leaves no trace body"
  end

  # The trace reads the reasoning count where the receipt reads it, every
  # spelling included: Anthropic reports its thinking as
  # `output_tokens_details.thinking_tokens`, and a signed block's text is
  # only a summary of what the server bills.
  test "token accounting reads the receipt's spellings, thinking tokens included" do
    signed = FakeResult.new(
      output_items: [{ "type" => "reasoning", "text" => "a short summary", "signature" => "sig" }],
      assistant_message: nil,
      usage: { "output_tokens" => 250, "output_tokens_details" => { "thinking_tokens" => 210 } }
    )

    envelope = build(signed, api_format: "anthropic_messages")

    assert_equal 210, envelope["items"].last["reasoning_tokens"], "priced as billed, not by its summary"
  end

  # Every answer that said something carries its message's place: a plain text answer — no
  # thought, no verdict — writes the one-marker envelope, and nothing in it replays.
  test "a text-only answer writes exactly its message's marker" do
    result = FakeResult.new(
      output_items: [{ "type" => "message", "content" => [{ "type" => "output_text", "text" => "answer" }] }],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "anthropic_messages", provider_id: "anthropic")

    assert_equal [{ "kind" => "assistant_message", "ordinal" => 0 }], envelope.fetch("items")
    assert_not envelope.key?("input_transformations")
    assert_not ModelReasoning::Trace.new(envelope: envelope).replay_material?
  end

  # The provider's own word on the history it was handed: `[]` is "replayed intact" and is
  # recorded even when nothing was thought; nil — the provider reports nothing — writes no
  # key, and with no material no envelope at all.
  test "the server's verdict on the replayed history rides the envelope, an intact [] included" do
    origin = { provider_id: "anthropic", model_id: "claude-opus-5-5",
               api_format: "anthropic_messages", invocation_id: "inv-1" }
    verdict = ->(result, list) do
      ModelReasoning::TraceBuilder.call(
        result: result, origin: origin, normalized_tool_calls: [], input_transformations: list
      )
    end

    intact = verdict.call(FakeResult.empty, [])
    assert_equal [], intact.fetch("items")
    assert_equal [], intact.fetch("input_transformations")
    assert_equal "anthropic_thinking", intact.fetch("origin_format_variant")

    assert_nil verdict.call(FakeResult.empty, nil), "no report and no material is still no envelope"

    dropped = [{ "type" => "thinking_dropped", "path" => "messages.1.content.0", "reason" => "prefix_binding_mismatch" }]
    thought = FakeResult.new(
      output_items: [{ "type" => "reasoning", "text" => "let me think", "signature" => "sig-abc" }],
      assistant_message: nil, usage: {}
    )
    both = verdict.call(thought, dropped)
    assert_equal dropped, both.fetch("input_transformations")
    assert_equal "sig-abc", both.fetch("items").sole.fetch("signature")
    assert_not verdict.call(thought, nil).key?("input_transformations"),
      "a provider that reports nothing writes no such key"
  end

  test "an unknown api format degrades to none, never raises" do
    result = FakeResult.new(
      output_items: [{ "type" => "reasoning", "text" => "t", "signature" => "s" }],
      assistant_message: nil, usage: {}
    )

    envelope = build(result, api_format: "future_format")

    assert_equal "none", envelope["origin_format_variant"]
    assert_equal "none", envelope["items"].sole["signature_kind"],
      "an unrecognized family's signature never native-replays"
  end
end
