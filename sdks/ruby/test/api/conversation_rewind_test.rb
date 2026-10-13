require "test_helper"
require_relative "../support/rewind_fixtures"

class ApiConversationRewindTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  include CybrosAgentTest::RewindFixtures

  def test_fork_preserves_per_runner_evidence_and_checkpoint_presence
    effects = evidence([effect("a").except("checkpoint"), effect("b", checkpoint: nil)])
    forked = chat([[201, { "Idempotency-Replayed" => "true" }, fork_reply(effects)]]).fork(
      turn_public_id: TURN_ID, variant_public_id: VARIANT_ID, title: "Branch", idempotency_key: "fork-1")

    assert_equal "#{PATH}/forks", request.fetch(:path)
    assert_equal "fork-1", request.fetch(:headers).fetch("Idempotency-Key")
    assert_predicate forked, :replayed?
    assert_predicate forked.runner_effects, :touched?
    refute forked.runner_effects.runners.first.to_h.key?(:checkpoint)
    assert forked.runner_effects.runners.last.to_h.key?(:checkpoint)
    assert_nil forked.runner_effects.runners.last.to_h.fetch(:checkpoint)
  end

  def test_side_fork_does_not_require_a_turn
    forked = chat([[201, {}, fork_reply(evidence([], status: "untouched"))]])
      .fork(side: true, idempotency_key: "side-1")
    assert_equal({ "side" => true }, request.fetch(:body).fetch("fork"))
    assert_predicate forked.runner_effects, :untouched?
    assert_raises(ArgumentError) { chat([]).fork(idempotency_key: "missing") }
  end

  def test_rewind_forks_first_and_restores_each_original_runner_without_a_host_default
    rewound = chat([[201, {}, fork_reply(evidence([effect("runner-a"), effect("runner-b")]))],
      *tool_responses, *tool_responses]).rewind(turn_public_id: TURN_ID, idempotency_key: "rewind")

    assert_predicate rewound, :restored?
    assert_nil rewound.conversation.default_runner
    assert_equal %w[runner-a runner-b], rewound.runners.map { |row| row.fetch(:runner_executor_public_id) }
    assert_equal %w[undo undo], rewound.runners.map { |row| row.fetch(:undo) }
    calls = @transport.requests.filter_map { |row| row.dig(:body, "run", "steps", 0, "tool") }
    assert_equal %w[runner-a runner-b], calls.map { |row| row.dig("route", "runner_executor_public_id") }
    assert_equal ["checkpoint_restore"] * 2, calls.map { |row| row.fetch("name") }
    assert_equal({ "checkpoint" => "tree", "store" => "store-a" }, calls.first.fetch("input"))
    assert_equal "#{PATH}/forks", request.fetch(:path)
  end

  def test_one_runner_failure_does_not_stop_other_restores
    rewound = chat([[201, {}, fork_reply(evidence([effect("a"), effect("b")]))],
      *tool_responses(tool_reply(error: "checkpoint_unknown: missing")), *tool_responses])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "partial")
    assert_predicate rewound, :partial?
    assert_equal %w[failed restored], rewound.runners.map { |row| row.fetch(:status) }
    assert_equal "checkpoint_unknown", rewound.runners.first.fetch(:reason)
  end

  def test_a_transport_failure_leaves_that_runner_unconfirmed_and_continues_others
    rewound = chat([[201, {}, fork_reply(evidence([effect("a"), effect("b")]))],
      :connection_error, *tool_responses])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "transport-partial")

    assert_predicate rewound, :partial?
    assert_equal %w[unavailable restored], rewound.runners.map { |row| row.fetch(:status) }
    assert_equal "transport_error", rewound.runners.first.fetch(:reason)
    calls = @transport.requests.filter_map { |row| row.dig(:body, "run", "steps", 0, "tool") }
    assert_equal %w[a b], calls.map { |row| row.dig("route", "runner_executor_public_id") }
  end

  def test_partial_retained_evidence_never_claims_complete_restoration
    rewound = chat([[201, {}, fork_reply(evidence(status: "unavailable", reason: "details_pruned"))], *tool_responses])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "partial-evidence")
    assert_predicate rewound, :partial?
    assert_equal "details_pruned", rewound.reason
  end

  def test_checkpoint_cache_miss_asks_the_original_runner_and_keeps_the_store
    missing = effect("a").except("checkpoint")
    found = tool_reply(content: { "records" => [{ "present" => true, "hash" => "found", "store" => "other" }] })
    rewound = chat([[201, {}, fork_reply(evidence([missing]))], *tool_responses(found), *tool_responses])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "lookup")
    assert_predicate rewound, :restored?
    assert_equal({ "run_public_id" => "source-run" }, request(1).dig(:body, "run", "steps", 0, "tool", "input"))
    assert_equal({ "checkpoint" => "found", "store" => "other" }, request(4).dig(:body, "run", "steps", 0, "tool", "input"))
  end

  def test_skipped_and_missing_checkpoints_report_unavailability
    skipped = effect("a", checkpoint: { "skipped" => "tree_too_large" })
    rewound = chat([[201, {}, fork_reply(evidence([skipped]))]])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "skipped")
    assert_predicate rewound, :unavailable?
    assert_equal "tree_too_large", rewound.runners.first.fetch(:skipped)
    assert_equal 1, @transport.requests.length
  end

  def test_untouched_or_explicitly_kept_forks_never_restore
    [[evidence([], status: "untouched"), true, "untouched"], [evidence, false, "kept"]].each do |effects, restore, status|
      rewound = chat([[201, {}, fork_reply(effects)]]).rewind(turn_public_id: TURN_ID,
        idempotency_key: "keep", restore_checkpoints: restore)
      assert_equal status, rewound.status
      assert_equal 1, @transport.requests.length
    end
  end

  def test_fork_refusal_happens_before_restoration
    assert_raises(CybrosAgent::Api::Conflict) do
      chat([[409, {}, { "error" => { "code" => "side_of_side", "message" => "no" } }]])
        .rewind(turn_public_id: TURN_ID, idempotency_key: "refused")
    end
    assert_equal 1, @transport.requests.length
  end
end
