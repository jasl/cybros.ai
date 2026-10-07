require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

class EvalsPredicatesTest < Minitest::Test
  include EvalsFixtureBench
  P = E2E::Evals::Predicates
  D = E2E::Evals::Drawing
  W = EvalsDrawings
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)

  def test_the_door_is_a_fan_of_two_task_calls_in_one_round
    assert_equal "task_fan", P.door(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, []))
    assert_nil P.door(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []))
    one_per_round = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "delegate_task", after: ["r1"]), D.tool("r2t0", "delegate_task", after: ["r2"])], [])
    assert_nil P.door(one_per_round), "two task calls in different rounds are not a fan"
    assert_match(/no round fanned two task calls: \{"delegate_task" => 2\}/, P.reached_a_door(one_per_round))
  end

  # ── the door, read in vivo (`door_kind` beside `door`) ─────────────────
  # Five delegations, one per file, and a mainline drawn from its rounds' calls (`EvalsDrawings.mainline`).
  FIVE = %w[a b c d e].map { |f| ["delegate_task", { "prompt" => "Review lib/#{f}.rb for the uncalled method." }] }.freeze

  def mainline(*rounds, answer: true) = W.mainline(*rounds, answer: answer)

  def bash(command) = W.bash(command)

  def door_at(trace) = [P.door_kind(trace), P.door_read(trace)["round"], P.dispatch_round(trace), P.scout_then_door(trace)]

  def test_the_door_kind_reads_the_first_round_that_is_not_a_look
    five = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [])
    assert_equal ["task_fan", 1, 1, false], door_at(five)
    assert_equal({ "round" => 1, "members" => 5, "beside" => [] }, P.door_read(five))
    assert_equal(%w[a b c d e].map { |f| { "tool" => "delegate_task", "wait" => true, "prompt_head" => "Review lib/#{f}.rb for the uncalled method." } },
      P.door_calls(five))

    mail = D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS)
    assert_equal ["task_one", 1, 1, false], door_at(mail)
    assert_equal ["bash"], P.door_read(mail)["beside"]
    assert_equal [{ "tool" => "delegate_task", "wait" => nil, "prompt_head" => "run ruby test/all.rb" },
                  { "tool" => "bash", "wait" => nil, "prompt_head" => "ls lib | wc -l" }], P.door_calls(mail)
    long = "Run the whole suite with bin/rails test and tell me which test fails, then fix nothing and report back to me."
    assert_equal [long[0, 80]], P.door_calls(mainline([["delegate_task", { "prompt" => long }]])).map { |call| call["prompt_head"] }
  end

  # A LOOK FIRST, THEN THE DOOR: a round of reads — two quiet shell reads, or a `;`-joined chain of
  # them — is a look and the fan after it the door at round 2. An opening the narrow look rule reads
  # as a door (`echo` is no look) is the door at round 1, `plain`; the dispatch round stays the
  # fan's, and a read-class call before it makes it a scout then a door.
  def test_a_look_then_a_fan_is_the_door_at_round_two_and_the_dispatch_round_is_the_fans
    looked = mainline([bash("ls lib"), bash("cat lib/a.rb 2>/dev/null")], FIVE)
    assert_equal ["task_fan", 2, 2, true], door_at(looked)
    assert_equal 5, P.door_read(looked)["members"]
    assert_equal ["task_fan", 2, 2, true], door_at(mainline([bash("cat lib/a.rb; ls -R lib; pwd")], FIVE))

    echoed = mainline([bash("ls -la; echo ---; ls bin")], FIVE)
    assert_equal ["plain", 1, 2, true], door_at(echoed)
    assert_equal({ "round" => 1, "members" => 0, "beside" => ["bash"] }, P.door_read(echoed))
    assert_equal ["delegate_task"] * 5, P.door_calls(echoed).map { |call| call["tool"] }, "the dispatch round's rows, not the door round's"
    refute P.scout_then_door(mainline([["write", { "path" => "notes.md" }]], FIVE)), "a write before the fan is no read"
    assert P.scout_then_door(mainline([["glob", { "pattern" => "lib/*.rb" }]], FIVE))
  end

  # THREE LOOKS ARE A SCOUT: no door round, no dispatch; fewer rounds than three, all looks, are a
  # scout too, and a mainline with no round at all is `none`. A shell command that is no read is the
  # door where it stands.
  def test_three_looks_are_a_scout_and_a_command_that_is_no_read_is_a_plain_door
    scout = mainline([["ls", { "path" => "." }]], [["read", { "path" => "lib/a.rb" }]], [["grep", { "pattern" => "def call" }]])
    assert_equal ["scout", nil, nil, false], door_at(scout)
    assert_equal({ "round" => nil, "members" => 0, "beside" => [] }, P.door_read(scout))
    assert_empty P.door_calls(scout)
    assert_equal ["scout", nil, nil, false], door_at(mainline([["read", { "path" => "lib/a.rb" }]], answer: false))
    assert_equal ["none", nil, nil, false], door_at(E2E::Evals::Trace.empty)
    assert_equal ["none", 2, nil, false], door_at(mainline([["read", { "path" => "lib/a.rb" }]])), "the round that answered is the door"
    assert_equal ["plain", 1, nil, false], door_at(mainline([bash("sleep 1 && rm x")]))
  end


  def test_the_door_is_unchanged_beside_the_door_kind
    assert_equal "task_fan", P.door(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, []))
    assert_nil P.door(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS))
    assert_equal "task_fan", P.door(mainline([bash("ls lib"), bash("cat lib/a.rb 2>/dev/null")], FIVE))
    assert_equal "task_fan", P.door(mainline([bash("ls -la; echo ---; ls bin")], FIVE))
    assert_nil P.door(mainline([["ls", { "path" => "." }]], [["read", { "path" => "lib/a.rb" }]], [["grep", { "pattern" => "def call" }]]))
    assert_nil P.door(mainline([bash("sleep 1 && rm x")]))
  end

  def test_the_receipt_loop_wants_a_receipt_and_every_loop_completed
    assert_equal true, P.receipt_loop(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS))
    assert_match(/no input_accepted/, P.receipt_loop(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, [])))
    stuck = W::MAIL_EVENTS.reject { |e| e["payload"]["run_public_id"] == "loop-2" && e["payload"]["run_status"] == "completed" }
    assert_equal "loop loop-2 never completed on the feed", P.receipt_loop(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, stuck))
    primary_open = D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS, loops: [{ "id" => "loop-1", "status" => "running" }])
    assert_equal "loop loop-1 never completed on the feed", P.every_loop_completed(primary_open)
  end

  # NO RECEIPT, TWO READINGS: a fan whose every `task` call waited owed no receipt — the kernel mails
  # one for a detached call alone — so the receipt-wake loop never ran and the red is the shape the
  # model chose; a detached call with no receipt is mail the kernel owed. The head stays the same.
  def test_the_receipt_loop_names_a_waited_fan_and_a_detached_fan_apart
    graph = D.graph([D.n("r1", "model_task"), *(0..11).map { |i| D.n("r1t#{i}", "tool_task") }, D.n("r2", "model_task", deliverable: true)],
      (0..11).flat_map { |i| [%W[r1 r1t#{i}], %W[r1t#{i} r2]] })
    waited = (0..11).map { |i| D.tool("r1t#{i}", "delegate_task", after: ["r1"], input: { "prompt" => "Refute claim C#{i}.", "wait" => true }) }
    assert_equal "no input_accepted{origin: task_result}: every task call waited (wait: true on 12 of 12), so no receipt was owed " \
                 "and the receipt-wake loop never ran ({\"delegate_task\" => 12})", P.receipt_loop(D.trace(graph, waited, []))
    detached = waited.each_with_index.map { |row, i| i.zero? ? row.merge("tool_input" => row["tool_input"].merge("wait" => false)) : row }
    assert_equal "no input_accepted{origin: task_result}: the kernel mailed no receipt for 1 detached task call(s) ({\"delegate_task\" => 12})",
      P.receipt_loop(D.trace(graph, detached, []))
  end

  # A PICTURE OVER A PLAN THAT DID NO WORK names why: a stage whose own source does not parse in
  # usable generation's own sentence, a script that places no step in the kernel's refusal of it —
  # never the picture's `missing_steps` over an empty graph. Read only once the picture missed, so
  # no green moves: an exact plan beside a stage that does not parse (canceled, it never ran) is
  # the picture still, and one beside a stage that failed reads its branch as it always did.

  # THE RECORDED-ONLY RENDEZVOUS ON BOTH TIERS: its picture is a fact, never the bar. The strong tier
  # reads the script the kernel accepted and its branch completed; the floor reads usable generation
  # by a call of the run AND that call's branch completed — usable alone reads a failed model member
  # as a node that stands, and the rendezvous keeps its branch. Both bars run on every tier, so a
  # plan the harness cannot read raises into the lane whichever the tier picks.

  # THE FAN OF FIVE'S MERGE, WHEREVER IT LANDED: a detached fan's merge is written by a turn a
  # receipt woke, so the merge is read on the first reply that names all five — turn 1's, then each
  # woken turn's, as the lane recorded them by the stop (`replies`) — and `merge_turn` names which.
  # A trace from before the lane recorded the replies holds turn 1's alone.
  def test_the_fan_of_five_reads_its_merge_on_the_first_reply_naming_all_five
    expected = CORPUS.find("task-fan-five").expected
    loops = [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed", "traced" => false }]
    promise = "I'll merge their answers as soon as the results arrive."
    detached = W::FIVE_TASKS.map { |row| row.merge("tool_input" => row["tool_input"].merge("wait" => false)) }
    woken = expected.verdict(D.trace(W::FIVE_GRAPH, detached, [], loops: loops,
      facts: { "reply" => promise, "replies" => { "loop-1" => promise, "loop-2" => "All five answers are in.\n#{W::FIVE_REPLY}" } }))
    assert_predicate woken, :green?, woken.reason
    assert_equal ["woken-1", false], woken.facts.values_at("merge_turn", "waited")

    waited = expected.verdict(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [], facts: { "reply" => W::FIVE_REPLY, "replies" => { "loop-1" => W::FIVE_REPLY } }))
    assert_predicate waited, :green?, waited.reason
    assert_equal ["primary", true], waited.facts.values_at("merge_turn", "waited")

    four = W::FIVE_REPLY.lines.first(4).join
    unread = expected.verdict(D.trace(W::FIVE_GRAPH, detached, [], facts: { "reply" => four }))
    assert_equal "the merged reply names no lib/e.rb", unread.reason
    assert_nil unread.facts.fetch("merge_turn"), "no reply named all five: not read"
    promised = expected.verdict(D.trace(W::FIVE_GRAPH, detached, [], loops: loops, facts: { "reply" => promise, "replies" => { "loop-1" => promise } }))
    assert_equal "the merged reply names no lib/a.rb", promised.reason, "a merge the stop cut before it was written is not on the record"
    assert_equal "primary", expected.verdict(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [], facts: { "reply" => W::FIVE_REPLY })).facts.fetch("merge_turn")
  end

  # THE QUIET POINT'S RECORD (the `settle_receipts` driver): every loop's reply rides `replies` and
  # the driver's `reply` is the LAST loop's, which may be a word spoken after the merge. The merge
  # and the orphans it names are read on the first reply naming all five, never on whichever loop
  # spoke last.
  def test_the_fan_of_five_at_the_quiet_point_reads_the_merge_not_the_last_word
    expected = CORPUS.find("task-fan-five").expected
    detached = W::FIVE_TASKS.map { |row| row.merge("tool_input" => row["tool_input"].merge("wait" => false)) }
    loops = %w[loop-1 loop-2 loop-3 loop-4].map { |id| { "id" => id, "status" => "completed" } }
    replies = { "loop-1" => "I'll merge their answers as soon as the results arrive.",
                "loop-2" => "Two answers are in; waiting for the rest.",
                "loop-3" => "All five answers are in.\n#{W::FIVE_REPLY}",
                "loop-4" => "Nothing is left to merge." }
    verdict = expected.verdict(D.trace(W::FIVE_GRAPH, detached, [], loops: loops,
      facts: { "reply" => replies.values.last, "replies" => replies, "woken_loops" => %w[loop-2 loop-3 loop-4] }))
    assert_predicate verdict, :green?, verdict.reason
    assert_equal ["woken-2", false, 5], verdict.facts.values_at("merge_turn", "waited", "orphans_named")
  end


  # THE FAN THAT CAME BACK WHOLE: a fan-and-merge on the task door owes no receipt — a judge called
  # with `wait: true` returns inline and the kernel mails nothing; a detached judge comes back as
  # mail — the property is every task the fan raised completed and every loop completed.
  # `receipt_loop` stays the iterative shapes' read.
  def test_the_fan_that_came_back_whole_owes_no_receipt
    panel = W.panel_trace
    assert_equal 0, panel.receipts
    assert_equal "task_fan", P.door(panel)
    assert_match(/no input_accepted/, P.receipt_loop(panel), "the receipt loop still refuses the waited panel")
    assert_equal true, P.fan_completed(panel)
    assert_equal true, P.fan_completed(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [])), "a waited five-fan came back whole"
    detached = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS.map { |row| row.merge("tool_input" => row["tool_input"].merge("wait" => false)) }, W::MAIL_EVENTS,
      loops: [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed" }])
    assert_equal true, P.fan_completed(detached), "a detached fan that was mailed back is the same shape"
    lost = W.panel_trace(tasks: W::PANEL_TASKS.map { |row| row["key"] == "r2t1" ? row.merge("status" => "failed") : row })
    assert_equal "r2t1(failed) did not complete: the fan never came back whole", P.fan_completed(lost)
    open = W.panel_trace(loops: [{ "id" => "loop-1", "status" => "running" }])
    assert_equal "loop loop-1 never completed on the feed", P.fan_completed(open)
    assert_match(/no round fanned two task calls: \{"delegate_task" => 2\}/,
      P.fan_completed(D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "delegate_task", after: ["r1"]), D.tool("r2t0", "delegate_task", after: ["r2"])], [])))
  end

  def test_background_is_the_task_row_without_wait_true
    assert P.background?(D.tool("r1t0", "delegate_task", input: { "prompt" => "x" }))
    assert P.background?(D.tool("r1t0", "delegate_task", input: { "prompt" => "x", "wait" => false }))
    refute P.background?(D.tool("r1t0", "delegate_task", input: { "prompt" => "x", "wait" => true }))
    refute P.background?(D.tool("r1t0", "bash", input: { "command" => "x" }))
  end

  def test_per_file_counts_task_prompts
    trace = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS + [D.tool("r2t0", "delegate_task", after: ["r2"], input: { "prompt" => "again lib/a.rb" })], [])
    assert_equal({ "a.rb" => 2, "b.rb" => 1, "e.rb" => 1 }, P.per_file(trace, %w[a.rb b.rb e.rb]))
    # PROMPTS, NOT MENTIONS (12a L2): a finder prompt that spells its file
    # twice — "Find … in lib/auth.rb … answer `lib/auth.rb — <token>`" —
    # is ONE finder; eight such prompts read as one per file, never two.
    twice = D.trace(W::FIVE_GRAPH, [D.tool("r1t0", "delegate_task", after: ["r1"],
      input: { "prompt" => "Find the token in lib/a.rb and answer `lib/a.rb — <token>`." })], [])
    assert_equal({ "a.rb" => 1, "b.rb" => 0 }, P.per_file(twice, %w[a.rb b.rb]))
    assert_equal 0, P.graph_verbs_inside_branches(trace)
    branchy = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS + [D.tool("r1t0-model-1-r3t0", "delegate_task", after: ["r1t0-model-1-r3"])], [])
    assert_equal 1, P.graph_verbs_inside_branches(branchy)
    # A delegate's own calls carry round keys (`r3t0`, `r6t0`) made by its root and by a round the
    # kernel marks `mainline: false`: inside the branch all the same.
    delegated = D.trace(*W.delegated("delegate_task", [{ "prompt" => "a" }, { "prompt" => "b" }]), [])
    assert_equal 4, P.graph_verbs_inside_branches(delegated)
    assert_equal %w[r2t0 r2t1], delegated.mainline_calls.map { |row| row["key"] }, "r1's fan is the mainline's; nothing under it is"
  end

  def test_the_compaction_columns_read_the_rounds_by_number
    events = W.compaction_events("prune", trigger: "wall", task_key: "r4")
    reread = W::WALL_TASKS.map { |row| row["key"] == "r5t0" ? row.merge("tool_input" => { "path" => "corpus/doc-001.txt" }) : row }
    trace = D.trace(W::WALL_GRAPH, reread, events)
    assert_equal "r4", P.compacted_round(trace)
    assert_equal 0.333, P.reread_rate(trace), "three reads after r4, one of a path seen before"
    assert_equal 4, P.induced_rounds(trace, minimum_after: 0), "r4 to r7"
    assert_equal 2, P.induced_rounds(trace, minimum_after: 2)
    assert_equal 0, P.induced_rounds(trace, minimum_after: 9), "never negative"
    assert_nil P.reread_rate(D.trace(W::WALL_GRAPH, W::WALL_TASKS, []))
    assert_nil P.induced_rounds(D.trace(W::WALL_GRAPH, W::WALL_TASKS, []), minimum_after: 0)
    columns = P.compaction_columns(trace.with_facts("summaries" => { "k1" => "Summary", "k2" => "more" }), minimum_after: 0)
    assert_equal({ "compactions" => { "prune/wall" => 1 }, "reread_rate" => 0.333, "induced_rounds" => 4, "summary_bytes" => 11,
                   "summary_keys" => %w[k1 k2] }, columns)
    assert_equal true, P.pointers_never_values(trace.with_facts("summaries" => { "k1" => "Tool read corpus/doc-001.txt (completed)" }), ["body-abc"])
    assert_match(/k2 reproduced a value.*body-abc/, P.pointers_never_values(trace.with_facts("summaries" => { "k1" => "x", "k2" => "line: body-abc" }), ["body-abc"]))
  end

  # KEYS ARE MARKS, NEVER NUMBERS (evals run 2, the wall-kernel record):
  # the until extension authors `work-2` on the mainline, the kernel's `k1`
  # hangs off it, and a reader that took the number out of a key raised
  # `undefined method '>=' for nil` — the columns count by the loop row's
  # order from the repaired round.
  def test_the_compaction_columns_count_by_order_when_a_mainline_round_is_not_keyed_rN
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task"), D.n("r2t0", "tool_task"),
       D.n("k1", "model_task", mainline: false), D.n("r3", "model_task"), D.n("check-1", "tool_task"),
       D.n("work-2", "model_task"), D.n("work-2t0", "tool_task"), D.n("r4", "model_task", deliverable: true)],
      [%w[r1 r1t0], %w[r1t0 r2], %w[r2 r2t0], %w[r2t0 r3], %w[k1 r3], %w[r3 check-1], %w[check-1 work-2], %w[work-2 work-2t0], %w[work-2t0 r4]]
    )
    tasks = [D.tool("r1t0", "read", after: ["r1"], input: { "path" => "src/a.txt" }),
             D.tool("r2t0", "read", after: ["r2"], input: { "path" => "src/b.txt" }),
             D.tool("check-1", "bash", after: ["r3"], input: { "command" => "sh check.sh" }),
             D.tool("work-2t0", "read", after: ["work-2"], input: { "path" => "src/a.txt" })]
    trace = D.trace(graph, tasks, W.compaction_events("kernel", trigger: "wall", task_key: "r3"))
    assert_equal %w[r1 r2 r3 work-2 r4], P.mainline_keys(trace), "k1 is the kernel's branch; work-2 is the mainline's"
    assert_equal "r3", P.compacted_round(trace)
    assert_equal 3, P.induced_rounds(trace, minimum_after: 0), "r3, work-2, r4"
    assert_equal 1.0, P.reread_rate(trace), "the one read after the wall, under work-2, is of a path read before it"
    assert_equal({ "compactions" => { "kernel/wall" => 1 }, "reread_rate" => 1.0, "induced_rounds" => 1, "summary_bytes" => 0,
                   "summary_keys" => [] }, P.compaction_columns(trace, minimum_after: 2))
  end

  # THE HARNESS'S OWN STOP IS NEVER A ROUND THAT DID NOT COMPLETE: a wall run the cost stop canceled
  # carries `creator_requested` on its canceled rounds; `every_round_completed` reads past them (and
  # names any other), and the columns answer on a loop whose repaired round is off the row — no
  # completed tail — without raising.
  def test_the_harness_stop_is_not_a_round_that_did_not_complete_and_the_columns_answer_on_a_stopped_loop
    # The rows in the loop row's ORDER (the columns count by it): the
    # canceled r7 sits where the kernel left it, after r6.
    rows = W::WALL_TASKS + D.rounds_of(W::WALL_KERNEL_GRAPH).map do |row|
      row["key"] == "r7" ? D.round("r7", status: "canceled", error: { "key" => "creator_requested" }) : row
    end
    stopped = D.trace(W::WALL_KERNEL_GRAPH, rows, W.compaction_events("kernel", trigger: "wall", task_key: "r4"), status: "canceled")
    assert_equal true, P.every_round_completed(stopped)
    assert_equal({ "creator_requested" => 1 }, stopped.round_errors, "the stop stays a fact on the record")
    # THE STOP'S SECOND KEY: `AgentRuns::Stop` stamps `run_canceled` on a QUEUED round (the
    # continuation the cost stop found waiting — wall-long's r106) and `creator_requested` on the
    # running step; both are the harness's, neither a round that did not complete.
    assert_equal %w[creator_requested run_canceled], P::HARNESS_STOP
    queued = rows.map { |row| row["key"] == "r7" ? D.round("r7", status: "canceled", error: { "key" => "run_canceled" }) : row }
    queued_stopped = D.trace(W::WALL_KERNEL_GRAPH, queued, W.compaction_events("kernel", trigger: "wall", task_key: "r4"), status: "canceled")
    assert_equal true, P.every_round_completed(queued_stopped)
    assert_equal({ "run_canceled" => 1 }, queued_stopped.round_errors)
    assert_match(/rests "canceled"/, CORPUS.find("compaction-wall-long").expected.verdict(queued_stopped.with_facts("checks" => [])).reason)
    failed = D.trace(W::WALL_GRAPH, W::WALL_TASKS + [D.round("r7", status: "failed", error: { "key" => "provider_http_error" })], [])
    assert_equal "a round did not complete: r7(failed !provider_http_error)", P.every_round_completed(failed)
    assert_match(/rests "canceled"/, P.loop_completed(stopped), "the loop's status names the stop")
    wall = CORPUS.find("compaction-wall-kernel").expected.verdict(stopped)
    assert_match(/rests "canceled"/, wall.reason)
    refute_match(/did not complete/, wall.reason)
    # The repaired round is not on the loop row: no completed tail to rate.
    off_row = D.trace(W::WALL_GRAPH, W::WALL_TASKS, W.compaction_events("kernel", trigger: "wall", task_key: "r9"))
    assert_nil P.compacted_round(off_row)
    assert_nil P.reread_rate(off_row)
    assert_nil P.induced_rounds(off_row, minimum_after: 0)
    columns = P.compaction_columns(stopped, minimum_after: 0)
    assert_equal 4, columns.fetch("induced_rounds"), "r4 to r7, the canceled tail counted as rounds"
    assert_equal 0.0, columns.fetch("reread_rate")
  end

  # One item per pass is what each bash command DID to the queue (`QueuePass`): a move of two items
  # is two, and so is a read of two items' contents, though it takes none out
  # (`evals_queue_pass_test.rb` reads the v11 records).
  def test_one_item_per_pass_reads_each_bash_command
    assert_equal true, P.one_item_per_pass(D.trace(*W::QUEUE, []), "queue")
    two = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "mv queue/item-01.txt queue/item-02.txt done/" })], [])
    assert_match(/one bash call handles 2 items/, P.one_item_per_pass(two, "queue"))
    looked = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "cat queue/item-01.txt queue/item-02.txt" })], [])
    assert_match(/one bash call handles 2 items/, P.one_item_per_pass(looked, "queue"))
    assert_equal [0], P.queue_passes(looked, "queue").map(&:taken), "a look takes none out"
    inside = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "mv item-01.txt ../done/", "workdir" => "queue" })], [])
    assert_equal [1], P.queue_passes(inside, "queue").map(&:taken), "the call's workdir is where its operands are read from"
    assert_match(/a shell loop over the queue/, P.one_item_per_pass(D.trace(*W::QUEUE_INFERENCE_REQUEST, []), "queue"))
    loop_elsewhere = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "for f in results/*.txt; do cat $f; done" })], [])
    assert_equal true, P.one_item_per_pass(loop_elsewhere, "queue"), "a loop that is not over the queue is allowed"
    assert_equal [1, 1, 1], P.queue_passes(D.trace(*W::QUEUE, []), "queue").map(&:taken)
    assert_equal({ "door" => nil, "rounds" => 5, "receipts" => 0, "task_calls" => 0, "bash_calls" => 3 },
      P.loop_style(D.trace(*W::QUEUE, [])))
  end

  def test_the_task_branch_must_complete_under_the_call
    trace = W.staged_arms([W::RACE_JOIN])
    assert_equal true, P.branch_completed(trace, "r1t0"), "a race cancels its losers"
    assert_match(/no task was placed under r1t0/, P.branch_completed(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []), "r1t0"))
    refused = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "code", after: ["r1"], status: "failed").merge("error" => { "key" => "execution_failed" })], [])
    assert_equal 'the task call r1t0 failed: "execution_failed"', P.branch_completed(refused, "r1t0")
  end

  # THE ARMS A RACE LET RUN ON, per arm: a race that stopped its losers reads 0, one whose losers a
  # reader kept alive reads each loser that completed, and a plan with no race reads nil.
  def test_losers_completed_counts_the_arms_a_race_let_run_on
    trace = W.staged_arms([W::RACE_JOIN])
    assert_equal 0, P.losers_completed(trace)
    nodes = trace.graph["nodes"].map { |node| node.merge("status" => "completed") }
    completed = trace.with(graph: trace.graph.merge("nodes" => nodes))
    assert_equal 2, P.losers_completed(completed)
    nodes = nodes.map { |node| node["key"] == W::RACE_JOIN ? node.merge("join" => { "until" => 2 }) : node }
    assert_equal 1, P.losers_completed(completed.with(graph: trace.graph.merge("nodes" => nodes)))
    assert_nil P.losers_completed(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []))
  end

  C = E2E::Evals::TaskReads

  def owed(owed, roots: owed, positional: []) = { "owed" => owed, "roots" => roots, "positional" => positional }

  def test_an_authored_step_is_owed_what_it_names_a_race_as_its_selection
    assert_equal({ "r1t0-model-1" => owed(%w[r1t0-script-2]) }, C.owed(W.staged_arms([W::RACE_JOIN])),
      "the race's winning wrap, never a loser's")
    assert_equal({ "r1t0-model-1" => owed([]) }, C.owed(W.staged_arms([])), "naming nothing, it is owed nothing")
    assert_equal({ "r1t0-model-1" => owed(%w[r1t0-script-3 r1t0-script-2]) },
      C.owed(W.staged_arms(%w[r1t0-script-3 r1t0-script-2])), "each name as itself, in the order named")
    assert_equal({ "r1t0-model-1" => owed(["r1t0-script-1", W::RACE_JOIN]) }, C.owed(W.failed_quorum([W::RACE_JOIN])),
      "a failed race hands on its partial winner, then itself")
    assert_equal({ "r1t0-model-1" => owed([W::STAGE_PLACED[4]]) }, C.owed(W.stage_placed([W::RACE_JOIN])),
      "a race over stage-placed wraps selects the wrap the stage placed")
    assert_nil C.owed(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, [])), "no independently placed model task"
  end

  # A RACE'S SELECTION IN FINISH ORDER, as the kernel hands it over: a quorum whose winners finished
  # out of placement order is owed the first finisher first, and a request in that order is no
  # kernel finding.
  def test_a_quorums_winners_are_owed_in_the_order_they_finished
    trace = W.quorum_out_of_order([W::RACE_JOIN])
    assert_equal({ "r1t0-model-1" => owed(%w[r1t0-tool-3 r1t0-tool-1]) }, C.owed(trace))
    request = { "tasks" => %w[r1t0-tool-3 r1t0-tool-1], "assistant" => 0 }
    assert_equal true, C.check(C.owed(trace), "r1t0-model-1" => request)
  end

  # A MODEL THAT USED TOOLS IS NAMED BY ITS FINAL ROUND, AND ITS ENVELOPE BY ITS STEP: the member's
  # own round continues it and is no authored step; the later step is owed the round, and an
  # envelope naming the step it roots at matches.
  def test_a_named_model_that_used_tools_is_owed_as_its_final_round_and_matched_by_its_step
    trace = W.continued_member
    assert_equal({ "r1t0-model-1" => owed([]), "r1t0-model-2" => owed(%w[r3], roots: %w[r1t0-model-1]) }, C.owed(trace))
    request = { "tasks" => %w[r1t0-model-1], "assistant" => 0 }
    assert_equal true, C.check(C.owed(trace), "r1t0-model-2" => request)
  end

  # THE CHECK: each read request against what its step is owed — true when every one carried exactly
  # that; a request whose envelopes are out of order, one short, or beside an assistant entry is a
  # kernel finding in words; a step the kernel handed anything by position is one before any request
  # is read; nil when no request was read.
  def test_the_kernel_check_reads_each_request_against_what_its_step_is_owed
    owed = C.owed(W.staged_arms(%w[r1t0-script-3 r1t0-script-2]))
    fresh = { "tasks" => %w[r1t0-script-3 r1t0-script-2], "assistant" => 0 }
    assert_equal true, C.check(owed, "r1t0-model-1" => fresh)
    assert_equal 'r1t0-model-1 was delivered ["r1t0-script-2", "r1t0-script-3"] where it is owed ["r1t0-script-3", "r1t0-script-2"]',
      C.check(owed, "r1t0-model-1" => fresh.merge("tasks" => %w[r1t0-script-2 r1t0-script-3]))
    assert_match(/was delivered \["r1t0-script-3"\]/, C.check(owed, "r1t0-model-1" => fresh.merge("tasks" => %w[r1t0-script-3])))
    assert_equal "r1t0-model-1's request carries 1 assistant entry", C.check(owed, "r1t0-model-1" => fresh.merge("assistant" => 1))
    assert_nil C.check(owed, "r1t0-model-1" => nil), "a step that never sealed a request is not read"
    assert_nil C.check(owed, nil)
    handed = C.owed(W.continued_member(input_from: %w[r1t0-model-1]))
    assert_equal 'r1t0-model-2 reads ["r1t0-model-1"] by position', C.check(handed, nil), "a kernel finding with no request read"
  end

  # EVERY RECORD CARRIES THE CHECK: the structure facts hold what each authored step is owed and the
  # check against the requests the trace read beside it.
  def test_every_record_carries_the_kernel_check
    trace = W.staged_arms([W::RACE_JOIN]).with_facts("task_requests" => { "r1t0-model-1" => { "tasks" => %w[r1t0-script-2], "assistant" => 0 } })
    assert_equal C.owed(trace), trace.structure_facts.fetch("task_reads")
    assert_equal true, trace.structure_facts.fetch("kernel_check")
    assert_nil W.staged_arms([W::RACE_JOIN]).structure_facts.fetch("kernel_check"), "no request read"
  end


  def test_a_node_a_stage_placed_counts_toward_the_branch
    failed = "01a0cb72-9bb9-7c33-bcbb-fcb72aed97ff"
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
       D.n("r1t0-script-1", "tool_task", expansion_parent: "r1t0"),
       D.n(failed, "tool_task", status: "failed", error_key: "tool_execution_error", expansion_parent: "r1t0-script-1"),
       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
      [%w[r1 r1t0], %w[r1t0 r1t0-script-1], ["r1t0-script-1", failed], %w[r1t0 r2]]
    )
    trace = D.trace(graph, [D.tool("r1t0", "code", after: ["r1"], input: { "code" => "return 1;" })], [])
    assert_equal "#{failed}(failed) did not complete under r1t0", P.branch_completed(trace, "r1t0")
    assert_equal ["r1t0-script-1", failed], trace.under("r1t0").map { |node| node["key"] }
  end



  def test_delegated_nothing_names_the_graph_verbs_it_saw
    assert_equal true, P.delegated_nothing(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []))
    assert_match(/over-reach: r1t0:delegate_task, r1t1:delegate_task/, P.delegated_nothing(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [])))
    assert_equal true, P.loop_completed(D.trace(W::LINEAR_GRAPH, [], []))
    assert_match(/rests "needs_attention"/, P.loop_completed(D.trace(W::LINEAR_GRAPH, [], [], status: "needs_attention")))
  end

  def test_the_declared_names_follow_the_style_fact
    nexus = P.declared_names(D.trace(W::LINEAR_GRAPH, [], []))
    assert_includes nexus, "bash"
    assert_includes nexus, "grep"
    assert_includes nexus, "code"
    refute_includes nexus, "probe_host"
    claude = P.declared_names(D.trace(W::LINEAR_GRAPH, [], [], facts: { "style" => "claude" }))
    assert_includes claude, "Agent"
    refute_includes claude, "task"
  end
end
