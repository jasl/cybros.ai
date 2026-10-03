require "support/host_run_harness"

# What following a HOST teaches a daemon, as opposed to following a reply:
# the useful state is a table keyed by task, the live text is a preview of
# the current round rather than a transcript, and the item that says where
# the host stands is the turn-shaped `turn_status` — one handler for both
# hosts, whose `status` is a LEVEL a retry reopens.
class HostRunTest < Minitest::Test
  include RhoTest::HostRunHarness

  # KERNEL MAIL on the conversation feed: an
  # `input_accepted` stamped `task_result` is a background answer that
  # outlived its turn, remembered by the key the model saw — once, across
  # turns; a person's own input is not mail. EVERY WRAPPED ROW is kept with its speaker: the kernel's two origins and a peer's
  # `agent` row, each with `origin`, `authored_by` and the sender stamp
  # as the feed carried them, so a watcher prints `from:`; a `person` row
  # (bare) is nobody's mail, and so is a BARE `agent` row — the person's
  # own word posted through this daemon's agent credential, or a peer
  # app's direct reply: only a row SENT from a conversation (the stamp)
  # is a peer's send.
  def test_kernel_mail_is_remembered_from_the_input_accepted_item
    mail = { "input_public_id" => "in-9", "queue_position" => 3, "state" => "pending",
             "delivery_mode" => "steer", "kind" => "message", "role" => "user",
             "origin" => "task_result", "agent_loop_public_id" => "al-1", "task_key" => "r2t0",
             "authored_by" => { "kind" => "agent", "handle" => "rho", "display_name" => "rho" } }
    sent = { "input_public_id" => "in-12", "kind" => "direct_reply", "role" => "user", "origin" => "agent",
             "sender_conversation_public_id" => "c-peer",
             "authored_by" => { "kind" => "agent", "handle" => "lark", "display_name" => "Lark" } }
    run = run_for([page(
      event(1, "input_accepted", mail),
      event(2, "input_accepted", mail.merge("input_public_id" => "in-10", "task_key" => "r2t1")),
      event(3, "input_accepted", { "input_public_id" => "in-11", "kind" => "direct_reply", "role" => "user",
                                   "origin" => "person", "authored_by" => { "kind" => "human", "handle" => "jo" } }),
      event(4, "input_accepted", mail),
      event(5, "input_accepted", sent),
      event(6, "input_accepted", { "input_public_id" => "in-13", "kind" => "message", "role" => "user",
                                   "origin" => "agent", "authored_by" => { "kind" => "agent", "handle" => "rho" } }),
      loop_event(7, "completed")
    )])

    run.follow
    assert_equal [
      { task_key: "r2t0", agent_loop_public_id: "al-1", input_public_id: "in-9", origin: "task_result",
        authored_by: { "kind" => "agent", "handle" => "rho", "display_name" => "rho" } },
      { task_key: "r2t1", agent_loop_public_id: "al-1", input_public_id: "in-10", origin: "task_result",
        authored_by: { "kind" => "agent", "handle" => "rho", "display_name" => "rho" } },
      { input_public_id: "in-12", origin: "agent", sender_conversation_public_id: "c-peer",
        authored_by: { "kind" => "agent", "handle" => "lark", "display_name" => "Lark" } },
    ], run.snapshot.mailed
    assert_equal run.snapshot.mailed, run.snapshot.to_h.fetch(:mailed)
  end

  # A SCHEDULED ROW is remembered
  # whatever its origin — a person's own word too, which is nobody's mail
  # otherwise — with the `deliver_at` the kernel narrated, so a watcher
  # prints `scheduled:`; an untimed person row stays bare.
  def test_a_scheduled_row_is_remembered_with_its_time_whatever_the_origin
    run = run_for([page(
      event(1, "input_accepted", { "input_public_id" => "in-20", "kind" => "direct_reply", "role" => "user",
                                   "origin" => "person", "deliver_at" => "2026-09-16T09:20:00Z",
                                   "authored_by" => { "kind" => "human", "handle" => "jo" } }),
      event(2, "input_accepted", { "input_public_id" => "in-21", "kind" => "direct_reply", "role" => "user",
                                   "origin" => "person", "authored_by" => { "kind" => "human", "handle" => "jo" } }),
      loop_event(3, "completed")
    )])

    run.follow
    assert_equal [
      { input_public_id: "in-20", origin: "person", authored_by: { "kind" => "human", "handle" => "jo" },
        deliver_at: "2026-09-16T09:20:00Z" },
    ], run.snapshot.mailed
  end

  # THE CHILD TREE: a conversation host reads its children
  # off the kernel when its turn settles and when a child's reply lands
  # (`origin: child`) — never per task, never on a standalone loop — and
  # the snapshot carries each child with its label, its answerer and
  # whether a reply runs there; a read that fails keeps the last list.
  def test_a_conversation_host_reads_its_children_at_the_turn_settle_and_on_child_mail
    child = CybrosAgent::Api::ConversationSummary.new(
      public_id: "c-child", title: nil, answering_user_public_id: "peer-1", archived_at: nil, billing_subject: nil,
      parent: CybrosAgent::Api::ConversationParent.new(public_id: "c-1", spawn_node_key: "r2t0", label: "reviewer"),
      forked_from_turn_public_id: nil, forked_from_variant_public_id: nil, side: false,
      active_turn_public_id: "t-9", context_revision: 0, last_activity_at: nil,
      created_at: "2026-09-12T00:00:00Z", updated_at: "2026-09-12T00:00:00Z"
    )
    reply = { "input_public_id" => "in-9", "origin" => "child", "agent_loop_public_id" => "al-1", "task_key" => "r2t0",
              "sender_conversation_public_id" => "c-child",
              "authored_by" => { "kind" => "agent", "handle" => "rho", "display_name" => "rho" } }
    run = run_for([page(
      settle_event(1, "running"), task_event(2, "r2t0", "completed", kind: "tool_task"),
      settle_event(3, "completed"), event(4, "input_accepted", reply)
    )], host: CONVERSATION, children: [child], sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }

    assert_equal 2, @context.children_reads, "once at the settle, once for the child's reply"
    assert_equal [{ public_id: "c-child", label: "reviewer", spawn_node_key: "r2t0", answering_user_public_id: "peer-1",
                    busy: true }], run.snapshot.children
    assert_equal run.snapshot.children, run.snapshot.to_h.fetch(:children)

    standalone = run_for([page(task_event(1, "r2t0", "completed", kind: "tool_task"), loop_event(2, "completed"))],
      children: [child])
    standalone.follow
    assert_equal 0, @context.children_reads, "a standalone loop has no children to read"
    refute standalone.snapshot.to_h.key?(:children)
  end

  # THE CHILD EDGE: `on_children` is told the
  # ids NEW to the listing on both edges — the settle, a child's mail —
  # never a child already listed, never an empty set; the daemon writes
  # each new child's environment copy from it.
  def test_on_children_is_told_the_ids_new_to_the_listing_on_both_edges
    summary = lambda do |public_id|
      CybrosAgent::Api::ConversationSummary.new(
        public_id: public_id, title: nil, answering_user_public_id: "peer-1", archived_at: nil, billing_subject: nil,
        parent: CybrosAgent::Api::ConversationParent.new(public_id: "c-1", spawn_node_key: nil, label: nil),
        forked_from_turn_public_id: nil, forked_from_variant_public_id: nil, side: false,
        active_turn_public_id: nil, context_revision: 0, last_activity_at: nil,
        created_at: "2026-09-12T00:00:00Z", updated_at: "2026-09-12T00:00:00Z"
      )
    end
    reply = { "input_public_id" => "in-9", "origin" => "child", "agent_loop_public_id" => "al-1", "task_key" => "r2t0",
              "sender_conversation_public_id" => "c-a",
              "authored_by" => { "kind" => "agent", "handle" => "rho", "display_name" => "rho" } }
    told = []
    listing = [summary.call("c-a")]
    run = run_for([page(
      settle_event(1, "running"), task_event(2, "r2t0", "completed", kind: "tool_task"),
      settle_event(3, "completed"), event(4, "input_accepted", reply)
    )], host: CONVERSATION, children: listing, sleeper: ->(_s) { raise StopIteration },
      on_children: ->(fired, added) { told << [fired.public_id, added]; listing << summary.call("c-b") })

    assert_raises(StopIteration) { run.follow }

    assert_equal [["c-1", ["c-a"]], ["c-1", ["c-b"]]], told, "the settle told of c-a; the child's mail of c-b alone"
  end

  # WHO RESOLVED A PARK: the settle's narration
  # rides the task item, and the task keeps it for the line a watcher prints.
  def test_a_tasks_resolved_by_rides_the_task_status_item
    run = run_for([page(
      task_event(1, "r1t0-ask-1", "waiting", kind: "await_task"),
      task_event(2, "r1t0-ask-1", "completed", kind: "await_task",
        resolved_by: { "kind" => "human", "public_id" => "0199-steward" }),
      loop_event(3, "completed")
    )])

    run.follow
    task = run.snapshot.tasks.find { |row| row.task_key == "r1t0-ask-1" }
    assert_equal({ "kind" => "human", "public_id" => "0199-steward" }, task.resolved_by)
    assert_equal({ "kind" => "human", "public_id" => "0199-steward" }, task.to_h.fetch(:resolved_by))
    refute run.snapshot.tasks.first.to_h.key?(:resolved_by) if run.snapshot.tasks.first.resolved_by.nil?
  end

  # A BLOCKED INPUT on the conversation feed: the drain's `input_blocked`
  # with a reason a person can act on (`unknown_model`, a refused
  # selection) is the input's durable STATE, remembered by id so the
  # author can read it off the snapshot. The `loop_held` narration rides
  # the same item type with NO state write — a transient hold the drain
  # re-narrates per settle — and is never a block.
  def test_a_blocked_input_is_remembered_and_a_loop_held_is_not
    run = run_for([page(
      event(1, "input_blocked", { "input_public_id" => "in-1", "queue_position" => 0, "blocked_reason" => "loop_held" }),
      event(2, "input_blocked", { "input_public_id" => "in-1", "queue_position" => 0, "blocked_reason" => "unknown_model" }),
      loop_event(3, "completed")
    )])

    run.follow
    assert_equal({ input_public_id: "in-1", blocked_reason: "unknown_model" }, run.snapshot.blocked)
    assert_equal run.snapshot.blocked, run.snapshot.to_h.fetch(:blocked)

    held = run_for([page(
      event(1, "input_blocked", { "input_public_id" => "in-1", "queue_position" => 0, "blocked_reason" => "loop_held" }),
      loop_event(2, "completed")
    )])
    held.follow
    assert_nil held.snapshot.blocked
    refute held.snapshot.to_h.key?(:blocked), "a nil block is compacted out of the row"
  end

  def test_tasks_accumulate_by_key_and_the_last_status_wins
    run = run_for([page(
      task_event(1, "round-1", "running"),
      task_event(2, "tool-1", "dispatched"),
      task_event(3, "round-1", "completed"),
      loop_event(4, "completed")
    )])

    run.follow
    tasks = run.snapshot.tasks.to_h { |task| [task.task_key, task.status] }
    assert_equal({ "round-1" => "completed", "tool-1" => "dispatched" }, tasks)
    assert run.snapshot.complete
    assert_equal "al-1", run.snapshot.loop
    assert_equal "agent_loop", run.snapshot.host_type
  end

  # THE CLAIMANT ASKED FOR MORE TIME (executor.md "Extend"): the item rides
  # the park it extends, the follower keeps the ask on the row so a watcher
  # prints it once, and the next status move drops it. The policy rides
  # every status item, so an `absorb` failure reads settled with no stamp.
  def test_a_deadline_extension_rides_the_park_and_the_policy_rides_every_item
    run = run_for([page(
      task_event(1, "t", "dispatched", kind: "tool_task", on_failure: "absorb"),
      event(2, "task_deadline_extended", { "task_key" => "t", "deadline_at" => "2026-09-08T12:30:00Z",
                                           "by" => "0199-runner", "timeout_ms" => 300_000 }),
      event(3, "task_deadline_extended", { "task_key" => "ghost", "timeout_ms" => 1 }),
      task_event(4, "u", "failed", kind: "tool_task", on_failure: "absorb", error_key: "tool_failed"),
      loop_event(5, "completed")
    )])

    run.follow
    extended = run.snapshot.tasks.find { |task| task.task_key == "t" }
    assert_equal 300_000, extended.extension_ms
    assert_equal "absorb", extended.on_failure
    assert_equal({ task_key: "t", kind: "tool_task", status: "dispatched", on_failure: "absorb", extension_ms: 300_000 },
      extended.to_h)
    assert_nil run.snapshot.tasks.find { |task| task.task_key == "ghost" }, "a late word about a row never seen"
    absorbed = run.snapshot.tasks.find { |task| task.task_key == "u" }
    assert_equal "absorb", absorbed.on_failure
    assert_nil absorbed.failure_resolution, "absorb stamps nothing: the policy is what says it is settled"

    moved = run_for([page(
      task_event(1, "t", "dispatched", kind: "tool_task"),
      event(2, "task_deadline_extended", { "task_key" => "t", "timeout_ms" => 300_000 }),
      task_event(3, "t", "completed"),
      loop_event(4, "completed")
    )])
    moved.follow
    assert_equal 1, moved.snapshot.tasks.length
    assert_nil moved.snapshot.tasks.first.extension_ms, "the next status move drops the ask"
  end

  # A follower that kept every task ever seen as a separate row would show
  # one loop as a hundred, which is exactly what a watcher cannot read.
  def test_a_task_that_moves_is_one_row_not_two
    run = run_for([page(
      task_event(1, "t", "running"),
      task_event(2, "t", "completed"),
      loop_event(3, "completed")
    )])

    run.follow
    assert_equal 1, run.snapshot.tasks.size
  end

  # `after` IS AUTHORED ONCE AND RIDES EVERY STATUS ITEM: a
  # status-only item must not erase it, a consumer's grows as a branch
  # forwards onto it, and the snapshot carries it — the one datum a
  # watcher indents a branch under its call key by.
  def test_after_is_kept_across_status_only_items_and_rides_the_snapshot
    run = run_for([page(
      task_event(1, "r1t0-model-1", "waiting", kind: "model_task", after: %w[r1t0]),
      task_event(2, "r1", "waiting", kind: "model_task", after: %w[r1t0]),
      task_event(3, "r1t0-model-1", "running"),
      task_event(4, "r1", "waiting", after: %w[r1t0 r1t0-model-1]),
      loop_event(5, "completed")
    )])

    run.follow
    root = run.snapshot.tasks.find { |task| task.task_key == "r1t0-model-1" }
    assert_equal %w[r1t0], root.after, "a status-only item keeps what the birth item said"
    assert_equal "running", root.status
    consumer = run.snapshot.tasks.find { |task| task.task_key == "r1" }
    assert_equal %w[r1t0 r1t0-model-1], consumer.after, "the latest word about what it hangs from wins"
    assert_equal(
      { task_key: "r1t0-model-1", kind: "model_task", status: "running", after: %w[r1t0] },
      run.snapshot.to_h.fetch(:tasks).find { |task| task[:task_key] == "r1t0-model-1" }
    )
    refute run.snapshot.to_h.fetch(:tasks).any? { |task| task.key?(:after) && task[:after].empty? },
      "a root carries no `after` at all, not an empty one"
  end

  # A `round_result` carries no `kind`. Before this, it replaced the row
  # and every settled model task read kind-less — nothing could tell a
  # round from a tool call once it finished.
  def test_a_round_result_keeps_the_kind_its_status_event_announced
    run = run_for([page(
      task_event(1, "r1", "running", kind: "model_task"),
      event(2, "round_result", { "task_key" => "r1", "status" => "completed", "model" => "m" }),
      loop_event(3, "completed")
    )])

    run.follow
    task = run.snapshot.tasks.find { |t| t.task_key == "r1" }
    assert_equal "model_task", task.kind
    assert_equal "completed", task.status
  end

  # A DECLINED ROUND ON THE ROW. The two items disagree on purpose: the
  # task failed `model_refused` while the invocation completed, so the
  # `round_result` that follows carries no `error_key` — it must not erase
  # the task's — and brings the round's own facts (who answered, how it
  # finished, the provider's category). A switch's `model_change` rides
  # the task item and survives its round; the task's next move starts the
  # row's round facts over.
  def test_a_declined_round_keeps_the_tasks_key_and_adds_the_rounds_facts
    primary = "dev/primary"
    change = { "from" => primary, "to" => "dev/fallback", "reason" => "model_refused", "category" => "cyber" }
    run = run_for([page(
      task_event(1, "r2", "running", kind: "model_task"),
      task_event(2, "r2", "failed", kind: "model_task", error_key: "model_refused", on_failure: "absorb"),
      event(3, "round_result", { "task_key" => "r2", "status" => "failed", "model" => primary,
                                 "finish_quality" => "refused", "refusal_category" => "cyber",
                                 "error_detail" => "This request triggered restrictions." }),
      task_event(4, "r3", "waiting", kind: "model_task", model_change: change),
      event(5, "round_result", { "task_key" => "r3", "status" => "waiting", "model" => primary, "finish_quality" => "refused" }),
      loop_event(6, "completed")
    )])

    run.follow
    tasks = run.snapshot.tasks.to_h { |task| [task.task_key, task] }
    stood = tasks.fetch("r2")
    assert_equal ["failed", "model_refused", primary, "refused", "cyber"],
      [stood.status, stood.error_key, stood.model, stood.finish_quality, stood.refusal_category]
    assert_equal({ task_key: "r2", kind: "model_task", status: "failed", on_failure: "absorb", error_key: "model_refused",
                   model: primary, finish_quality: "refused", refusal_category: "cyber" }, stood.to_h)
    moved = tasks.fetch("r3")
    assert_equal change, moved.model_change, "the round does not erase the switch it follows"
    assert_equal "refused", moved.finish_quality

    run = run_for([page(
      task_event(1, "r3", "waiting", kind: "model_task", model_change: change),
      event(2, "round_result", { "task_key" => "r3", "status" => "waiting", "model" => primary, "finish_quality" => "refused" }),
      task_event(3, "r3", "running", kind: "model_task"),
      loop_event(4, "completed")
    )])
    run.follow
    running = run.snapshot.tasks.find { |task| task.task_key == "r3" }
    assert_equal [nil, nil, nil], [running.model_change, running.finish_quality, running.model],
      "the task moved: the last round's facts and the switch note are behind it"
  end

  # Both sets are the gem's, never written here: the loop row's terminal
  # (what `LiveJourney` and `attach` read) and the turn shape's.
  def test_the_terminal_statuses_are_the_kernels
    assert_equal %w[completed canceled], Rho::HostRun::LOOP_TERMINAL_STATUSES,
      "no loop failed: a reasoned cancel is the loop failing (node review 2026-09-08)"
    assert_equal CybrosAgent::Api::TURN_TERMINAL_STATUSES, Rho::HostRun::TURN_TERMINAL_STATUSES
  end

  def test_a_gate_is_nudged_when_a_check_parks_and_told_when_the_loop_ends
    looks = []
    gate = fake_gate(looks)
    finished = []
    run = run_for([page(
      task_event(1, "work", "running", kind: "model_task"),
      task_event(2, "work", "completed"),
      task_event(3, "check-1", "completed", kind: "tool_task"),
      task_event(4, "hold-1", "dispatched", kind: "await_task"),
      loop_event(5, "completed")
    )], gate: gate, spawner: ->(&work) { work.call }, on_complete: ->(r) { finished << r.public_id })

    run.follow

    assert_equal 1, looks.count { |l| l != :cancelled }, "one nudge, on the parking event"
    assert_includes looks, :cancelled
    assert_equal [run.public_id], finished
    assert_equal({ "command" => "t" }, run.snapshot.to_h[:until])
  end

  # A LOOP HOST ends with its one turn. A loop is its own backing loop
  # from the first moment, so a gate bound to it is nudged before any
  # event has named it.
  def test_a_completed_or_canceled_turn_ends_the_follow_on_a_loop_host
    %w[completed canceled].each do |status|
      run = run_for([page(loop_event(1, status))])
      assert_equal "al-1", run.snapshot.loop, "a loop backs itself"
      run.follow
      assert run.snapshot.complete, "#{status} should end the follow"
      assert_predicate run, :turn_settled?
      assert_predicate run, :settled?
      assert_equal status, run.snapshot.status
    end
  end

  # A CONVERSATION HOST OUTLIVES ITS TURN: the turn's
  # terminal sets `complete` as the level a watcher reads, `on_complete`
  # is told, the gate is cancelled — and the follow goes on, because the
  # next `rho say` starts another turn on the same feed.
  def test_a_conversation_hosts_turn_terminal_does_not_end_the_follow
    finished = []
    looks = []
    run = run_for([page(settle_event(1, "running"), settle_event(2, "completed"))],
      host: CONVERSATION, on_complete: ->(r) { finished << r.snapshot.turn },
      gate: fake_gate(looks, loop_public_id: "al-1"), spawner: ->(&work) { work.call },
      sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }

    assert run.snapshot.complete
    assert_equal "completed", run.snapshot.status
    assert_predicate run, :turn_settled?
    refute_predicate run, :settled?, "the conversation stands; only stop or forget ends the follow"
    assert_equal %w[t-1], finished, "told at the turn terminal"
    assert_includes looks, :cancelled
  end

  # THE SECOND TURN starts the table over: a `turn_status` naming a turn
  # this follower has not seen moves `loop`/`turn` to the new pair, clears
  # the tasks, the text and the level, tells `on_turn`, and keeps every
  # backing loop in `loops`. A late note about the turn left behind moves
  # nothing.
  def test_a_new_turn_reopens_the_run_and_moves_the_pair_while_loops_keeps_both
    moves = []
    run = run_for([page(
      settle_event(1, "running"),
      task_event(2, "r1", "completed", kind: "model_task"),
      event(3, "text_delta", { "text" => "first" }),
      settle_event(4, "completed")
    ), page(
      event(5, "turn_status", { "status" => "running", "turn_public_id" => "t-2", "agent_loop_public_id" => "al-2" }),
      event(6, "turn_status", { "loop_status" => "canceled", "failure_reason" => "replaced",
                                "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" }),
      event(7, "turn_status", { "status" => "canceled", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" }),
      task_event(8, "r1", "running", kind: "model_task")
    )], host: CONVERSATION, on_turn: ->(r) { moves << [r.snapshot.turn, r.snapshot.loop] },
      sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    first = run.snapshot
    assert_equal %w[t-1 al-1 completed], [first.turn, first.loop, first.status]
    assert first.complete

    assert_raises(StopIteration) { run.follow }
    second = run.snapshot
    assert_equal %w[t-2 al-2 running], [second.turn, second.loop, second.status]
    refute second.complete, "the level is the new turn's"
    assert_nil second.loop_status, "the old loop's `replaced` note moved nothing here"
    assert_equal "", second.text
    assert_equal({ "r1" => "running" }, second.tasks.to_h { |task| [task.task_key, task.status] })
    assert_equal %w[al-1 al-2], second.loops
    assert_equal [%w[t-1 al-1], %w[t-2 al-2]], moves
  end

  # THE GATE IS BOUND TO ONE LOOP: nudged only while that loop backs the
  # turn, and handed the LOOP's own context — the trace it reads and the
  # door it appends through are the loop's, never the conversation's.
  def test_the_gate_is_nudged_for_its_own_loop_only_and_reads_the_loops_context
    looks = []
    built = []
    run = run_for([page(
      settle_event(1, "running"),
      task_event(2, "r1", "completed", kind: "model_task"),
      task_event(3, "check-1", "completed", kind: "tool_task"),
      task_event(4, "hold-1", "dispatched", kind: "await_task")
    ), page(
      settle_event(5, "completed"),
      event(6, "turn_status", { "status" => "running", "turn_public_id" => "t-2", "agent_loop_public_id" => "al-2" }),
      task_event(7, "r1", "completed", kind: "model_task"),
      task_event(8, "check-1", "completed", kind: "tool_task"),
      task_event(9, "hold-1", "dispatched", kind: "await_task")
    )], host: CONVERSATION, gate: fake_gate(looks, loop_public_id: "al-1"),
      spawner: ->(&work) { work.call },
      loop_context: ->(id) { built << id; "context for #{id}" },
      sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    assert_equal ["context for al-1"], looks
    assert_equal %w[al-1], built

    assert_raises(StopIteration) { run.follow }
    assert_equal ["context for al-1", :cancelled], looks, "the second turn's park nudges nothing: another loop"
  end

  # A re-adopted follower starts from what the row knew, so a gate bound
  # to that loop can be nudged before the feed has replayed a word.
  def test_a_seeded_follower_starts_on_the_rows_pair
    looks = []
    run = run_for([], host: CONVERSATION, loop: "al-4", turn: "t-4",
      gate: fake_gate(looks, loop_public_id: "al-4"), spawner: ->(&work) { work.call })

    run.nudge

    assert_equal %w[t-4 al-4], [run.snapshot.turn, run.snapshot.loop]
    assert_equal %w[al-4], run.snapshot.loops
    assert_equal [@context], looks, "a loop host's own context stands in when nothing builds one"
  end

  # A RE-ADOPTED FOLLOWER REPLAYS FROM THE START (the events feed holds no
  # durable position), so the row's own turn is the LAST one the replay
  # reaches — its events must be admitted like any turn's, never rejected
  # as "a turn left behind": seeded on `t-2`, a replay of t-1 then t-2 ends
  # on t-2's pair with t-2's tasks, settled. (Found by the todo journey's restart)
  def test_a_seeded_follower_admits_its_own_turn_when_the_replay_reaches_it
    run = run_for([page(
      event(1, "turn_status", { "status" => "running", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" }),
      task_event(2, "r1t0", "completed", kind: "tool_task"),
      event(3, "turn_status", { "status" => "completed", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" }),
      event(4, "turn_status", { "status" => "running", "turn_public_id" => "t-2", "agent_loop_public_id" => "al-2" }),
      task_event(5, "r2t0", "completed", kind: "tool_task"),
      event(6, "turn_status", { "status" => "completed", "turn_public_id" => "t-2", "agent_loop_public_id" => "al-2" })
    )], host: CONVERSATION, loop: "al-2", turn: "t-2", sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    replayed = run.snapshot
    assert_equal %w[t-2 al-2 completed], [replayed.turn, replayed.loop, replayed.status]
    assert replayed.complete
    assert_equal %w[r2t0], replayed.tasks.map(&:task_key), "the last turn's table, not the one before it"
    assert_equal %w[al-2 al-1], replayed.loops
  end

  # THE LEVEL: a standalone loop renders `failed` on
  # `needs_attention` and returns to `running` on retry or answer. A
  # follower that ended the follow on that `failed` stopped one event
  # early — `live_human_in_the_loop` drives the retry after the halt.
  def test_a_hold_is_complete_as_a_level_and_a_retry_reopens_it
    finished = []
    holding = true
    run = run_for([page(
      loop_event(1, "failed", loop_status: "needs_attention", failure_reason_key: "halt_failure",
        attention_reason: "halt_failure"),
      event(2, "attention_required", { "reason" => "halt_failure", "blocked_task_keys" => %w[r1] })
    ), page(
      loop_event(3, "running", loop_status: "running"),
      loop_event(4, "completed")
    )], on_complete: ->(r) { finished << r.public_id },
      sleeper: ->(_s) { raise StopIteration if holding })

    # First pass: the hold. Complete as a level, but nothing ended.
    assert_raises(StopIteration) { run.follow }
    held = run.snapshot
    assert held.complete
    assert_equal %w[failed needs_attention halt_failure], [held.status, held.loop_status, held.failure_reason_key]
    assert_equal "halt_failure", held.attention.reason
    refute_predicate run, :settled?, "a hold keeps the follow alive"
    assert_empty finished

    # Second pass: the retry reopened the turn, then it completed.
    holding = false
    run.follow
    assert_equal [run.public_id], finished
    assert_equal "completed", run.snapshot.status
    assert_predicate run, :settled?
  end

  # THE HOST IS GONE: a 404 on the feed — a poller's reading of the same end — ends the
  # follow and tells the daemon the same way.
  def test_a_not_found_on_the_feed_tells_the_daemon_the_host_ended
    ended = []
    @context = Context.new([], raise_once: CybrosAgent::Api::NotFound.new("gone", code: "conversation_not_found"))
    run = Rho::HostRun.new(host: CONVERSATION, context: @context, sleeper: ->(_seconds) { },
      on_ended: ->(finished) { ended << finished })

    assert_raises(CybrosAgent::Api::NotFound) { run.follow }
    assert_equal [run], ended
  end

  def test_a_failed_turn_on_a_terminal_loop_ends_the_follow
    run = run_for([page(loop_event(1, "failed", loop_status: "canceled", failure_reason: "authority_lost",
      failure_reason_key: "authority_lost"))])

    run.follow
    assert_predicate run, :settled?
    assert_equal "authority_lost", run.snapshot.failure_reason
  end

  # A CONVERSATION HOST hears two writers of one item type: the
  # loop-locked note moves only the loop's word — `status` absent means
  # the turn did not move — and settle's item carries the turn's.
  def test_a_turn_status_without_status_is_a_loop_note_and_settle_moves_the_turn
    run = run_for([page(
      note_event(1, "running"),
      note_event(2, "needs_attention", attention_reason: "halt_failure"),
      settle_event(3, "failed", failure_reason_key: "halt_failure", error_key: "provider_http_error",
        blocked_task_keys: %w[r1])
    ), page(
      note_event(4, "running"),
      settle_event(5, "running"),
      note_event(6, "completed"),
      settle_event(7, "completed", variant_status: "completed")
    )], host: CONVERSATION, sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    held = run.snapshot
    assert_equal "conversation", held.host_type
    assert_equal %w[failed needs_attention halt_failure], [held.status, held.loop_status, held.failure_reason_key]
    assert_equal %w[t-1 al-1], [held.turn, held.loop]
    refute_predicate run, :turn_settled?

    assert_raises(StopIteration) { run.follow }
    assert_equal %w[completed completed], [run.snapshot.status, run.snapshot.loop_status]
    assert_predicate run, :turn_settled?
    refute_predicate run, :settled?, "a conversation outlives its turn"
  end

  # THE TURN'S KIND rides `turn_status` on a
  # conversation host — `direct_reply`, `compaction_summary` — so a wait
  # for the loop a person's word minted can read past the between-turn
  # summary's. A new turn takes the item's word (nil when it carries
  # none); a note about the current turn without the key leaves it; one
  # with the key moves it; a snapshot without one serves no key at all.
  def test_the_turn_kind_follows_the_turn_status_items_that_name_it
    run = run_for([page(
      note_event(1, "running"),
      settle_event(2, "running", turn_kind: "direct_reply"),
      note_event(3, "running"),
      settle_event(4, "completed")
    ), page(
      event(5, "turn_status", { "status" => "running", "turn_public_id" => "t-s", "agent_loop_public_id" => "al-s",
                                "turn_kind" => "compaction_summary" }),
      event(6, "turn_status", { "loop_status" => "running", "turn_public_id" => "t-s", "agent_loop_public_id" => "al-s" })
    ), page(
      event(7, "turn_status", { "status" => "running", "turn_public_id" => "t-3", "agent_loop_public_id" => "al-3" })
    )], host: CONVERSATION, sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    held = run.snapshot
    assert_equal %w[t-1 al-1 direct_reply], [held.turn, held.loop, held.turn_kind], "named on the turn's settle item, kept by the notes"
    assert_equal "direct_reply", held.to_h.fetch(:turn_kind)

    assert_raises(StopIteration) { run.follow }
    summary = run.snapshot
    assert_equal %w[t-s al-s compaction_summary], [summary.turn, summary.loop, summary.turn_kind],
      "the summary's turn, its kind from the item that opened it"

    assert_raises(StopIteration) { run.follow }
    assert_equal ["t-3", "al-3", nil], [run.snapshot.turn, run.snapshot.loop, run.snapshot.turn_kind],
      "a new turn whose item carries no kind resets it"
    refute run.snapshot.to_h.key?(:turn_kind), "absent, the snapshot is byte-identical to before"
  end

  def test_an_unknown_item_type_advances_the_position_and_means_nothing
    run = run_for([page(
      event(1, "a_type_this_daemon_predates", { "whatever" => true }),
      loop_event(2, "completed")
    )])

    run.follow
    assert_equal 2, run.snapshot.sequence
  end

  def test_a_follower_with_no_watcher_subscribes_to_lifecycle_only
    run = run_for([page(loop_event(1, "running"))],
                  sockets: [Socket.new([])], live: false,
                  sleeper: ->(_s) { raise StopIteration })
    assert_raises(StopIteration) { run.follow }

    assert_equal [Rho::HostRun::LIFECYCLE_ITEMS], @context.asked
    refute run.snapshot.live
  end

  def test_attaching_a_watcher_widens_the_subscription
    run = run_for([page(loop_event(1, "running"))],
                  sockets: [Socket.new([]), Socket.new([])], live: false,
                  sleeper: ->(_s) { raise StopIteration })
    assert_raises(StopIteration) { run.follow }

    assert run.attach_socket
    assert_equal [Rho::HostRun::LIFECYCLE_ITEMS, nil], @context.asked
    assert run.snapshot.live
    refute run.attach_socket, "attaching twice should report no change"
  end

  # A follow that gave up on a brief kernel outage would leave a running
  # loop with nobody watching — the outage is transient, the loop is not.
  def test_transient_errors_are_retried_rather_than_raised
    slept = []
    @context = Context.new([page(loop_event(1, "completed"))],
                           raise_once: CybrosAgent::Api::ServerError.new("briefly unavailable"))
    run = Rho::HostRun.new(host: LOOP, context: @context,
                           sleeper: ->(seconds) { slept << seconds })

    run.follow
    assert run.snapshot.complete
    # The FEED spends its own transient budget first and re-drains from the
    # position it did not advance, so the follower never sees this one. Its
    # own rescue is the second line: it catches what survives that budget,
    # and re-drains on the next pass rather than dying.
    assert_empty slept
  end

  # ---- the host, and the one resolution rule ----

  # THE HOST PICKS THE KIND ITS DOOR ADMITS: a `message` on a
  # standalone loop, a `direct_reply` on the model a conversation last
  # used; and each stops through its own verb.
  def test_each_host_speaks_and_stops_its_own_way
    assert_equal({ kind: "message", text: "hi", delivery_mode: "steer" },
      LOOP.input_fields("hi", mode: "steer", model: "ignored"))
    assert_equal({ kind: "direct_reply", text: "hi", delivery_mode: "queue", model: "openrouter/x" },
      CONVERSATION.input_fields("hi", mode: "queue", model: "openrouter/x"))
    assert_equal({ kind: "direct_reply", text: "hi", delivery_mode: "steer" },
      CONVERSATION.input_fields("hi", mode: "steer"))
    # The turn's tightening of the profile's word rides the
    # conversation's reply; a loop host's `message` has no such field.
    assert_equal({ kind: "direct_reply", text: "hi", delivery_mode: "queue", model: "m", approval_mode: "ask" },
      CONVERSATION.input_fields("hi", mode: "queue", model: "m", approval_mode: "ask"))
    assert_equal({ kind: "message", text: "hi", delivery_mode: "steer" },
      LOOP.input_fields("hi", mode: "steer", approval_mode: "ask"))

    stopped = Struct.new(:status).new("canceling")
    loop_context = Object.new
    loop_context.define_singleton_method(:stop) { |force:| stopped if force }
    assert_equal "canceling", LOOP.stop(loop_context, force: true)
    canceled = []
    chat = Object.new
    chat.define_singleton_method(:cancel) { canceled << true }
    assert_equal "canceling", CONVERSATION.stop(chat, force: true)
    assert_equal [true], canceled
  end

  # A verb given a LOOP id — the eleven paid lanes parse one off `rho do`
  # — must never open the loop feed blind: a loop-backed loop's feed is its
  # conversation's. The store's row answers first; else the loop's own
  # turn block says whose it is.
  def test_a_loop_id_resolves_to_its_host_through_the_store_then_the_turn_block
    rows = [
      Rho::HostStore::Row.new(host_type: "agent_loop", host_public_id: "al-1", workspace: "ws-1",
        live: true, remembered_at: "", turn: nil, loop: nil, model: nil, compose: nil, notes: {}),
      Rho::HostStore::Row.new(host_type: "conversation", host_public_id: "c-2", workspace: "ws-1",
        live: true, remembered_at: "", turn: "t-2", loop: "al-2", model: nil, compose: nil, notes: {}),
    ]
    fetched = []
    fetch = lambda do |id|
      fetched << id
      turn = id == "al-3" ? CybrosAgent::Api::LoopTurn.new(status: "running") :
        CybrosAgent::Api::LoopTurn.new(status: "running", public_id: "t-4", conversation_public_id: "c-4")
      CybrosAgent::Api::AgentLoop.new(public_id: id, status: "running", failure_reason: nil,
        deliverable_task_key: nil, task_progress: nil, attention: nil, turn: turn, started_at: nil,
        paused_at: nil, completed_at: nil, created_at: "", updated_at: "")
    end

    assert_equal LOOP, Rho::Host.resolve("al-1", rows: rows, fetch_loop: fetch)
    assert_equal CONVERSATION.with(public_id: "c-2"), Rho::Host.resolve("c-2", rows: rows, fetch_loop: fetch)
    assert_equal CONVERSATION.with(public_id: "c-2"), Rho::Host.resolve("al-2", rows: rows, fetch_loop: fetch)
    assert_empty fetched, "a row rho placed is never second-guessed with a fetch"

    assert_equal LOOP.with(public_id: "al-3"), Rho::Host.resolve("al-3", rows: rows, fetch_loop: fetch)
    assert_equal CONVERSATION.with(public_id: "c-4"), Rho::Host.resolve("al-4", rows: rows, fetch_loop: fetch)
    assert_equal %w[al-3 al-4], fetched
  end

  # THE HANDOFF FOLLOWED: a `runner_bound` on the host feed
  # tells `on_runner_bound` with the payload — the executor, or none after
  # a reap — and the snapshot carries the binding as the feed last said it.
  def test_a_runner_bound_item_tells_the_follower_and_moves_the_snapshots_runner
    told = []
    run = run_for([page(
      event(1, "turn_status", { "status" => "running", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" }),
      event(2, "runner_bound", { "executor_public_id" => "0199-h", "previous_executor_public_id" => "0199-runner",
                                 "by" => "0199-steward" })
    )], host: CONVERSATION, on_runner_bound: ->(r, payload) { told << [r.public_id, payload] },
      sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    assert_equal [["c-1", { "executor_public_id" => "0199-h", "previous_executor_public_id" => "0199-runner",
                            "by" => "0199-steward" }]], told
    assert_equal "0199-h", run.snapshot.runner
    assert_equal "0199-h", run.snapshot.to_h.fetch(:runner)

    reaped = run_for([page(
      event(1, "runner_bound", { "previous_executor_public_id" => "0199-h", "by" => "0199-steward" })
    )], host: CONVERSATION, on_runner_bound: ->(_r, payload) { told << payload },
      sleeper: ->(_s) { raise StopIteration })
    assert_raises(StopIteration) { reaped.follow }
    assert_nil reaped.snapshot.runner
    refute reaped.snapshot.to_h.key?(:runner), "nil is compacted away, like every absent fact"
    assert_nil told.last["executor_public_id"]
  end
end
