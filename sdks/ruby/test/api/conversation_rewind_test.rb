require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationRewindTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_fork_is_idempotent_on_the_source_and_answers_the_child_and_the_world_at_the_fork_point
    forked = chat([[201, { "Idempotency-Replayed" => "false" }, contract.fetch("valid_fork_fixture")]]).fork(
      turn_public_id: TURN_ID, variant_public_id: VARIANT_ID,
      title: "Branch", idempotency_key: "fork-1"
    )

    assert_equal "#{PATH}/forks", request.fetch(:path)
    assert_equal "fork-1", request.fetch(:headers).fetch("Idempotency-Key")
    fields = request.fetch(:body).fetch("fork")
    assert_equal TURN_ID, fields.fetch("turn_public_id")
    assert_equal VARIANT_ID, fields.fetch("variant_public_id")
    refute_predicate forked, :replayed?
    # THE FORK POINT'S WORLD: the kernel's fact, beside the child —
    # the writing loop, the claimant, the runner's record verbatim.
    world = contract.fetch("valid_fork_fixture").fetch("world")
    assert_predicate forked.world, :touched?
    assert_equal world.fetch("loop"), forked.world.loop
    assert_equal world.fetch("runner"), forked.world.runner
    assert_equal world.fetch("checkpoint"), forked.world.checkpoint.raw
    assert_equal world.dig("checkpoint", "hash"), forked.world.checkpoint_hash

    replayed = chat([[201, { "Idempotency-Replayed" => "true" }, contract.fetch("valid_fork_fixture")]])
      .fork(turn_public_id: TURN_ID, idempotency_key: "fork-1")
    assert_predicate replayed, :replayed?
    assert_equal forked.world, replayed.world, "a replay answers the same world off the receipt"
  end

  # THE SIDE FORK: no turn named — the kernel takes the parent's
  # newest settled turn, live head or not; the body says `side` and
  # nothing about a turn. A fork naming neither is a caller confusion the
  # SDK refuses before the wire does.
  def test_a_side_fork_sends_side_and_names_no_turn
    fixture = contract.fetch("valid_fixture").fetch("conversation").merge("side" => true)
    untouched = contract.fetch("world_fixtures").fetch("untouched")
    forked = chat([[201, {}, { "conversation" => fixture, "world" => untouched }]])
      .fork(side: true, idempotency_key: "side-1")

    assert_equal "#{PATH}/forks", request.fetch(:path)
    assert_equal({ "side" => true }, request.fetch(:body).fetch("fork"))
    assert_predicate forked.conversation, :side?
    assert_predicate forked.world, :untouched?, "a side's point is the newest settled turn: nothing above it"

    assert_raises(ArgumentError) { chat([]).fork(idempotency_key: "side-2") }
  end

  # ---- rewind — the SDK's composition over the fork and the relay --

  REWIND_RUNNER = "019f0000-0000-7000-8000-000000000301".freeze
  REWIND_LOOP = {
    "public_id" => "019f0000-0000-7000-8000-000000000602", "status" => "queued",
    "deliverable_task_key" => "relay", "tasks" => [], "created_at" => "2026-09-15T00:00:00Z",
    "updated_at" => "2026-09-15T00:00:00Z",
  }.freeze

  def loop_pack = CybrosAgentTest::ContractFixtures.pack("agent_loops.json")

  # The pack's fork fixture with the child bound to the SAME runner its
  # world names — the settled pair a restore compares (the pack's
  # conversation is unbound).
  def restorable_fork(world = contract.fetch("valid_fork_fixture").fetch("world"))
    conversation = contract.fetch("valid_fork_fixture").fetch("conversation")
      .merge("runner" => { "executor_public_id" => world.fetch("runner"), "presence" => "online" })
    { "conversation" => conversation, "world" => world }
  end

  def request_create = [201, {}, { "agent_loop" => REWIND_LOOP, "receipt" => { "revision" => 1 } }]
  def request_start = [200, {}, { "agent_loop" => REWIND_LOOP.merge("status" => "running") }]
  def relay_task(fixture_key) = [200, {}, loop_pack.fetch(fixture_key)]

  # FORK FIRST, then the restore request loop on the child's bound runner;
  # the answer is `restored` with the tree put back and the undo a later
  # call could replay.
  def test_rewind_forks_then_restores_the_world_through_the_childs_runner
    rewound = chat([
      [201, {}, restorable_fork],
      request_create, request_start, relay_task("valid_world_restore_task_detail_fixture"),
    ]).rewind(turn_public_id: TURN_ID, idempotency_key: "rw-1")

    assert_equal "#{PATH}/forks", request(0).fetch(:path)
    assert_equal "rw-1", request(0).fetch(:headers).fetch("Idempotency-Key"), "the caller's key is the fork's"
    authored = request(1).fetch(:body).fetch("agent_loop")
    assert_equal "world_restore", authored.dig("steps", 0, "tool", "name")
    assert_equal({ "checkpoint" => "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
                   "store" => rewound.fork_point.checkpoint.store },
      authored.dig("steps", 0, "tool", "input"), "the fork point's tree is the checkpoint")
    refute_equal "rw-1", request(1).fetch(:headers).fetch("Idempotency-Key"), "the restore mints its own key"

    assert_predicate rewound, :restored?
    assert_equal "4b825dc642cb6eb9a060e54bf8d69288fbee4904", rewound.checkpoint
    assert_equal "9c1f2e3d4b5a69788796a5b4c3d2e1f0a9b8c7d6", rewound.undo, "the undo rides metadata.checkpoint"
    assert_predicate rewound.fork_point, :touched?, "fork_point is the kernel's fact, world is the SDK's outcome"
    refute_predicate rewound, :replayed?
  end

  # An OUTSIDE-ROOT write and an IGNORED path: the marks ride the fork
  # point's checkpoint and the restored outcome carries them, honestly
  # (a reader prints what the restore did not reach).
  def test_rewind_reports_what_the_restore_could_not_reach
    world = contract.fetch("valid_fork_fixture").fetch("world")
    world = world.merge("checkpoint" => world.fetch("checkpoint")
      .merge("outside" => ["/home/outside.txt"], "ignored" => ["secrets/.env"]))
    rewound = chat([
      [201, {}, restorable_fork(world)],
      request_create, request_start, relay_task("valid_world_restore_task_detail_fixture"),
    ]).rewind(turn_public_id: TURN_ID, idempotency_key: "rw-out")

    assert_predicate rewound, :restored?
    assert_equal ["/home/outside.txt"], rewound.world[:outside]
    assert_equal ["secrets/.env"], rewound.world[:ignored], "an ignored path the store never held"
  end

  # NOTHING WROTE above the turn: the fork alone, `untouched`, no request.
  def test_rewind_of_an_untouched_point_forks_and_restores_nothing
    fixture = contract.fetch("valid_fixture").fetch("conversation")
    untouched = contract.fetch("world_fixtures").fetch("untouched")
    rewound = chat([[201, {}, { "conversation" => fixture, "world" => untouched }]])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "rw-u")

    assert_predicate rewound, :untouched?
    assert_equal 1, @transport.requests.length, "the fork alone"
  end

  # THE RESTORE HALF ON ITS OWN: the composition a
  # regenerate runs BEFORE the kernel's door — no fork, the same request
  # loop on the runner the caller names, the same outcome Hash `rewind`
  # reports. rho keeps no copy of this sequence: this is the one.
  def test_restore_world_restores_a_points_world_through_the_named_runner
    fact = contract.fetch("valid_fork_fixture").fetch("world")
    world = world_of(fact)

    outcome = chat([request_create, request_start, relay_task("valid_world_restore_task_detail_fixture")])
      .restore_world(world, runner: fact.fetch("runner"))

    authored = request(0).fetch(:body).fetch("agent_loop")
    assert_equal "world_restore", authored.dig("steps", 0, "tool", "name")
    assert_equal({ "checkpoint" => "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "store" => world.checkpoint.store },
      authored.dig("steps", 0, "tool", "input"), "the point's tree is the checkpoint")
    assert_equal "restored", outcome[:status]
    assert_equal "4b825dc642cb6eb9a060e54bf8d69288fbee4904", outcome[:checkpoint]
    assert_equal "9c1f2e3d4b5a69788796a5b4c3d2e1f0a9b8c7d6", outcome[:undo], "the undo rides metadata.checkpoint"
  end

  # The two facts differ, or nothing wrote: answered off the reads, no request.
  def test_restore_world_answers_runner_mismatch_and_untouched_without_a_request
    fact = contract.fetch("valid_fork_fixture").fetch("world")
    touched = world_of(fact)
    untouched = CybrosAgent::Api::World.new(status: "untouched")

    assert_equal({ status: "unavailable", reason: "runner_mismatch" },
      chat([]).restore_world(touched, runner: "019f0000-0000-7000-8000-000000000999"))
    assert_equal({ status: "untouched" }, chat([]).restore_world(untouched, runner: fact.fetch("runner")))
    assert_empty @transport.requests, "two strings compared; nothing asked"
  end

  # A World as a caller holds one off a read: the kernel's fact with the
  # runner's checkpoint as the typed value.
  def world_of(fact)
    CybrosAgent::Api::World.new(
      status: fact.fetch("status"), loop: fact.fetch("loop"), runner: fact.fetch("runner"),
      checkpoint: CybrosAgent::Api::Checkpoint.new(
        hash: fact.dig("checkpoint", "hash"), store: fact.dig("checkpoint", "store"), raw: fact.fetch("checkpoint")
      )
    )
  end

  # world: false forks and keeps the world as it is.
  def test_rewind_with_world_false_keeps_the_world
    rewound = chat([[201, {}, restorable_fork]])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "rw-k", world: false)

    assert_predicate rewound, :kept?
    assert_equal 1, @transport.requests.length, "no restore was requested"
  end

  # ANOTHER runner holds the tree (or none): the two strings differ.
  def test_rewind_is_unavailable_when_the_binding_is_not_the_claimant
    rewound = chat([[201, {}, contract.fetch("valid_fork_fixture")]])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "rw-m")

    assert_predicate rewound, :unavailable?
    assert_equal "runner_mismatch", rewound.reason, "the fork fixture's child carries no runner"
    assert_equal 1, @transport.requests.length, "no restore of a tree this binding cannot reach"
  end

  # THE RUNNER DECLINED (a `{skipped}` fact): final, no store consult.
  def test_rewind_is_unavailable_when_the_runner_declined_to_capture
    skipped = contract.fetch("world_fixtures").fetch("skipped")
    rewound = chat([[201, {}, restorable_fork(skipped)]])
      .rewind(turn_public_id: TURN_ID, idempotency_key: "rw-s")

    assert_predicate rewound, :unavailable?
    assert_equal "no_checkpoint", rewound.reason
    assert_equal "tree_too_large", rewound.world[:skipped]
    assert_equal 1, @transport.requests.length, "a skip is final: the store is not asked"
  end

  # THE CACHE MISS ASKS THE STORE (K-s3): a placeholder value carries no
  # hash, so `checkpoints {loop}` is consulted; none present → no_checkpoint.
  def test_rewind_asks_the_store_on_a_cache_miss_and_reports_no_checkpoint_when_none_stands
    placeholder = contract.fetch("world_fixtures").fetch("placeholder")
    empty = loop_pack.fetch("valid_checkpoints_task_detail_fixture")
    empty = { "task" => empty.fetch("task").merge("structured_content" => { "records" => [] }) }
    rewound = chat([
      [201, {}, restorable_fork(placeholder)],
      request_create, request_start, [200, {}, empty],
    ]).rewind(turn_public_id: TURN_ID, idempotency_key: "rw-miss")

    assert_equal "checkpoints", request(1).fetch(:body).dig("agent_loop", "steps", 0, "tool", "name")
    assert_predicate rewound, :unavailable?
    assert_equal "no_checkpoint", rewound.reason
  end

  def test_rewind_preserves_the_store_found_on_a_cache_miss
    placeholder = contract.fetch("world_fixtures").fetch("placeholder")
    found = loop_pack.fetch("valid_checkpoints_task_detail_fixture")
    record = found.fetch("task").fetch("structured_content").fetch("records").first.merge("store" => "3f0c9d2a7b1e5c68")
    found = { "task" => found.fetch("task").merge("structured_content" => { "records" => [record] }) }
    rewound = chat([
      [201, {}, restorable_fork(placeholder)],
      request_create, request_start, [200, {}, found],
      request_create, request_start, relay_task("valid_world_restore_task_detail_fixture"),
    ]).rewind(turn_public_id: TURN_ID, idempotency_key: "rw-found")

    assert_predicate rewound, :restored?
    authored = @transport.requests.find do |request|
      request.dig(:body, "agent_loop", "steps", 0, "tool", "name") == "world_restore"
    end
    assert_equal record.slice("hash", "store").transform_keys { |key| key == "hash" ? "checkpoint" : key },
      authored.fetch(:body).dig("agent_loop", "steps", 0, "tool", "input")
  end

  # THE RESTORE RAN AND COULD NOT: a completed row carrying `is_error` is
  # `failed` with the tool's first word, never `restored`.
  def test_rewind_reads_a_tool_error_as_failed_with_the_reason_word
    failed = {
      "task" => {
        "key" => "relay", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "on_failure" => "propagate",
        "tool_name" => "world_restore", "result" => { "resolved" => true, "is_error" => true },
        "output" => "checkpoint_unknown: 0000000000000000000000000000000000000000",
        "visibility" => "visible", "created_at" => "2026-09-15T00:00:00Z",
      },
    }
    rewound = chat([
      [201, {}, restorable_fork],
      request_create, request_start, [200, {}, failed],
    ]).rewind(turn_public_id: TURN_ID, idempotency_key: "rw-f")

    assert_predicate rewound, :failed?
    assert_equal "checkpoint_unknown", rewound.reason
  end

  # FORK FIRST is the safety: every fork refusal raises BEFORE any restore,
  # so no source ever stands on a rewound tree.
  def test_rewind_raises_a_fork_refusal_before_any_restore
    error = assert_raises(CybrosAgent::Api::Conflict) do
      chat([[409, {}, { "error" => { "code" => "side_of_side", "message" => "no" } }]])
        .rewind(turn_public_id: TURN_ID, idempotency_key: "rw-r")
    end
    assert_equal "side_of_side", error.code
    assert_equal 1, @transport.requests.length, "the fork alone: no restore was requested"
  end
end
