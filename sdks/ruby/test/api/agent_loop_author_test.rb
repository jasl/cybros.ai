require "test_helper"
require_relative "../support/contract_fixtures"
require_relative "../support/fake_realtime_client"
require_relative "../support/agent_loop_fixtures"

class ApiAgentLoopAuthorTest < Minitest::Test
  include CybrosAgentTest::AgentLoopFixtures

  def test_create_authors_the_seed_envelope_in_written_order_and_answers_the_trace
    created = workspace([[201, {}, { "agent_loop" => LOOP, "receipt" => { "revision" => 1 } }]])
      .agent_loops.create(
        steps: CybrosAgent::Steps.build { |s|
          s.model "do the work", key: "round1", model: { "model" => "dev/mock-text" }
        },
        idempotency_key: "seed-1", approval_mode: "bypass"
      )

    assert_equal :post, request[:method]
    assert_equal LOOPS_PATH, request[:path]
    assert_equal "seed-1", request[:headers].fetch("Idempotency-Key")
    envelope = request[:body].fetch("agent_loop")
    assert_equal %w[steps approval_mode], envelope.keys,
      "nothing names a deliverable; the envelope's end is the answer — and the mode is always named"
    assert_equal [{ "model" => { "prompt" => "do the work", "key" => "round1",
                                 "model" => { "model" => "dev/mock-text" } } }], envelope.fetch("steps")

    refute_predicate created, :replayed?
    assert_equal LOOP_ID, created.agent_loop.public_id
    assert_equal "round1", created.agent_loop.deliverable.key
  end

  # The creator names its runner on the loop shell exactly as on
  # the conversation door — one field, both hosts; omitted sends nothing.
  def test_create_names_the_runner_only_when_asked
    workspace([[201, {}, { "agent_loop" => LOOP, "receipt" => { "revision" => 1 } }]])
      .agent_loops.create(
        steps: [{ "model" => { "key" => "round1", "prompt" => "p" } }],
        idempotency_key: "seed-1", approval_mode: "bypass", runner_executor_public_id: "0199-runner"
      )

    envelope = request[:body].fetch("agent_loop")
    assert_equal %w[steps approval_mode runner_executor_public_id], envelope.keys
    assert_equal "0199-runner", envelope.fetch("runner_executor_public_id")
  end

  # A wire Hash passes through untouched beside a value: a caller that
  # builds its steps elsewhere is not made to re-wrap them.
  def test_create_takes_wire_hashes_beside_values
    workspace([[201, {}, { "agent_loop" => LOOP, "receipt" => { "revision" => 1 } }]])
      .agent_loops.create(
        steps: [{ "model" => { "key" => "round1", "prompt" => "p" } },
                CybrosAgent::Steps::Ask.new(prompt: "ok?", key: "gate")],
        idempotency_key: "seed-1", approval_mode: "bypass"
      )

    assert_equal [{ "model" => { "key" => "round1", "prompt" => "p" } },
                  { "ask" => { "prompt" => "ok?", "key" => "gate" } }],
      request[:body].dig("agent_loop", "steps")
  end

  # A REPLAY IS A 200 AND A CREATE IS A 201: the retry could not have known
  # the id; the standing loop and original seed receipt recover both its
  # address and the capability to resolve a seed ask.
  def test_an_exact_repeat_answers_the_standing_loop_and_seed_receipt
    receipt = { "revision" => 1, "resolution_tokens" => { "gate" => "seed-answer" } }
    created = workspace([[200, {}, { "agent_loop" => LOOP, "replayed" => true, "receipt" => receipt }]])
      .agent_loops.create(steps: [{ "model" => { "key" => "round1", "prompt" => "p" } }],
        idempotency_key: "seed-1", approval_mode: "bypass")

    assert_predicate created, :replayed?
    assert_equal LOOP_ID, created.agent_loop.public_id
    assert_equal receipt, created.receipt
    assert_equal "seed-answer", created.receipt.dig("resolution_tokens", "gate")
  end

  def test_creation_refuses_an_empty_batch_before_it_reaches_the_wire
    context = workspace([]).agent_loops
    # EMPTY, not nil: `nil` is refused by the signature before the guard can
    # see it, so the case worth testing is the one a well-typed caller can
    # still get wrong — an Array with nothing in it. A loop with no steps
    # has nothing to schedule and would only ever be an id.
    assert_raises(ArgumentError) { context.create(steps: [], idempotency_key: "k", approval_mode: "bypass") }
    # The SDK never mints an idempotency key: a retry the caller cannot
    # recognize as a retry is how one loop becomes two.
    assert_raises(ArgumentError) do
      context.create(steps: [{ "model" => { "prompt" => "a" } }], idempotency_key: "", approval_mode: "bypass")
    end
    assert_empty @transport.requests, "nothing reached the wire"
  end

  # COMPACTED MEANS LENIENT. Every projection here is built with `.compact`,
  # so a task with no retry budget carries no `retry` key at all and a loop
  # that needs nothing from anybody carries no `attention` block. Reading
  # those strictly would make an ordinary loop unparseable.
  def test_the_compacted_trace_reads_without_the_absent_members
    loop_row = workspace([[200, {}, { "agent_loop" => LOOP }]]).agent_loops.fetch(LOOP_ID)

    task = loop_row.task("round1")
    assert_equal 0, task.retry_budget, "an absent retry block is a zero, not a nil"
    assert_empty task.waiting_on, "an absent waiting_on is nothing waited for, not a nil"
    assert_nil task.error
    assert_nil loop_row.attention
    assert_nil loop_row.failure_reason
    assert_predicate task, :waiting?
    refute_predicate task, :terminal?
  end

  # WHO A STARTED CALL IS FOR AND WHO HOLDS IT: the
  # task read names the addressee — a role and the executor the kernel
  # bound, or the role ALONE for a pool row — and the claimant's public-id
  # snapshot once somebody took it. Absent on a model task, and never the
  # effect profile.
  def test_a_tool_call_names_its_addressee_and_its_claimant
    pool = TASK.merge("key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "dispatched", "tool_name" => "find",
      "addressed_to" => { "role" => "tools_provider" },
      "claimed_by" => { "executor_public_id" => "019f0000-0000-7000-8000-000000000702" })
    bound = TASK.merge("key" => "r1t1", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "dispatched", "tool_name" => "read",
      "addressed_to" => { "role" => "runner", "executor_public_id" => "019f0000-0000-7000-8000-000000000701" })
    row = LOOP.merge("tasks" => [TASK, pool, bound])
    loop_row = workspace([[200, {}, { "agent_loop" => row }]]).agent_loops.fetch(LOOP_ID)

    pooled = loop_row.task("r1t0")
    assert_instance_of CybrosAgent::Api::AddressedTo, pooled.addressed_to
    assert_equal "tools_provider", pooled.addressed_to.role
    assert_nil pooled.addressed_to.executor_public_id, "a pool row names the role alone"
    assert_instance_of CybrosAgent::Api::ClaimedBy, pooled.claimed_by
    assert_equal "019f0000-0000-7000-8000-000000000702", pooled.claimed_by.executor_public_id

    addressed = loop_row.task("r1t1")
    assert_equal ["runner", "019f0000-0000-7000-8000-000000000701"],
      [addressed.addressed_to.role, addressed.addressed_to.executor_public_id]
    assert_nil addressed.claimed_by, "unclaimed: nobody holds it yet"

    model = loop_row.task("round1")
    assert_nil model.addressed_to
    assert_nil model.claimed_by
  end

  # `retry` is `{budget: N}` when there is one; flattening it keeps the
  # caller from reaching through a hash for a number.
  def test_a_retry_budget_flattens_to_a_number
    row = LOOP.merge("tasks" => [TASK.merge("retry" => { "budget" => 3 })])
    task = workspace([[200, {}, { "agent_loop" => row }]])
      .agent_loops.fetch(LOOP_ID).task("round1")

    assert_equal 3, task.retry_budget
  end

  def test_append_carries_the_optimistic_fence_and_answers_the_receipt
    appended = workspace([[201, {}, { "receipt" => {
      "accepted_task_keys" => %w[tests lint round2 s2-parallel-1 gate],
      "steps" => [{ "parallel" => %w[tests lint], "key" => "s2-parallel-1" }, "round2", "gate"],
      "deliverable_task_key" => "gate",
      "revision" => 2,
      "resolution_tokens" => { "gate" => "rt-secret" },
    } }]]).agent_loop(LOOP_ID).append(
      steps: CybrosAgent::Steps.build { |s|
        s.parallel(until: "any") do |p|
          p.tool "bash", input: { "command" => "t" }, key: "tests"
          p.tool "bash", input: { "command" => "l" }, key: "lint"
        end
        s.model "sum it", key: "round2"
        s.ask "right?", key: "gate", timeout_ms: 1000
      },
      expected_revision: 1, idempotency_key: "grow-1"
    )

    assert_equal "#{LOOP_PATH}/tasks", request[:path]
    assert_equal 1, request[:body].fetch("expected_revision"),
      "a caller holding its last receipt that lost a race must refuse, not interleave"
    assert_equal %w[steps expected_revision], request[:body].keys, "no deliverable rides an append"
    assert_equal [
      { "parallel" => [{ "tool" => { "name" => "bash", "input" => { "command" => "t" }, "key" => "tests" } },
                       { "tool" => { "name" => "bash", "input" => { "command" => "l" }, "key" => "lint" } }],
        "until" => "any" },
      { "model" => { "prompt" => "sum it", "key" => "round2" } },
      { "ask" => { "prompt" => "right?", "key" => "gate", "timeout_ms" => 1000 } },
    ], request[:body].fetch("steps")
    assert_equal %w[tests lint round2 s2-parallel-1 gate], appended.accepted_task_keys
    assert_equal [{ "parallel" => %w[tests lint], "key" => "s2-parallel-1" }, "round2", "gate"], appended.steps,
      "the receipt mirrors the request by key, the race's barrier named"
    assert_equal "gate", appended.deliverable_task_key
    assert_equal 2, appended.revision
    assert_equal "rt-secret", appended.resolution_tokens.fetch("gate")
    refute_predicate appended, :replayed?
  end

  # An envelope of resolves alone is legal — it settles an ask and places
  # nothing — while one with neither is refused before the wire.
  def test_append_admits_resolves_alone_and_refuses_an_empty_envelope
    context = workspace([[201, {}, { "receipt" => { "accepted_task_keys" => [], "revision" => 3 } }]])
      .agent_loop(LOOP_ID)

    appended = context.append(steps: [], resolve: [{ "task" => "gate", "content" => "yes" }],
      idempotency_key: "settle-1")
    assert_equal({ "steps" => [], "resolve" => [{ "task" => "gate", "content" => "yes" }] }, request[:body])
    assert_empty appended.accepted_task_keys
    assert_nil appended.deliverable_task_key

    assert_raises(ArgumentError) { context.append(steps: [], idempotency_key: "settle-2") }
  end

  # HOW FAR ALONG is `phases`: the derived read under the word
  # for what it answers; `progress` is the ephemeral feed below. The path
  # string is pinned so no reader keeps the old word.
  def test_phases_reads_the_phases_the_current_one_the_background_and_the_spend
    progress = workspace([[200, {}, {
      "phases" => [
        { "label" => "tests · lint", "keys" => %w[tests lint], "done" => 2, "total" => 2, "status" => "completed" },
        { "label" => "summary", "keys" => ["summary"], "done" => 0, "total" => 1, "status" => "running" },
      ],
      "current" => 1,
      "background" => [{ "key" => "r1t0-model-1", "status" => "running" }],
      "spend" => { "input_tokens" => 41_230, "output_tokens" => 6_120, "cost_amount" => nil, "cost_unit" => nil },
    }]]).agent_loop(LOOP_ID).phases

    assert_equal "#{LOOP_PATH}/phases", request[:path]
    assert_instance_of CybrosAgent::Api::AgentLoopPhases, progress
    assert_equal ["tests · lint", "summary"], progress.phases.map(&:label)
    assert_predicate progress.phases.first, :completed?
    assert_equal %w[tests lint], progress.phases.first.keys
    assert_equal "summary", progress.current_phase.label
    assert_equal [%w[r1t0-model-1 running]], progress.background.map { |task| [task.key, task.status] }
    assert_equal 41_230, progress.spend.fetch("input_tokens")
  end

  # A BACKGROUND TASK MAILED AFTER THE REPLY WAS FINAL SAYS WHEN: the
  # kernel stamps `mailed_at` on a settled detached tip it delivered as
  # mail and compacts the member away on one still running. A host that
  # re-serves the read hands `to_h` on (rho's daemon does, for `rho-dev
  # phases`), so the stamp has to survive the shape or no reader past the
  # SDK can ever show it, and a running tip's shape has to stay the
  # kernel's compacted row rather than gain a null the kernel never sent.
  def test_a_mailed_background_task_carries_its_stamp_and_a_running_one_none
    progress = workspace([[200, {}, {
      "phases" => [],
      "current" => nil,
      "background" => [
        { "key" => "r1t0-model-1", "status" => "running" },
        { "key" => "r1t0-model-2", "status" => "completed", "mailed_at" => "2026-09-06T00:00:09.000Z" },
      ],
      "spend" => {},
    }]]).agent_loop(LOOP_ID).phases

    running, mailed = progress.background
    assert_nil running.mailed_at
    assert_equal({ key: "r1t0-model-1", status: "running" }, running.to_h)
    assert_equal "2026-09-06T00:00:09.000Z", mailed.mailed_at
    assert_equal({ key: "r1t0-model-2", status: "completed", mailed_at: "2026-09-06T00:00:09.000Z" }, mailed.to_h)
  end

  # The append door answers the RECEIPT and no loop body — growth is a
  # write, and re-projecting the whole trace on every append would make the
  # cheap call the expensive one.
  def test_a_replayed_append_says_so_in_the_receipt
    appended = workspace([[200, {}, { "receipt" => {
      "accepted_task_keys" => ["round2"], "revision" => 2, "replayed" => true,
    } }]]).agent_loop(LOOP_ID).append(
      steps: [{ "model" => { "key" => "round2", "prompt" => "p" } }], idempotency_key: "grow-1"
    )

    assert_predicate appended, :replayed?
    assert_empty appended.resolution_tokens
  end

  # CREATED STOPPED, STARTED DELIBERATELY: create spends nothing, start is
  # what puts a model call on the wire.
  def test_the_lifecycle_verbs_answer_the_loop_they_changed
    running = LOOP.merge("status" => "running", "started_at" => "2026-09-02T00:01:00Z")
    context = workspace([[200, {}, { "agent_loop" => running }],
                         [200, {}, { "agent_loop" => LOOP.merge("status" => "canceled") }]])
      .agent_loop(LOOP_ID)

    started = context.start
    assert_equal "#{LOOP_PATH}/start", request[:path]
    assert_predicate started, :running?
    assert_nil request[:body], "start takes no options, so it sends no body"

    stopped = context.stop
    assert_equal "#{LOOP_PATH}/stop", request(1)[:path]
    # stop means stop — force is the default and rides explicitly
    assert_equal({ "force" => true }, request(1)[:body])
    assert_predicate stopped, :terminal?
  end

  # THE HANDOFF on a standalone loop: PUT on the nested singular
  # `runner`, answered with the loop document carrying the binding. The
  # loop document COMPACTS, so an unbound loop carries no key at all.
  def test_bind_runner_puts_the_nested_binding_and_answers_the_loop_carrying_it
    bound = LOOP.merge("runner" => { "executor_public_id" => "019f0000-0000-7000-8000-000000000701",
                                     "display_name" => "lab-mac", "presence" => "online",
                                     "last_seen_at" => "2026-09-08T10:00:00Z" })
    loop_row = workspace([[200, {}, { "agent_loop" => bound }]]).agent_loop(LOOP_ID)
      .bind_runner(executor_public_id: "019f0000-0000-7000-8000-000000000701")

    assert_equal :put, request.fetch(:method)
    assert_equal "#{LOOP_PATH}/runner", request.fetch(:path)
    assert_equal({ "runner" => { "executor_public_id" => "019f0000-0000-7000-8000-000000000701" } },
      request.fetch(:body))
    assert_instance_of CybrosAgent::Api::RunnerBinding, loop_row.runner
    assert_equal "019f0000-0000-7000-8000-000000000701", loop_row.runner.executor_public_id
    assert_equal "lab-mac", loop_row.runner.display_name
    assert_predicate loop_row.runner, :online?

    unbound = workspace([[200, {}, { "agent_loop" => LOOP }]]).agent_loops.fetch(LOOP_ID)
    assert_nil unbound.runner, "an unbound loop compacts the key away"
  end

  def test_bind_runner_refuses_an_empty_id_and_relays_the_kernels_refusals_by_code
    assert_raises(ArgumentError) { workspace([]).agent_loop(LOOP_ID).bind_runner(executor_public_id: "") }

    error = assert_raises(CybrosAgent::Api::Conflict) do
      workspace([[409, {}, { "error" => { "code" => "conversation_hosted", "message" => "hosted" } }]])
        .agent_loop(LOOP_ID).bind_runner(executor_public_id: "019f0000-0000-7000-8000-000000000701")
    end
    assert_equal "conversation_hosted", error.code

    error = assert_raises(CybrosAgent::Api::Forbidden) do
      workspace([[403, {}, { "error" => { "code" => "not_authorized", "message" => "not yours" } }]])
        .agent_loop(LOOP_ID).bind_runner(executor_public_id: "019f0000-0000-7000-8000-000000000701")
    end
    assert_equal "not_authorized", error.code
  end

  def test_pause_is_graceful_by_default_and_force_is_the_caller_s_word
    context = workspace([[200, {}, { "agent_loop" => LOOP }],
                         [200, {}, { "agent_loop" => LOOP }]]).agent_loop(LOOP_ID)

    context.pause
    assert_equal({ "force" => false }, request[:body])
    context.pause(force: true)
    assert_equal({ "force" => true }, request(1)[:body])
  end

  # The single-task read is the one projection that loads a body — the
  # deliverable retrieval path.
  def test_reading_one_task_carries_the_body_the_trace_leaves_out
    detail = workspace([[200, {}, { "task" => TASK.merge(
      "status" => "completed",
      "output" => "the answer",
      "structured_content" => { "files" => ["a.rb"] }
    ) }]]).agent_loop(LOOP_ID).task("round1")

    assert_equal "#{LOOP_PATH}/tasks/round1", request[:path]
    assert_equal "the answer", detail.output
    assert_equal({ "files" => ["a.rb"] }, detail.structured_content)
    assert_predicate detail.task, :terminal?
    assert_nil detail.title, "a result that sent no UI fields reads none"
    assert_nil detail.metadata
  end

  # The UI's two fields ride the single-task read alone: the
  # header and the model-invisible carrier the executor committed.
  def test_reading_one_task_carries_the_title_and_metadata_its_result_was_committed_with
    detail = workspace([[200, {}, { "task" => TASK.merge(
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "output" => "",
      "structured_content" => { "lines" => 1 },
      "title" => "read x.rb", "metadata" => { "checkpoint" => "c1" }
    ) }]]).agent_loop(LOOP_ID).task("round1")

    assert_equal "read x.rb", detail.title
    assert_equal({ "checkpoint" => "c1" }, detail.metadata)
    assert_equal "", detail.output, "structure alone reads as the empty word, never entry JSON"
  end

  def test_reading_a_wait_preserves_its_target_and_passive_delivery_policy
    target = { "agent_loop" => LOOP_ID, "task" => "earlier", "timeout_ms" => 10_000 }
    detail = workspace([[200, {}, { "task" => TASK.merge(
      "kind" => "await_task", "wake" => "passive", "wait" => target
    ) }]]).agent_loop(LOOP_ID).task("round1")

    assert_equal "passive", detail.task.wake
    assert_equal target, detail.wait
    assert_predicate detail.wait, :frozen?
  end

  # THE REPLAY WINDOW a follower drains, on the one hosted projection: a
  # standalone loop is a host of the conversation plane, so its items are
  # the conversation's shape naming the loop as the resource. Sequences are
  # host-local, start at 1 and are CONTIGUOUS, which is what lets a gap be
  # arithmetic rather than a guess.
  def test_events_read_the_window_and_report_where_it_ends
    page = workspace([[200, {}, {
      "events" => [
        { "public_id" => "e1", "sequence" => 1, "cursor" => "c1", "type" => "turn_status",
          "resource" => { "type" => "agent_loop", "public_id" => LOOP_ID },
          "occurred_at" => "2026-09-02T00:00:00.000Z",
          "payload" => { "agent_loop_public_id" => LOOP_ID, "loop_status" => "running",
                         "status" => "running" } },
        { "public_id" => "e2", "sequence" => 2, "cursor" => "c2", "type" => "task_status",
          "resource" => { "type" => "agent_loop", "public_id" => LOOP_ID },
          "occurred_at" => "2026-09-02T00:00:01.000Z", "payload" => { "key" => "round1" } },
      ],
      "pagination" => { "next_after" => "c2", "watermark" => 2 },
    }]]).agent_loop(LOOP_ID).events(after: "c0", limit: 50)

    assert_equal({ "after" => "c0", "limit" => 50 }, request[:params])
    assert_equal 2, page.length
    assert_kind_of CybrosAgent::Api::ConversationEventPage, page
    assert_equal "turn_status", page.first.type
    assert_equal "agent_loop", page.first.resource_type
    assert_equal LOOP_ID, page.first.resource_public_id
    assert_equal "running", page.first.payload.fetch("status")
    assert_predicate page, :caught_up?, "drained to the watermark"
  end

  # THE READER RULE: `status` on a `turn_status` is optional. Present,
  # the turn moved; absent, it is a loop-state note and the turn did not.
  # The projection carries the payload verbatim, so a follower reads the
  # absence rather than inventing a transition from `loop_status`.
  def test_a_turn_status_without_status_is_a_loop_note_and_no_turn_change
    page = workspace([[200, {}, {
      "events" => [
        { "public_id" => "e1", "sequence" => 1, "cursor" => "c1", "type" => "turn_status",
          "resource" => { "type" => "conversation", "public_id" => "conv-1" },
          "occurred_at" => "2026-09-02T00:00:00.000Z",
          "payload" => { "turn_public_id" => "turn-1", "agent_loop_public_id" => LOOP_ID,
                         "loop_status" => "paused" } },
      ],
      "pagination" => { "next_after" => "c1", "watermark" => 1 },
    }]]).agent_loop(LOOP_ID).events

    note = page.first
    assert_equal "paused", note.payload.fetch("loop_status")
    assert_nil note.payload["status"], "no turn transition rides this item"
    assert_equal "turn-1", note.payload.fetch("turn_public_id")
  end

  def test_a_follower_detects_a_gap_by_arithmetic
    page = workspace([[200, {}, {
      "events" => [{ "public_id" => "e5", "sequence" => 5, "cursor" => "c5",
                     "type" => "usage", "resource" => { "type" => "agent_loop", "public_id" => LOOP_ID },
                     "occurred_at" => "2026-09-02T00:00:00.000Z", "payload" => {} }],
      "pagination" => { "next_after" => "c5", "watermark" => 9 },
    }]]).agent_loop(LOOP_ID).events

    assert page.gap_after?(1), "sequence 5 after 1 skipped 2, 3 and 4"
    refute page.gap_after?(4)
    refute_predicate page, :caught_up?, "the watermark is ahead of what arrived"
  end

  # An UNKNOWN type rides verbatim: a follower that refused one would
  # break on the deploy that adds one.
  def test_an_unfamiliar_event_type_is_carried_rather_than_refused
    page = workspace([[200, {}, {
      "events" => [{ "public_id" => "e1", "sequence" => 1, "cursor" => "c1",
                     "type" => "something_invented_next_year",
                     "resource" => { "type" => "agent_loop", "public_id" => LOOP_ID },
                     "occurred_at" => "2026-09-02T00:00:00.000Z", "payload" => { "x" => 1 } }],
      "pagination" => { "next_after" => "c1", "watermark" => 1 },
    }]]).agent_loop(LOOP_ID).events

    assert_equal "something_invented_next_year", page.first.type
  end

  def test_an_empty_window_is_caught_up_rather_than_broken
    # The wire's empty window: `next_after` is present and null.
    page = workspace([[200, {}, {
      "events" => [], "pagination" => { "next_after" => nil, "watermark" => 7 },
    }]]).agent_loop(LOOP_ID).events(after: "c7")

    assert_predicate page, :empty?
    assert_predicate page, :caught_up?
    refute page.gap_after?(7)
    assert page.gap_after?(6), "an expired final event remains visible through the committed head"
  end

  # THE PICTURE: never written from here, readable
  # whole — nodes, edges as task keys, and the Mermaid text derived from them.
  def test_the_graph_is_the_whole_run_as_nodes_edges_and_a_picture
    graph = workspace([[200, {}, {
      "nodes" => [
        { "key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
          "visibility" => "visible", "deliverable" => false, "input_from" => [], "result_from" => [] },
        { "key" => "gate", "kind" => "join_task", "lifetime" => "conversation", "wake" => "auto", "status" => "waiting",
          "visibility" => "hidden", "deliverable" => true, "input_from" => [], "result_from" => [],
          "join" => { "until" => 2, "losers" => "cancel" } },
        { "key" => "r1t0", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "failed",
          "visibility" => "collapsed", "deliverable" => false, "error_key" => "tool_timeout",
          "input_from" => [], "result_from" => [] },
      ],
      "edges" => [{ "from" => "r1", "to" => "gate", "structural" => false },
                  { "from" => "r1", "to" => "r1t0", "structural" => true }],
      "mermaid" => "flowchart TD\n  n0[\"r1 · model_task · completed\"]:::completed",
    }]]).agent_loop(LOOP_ID).graph

    assert_equal "#{LOOP_PATH}/graph", request[:path]
    assert_equal %w[r1 gate r1t0], graph.nodes.map(&:key)
    assert_equal %w[model_task join_task tool_task], graph.nodes.map(&:kind)
    assert_equal %w[auto auto auto], graph.nodes.map(&:wake)
    assert_equal [false, true, false], graph.nodes.map(&:deliverable?)
    assert_equal "gate", graph.deliverable.key
    assert_equal({ "until" => 2, "losers" => "cancel" }, graph.node("gate").join,
      "the barrier reads back in the words that wrote it")
    assert_nil graph.node("r1").join
    assert_empty graph.node("r1").input_from
    assert_empty graph.node("r1").result_from
    assert_nil graph.node("r1").expansion_parent
    refute graph.node("r1").to_h.key?(:expansion_parent)
    assert_equal "tool_timeout", graph.node("r1t0").error_key
    assert_equal [%w[r1 gate], %w[r1 r1t0]], graph.edges.map { |edge| [edge.from, edge.to] }
    assert_equal [false, true], graph.edges.map(&:structural)
    assert_equal({ from: "r1", to: "gate", structural: false }, graph.edges.first.to_h)
    assert_equal %w[gate r1t0], graph.after("r1").map(&:key), "the heads an edge leaves a node for"
    assert_equal ["r1"], graph.before("gate").map(&:key)
    assert_match(/\Aflowchart TD\n/, graph.mermaid)
  end

  def test_the_graph_keeps_material_and_expansion_relations_separate_from_dependencies
    node = { "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
             "visibility" => "visible", "deliverable" => false, "input_from" => [], "result_from" => [] }
    graph = workspace([[200, {}, {
      "nodes" => [
        node.merge("key" => "seed"),
        node.merge("key" => "compose", "kind" => "script_task"),
        node.merge("key" => "worker", "expansion_parent" => "compose"),
        node.merge("key" => "answer", "input_from" => ["seed", "worker"], "result_from" => ["worker", "seed"],
          "expansion_parent" => "compose"),
      ],
      "edges" => [{ "from" => "worker", "to" => "answer", "structural" => false }],
      "mermaid" => "flowchart TD",
    }]]).agent_loop(LOOP_ID).graph

    assert_equal %w[seed worker], graph.node("answer").input_from
    assert_equal %w[worker seed], graph.node("answer").result_from
    assert_equal "compose", graph.node("answer").expansion_parent
    assert_equal "compose", graph.node("answer").to_h.fetch(:expansion_parent)
    assert_equal ["worker"], graph.before("answer").map(&:key)
    assert_equal ["answer"], graph.after("worker").map(&:key)
    assert_empty graph.after("seed")
    assert_empty graph.after("compose")
  end

  def test_the_graph_requires_material_lists_and_the_structural_flag
    node = { "key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto",
             "status" => "completed", "visibility" => "visible", "deliverable" => false,
             "input_from" => [], "result_from" => [] }
    %w[input_from result_from].each do |field|
      error = assert_raises(CybrosAgent::Api::MalformedResponse) do
        workspace([[200, {}, { "nodes" => [node.except(field)], "edges" => [], "mermaid" => "flowchart TD" }]])
          .agent_loop(LOOP_ID).graph
      end
      assert_match(/#{field}/, error.message)
    end

    error = assert_raises(CybrosAgent::Api::MalformedResponse) do
      workspace([[200, {}, { "nodes" => [node], "edges" => [{ "from" => "r1", "to" => "r2" }],
                            "mermaid" => "flowchart TD" }]]).agent_loop(LOOP_ID).graph
    end
    assert_match(/structural/, error.message)
  end

  def test_a_task_names_what_it_was_authored_after
    head = TASK.merge("key" => "round2", "after" => ["round1"], "waiting_on" => ["round1"])
    agent_loop = workspace([[200, {}, { "agent_loop" => LOOP.merge("tasks" => [TASK, head]) }]])
      .agent_loop(LOOP_ID).fetch

    assert_equal ["round1"], agent_loop.task("round2").after
    assert_empty agent_loop.task("round1").after, "a root was authored after nothing"
  end

  # THE THREAD: the pack's page maps to typed rows — the spine
  # mark, the calls a round read as `{count, items}`, the branches under
  # it — and `prefix:` asks for one branch's page by the call key.
  def test_the_transcript_is_the_thread_and_a_prefix_expands_one_branch
    page = CybrosAgentTest::ContractFixtures.pack("agent_loops.json").fetch("valid_thread_page_fixture")
    transcript = workspace([[200, {}, page]]).agent_loop(LOOP_ID).transcript(limit: 5)

    assert_equal "#{LOOP_PATH}/transcript", request[:path]
    assert_equal({ "limit" => 5 }, request[:params])
    assert_equal 3, transcript.length
    assert_predicate transcript, :has_older?
    assert_equal "MQ", transcript.next_before
    opener, reader, tail = transcript.to_a
    assert_instance_of CybrosAgent::Api::ThreadRow, opener
    assert_predicate opener, :spine?
    assert_equal({ count: 0, items: [] }, opener.calls.to_h)
    assert_equal 2, reader.calls.count
    assert_equal 0, reader.calls.overflow
    assert_equal %w[r2t0 r2t1], reader.calls.items.map(&:task_key)
    assert_equal %w[Agent task], [reader.calls.items.last.name, reader.calls.items.last.tool]
    assert_nil reader.calls.items.first.tool, "no alias, no second name"
    assert_equal ["r2t1"], reader.branches
    assert_equal({ "checkpoint" => "c1" }, reader.calls.items.first.metadata)
    assert_equal "waiting", tail.status
    assert_equal 1, tail.calls.items.length
    assert_equal "dispatched", tail.calls.items.fetch(0).status
    assert_equal page.fetch("rounds"), transcript.map { |row| JSON.parse(JSON.generate(row.to_h)) },
      "the typed rows round-trip to the page's bytes: nothing is dropped, nothing invented"

    branch = workspace([[200, {}, { "rounds" => [], "pagination" => { "has_older" => false } }]])
      .agent_loop(LOOP_ID).transcript(prefix: "r2t1")
    assert_equal({ "prefix" => "r2t1" }, request[:params])
    assert_equal 0, branch.length
  end

  # THE LOOP'S TRANSCRIPT OPENER: the same feed the
  # conversation's `transcript` opens, on the loop's own channel, and one
  # item type over the host — a standalone round's items carry the loop's
  # keys and no turn's. One method, keyword-dispatched: the window and the
  # socket are the same name, and a page keyword beside `realtime:` raises
  # rather than quietly opening a socket with a limit nobody honours.
  def test_the_transcript_opener_subscribes_to_the_loop_host_and_projects_a_settled_round
    frames = [{ "event" => {
      "type" => "round", "agent_loop_public_id" => LOOP_ID, "task_key" => "r1",
      "round" => { "task_key" => "r1", "status" => "completed", "text_preview" => "done" },
    } }]
    client = CybrosAgentTest::FakeRealtimeClient.new(frames)

    items = []
    workspace([]).agent_loop(LOOP_ID).transcript(realtime: client).call.each { |item| items << item }

    subscription = client.subscriptions.fetch(0)
    assert_equal "AgentAPI::V1::AgentLoopEventsChannel", subscription.channel
    assert_equal({ workspace_id: WORKSPACE_ID, agent_loop_id: LOOP_ID, items: "transcript" },
      subscription.params)
    assert_empty @transport.requests, "a socket and nothing else"

    round = items.fetch(0)
    assert_predicate round, :settled?
    assert_predicate round, :round?
    assert_equal [LOOP_ID, "r1"], [round.agent_loop_public_id, round.task_key]
    assert_nil round.turn_public_id, "on a loop host the turn keys are the absent ones"
    assert_equal "done", round.payload.dig("round", "text_preview")
  end

  # THE EPHEMERAL FEED: its envelope is `{frame}`, never
  # `{event}` — the events mapper raises on it and this opener has its own
  # — and a frame is projected with the kernel's stamps by name, the
  # payload untyped, and a type this gem predates carried verbatim.
  def test_the_progress_opener_subscribes_the_loops_progress_feed_and_projects_frames
    frames = [
      { "frame" => { "type" => "executor_progress", "agent_loop_public_id" => LOOP_ID, "task_key" => "r1t0",
                     "tool_name" => "bash", "executor_public_id" => "ex-1", "at" => "2026-09-13T10:00:00.250Z",
                     "text_tail" => "3/9\n", "structured" => { "n" => 3 } } },
      { "frame" => { "type" => "zz_future", "agent_loop_public_id" => LOOP_ID, "executor_public_id" => "ex-1",
                     "at" => "2026-09-13T10:00:00.500Z", "anything" => [1] } },
    ]
    client = CybrosAgentTest::FakeRealtimeClient.new(frames)

    items = []
    workspace([]).agent_loop(LOOP_ID).progress(realtime: client).call.each { |item| items << item }

    subscription = client.subscriptions.fetch(0)
    assert_equal "AgentAPI::V1::AgentLoopEventsChannel", subscription.channel
    assert_equal({ workspace_id: WORKSPACE_ID, agent_loop_id: LOOP_ID, items: "progress" }, subscription.params)
    assert_empty @transport.requests, "a socket and nothing else"

    frame, future = items
    assert_instance_of CybrosAgent::Api::ProgressFrame, frame
    assert_predicate frame, :executor_progress?
    assert_equal [LOOP_ID, "r1t0", "bash", "ex-1"],
      [frame.agent_loop_public_id, frame.task_key, frame.tool_name, frame.executor_public_id]
    assert_nil frame.conversation_public_id, "a loop host's frame carries the loop key alone"
    assert_equal "2026-09-13T10:00:00.250Z", frame.at
    assert_equal "3/9\n", frame.text_tail
    assert_equal({ "text_tail" => "3/9\n", "structured" => { "n" => 3 } }, frame.payload)
    assert_equal "zz_future", future.type, "a frame type this gem predates reaches the caller whole"
    assert_equal({ "anything" => [1] }, future.payload)

    # The events mapper never sees a frame: an `{event}` envelope here is
    # malformed, which is the disjointness by construction.
    bad = CybrosAgentTest::FakeRealtimeClient.new([{ "event" => { "type" => "task_status" } }])
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      workspace([]).agent_loop(LOOP_ID).progress(realtime: bad).call.each { |_item| nil }
    end
  end

  def test_the_transcript_opener_refuses_a_page_keyword_beside_the_socket
    # The sig has no overload for the pair, so under the type hook the call
    # is rejected as a TypeError first (workspaces_test's precedent); the
    # behavior suite sees Ruby's own refusal.
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    client = CybrosAgentTest::FakeRealtimeClient.new
    assert_raises(ArgumentError) { workspace([]).agent_loop(LOOP_ID).transcript(realtime: client, limit: 5) }
  end

  # A COMPLETED LOOP MUST PARSE, which for the whole life of this gem it
  # did not. `result` is an outcome SUMMARY object — the kernel writes
  # `{"finish_quality" => ...}` on a settled round and `{"resolved" =>
  # true}` on a settled park — and this side typed it as a String, so the
  # first task to actually finish raised MalformedResponse on the way in.
  # Every fixture here omitted the field, which is exactly why nothing
  # caught it until a daemon read back a run a real model had finished.
  def test_a_settled_task_carries_its_outcome_summary
    settled = TASK.merge(
      "status" => "completed",
      "result" => { "finish_quality" => "complete" },
      "completed_at" => "2026-09-02T00:01:00Z"
    )
    body = { "agent_loop" => LOOP.merge("status" => "completed", "tasks" => [settled]) }
    loop_row = workspace([[200, {}, body]]).agent_loops.agent_loop(LOOP_ID).fetch

    task = loop_row.tasks.first
    assert_equal({ "finish_quality" => "complete" }, task.result)
    assert_predicate task, :terminal?
  end

  # Absent stays absent: the projection is compacted, so a task that
  # summarized nothing must read as nil rather than an empty object.
  def test_a_task_with_no_summary_reads_as_none
    loop_row = workspace([[200, {}, { "agent_loop" => LOOP }]])
      .agent_loops.agent_loop(LOOP_ID).fetch
    assert_nil loop_row.tasks.first.result
  end

  # THE SHELL: the configuration words ride the create
  # envelope beside the steps; a mechanism the kernel cannot honour yet
  # comes back typed rather than defaulted, and the rule list rides only
  # when the caller wrote one.
  def test_create_carries_the_configuration_shell_and_surfaces_its_typed_refusal
    seed = CybrosAgent::Steps::Model.new(prompt: "p", key: "round1")
    rules = [{ "tool" => "bash", "path" => "command", "match" => "*rm -rf /*", "verdict" => "deny" }]
    workspace([[201, {}, { "agent_loop" => LOOP, "receipt" => { "revision" => 1 } }]])
      .agent_loops.create(
        steps: [seed], idempotency_key: "seed-1",
        prompt_mechanism: "raw", approval_mode: "ask", approval_rules: rules
      )
    envelope = request[:body].fetch("agent_loop")
    assert_equal "raw", envelope.fetch("prompt_mechanism")
    assert_equal "ask", envelope.fetch("approval_mode")
    assert_equal rules, envelope.fetch("approval_rules"), "sent as written; the kernel is the one evaluator"

    error = assert_raises(CybrosAgent::Api::Error) do
      workspace([[422, {}, { "error" => { "code" => "prompt_template_missing", "message" => "no" } }]])
        .agent_loops.create(steps: [seed], idempotency_key: "seed-2", prompt_mechanism: "assembly",
          approval_mode: "bypass")
    end
    assert_equal "prompt_template_missing", error.code, "the shell's refusal, relayed with its code"
    refute request[:body].fetch("agent_loop").key?("approval_rules"), "no rules written, none sent"
  end

  # NO SILENT DEFAULT:
  # `approval_mode` is REQUIRED — `bypass`, `ask` or `rules` — and the
  # kernel refuses nil `invalid_approval_mode`, so an omission is an
  # ArgumentError before any request rather than a 422 after one, and
  # an empty word is refused the same way.
  def test_create_refuses_to_leave_the_process_without_an_approval_mode
    seed = CybrosAgent::Steps::Model.new(prompt: "p", key: "round1")
    context = workspace([]).agent_loops

    # An EMPTY word is well-typed and still wrong — the guard's own case,
    # under every run; the omission and nil are the signature's, below.
    assert_raises(ArgumentError) { context.create(steps: [seed], idempotency_key: "seed-1", approval_mode: "") }
    assert_empty @transport.requests, "a missing word never reaches the wire"

    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      workspace([[422, {}, { "error" => { "code" => "invalid_approval_mode", "message" => "no" } }]])
        .agent_loops.create(steps: [seed], idempotency_key: "seed-1", approval_mode: "telepathy")
    end
    assert_equal "invalid_approval_mode", error.code, "the vocabulary is the kernel's to judge"
  end

  # The omission itself, and nil: Ruby's own ArgumentError for a required
  # keyword (the RBS hook answers first under the conformance run — the
  # `transcript` precedent above).
  def test_create_without_an_approval_mode_is_an_argument_error_before_any_request
    skip("the RBS hook answers before Ruby's own ArgumentError") if ENV["RBS_TEST_TARGET"]

    seed = CybrosAgent::Steps::Model.new(prompt: "p", key: "round1")
    context = workspace([]).agent_loops
    assert_raises(ArgumentError) { context.create(steps: [seed], idempotency_key: "seed-1") }
    assert_raises(ArgumentError) { context.create(steps: [seed], idempotency_key: "seed-1", approval_mode: nil) }
    assert_empty @transport.requests
  end
end
