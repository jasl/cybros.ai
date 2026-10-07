require "test_helper"

# Cache placement has two markers: the stable head after leading tools/system material, and the
# rolling tail after this round's settled prefix. Without a separate system field, the leading
# slot-and-memory messages supply the stable head. The caller selects the tier: `5m` uses the
# default marker shape and `1h` adds Anthropic's TTL.
class Nexus::PromptCacheBreakpointsTest < ActiveSupport::TestCase
  Breakpoints = Nexus::PromptCache::Breakpoints
  MARKER = Nexus::PromptCache::Breakpoints.marker("5m")

  def msg(role, text)
    { "role" => role, "content" => [{ "type" => "input_text", "text" => text }] }
  end

  # `capable: false` is Build's reading of any wire but the one with
  # breakpoints, or of a row that wrote `prompt_caching: false`.
  test "an incapable profile is byte-untouched" do
    input = [msg("user", "hi")]
    placement = Breakpoints.apply(instructions: "sys", input: input, capable: false, tier: "5m")

    assert_equal input, placement.input
    assert_equal "sys", placement.instructions
    assert_not placement.enabled
    assert_not placement.capable
  end

  test "with a system channel: the stable marker rides the last system block" do
    placement = Breakpoints.apply(
      instructions: "You are terse.", input: [msg("user", "a"), msg("user", "b")],
      capable: true, tier: "5m"
    )

    assert_equal [{ "type" => "text", "text" => "You are terse.",
                    "cache_control" => MARKER }], placement.instructions,
      "one marker there caches the TOOL LIST and the system prompt together - " \
        "the wire renders tools first"
    assert_nil placement.input.first["content"].last["cache_control"],
      "the first message is not a second head"
    assert_equal MARKER, placement.input.last["content"].last["cache_control"],
      "and the rolling tail caches this round's prefix for the next"
  end

  # A request nobody will extend — the summarizer's, whose serialized
  # history no later request reads — writes no tail: `tail: false` marks the
  # stable head alone, and the placement says the tail was not asked for.
  test "tail false marks the stable head alone, on either channel" do
    placement = Breakpoints.apply(
      instructions: "You are terse.", input: [msg("user", "a"), msg("user", "b")],
      capable: true, tier: "5m", tail: false
    )

    assert_equal MARKER, placement.instructions.sole["cache_control"]
    assert placement.input.none? { |entry| entry["content"].last.key?("cache_control") }, "no rolling tail"
    assert_not placement.tail

    headless = Breakpoints.apply(instructions: nil, input: [msg("system", "s"), msg("user", "a"), msg("user", "b")],
      capable: true, tier: "1h", tail: false)
    marked = headless.input.map { |entry| entry["content"].last.key?("cache_control") }
    assert_equal [false, true, false], marked, "the stable marker after the leading run, no tail"
  end

  test "without a system channel: head and tail both ride messages" do
    placement = Breakpoints.apply(
      instructions: nil, input: [msg("user", "a"), msg("user", "b")],
      capable: true, tier: "5m"
    )

    assert_equal MARKER, placement.input.first["content"].last["cache_control"]
    assert_equal MARKER, placement.input.last["content"].last["cache_control"]
  end

  test "a tool round's tail is the function_call_output entry itself" do
    input = [
      msg("user", "read it"),
      { "type" => "function_call", "call_id" => "c1", "name" => "read", "arguments" => "{}" },
      { "type" => "function_call_output", "call_id" => "c1", "output" => "contents" },
    ]
    placement = Breakpoints.apply(instructions: "sys", input: input, capable: true, tier: "5m")

    assert_equal MARKER, placement.input.last["cache_control"],
      "the protocol forwards an entry marker onto the tool_result block - " \
        "the natural tail of a tool round"
  end

  test "a thinking tail SKIPS the breakpoint rather than emitting an illegal one" do
    input = [
      msg("user", "a"),
      { "role" => "assistant",
        "content" => [{ "type" => "thinking", "thinking" => "hmm", "signature" => "s" }] },
    ]
    placement = Breakpoints.apply(instructions: "sys", input: input, capable: true, tier: "5m")

    assert_equal input, placement.input,
      "Anthropic 400s a marked thinking block: skip, never relocate, never stamp"
    assert_not placement.tail, "the skip is REPORTED on the placement, never swallowed"
    assert_equal MARKER, placement.instructions.last["cache_control"],
      "and the head still rides - degradation is bounded"
  end

  # THE CACHE AUDIT'S prefix-1 (2026-09-16): replayed reasoning is no
  # reason to skip the tail — Anthropic keeps prior-turn thinking blocks
  # in the cached prefix and never strips them inside a tool-use loop, so
  # a loop replaying its own thinking is exactly where the history cache
  # pays. The gate that skipped the tail under replay turned the cache
  # off on the models where it works; a thinking-LAST block is the ONE skip.
  test "replayed reasoning still places the tail on the round's tool_result; a thinking-LAST block is the one skip" do
    replayed = [
      msg("user", "read it"),
      { "type" => "reasoning", "id" => "rs_1", "encrypted_content" => "blob" },
      { "role" => "assistant",
        "content" => [{ "type" => "thinking", "thinking" => "hmm", "signature" => "s" },
                      { "type" => "text", "text" => "reading" }] },
      { "type" => "function_call", "call_id" => "c1", "name" => "read", "arguments" => "{}" },
      { "type" => "function_call_output", "call_id" => "c1", "output" => "contents" },
    ]
    placement = Breakpoints.apply(instructions: "sys", input: replayed, capable: true, tier: "5m")

    assert placement.tail
    assert_equal MARKER, placement.input.last["cache_control"],
      "the tool_result is this round's prefix for the next — cached with the thinking before it"
    assert_equal MARKER, placement.instructions.last["cache_control"]
    assert_nil placement.input[2]["content"].first["cache_control"], "no marker lands ON a thinking block"

    thinking_last = replayed.first(2) + [
      { "role" => "assistant",
        "content" => [{ "type" => "text", "text" => "so" },
                      { "type" => "redacted_thinking", "data" => "x" }] },
    ]
    skipped = Breakpoints.apply(instructions: "sys", input: thinking_last, capable: true, tier: "5m")

    assert_not skipped.tail, "the one skip, reported"
    assert_equal thinking_last, skipped.input
  end

  test "the wire cap is a backstop over BOTH arms, not a message-only subcount" do
    assert_raises(ArgumentError) do
      Breakpoints.mark_messages([{ "content" => [] }], stable_at: 0, placed: 4, tier: "5m")
    end
  end

  test "placement never mutates the caller's material" do
    input = [msg("user", "a")].freeze
    instructions = ["You are terse."].freeze
    Breakpoints.apply(instructions: instructions, input: input, capable: true, tier: "5m")

    assert_nil input.first["content"].last["cache_control"]
    assert_equal ["You are terse."], instructions
  end

  # THE TIER: Anthropic's own two words; both markers of one request take the request's tier; `5m`
  # is the old constant's bytes.
  test "5m emits no ttl key, 1h emits ttl on BOTH markers, a third word raises" do
    assert_equal({ "type" => "ephemeral" }, Breakpoints.marker("5m"))
    assert_equal({ "type" => "ephemeral", "ttl" => "1h" }, Breakpoints.marker("1h"))
    assert_equal %w[5m 1h], Breakpoints::TIERS
    assert_raises(ArgumentError) { Breakpoints.marker("2h") }

    placement = Breakpoints.apply(
      instructions: "sys", input: [msg("user", "a"), msg("user", "b")], capable: true, tier: "1h"
    )
    assert_equal({ "type" => "ephemeral", "ttl" => "1h" }, placement.instructions.last["cache_control"])
    assert_equal({ "type" => "ephemeral", "ttl" => "1h" }, placement.input.last["content"].last["cache_control"])
    assert_raises(ArgumentError) do
      Breakpoints.apply(instructions: "sys", input: [msg("user", "a")], capable: true, tier: "2h")
    end
  end

  # THE STABLE PREFIX without a system field: the leading run of system-role items plus at most one
  # user-role item directly after it — the assembler's slots, then its memory block — derived from
  # the list's ROLE structure, never a stored count.
  test "the stable marker rides the last item of the leading system run plus one user item" do
    marks = ->(input) {
      placement = Breakpoints.apply(instructions: nil, input: input, capable: true, tier: "5m")
      placement.input.each_index.select { |i| placement.input[i]["content"].last.key?("cache_control") }
    }

    assert_equal [1, 2], marks.call([msg("system", "s"), msg("user", "memory"), msg("user", "prompt")]),
      "[system][user][user]: the slots and memory, then the tail"
    assert_equal [2, 3],
      marks.call([msg("system", "s"), msg("system", "t"), msg("user", "memory"), msg("assistant", "a")]),
      "[system][system][user][assistant]: the whole run and the one user item after it"
    assert_equal [0, 2], marks.call([msg("system", "s"), msg("developer", "lead"), msg("user", "prompt")]),
      "[system][developer][user]: a developer lead is outside the prefix — the run alone is stable"
    assert_equal [0, 1], marks.call([msg("user", "a"), msg("user", "b")]),
      "[user][user]: no leading run, index 0 as before"
    assert_equal [0], marks.call([msg("system", "s")]), "[system] alone: head and tail coincide, one marker"
    assert_equal 0, Breakpoints.stable_index([msg("user", "summary"), msg("user", "x")]),
      "a pruned round opening with the summary marks item 0 — the one licensed bust"
    assert_nil Breakpoints.stable_index([])
  end

  # A template that places a `user`/`developer` inline ahead of the slots marks item 0 — the
  # licensed bust, the author's choice; and the rolling tail rides the LAST entry whatever its role,
  # which is why the grammar admits a system-role inline only in the leading run: a trailing system
  # item would carry the tail marker, and the wires that peel every system entry (Anthropic, Gemini)
  # would hoist it.
  test "a template-shaped list: a user inline ahead of the slots busts the prefix; the tail rides the last entry" do
    marks = ->(input) {
      placement = Breakpoints.apply(instructions: nil, input: input, capable: true, tier: "5m")
      placement.input.each_index.select { |i| placement.input[i]["content"].last.key?("cache_control") }
    }

    assert_equal [0, 3], marks.call([msg("user", "scene"), msg("system", "s"), msg("user", "memory"), msg("user", "prompt")]),
      "[user][system][user][user]: no leading run, item 0 — the one licensed bust"
    assert_equal [1, 3], marks.call([msg("system", "s"), msg("user", "scene + persona + memory"), msg("assistant", "a"), msg("user", "prompt")]),
      "[system][user][assistant][user]: the leading run, the one user item after it, the tail on the input"
    assert_equal [1, 2], marks.call([msg("system", "s"), msg("user", "prompt"), msg("system", "trailing")]),
      "a trailing system item takes the tail marker — the shape the template grammar refuses"
  end

  test "the wire cap counts the stable marker wherever it lands" do
    input = [msg("system", "s"), msg("user", "m"), msg("user", "p")]
    assert_raises(ArgumentError) do
      Breakpoints.mark_messages(input, stable_at: 1, placed: 3, tier: "5m")
    end
    assert_nothing_raised { Breakpoints.mark_messages(input, stable_at: 1, placed: 2, tier: "5m") }
  end
end
