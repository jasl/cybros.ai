require "test_helper"
require_relative "../support/contract_fixtures"

class ApiRewindGuardTest < Minitest::Test
  def fixture = CybrosAgentTest::ContractFixtures.pack("conversations.json").fetch("valid_fork_fixture")
  def loop_fixture = CybrosAgentTest::ContractFixtures.pack("agent_loops.json")

  def fork_reply(world = fixture.fetch("world"))
    { "conversation" => fixture.fetch("conversation").merge(
      "runner" => { "executor_public_id" => world["runner"] || fixture.dig("world", "runner"),
                    "presence" => "online" }), "world" => world }
  end

  def chat(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "https://nexus.example", credential: "member", transport: @transport)
      .workspace("ws-1").conversation("c-1")
  end

  def request_responses(detail)
    loop = { "public_id" => "loop-1", "status" => "queued", "deliverable_task_key" => "relay", "tasks" => [],
             "created_at" => "2026-09-15T00:00:00Z", "updated_at" => "2026-09-15T00:00:00Z" }
    [[201, {}, { "agent_loop" => loop, "receipt" => { "revision" => 1 } }],
     [200, {}, { "agent_loop" => loop.merge("status" => "running") }], [200, {}, detail]]
  end

  def test_a_restore_guard_receives_the_resolved_checkpoint_and_preserves_the_fork_on_refusal
    seen = []
    rewound = chat([[201, {}, fork_reply]])
      .rewind(turn_public_id: "t-1", idempotency_key: "rewind-1", restore_guard: ->(runner, captured) {
        seen << [runner, captured]
        "process_live"
      })

    assert_equal fixture.dig("conversation", "public_id"), rewound.conversation.public_id
    assert_equal({ status: "failed", reason: "process_live" }, rewound.world)
    assert_equal 1, @transport.requests.length, "only the fork: the guard refuses before a restore request exists"
    assert_equal [[rewound.fork_point.runner, rewound.fork_point.checkpoint]], seen
  end

  def test_the_guard_runs_once_after_a_cache_miss_recovers_the_actual_store
    found = loop_fixture.fetch("valid_checkpoints_task_detail_fixture")
    record = found.dig("task", "structured_content", "records").find { |row| row["present"] }
    record["store"] = fixture.dig("world", "checkpoint", "store")
    world = fixture.fetch("world").except("checkpoint")
    seen = []
    rewound = chat([[201, {}, fork_reply(world)], *request_responses(found)])
      .rewind(turn_public_id: "t-1", idempotency_key: "rewind-1", restore_guard: ->(runner, captured) {
        seen << [runner, captured.hash, captured.store]
        "process_live"
      })

    assert_equal [[world.fetch("runner"), record.fetch("hash"), record.fetch("store")]], seen
    assert_equal({ status: "failed", reason: "process_live" }, rewound.world)
    assert_equal ["checkpoints"], @transport.requests.filter_map { |row| row.dig(:body, "agent_loop", "steps", 0, "tool", "name") }
  end

  def test_a_guard_can_allow_the_existing_restore_to_run
    calls = 0
    rewound = chat([[201, {}, fork_reply], *request_responses(loop_fixture.fetch("valid_world_restore_task_detail_fixture"))])
      .rewind(turn_public_id: "t-1", idempotency_key: "rewind-1", restore_guard: ->(_runner, _captured) {
        calls += 1
        nil
      })

    assert_predicate rewound, :restored?
    assert_equal 1, calls
    assert_equal 4, @transport.requests.length
  end

  def test_the_guard_is_not_called_when_no_restore_will_be_requested
    untouched = { "status" => "untouched" }
    skipped = fixture.fetch("world").merge("checkpoint" => { "skipped" => "tree_too_large" })
    mismatch = fork_reply.merge("conversation" => fixture.fetch("conversation"))
    [[fork_reply, false, "kept"], [fork_reply(untouched), true, "untouched"],
     [fork_reply(skipped), true, "unavailable"], [mismatch, true, "unavailable"]].each do |reply, world, expected|
      rewound = chat([[201, {}, reply]])
        .rewind(turn_public_id: "t-1", idempotency_key: "rewind-1", world: world,
          restore_guard: ->(*) { flunk "no restore is possible" })

      assert_equal expected, rewound.world.fetch(:status)
      assert_equal 1, @transport.requests.length
    end
  end
end
