require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"
require_relative "../../../test_helpers/compaction_summary_test_helper"

class Conversations::Compaction::ConsumedPairsTest < ActiveJob::TestCase
  include CompactionTestHelper
  include CompactionSummaryTestHelper

  test "prune savings include pairs first read beside a summary at their consuming round" do
    _conversation, _turn, agent_loop, bodies = consumed_pairs_history
    history = Conversations::Compaction::Serialize.loop_history(loop_node(agent_loop, "r4"))

    assert_equal %w[r2 r3], history.rounds.map(&:node_key), "the arrived summary remains the history floor"
    assert_equal "r3", history.prune_round.node_key, "the current fan still has its first read ahead of it"
    assert_equal bodies.first(2).sum(&:bytesize) - 2 * Conversations::Compaction::Serialize::CLEARED_BYTES,
      history.prunable_bytes,
      "the first pair was consumed at r2; it must free bytes once even though its source is behind the summary"
    consumed = round_request_entries(loop_node(agent_loop, "r3")).select { |entry| entry["type"] == "tool_result_item" }
    cleared = consumed.map do |entry|
      entry.merge("payload" => entry.fetch("payload").merge("output" => AgentLoops::RoundReplay::Pairing::CLEARED))
    end
    profile = DevModelLane.selection(workload: "text_generation", account: @account).execution_profile
    counts = [consumed, cleared].map do |entries|
      elements = Nexus::InputEntries.from(entries: entries, workload: "text_generation")
      counted = ModelRequests::TokenCount.count(profile: profile, segments: Nexus::ModelRequestInput.text_segments(elements))
      assert_predicate counted, :counted?
      counted.tokens
    end
    assert_equal counts.first - counts.last, history.prunable_tokens(profile),
      "the selected counter uses the same two consumed outputs as the byte cutoff, excluding fresh C"

    r4 = loop_node(agent_loop, "r4")
    repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: r4,
      trigger: Conversations::Compaction::Trigger.wall(r4,
        overshoot: Conversations::Compaction::Overshoot.bytes(bodies.first.bytesize)))
    assert_predicate repair, :pruned?, "the two consumed results cover a wall the second result alone cannot cover"
    assert_equal "r3", r4.reload.pruned_before
  end

  test "a later prune clears consumed summary pairs in the request and later turn history" do
    conversation, turn, agent_loop, bodies = consumed_pairs_history
    r4 = loop_node(agent_loop, "r4")
    repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: r4,
      trigger: Conversations::Compaction::Trigger.wall(r4,
        overshoot: Conversations::Compaction::Overshoot.bytes(100)))
    assert_predicate repair, :pruned?
    assert_equal "r3", r4.reload.pruned_before
    schedule_loop!(agent_loop)

    cleared = AgentLoops::RoundReplay::Pairing::CLEARED
    expected = [["call_a", cleared], ["call_b", cleared], ["call_c", bodies.last]]
    request = round_request_entries(r4.reload)
    assert_equal expected, paired_outputs(request),
      "row reconstruction clears both results r2 consumed or emitted, while the current fan stays whole"
    assert_equal %w[call_a call_b call_c], call_ids(request), "every cleared result keeps its call exactly once"
    assert_includes request.to_json, "COMPACTED HISTORY"
    refute_includes request.to_json, "the answer replaced by compaction"

    run_loop_round!(agent_loop, sse_success("the final word"))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    selected = Conversations::ContextAssembly::ChatHistory.call(conversation: conversation.reload)
    later = Nexus::InputEntries.for(selected.segments.flat_map(&:elements))
    assert_equal expected, paired_outputs(later), "later history honors the same consumer-position prune mark"
    assert_equal %w[call_a call_b call_c], call_ids(later)
    assert_includes later.to_json, "COMPACTED HISTORY"
    refute_includes later.to_json, "the answer replaced by compaction"
  end

  private

    # r2 first consumes A after a summary, then emits B. r3 consumes B
    # and emits C. At r4's wall r2 is eligible to clear, while C is fresh.
    def consumed_pairs_history
      bodies = ["old A\n#{prose(12_000)}", "old B\n#{prose(1_000)}", "fresh C\n#{prose(4_000)}"]
      conversation, turn, agent_loop = loop_backed_read!(body: bodies.first,
        words: "the answer replaced by compaction", compaction_policy: { "mode" => "kernel" })
      r2 = loop_node(agent_loop, "r2")
      complete_compaction_summary(r2)
      schedule_loop!(agent_loop)
      first_read = round_request_entries(r2.reload)
      assert_equal [["call_a", bodies.first]], paired_outputs(first_read),
        "the old pair reaches its first consumer beside the summary before any later prune"
      refute_includes first_read.to_json, "the answer replaced by compaction"
      read!(agent_loop, "call_b", "docs/second.txt", "read the next file", bodies[1])
      schedule_loop!(agent_loop)
      assert_equal [["call_a", bodies.first], ["call_b", bodies[1]]],
        paired_outputs(round_request_entries(loop_node(agent_loop, "r3")))
      read!(agent_loop, "call_c", "docs/current.txt", "read the current file", bodies.last)
      [conversation, turn, agent_loop, bodies]
    end

    def paired_outputs(entries)
      entries.select { |entry| entry["type"] == "tool_result_item" }
        .map { |entry| entry.fetch("payload").values_at("call_id", "output") }
    end

    def call_ids(entries)
      entries.filter_map { |entry| entry.dig("payload", "call_id") if entry["type"] == "tool_call_item" }
    end
end
