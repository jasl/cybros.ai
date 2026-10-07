require "test_helper"
require_relative "../support/rewind_fixtures"

class ApiRewindGuardTest < Minitest::Test
  include CybrosAgentTest::RewindFixtures
  def test_guard_receives_each_resolved_runner_checkpoint_before_its_restore
    seen = []
    rewound = chat([[201, {}, fork_reply(evidence([effect("a"), effect("b")]))], *tool_responses])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "guard", restore_guard: ->(runner, captured) {
        seen << [runner, captured.hash, captured.store]
        runner == "a" ? "process_live" : nil
      })
    assert_equal [["a", "tree", "store-a"], ["b", "tree", "store-a"]], seen
    assert_predicate rewound, :partial?
    assert_equal "process_live", rewound.runners.first.fetch(:reason)
    assert_equal 4, @transport.requests.length
  end

  def test_guard_uses_store_resolved_after_checkpoint_cache_miss
    seen = []
    found = tool_reply(content: { "records" => [{ "present" => true, "hash" => "found", "store" => "resolved" }] })
    rewound = chat([[201, {}, fork_reply(evidence([effect("a").except("checkpoint")]))], *tool_responses(found)])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "guard-lookup", restore_guard: ->(runner, captured) {
        seen << [runner, captured.hash, captured.store]
        "process_live"
      })
    assert_equal [["a", "found", "resolved"]], seen
    assert_predicate rewound, :failed?
    assert_equal 4, @transport.requests.length
  end
end
