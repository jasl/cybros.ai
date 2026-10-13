require "test_helper"

class Nexus::ModelToolCallsTest < ActiveSupport::TestCase
  test "normalizes the chat-completions wire shape with ordinals" do
    calls = Nexus::ModelToolCalls.normalize([
      { "id" => "call_1", "type" => "function",
        "function" => { "name" => "read", "arguments" => "{\"path\":\"a.rb\"}" } },
    ])

    assert_equal(
      [{ "id" => "call_1", "name" => "read",
         "arguments" => "{\"path\":\"a.rb\"}", "ordinal" => 0 }],
      calls
    )
  end

  test "normalizes the responses function_call item preferring call_id" do
    calls = Nexus::ModelToolCalls.normalize([
      { "type" => "function_call", "id" => "item_9", "call_id" => "call_9",
        "name" => "bash", "arguments" => "{\"command\":\"ls\"}" },
    ])

    assert_equal "call_9", calls.sole.fetch("id"),
      "call_id is the Responses pairing key and wins over the item id"
  end

  test "serializes non-string arguments, skips junk, keeps encounter order" do
    calls = Nexus::ModelToolCalls.normalize([
      { "id" => "call_2", "name" => "write", "arguments" => { "path" => "b.rb" } },
      { "id" => "call_3" },
      "junk",
      nil,
      { "id" => "call_4", "name" => "bash", "arguments" => nil },
    ])

    assert_equal(
      [
        { "id" => "call_2", "name" => "write",
          "arguments" => "{\"path\":\"b.rb\"}", "ordinal" => 0 },
        { "id" => "call_4", "name" => "bash", "arguments" => "{}", "ordinal" => 4 },
      ], calls
    )
    assert_equal [], Nexus::ModelToolCalls.normalize(nil)
  end

  test "the envelope is versioned and absent when no calls survive" do
    envelope = Nexus::ModelToolCalls.envelope([
      { "id" => "c", "name" => "read", "arguments" => "{}" },
    ])
    assert_equal "nexus.tool_calls.v1", envelope.fetch("format")
    assert_equal "tool_calls", envelope.fetch("type")
    assert_nil Nexus::ModelToolCalls.envelope(["junk"])
  end

  test "a call without an id gets a deterministic kernel-minted pairing key" do
    wire = [{ "type" => "function_call", "name" => "read", "arguments" => "{}" }]

    first = Nexus::ModelToolCalls.normalize(wire)
    assert_equal Nexus::ModelToolCalls.normalize(wire), first
    assert first.first.fetch("id").start_with?(Nexus::ModelToolCalls::SYNTHETIC_ID_PREFIX)
  end

  test "a repeated provider id is disambiguated rather than trusted" do
    ids = Nexus::ModelToolCalls.normalize([
      { "type" => "function_call", "call_id" => "c1", "name" => "a", "arguments" => "{}" },
      { "type" => "function_call", "call_id" => "c1", "name" => "b", "arguments" => "{}" },
    ]).map { |call| call.fetch("id") }

    assert_equal 2, ids.uniq.size
    assert_equal "c1", ids.first
  end

  # The key is stored on the call's row, whose column holds MAX_ID_LENGTH characters: a longer
  # provider id, or a repeated one the disambiguation would push past it, is replaced by a key the
  # kernel mints — still unique, still deterministic, so a retried round recomposes to the same bytes.
  test "a pairing key never exceeds the column that stores it" do
    limit = Nexus::ModelToolCalls::MAX_ID_LENGTH
    assert_equal 128, limit, "the agent_run_tasks.tool_call_id column is string(128)"
    wire = [
      { "type" => "function_call", "call_id" => "c" * 200, "name" => "a", "arguments" => "{}" },
      { "type" => "function_call", "call_id" => "d" * limit, "name" => "b", "arguments" => "{}" },
      { "type" => "function_call", "call_id" => "d" * limit, "name" => "c", "arguments" => "{}" },
      { "type" => "function_call", "call_id" => "c3", "name" => "d", "arguments" => "{}" },
    ]

    ids = Nexus::ModelToolCalls.normalize(wire).map { |call| call.fetch("id") }

    assert_equal ids, Nexus::ModelToolCalls.normalize(wire).map { |call| call.fetch("id") }, "deterministic"
    assert_equal 4, ids.uniq.size, "still unique"
    assert ids.all? { |id| id.length <= limit }, ids.inspect
    assert_equal "#{Nexus::ModelToolCalls::SYNTHETIC_ID_PREFIX}0", ids.first, "an over-long id is replaced by a minted key"
    assert_equal "d" * limit, ids.second, "an id at the limit is the provider's own"
    assert_equal "#{Nexus::ModelToolCalls::SYNTHETIC_ID_PREFIX}2", ids.third,
      "a repeat the disambiguation would push past the limit is minted too"
    assert_equal "c3", ids.last
  end
end
