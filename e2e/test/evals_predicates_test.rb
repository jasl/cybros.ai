require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

# THE READS THE FAMILIES SHARE, proved on paper (`E2E::Evals::Predicates`):
# the workflow door and the receipt loop, the task family's background
# rule and `per_file`, the compaction columns (re-read rate, induced
# rounds, summary bytes, pointers never values), the one-item rule, the
# compose branch's completion. Pure Ruby: nothing here boots.
class EvalsPredicatesTest < Minitest::Test
  include EvalsFixtureBench
  P = E2E::Evals::Predicates
  D = E2E::Evals::Drawing
  W = EvalsDrawings
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)

  def test_the_door_is_a_compose_branch_or_a_fan_of_two_task_calls_in_one_round
    assert_equal "compose", P.door(W.compose_trace(W::SCRIPTS["O1"]))
    assert_equal "task_fan", P.door(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, []))
    assert_nil P.door(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []))
    one_per_round = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "task", after: ["r1"]), D.tool("r2t0", "task", after: ["r2"])], [])
    assert_nil P.door(one_per_round), "two task calls in different rounds are not a fan"
    assert_match(/no compose call and no round fanned two task calls: \{"task" => 2\}/, P.reached_a_door(one_per_round))
  end

  # ── the door, read in vivo (`door_kind` beside `door`) ─────────────────
  # Five delegations, one per file, and a spine drawn from its rounds' calls (`EvalsDrawings.spine`).
  FIVE = %w[a b c d e].map { |f| ["task", { "prompt" => "Review lib/#{f}.rb for the uncalled method." }] }.freeze

  def spine(*rounds, answer: true) = W.spine(*rounds, answer: answer)

  def bash(command) = W.bash(command)

  def door_at(trace) = [P.door_kind(trace), P.door_read(trace)["round"], P.dispatch_round(trace), P.scout_then_door(trace)]

  # THE DOOR IS THE FIRST OF THE SPINE'S FIRST THREE ROUNDS THAT IS NOT A LOOK, kinded as the task
  # bench kinds a message (`TaskBench::Door`): a compose panel whose chair reads its three reviews,
  # a fan of five, one task beside a count. `door_read` carries the door's facts beside its round;
  # `dispatch_round` is the first spine round that handed work out and `door_calls` its rows.
  def test_the_door_kind_reads_the_first_round_that_is_not_a_look
    panel = W.compose_trace(W::SCRIPTS["O1"])
    assert_equal ["compose_steps", 1, 1, false], door_at(panel)
    assert_equal({ "round" => 1, "built" => true, "members" => 3, "unread" => ["model-4"], "beside" => [] }, P.door_read(panel))
    assert_equal [{ "tool" => "compose", "wait" => nil, "prompt_head" => W::SCRIPTS["O1"][0, 80] }], P.door_calls(panel)

    five = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [])
    assert_equal ["task_fan", 1, 1, false], door_at(five)
    assert_equal({ "round" => 1, "built" => nil, "members" => 5, "unread" => [], "beside" => [] }, P.door_read(five))
    assert_equal(%w[a b c d e].map { |f| { "tool" => "task", "wait" => true, "prompt_head" => "Review lib/#{f}.rb for the uncalled method." } },
      P.door_calls(five))

    mail = D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS)
    assert_equal ["task_one", 1, 1, false], door_at(mail)
    assert_equal ["bash"], P.door_read(mail)["beside"]
    assert_equal [{ "tool" => "task", "wait" => nil, "prompt_head" => "run ruby test/all.rb" },
                  { "tool" => "bash", "wait" => nil, "prompt_head" => "ls lib | wc -l" }], P.door_calls(mail)
    long = "Run the whole suite with bin/rails test and tell me which test fails, then fix nothing and report back to me."
    assert_equal [long[0, 80]], P.door_calls(spine([["task", { "prompt" => long }]])).map { |call| call["prompt_head"] }
  end

  # A LOOK FIRST, THEN THE DOOR: a round of reads — two quiet shell reads, or a `;`-joined chain of
  # them — is a look and the fan after it the door at round 2. An opening the narrow look rule reads
  # as a door (`echo` is no look) is the door at round 1, `plain`; the dispatch round stays the
  # fan's, and a read-class call before it makes it a scout then a door.
  def test_a_look_then_a_fan_is_the_door_at_round_two_and_the_dispatch_round_is_the_fans
    looked = spine([bash("ls lib"), bash("cat lib/a.rb 2>/dev/null")], FIVE)
    assert_equal ["task_fan", 2, 2, true], door_at(looked)
    assert_equal 5, P.door_read(looked)["members"]
    assert_equal ["task_fan", 2, 2, true], door_at(spine([bash("cat lib/a.rb; ls -R lib; pwd")], FIVE))

    echoed = spine([bash("ls -la; echo ---; ls bin")], FIVE)
    assert_equal ["plain", 1, 2, true], door_at(echoed)
    assert_equal({ "round" => 1, "built" => nil, "members" => 0, "unread" => [], "beside" => ["bash"] }, P.door_read(echoed))
    assert_equal ["task"] * 5, P.door_calls(echoed).map { |call| call["tool"] }, "the dispatch round's rows, not the door round's"
    refute P.scout_then_door(spine([["write", { "path" => "notes.md" }]], FIVE)), "a write before the fan is no read"
    assert P.scout_then_door(spine([["glob", { "pattern" => "lib/*.rb" }]], FIVE))
  end

  # THREE LOOKS ARE A SCOUT: no door round, no dispatch; fewer rounds than three, all looks, are a
  # scout too, and a spine with no round at all is `none`. A shell command that is no read is the
  # door where it stands.
  def test_three_looks_are_a_scout_and_a_command_that_is_no_read_is_a_plain_door
    scout = spine([["ls", { "path" => "." }]], [["read", { "path" => "lib/a.rb" }]], [["grep", { "pattern" => "def call" }]])
    assert_equal ["scout", nil, nil, false], door_at(scout)
    assert_equal({ "round" => nil, "built" => nil, "members" => 0, "unread" => [], "beside" => [] }, P.door_read(scout))
    assert_empty P.door_calls(scout)
    assert_equal ["scout", nil, nil, false], door_at(spine([["read", { "path" => "lib/a.rb" }]], answer: false))
    assert_equal ["none", nil, nil, false], door_at(E2E::Evals::Trace.empty)
    assert_equal ["none", 2, nil, false], door_at(spine([["read", { "path" => "lib/a.rb" }]])), "the round that answered is the door"
    assert_equal ["plain", 1, nil, false], door_at(spine([bash("sleep 1 && rm x")]))
  end

  # THE ROUND'S OWN DECLARED SET kinds its compose: the sealed request's entries when the sealed
  # round is the door round, the style's set otherwise; `declared:` names a set outright.
  def test_the_door_kinds_a_compose_under_the_set_its_round_declared
    trace = W.compose_trace(W::SCRIPTS["O2"])
    only_compose = E2E::TaskBench::DeclaredSet.function_definitions.select { |entry| entry.dig("function", "name") == "compose" }
    sealed = { "task_key" => "r1", "entries" => [], "request_options" => { "tools" => only_compose } }
    assert_equal "compose_refused", P.door_kind(trace.with(sealed: sealed)), "grep is not among the names r1 declared"
    assert_equal false, P.door_read(trace.with(sealed: sealed))["built"]
    built = P.door_kind(trace)
    refute_equal "compose_refused", built
    assert_equal built, P.door_kind(trace.with(sealed: sealed.merge("task_key" => "r2"))), "another round's set never kinds r1"
    assert_equal "compose_refused", P.door_kind(trace, declared: only_compose)
  end

  # `door` IS UNCHANGED BESIDE IT: a compose branch or a fan of two tasks in one round, else nil.
  def test_the_door_is_unchanged_beside_the_door_kind
    assert_equal "compose", P.door(W.compose_trace(W::SCRIPTS["O1"]))
    assert_equal "task_fan", P.door(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, []))
    assert_nil P.door(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS))
    assert_equal "task_fan", P.door(spine([bash("ls lib"), bash("cat lib/a.rb 2>/dev/null")], FIVE))
    assert_equal "task_fan", P.door(spine([bash("ls -la; echo ---; ls bin")], FIVE))
    assert_nil P.door(spine([["ls", { "path" => "." }]], [["read", { "path" => "lib/a.rb" }]], [["grep", { "pattern" => "def call" }]]))
    assert_nil P.door(spine([bash("sleep 1 && rm x")]))
  end

  # ── the plain concurrent fan (barrier-free's reach beside the door) ─────
  # THE BACKGROUND JOBS A COMMAND RUNS A PROGRAM IN, read on the shapes the v13–v15 barrier-free runs
  # wrote (SCRATCH traces, `e2e/artifacts/evals/2026-09-2*-v1[345]-workflow`): a job is the list a
  # lone `&` ends — its pipeline, the `&&` chain around it, the `( … )` or `{ …; }` group holding it —
  # counted once per word of each `for` loop around it. A chain run in the background is ONE job; a
  # loop whose body ends on `;` runs its fetches in turn, backgrounded or not; a redirect onto a file
  # descriptor (`2>&1`) backgrounds nothing; a comment, a quoted string and a read run nothing.
  FAN_JOBS = {
    %(set -e\n# one pipeline per source, all in parallel: sh bin/fetch x &\nfor s in a b c; do\n  ( sh bin/fetch "$s" | awk -F'|' '{printf "source=%s", $1}' > "rec_$s.txt" ) &\ndone\nwait) => 3, # v13 deepseek-flash #1
    %(sh bin/fetch a | { IFS='|' read -r s d v; printf '%s\\n' "$s" > a.norm; } &\nsh bin/fetch b | { IFS='|' read -r s d v; printf '%s\\n' "$s" > b.norm; } &\nwait) => 2, # v13 kimi-k3 #1
    %(( sh bin/fetch a | norm > out/a.rec ; echo "a at $(date +%S.%N)" >> out/t.log ) &\npa=$!\n( sh bin/fetch b | norm > out/b.rec ) &\nwait "$pa") => 2, # v14 deepseek-flash #1
    %(for s in a b c; do\n  (\n    raw=$(sh bin/fetch "$s") || exit 1\n    name=${raw%%|*}; echo "$name"\n  ) &\ndone\nwait) => 3, # v14 deepseek-flash #3
    %((\n  sh bin/fetch a > "$tmp/a.raw" && awk -F'|' '{print $1}' "$tmp/a.raw" > "$tmp/a.norm"\n) & pa=$!\n(\n  sh bin/fetch b > b.raw\n) & pb=$!\nwait "$pa" && wait "$pb") => 2, # v15 luna #3
    %(sh bin/fetch a > a.raw 2>&1 & pa=$!\n./bin/fetch b &> b.raw & pb=$!\nwait) => 2,
    "sh bin/fetch a && sh bin/fetch b & wait" => 1,
    %(for s in a b c; do sh bin/fetch "$s" | norm; done & wait) => 0,
    %(for s in a b c; do sh bin/fetch "$s" | norm; done) => 0,
    "sh bin/fetch a > a.raw 2>&1; bin/fetch b 2>&1" => 0,
    %(echo "sh bin/fetch a & sh bin/fetch b &"; cat bin/fetch & wait) => 0,
    # A loop whose word count the text holds counts its words (a brace's alternatives each); one it
    # does not — a substitution, a parameter, a glob, a range, a `while`/`until`, a C-style `for` —
    # counts at least two.
    %(for s in {a,b,c}; do sh bin/fetch "$s" > "$s.raw" & done; wait) => 3,
    %(for s in $(echo a b c); do sh bin/fetch "$s" > "$s.raw" & done; wait) => 2,
    %(printf 'a\\nb\\nc\\n' | while read s; do sh bin/fetch "$s" > "$s.raw" & done; wait) => 2,
    %(for ((i = 0; i < 3; i++)); do sh bin/fetch "$i" & done; wait) => 2,
    %(for s in "{a,b}"; do sh bin/fetch "$s" & done; wait) => 1,
  }.freeze

  def test_the_concurrent_fan_counts_the_background_jobs_that_run_the_program
    fan = E2E::Evals::ConcurrentFan
    FAN_JOBS.each { |command, jobs| assert_equal jobs, fan.background_jobs(command, "bin/fetch"), command }
    assert_equal 2, fan.runs("sh bin/fetch a > a.raw 2>&1; bin/fetch b 2>&1", "bin/fetch")
    assert_equal 1, fan.runs(%(x=$(sh bin/fetch a); echo "$x"), "bin/fetch"), "a run inside a substitution"
    assert_equal 0, fan.runs("cat bin/fetch 2>/dev/null; ls bin 2>/dev/null", "bin/fetch")
    assert_equal 0, fan.runs("sh bin/fetcher a", "bin/fetch")
    assert fan.waits?(%(sh bin/fetch a & pa=$!\nwait "$pa"))
    refute fan.waits?(%(sh bin/fetch a & echo "then wait")), "a quoted wait waits for nothing"
    assert fan.concurrent?("sh bin/fetch a & sh bin/fetch b & wait", "bin/fetch")
    refute fan.concurrent?("sh bin/fetch a & sh bin/fetch b &", "bin/fetch"), "no wait"
    refute fan.concurrent?("sh bin/fetch a & wait", "bin/fetch"), "one job"
    assert fan.concurrent?(%(for s in {a,b,c}; do sh bin/fetch "$s" & done; wait), "bin/fetch")
    assert fan.concurrent?(%(ls | while read s; do sh bin/fetch "$s" & done; wait), "bin/fetch")
    # A wait between the jobs runs them in turn: each is waited on before the next starts.
    refute fan.concurrent?(%(for s in a b c; do sh bin/fetch "$s" & wait; done), "bin/fetch"), "a wait inside the loop's body"
    refute fan.concurrent?("sh bin/fetch a & wait; sh bin/fetch b & wait", "bin/fetch"), "a wait between the two jobs"
    refute fan.concurrent?("wait; sh bin/fetch a & sh bin/fetch b &", "bin/fetch"), "the only wait comes before the jobs"
    assert fan.concurrent?(%((sh bin/fetch a) & pa=$!\n(sh bin/fetch b) & pb=$!\nwait "$pa" && wait "$pb"), "bin/fetch")
  end

  # THE FAN'S ROUND: the first spine round holding two `bash` rows or more that each run the program,
  # or one row that runs it concurrently; rows split across rounds are a sequence, and a program the
  # rows name without running it is no fan.
  def test_the_concurrent_fan_round_is_the_spines_first_fanned_round
    fetch = ->(source) { bash("sh bin/fetch #{source} > raw.#{source}") }
    assert_equal 2, P.concurrent_fan_round(spine([bash("ls bin")], [fetch.("a"), fetch.("b")]), "bin/fetch")
    assert_equal 1, P.concurrent_fan_round(spine([bash("sh bin/fetch a & sh bin/fetch b & wait")]), "bin/fetch")
    assert_nil P.concurrent_fan_round(spine([fetch.("a")], [fetch.("b")], [fetch.("c")]), "bin/fetch"), "one fetch a round"
    assert_nil P.concurrent_fan_round(spine([fetch.("a"), bash("cat bin/fetch")]), "bin/fetch"), "one run beside a read"
    assert_nil P.concurrent_fan_round(E2E::Evals::Trace.empty, "bin/fetch")
  end

  def test_the_receipt_loop_wants_a_receipt_and_every_loop_completed
    assert_equal true, P.receipt_loop(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, W::MAIL_EVENTS))
    assert_match(/no input_accepted/, P.receipt_loop(D.trace(W::MAIL_GRAPH, W::MAIL_TASKS, [])))
    stuck = W::MAIL_EVENTS.reject { |e| e["payload"]["agent_loop_public_id"] == "loop-2" && e["payload"]["loop_status"] == "completed" }
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
    waited = (0..11).map { |i| D.tool("r1t#{i}", "task", after: ["r1"], input: { "prompt" => "Refute claim C#{i}.", "wait" => true }) }
    assert_equal "no input_accepted{origin: task_result}: every task call waited (wait: true on 12 of 12), so no receipt was owed " \
                 "and the receipt-wake loop never ran ({\"task\" => 12})", P.receipt_loop(D.trace(graph, waited, []))
    detached = waited.each_with_index.map { |row, i| i.zero? ? row.merge("tool_input" => row["tool_input"].merge("wait" => false)) : row }
    assert_equal "no input_accepted{origin: task_result}: the kernel mailed no receipt for 1 detached task call(s) ({\"task\" => 12})",
      P.receipt_loop(D.trace(graph, detached, []))
  end

  # A PICTURE OVER A PLAN THAT DID NO WORK names why: a stage whose own source does not parse in
  # usable generation's own sentence, a script that places no step in the kernel's refusal of it —
  # never the picture's `missing_steps` over an empty graph. Read only once the picture missed, so
  # no green moves: an exact plan beside a stage that does not parse (canceled, it never ran) is
  # the picture still, and one beside a stage that failed reads its branch as it always did.
  def test_a_picture_over_a_failed_or_empty_plan_names_the_stage_not_the_missing_steps
    strong = { "tier" => E2E::Evals::Bench::STRONG }
    call = ->(script, nodes) do
      graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), *nodes,
                       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
        [%w[r1 r1t0], %w[r1t0 r2], *nodes.map { |node| ["r1t0", node["key"]] }])
      D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => script })], [], facts: strong)
    end
    unparsed = call.('g.script({ script: "return (;" });',
      [D.n("r1t0-script-1", "script_task", status: "failed", error_key: "script_syntax_error", expansion_parent: "r1t0")])
    assert_match(/\Astage script-1 of r1t0 does not parse: SyntaxError/, P.compose_picture(unparsed, "O2"))
    assert_equal "the script was refused script_error: #{Nexus::Compose::Evaluator::NO_STEP}",
      P.compose_picture(call.("const files = [];", []), "O2")

    beside = "#{W::SCRIPTS["O1"]}g.script({ script: \"return (;\" });\n"
    exact = W.compose_trace(beside, graph: D.composed(beside, status: { "script-1" => "canceled" }), facts: strong)
    assert_match(/does not parse/, E2E::Evals::Usable.call(exact, exact.compose_rows.first, tool_names: P.declared_names(exact)))
    assert_equal true, P.compose_picture(exact, "O1"), "an exact picture never reads usable's sentence"
    failed = W.compose_trace(beside, graph: D.composed(beside, status: { "script-1" => "failed" }), facts: strong)
    assert_equal "r1t0-script-1(failed) did not complete under r1t0", P.compose_picture(failed, "O1")
  end

  # THE RECORDED-ONLY RENDEZVOUS ON BOTH TIERS: its picture is a fact, never the bar. The strong tier
  # reads the script the kernel accepted and its branch completed; the floor reads usable generation
  # by a call of the run AND that call's branch completed — usable alone reads a failed model member
  # as a node that stands, and the rendezvous keeps its branch. Both bars run on every tier, so a
  # plan the harness cannot read raises into the lane whichever the tier picks.
  def test_rendezvous_reads_usable_generation_and_a_completed_branch_on_the_floor_and_the_accepted_script_on_the_strong_tier
    expected = CORPUS.find("compose-rendezvous").expected
    floor = { "tier" => E2E::Evals::Bench::FLOOR }
    strong = { "tier" => E2E::Evals::Bench::STRONG }
    repaired = W.repaired_trace(W::SCRIPTS["T5"])
    green = expected.verdict(repaired.with_facts(floor))
    assert_equal [true, true], [green.reached, green.succeeded], green.reason
    assert_equal 2, green.facts.fetch("usable_on_call")
    assert_match(/\Athe script was refused /, green.facts.fetch("picture"), "the picture rides as a fact on the floor")
    assert_match(/\Athe script was refused /, expected.verdict(repaired.with_facts(strong)).reason, "the strong tier reads the first call")

    stuck = D.composed(W::SCRIPTS["T5"], status: { "model-2" => "failed" })
    failed_member = W.compose_trace(W::SCRIPTS["T5"], graph: stuck, facts: floor)
    assert_equal true, P.compose_usable(failed_member), "a failed model member stands for usable generation"
    assert_equal "r1t0-model-2(failed) did not complete under r1t0", expected.verdict(failed_member).reason, "the branch still gates the floor"

    drifted = W.compose_trace("g.model({ prompt: ", graph: W::FAN_GRAPH)
    [floor, strong].each do |tier|
      assert_raises(E2E::ComposeBench::Executed::Drifted, tier.inspect) { expected.verdict(drifted.with_facts(tier)) }
    end
    # A stage-free plan that is not the script's stands for usable generation, so on the floor only
    # the accepted script's reading can raise — it runs there too.
    borrowed = W.compose_trace(W::SCRIPTS["T5"], graph: W::FAN_GRAPH).with_facts(floor)
    assert_equal true, P.compose_usable(borrowed), "usable reads the borrowed plan as standing"
    assert_raises(E2E::ComposeBench::Executed::Drifted, "the accepted reading's guard on the floor") { expected.verdict(borrowed) }
  end

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

  # THE COMPOSE DOOR OWES NO RECEIPT: a run whose only door is a compose branch — no `task` row — is
  # read by its branch completed under the call and every loop completed, never by the receipts (the
  # kernel mails `task_result` for a detached task alone); a compose beside `task` rows keeps the
  # receipt rule.
  def test_the_compose_door_owes_no_receipt_and_is_read_by_its_branch
    door = W.compose_trace(W::SCRIPTS["O1"])
    assert_equal 0, door.receipts
    assert_equal true, P.receipt_loop(door)
    assert_equal "compose", P.door(door)
    failed_member = D.composed(W::SCRIPTS["O1"], status: { "model-4" => "failed" })
    assert_equal "the compose door mails no task_result receipt, and r1t0-model-4(failed) did not complete under r1t0",
      P.receipt_loop(W.compose_trace(W::SCRIPTS["O1"], graph: failed_member))
    still_running = D.trace(W::FAN_GRAPH, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => W::SCRIPTS["O1"] })], [],
      loops: [{ "id" => "loop-1", "status" => "running" }])
    assert_equal "loop loop-1 never completed on the feed", P.receipt_loop(still_running)
    beside_tasks = D.trace(W::FAN_GRAPH, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "x" }),
                                          D.tool("r1t1", "task", after: ["r1"], input: { "prompt" => "y" })], [])
    assert_match(/no input_accepted/, P.receipt_loop(beside_tasks), "a task row beside the compose keeps the receipt rule")
    # The task's own predicate: green on the compose door, `waited` reading a `wait: true` on the
    # compose row too, the door on the record.
    expected = CORPUS.find("workflow-adversarial-verify").expected
    verdict = expected.verdict(door)
    assert_predicate verdict, :green?, verdict.reason
    assert_equal "compose", verdict.facts.fetch("door")
    assert_equal false, verdict.facts.fetch("waited")
    waited = W.compose_trace(W::SCRIPTS["O1"]).with(tasks: [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => W::SCRIPTS["O1"], "wait" => true })])
    assert_equal true, expected.verdict(waited).facts.fetch("waited"), "a compose called with wait: true is the waited shape"
    assert_equal true, expected.verdict(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [])).facts.fetch("waited"), "a task fan with wait: true still is"
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
    assert_match(/no round fanned two task calls: \{"task" => 2\}/,
      P.fan_completed(D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "task", after: ["r1"]), D.tool("r2t0", "task", after: ["r2"])], [])))
    assert_match(/no round fanned two task calls/, P.fan_completed(W.compose_trace(W::SCRIPTS["O1"])), "the compose door is the gallery's fan_join?")
  end

  def test_background_is_the_task_row_without_wait_true
    assert P.background?(D.tool("r1t0", "task", input: { "prompt" => "x" }))
    assert P.background?(D.tool("r1t0", "task", input: { "prompt" => "x", "wait" => false }))
    refute P.background?(D.tool("r1t0", "task", input: { "prompt" => "x", "wait" => true }))
    refute P.background?(D.tool("r1t0", "bash", input: { "command" => "x" }))
  end

  def test_per_file_counts_task_prompts_and_compose_scripts
    trace = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS + [D.tool("r2t0", "task", after: ["r2"], input: { "prompt" => "again lib/a.rb" })], [])
    assert_equal({ "a.rb" => 2, "b.rb" => 1, "e.rb" => 1 }, P.per_file(trace, %w[a.rb b.rb e.rb]))
    assert_equal 1, P.per_file(W.compose_trace(W::SCRIPTS["FINDERS"]), ["lib/mailer.rb"]).fetch("lib/mailer.rb")
    # PROMPTS, NOT MENTIONS (12a L2): a finder prompt that spells its file
    # twice — "Find … in lib/auth.rb … answer `lib/auth.rb — <token>`" —
    # is ONE finder; eight such prompts read as one per file, never two.
    twice = D.trace(W::FIVE_GRAPH, [D.tool("r1t0", "task", after: ["r1"],
      input: { "prompt" => "Find the token in lib/a.rb and answer `lib/a.rb — <token>`." })], [])
    assert_equal({ "a.rb" => 1, "b.rb" => 0 }, P.per_file(twice, %w[a.rb b.rb]))
    assert_equal 0, P.graph_verbs_inside_branches(trace)
    branchy = D.trace(W::FIVE_GRAPH, W::FIVE_TASKS + [D.tool("r1t0-model-1-r3t0", "task", after: ["r1t0-model-1-r3"])], [])
    assert_equal 1, P.graph_verbs_inside_branches(branchy)
    # A delegate's own calls carry round keys (`r3t0`, `r6t0`) made by its root and by a round the
    # kernel marks `spine: false`: inside the branch all the same.
    delegated = D.trace(*W.delegated("task", [{ "prompt" => "a" }, { "prompt" => "b" }]), [])
    assert_equal 4, P.graph_verbs_inside_branches(delegated)
    assert_equal %w[r2t0 r2t1], delegated.spine_calls.map { |row| row["key"] }, "r1's fan is the spine's; nothing under it is"
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
  # the until extension authors `work-2` on the spine, the kernel's `k1`
  # hangs off it, and a reader that took the number out of a key raised
  # `undefined method '>=' for nil` — the columns count by the loop row's
  # order from the repaired round.
  def test_the_compaction_columns_count_by_order_when_a_spine_round_is_not_keyed_rN
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task"), D.n("r2t0", "tool_task"),
       D.n("k1", "model_task", spine: false), D.n("r3", "model_task"), D.n("check-1", "tool_task"),
       D.n("work-2", "model_task"), D.n("work-2t0", "tool_task"), D.n("r4", "model_task", deliverable: true)],
      [%w[r1 r1t0], %w[r1t0 r2], %w[r2 r2t0], %w[r2t0 r3], %w[k1 r3], %w[r3 check-1], %w[check-1 work-2], %w[work-2 work-2t0], %w[work-2t0 r4]]
    )
    tasks = [D.tool("r1t0", "read", after: ["r1"], input: { "path" => "src/a.txt" }),
             D.tool("r2t0", "read", after: ["r2"], input: { "path" => "src/b.txt" }),
             D.tool("check-1", "bash", after: ["r3"], input: { "command" => "sh check.sh" }),
             D.tool("work-2t0", "read", after: ["work-2"], input: { "path" => "src/a.txt" })]
    trace = D.trace(graph, tasks, W.compaction_events("kernel", trigger: "wall", task_key: "r3"))
    assert_equal %w[r1 r2 r3 work-2 r4], P.spine_keys(trace), "k1 is the kernel's branch; work-2 is the spine's"
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
    # THE STOP'S SECOND KEY: `AgentLoops::Stop` stamps `loop_canceled` on a QUEUED round (the
    # continuation the cost stop found waiting — wall-long's r106) and `creator_requested` on the
    # running step; both are the harness's, neither a round that did not complete.
    assert_equal %w[creator_requested loop_canceled], P::HARNESS_STOP
    queued = rows.map { |row| row["key"] == "r7" ? D.round("r7", status: "canceled", error: { "key" => "loop_canceled" }) : row }
    queued_stopped = D.trace(W::WALL_KERNEL_GRAPH, queued, W.compaction_events("kernel", trigger: "wall", task_key: "r4"), status: "canceled")
    assert_equal true, P.every_round_completed(queued_stopped)
    assert_equal({ "loop_canceled" => 1 }, queued_stopped.round_errors)
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
    assert_match(/a shell loop over the queue/, P.one_item_per_pass(D.trace(*W::QUEUE_ONE_SHOT, []), "queue"))
    loop_elsewhere = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "for f in results/*.txt; do cat $f; done" })], [])
    assert_equal true, P.one_item_per_pass(loop_elsewhere, "queue"), "a loop that is not over the queue is allowed"
    assert_equal [1, 1, 1], P.queue_passes(D.trace(*W::QUEUE, []), "queue").map(&:taken)
    assert_equal({ "door" => nil, "rounds" => 5, "receipts" => 0, "compose_calls" => 0, "task_calls" => 0, "bash_calls" => 3 },
      P.loop_style(D.trace(*W::QUEUE, [])))
  end

  def test_the_compose_branch_must_complete_under_the_call
    trace = W.compose_trace(W::SCRIPTS["O1"])
    assert_equal true, P.branch_completed(trace, "r1t0")
    assert_match(/nothing was composed under r1t0/, P.branch_completed(W.compose_trace(W::SCRIPTS["O1"], graph: W::LINEAR_GRAPH), "r1t0"))
    refused = D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "compose", after: ["r1"], status: "failed", input: { "script" => "x" }).merge("error" => { "key" => "script_error" })], [])
    assert_equal 'the compose call r1t0 failed: "script_error"', P.branch_completed(refused, "r1t0")
    canceled = D.composed(W::SCRIPTS["O3"], status: { "tool-1" => "canceled", "tool-3" => "canceled" })
    assert_equal true, P.branch_completed(W.compose_trace(W::SCRIPTS["O3"], graph: canceled), "r1t0"), "a race cancels its losers"
    assert_equal "no compose call to score", P.score_compose(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []), "O1")
    assert_match(/carries no script/, P.score_compose(W.compose_trace("", graph: W::REFUSED_GRAPH), "O1"))
  end

  # THE ARMS A RACE LET RUN ON, per arm: a race that stopped its losers reads 0, one whose losers a
  # reader kept alive reads each loser that completed, and a plan with no race reads nil.
  def test_losers_completed_counts_the_arms_a_race_let_run_on
    stopped = D.composed(W::SCRIPTS["O3"], status: { "tool-1" => "canceled", "tool-3" => "canceled" })
    assert_equal 0, P.losers_completed(W.compose_trace(W::SCRIPTS["O3"], graph: stopped))
    assert_equal 2, P.losers_completed(W.compose_trace(W::SCRIPTS["O3"])), "every probe completed: both losers ran on"
    assert_nil P.losers_completed(W.compose_trace(W::SCRIPTS["O1"])), "no race placed"
    quorum = <<~JS
      g.parallel([g.tool({ name: "bash" }), g.tool({ name: "bash" }), g.tool({ name: "bash" })], { until: 2 });
      g.model({ prompt: "Name the two that answered." });
    JS
    assert_equal 1, P.losers_completed(W.compose_trace(quorum)), "a quorum of two needed two of three"
  end

  # ── what a composed step is owed, and the kernel check (`ComposedReads`) ────
  # Every model step a compose call placed is owed the envelopes of what its `results:` named, a
  # race read as its selection — a completed race its winners, a failed one its partial winners
  # then itself, one that selected nothing its own row — once each and in order, and nothing by
  # position. `roots` names each owed tip by the step whose brief its envelope carries.
  C = E2E::Evals::ComposedReads

  def owed(owed, roots: owed, positional: []) = { "owed" => owed, "roots" => roots, "positional" => positional }

  def test_a_composed_step_is_owed_what_it_names_a_race_as_its_selection
    assert_equal({ "r1t0-model-1" => owed(%w[r1t0-script-2]) }, C.owed(W.staged_arms([W::RACE_JOIN])),
      "the race's winning wrap, never a loser's")
    assert_equal({ "r1t0-model-1" => owed([]) }, C.owed(W.staged_arms([])), "naming nothing, it is owed nothing")
    assert_equal({ "r1t0-model-1" => owed(%w[r1t0-script-3 r1t0-script-2]) },
      C.owed(W.staged_arms(%w[r1t0-script-3 r1t0-script-2])), "each name as itself, in the order named")
    assert_equal({ "r1t0-model-1" => owed(["r1t0-script-1", W::RACE_JOIN]) }, C.owed(W.failed_quorum([W::RACE_JOIN])),
      "a failed race hands on its partial winner, then itself")
    assert_equal({ "r1t0-model-1" => owed([W::STAGE_PLACED[4]]) }, C.owed(W.stage_placed([W::RACE_JOIN])),
      "a race over stage-placed wraps selects the wrap the stage placed")
    assert_nil C.owed(W.compose_trace(W::SCRIPTS["O1"]).with(tasks: [])), "no compose call placed a model step"
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
  # own round continues it and is no composed step; the later step is owed the round, and an
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

  # EVERY RECORD CARRIES THE CHECK: the structure facts hold what each composed step is owed and the
  # check against the requests the trace read beside it.
  def test_every_record_carries_the_kernel_check
    trace = W.staged_arms([W::RACE_JOIN]).with_facts("composed_requests" => { "r1t0-model-1" => { "tasks" => %w[r1t0-script-2], "assistant" => 0 } })
    assert_equal C.owed(trace), trace.structure_facts.fetch("composed_reads")
    assert_equal true, trace.structure_facts.fetch("kernel_check")
    assert_nil W.staged_arms([W::RACE_JOIN]).structure_facts.fetch("kernel_check"), "no request read"
  end

  # ── the explicit-read columns (`reads`) ────────────────────────────────
  # Per composed model step whether it named anything, the share that did, the stage-fed credit, what
  # came back to the caller per call, the calls a round made after reading an earlier call's results,
  # and the over-read split; every compose picture task records the fact as the predicate reads it.
  def test_the_reads_fact_names_each_steps_source_what_came_back_and_the_over_read_split
    o7b = W.compose_trace(W::SCRIPTS["O7b"])
    reads = P.reads(o7b, "O7b")
    assert_equal(%w[r1t0-model-1 r1t0-model-2 r1t0-model-3].to_h { |key| [key, "named"] }, reads["reads_source"])
    assert_equal({ "results_named_share" => 1.0, "stage_fed" => {}, "unread_delivered" => { "r1t0" => 0 },
                   "recomposed_after_receipt" => 0, "over_read_positional" => 0, "over_read_named" => false },
      reads.except("reads_source"))

    blind = P.reads(W.compose_trace(W::SCRIPTS["O1"].sub(", results: reviews", "")), "O1")
    assert_equal "none", blind["reads_source"].fetch("r1t0-model-4")
    assert_equal 0.0, blind["results_named_share"]

    # The waited continuation reads the report; a second call made by it after reading counts.
    graph = o7b.graph.merge("nodes" => o7b.graph["nodes"].map { |node| node["key"] == "r2" ? node.merge("input_from" => %w[r1 r1t0-model-3]) : node })
    second = D.tool("r2t0", "compose", after: ["r2"], input: { "script" => W::SCRIPTS["O1"] })
    again = o7b.with(graph: graph, tasks: o7b.tasks + [second])
    assert_equal({ "r1t0" => 1, "r2t0" => 0 }, P.reads(again, "O7b")["unread_delivered"])
    assert_equal 1, P.reads(again, "O7b")["recomposed_after_receipt"]
    mailed = o7b.with(events: [D.event("input_accepted", { "origin" => "task_result", "task_key" => "r1t0-model-3" })])
    assert_equal({ "r1t0" => 1 }, P.reads(mailed, "O7b")["unread_delivered"], "a receipt naming a placed step came back")

    assert_nil P.reads(W.staged_arms([W::RACE_JOIN]).with(tasks: []), "O3"), "no compose call, no fact"
    %w[compose-background-suite compose-grep-then-edit compose-race compose-rendezvous compose-review-angles
       compose-three-stage-pairing compose-two-source-fan-in workflow-barrier-free-pipeline].each do |name|
      assert CORPUS.find(name).expected.facts.key?("reads"), name
    end
    column = CORPUS.find("compose-two-source-fan-in").expected.facts.fetch("reads")
    assert_equal reads, E2E::Evals::Expected.column(column, o7b)
  end

  # A STAGE'S PLACEMENTS ARE THE CALL'S BRANCH: a node a `g.script` stage placed carries a UUIDv7
  # key, never the call's prefix, and the kernel marks the stage as what placed it — a failed one is
  # a branch that did not complete, where the prefix read it as complete.
  def test_a_node_a_stage_placed_counts_toward_the_branch
    failed = "01a0cb72-9bb9-7c33-bcbb-fcb72aed97ff"
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
       D.n("r1t0-script-1", "script_task", expansion_parent: "r1t0"),
       D.n(failed, "script_task", status: "failed", error_key: "script_error", expansion_parent: "r1t0-script-1"),
       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
      [%w[r1 r1t0], %w[r1t0 r1t0-script-1], ["r1t0-script-1", failed], %w[r1t0 r2]]
    )
    trace = D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.script({ script: \"return 1;\" });" })], [])
    assert_equal "#{failed}(failed) did not complete under r1t0", P.branch_completed(trace, "r1t0")
    assert_equal ["r1t0-script-1", failed], trace.under("r1t0").map { |node| node["key"] }
  end

  # THE COMPOSE SCORE READS THE PLAN THE KERNEL PLACED where the trace holds one: a race a stage
  # placed — its probes, its join and the model naming the winner, all keyed UUIDv7 under the stage
  # — is O3 exactly, though the script's text is one stage. The static reading rides beside it and
  # is still the only word on whether the script built. A drawing with no ownership mark holds no
  # plan and reads statically.
  def test_the_compose_score_reads_the_plan_a_stage_placed
    score = P.score_compose(STAGED_RACE, "O3")
    assert_equal "executed", score["reading"]
    assert score["first_time_right"], score.inspect
    assert score["valid_first"]
    assert_equal %w[missing_join missing_steps], score.dig("static", "silent")
    assert_includes score["graph"]["nodes"], "script-1/model-1:model"
    assert_equal true, P.compose_picture(STAGED_RACE, "O3")
    unmarked = D.trace(D.graph(STAGED_RACE.graph["nodes"].map { |node| node.except("expansion_parent") }, STAGED_RACE.graph["edges"].map(&:values)),
      STAGED_RACE.tasks, [])
    assert_equal "static", P.score_compose(unmarked, "O3")["reading"]
    assert_match(/the picture is not the objective's/, P.compose_picture(unmarked, "O3"))
  end

  # A PLAN WITH NO STAGE THAT IS NOT THE SCRIPT'S LOWERING is the harness's own fault — its copy of
  # the kernel's lowering drifted — so the success predicate raises, and the lane files a raised
  # predicate as a lane bug; the score column records the error in its place.
  def test_a_stage_free_plan_that_is_not_the_scripts_raises
    borrowed = W.compose_trace(W::SCRIPTS["O2"], graph: W::FAN_GRAPH)
    assert_raises(E2E::ComposeBench::Executed::Drifted) { P.compose_picture(borrowed, "O2") }
    assert_raises(E2E::ComposeBench::Executed::Drifted, "the floor reads usable, and still runs the picture's guard") do
      P.compose_bar(borrowed.with_facts("tier" => E2E::Evals::Bench::FLOOR), "O2")
    end
    column = CORPUS.find("compose-grep-then-edit").expected.facts.fetch("score")
    assert_match(/\AE2E::ComposeBench::Executed::Drifted: a plan with no stage reads/, E2E::Evals::Expected.column(column, borrowed))
  end

  STAGE_KEYS = (1..5).map { |i| "01a0cb96-4f65-7736-abb8-eff8cb46a14#{i}" }.freeze
  STAGED_RACE = begin
    probes = STAGE_KEYS.first(3)
    join, winner = STAGE_KEYS.last(2)
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
       D.n("r1t0-script-1", "script_task", expansion_parent: "r1t0"),
       *probes.map { |key| D.n(key, "tool_task", expansion_parent: "r1t0-script-1") },
       D.n(join, "join_task", join: { "until" => "any", "losers" => "cancel" }, expansion_parent: "r1t0-script-1"),
       D.n(winner, "model_task", spine: false, expansion_parent: "r1t0-script-1", input_from: probes),
       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1", input_from: %w[r1 r1t0])],
      [%w[r1 r1t0], %w[r1t0 r1t0-script-1], *probes.flat_map { |key| [["r1t0-script-1", key], [key, join]] }, [join, winner],
       %w[r1t0 r2]]
    )
    script = <<~'JS'
      g.script({ script: `
        g.parallel([
          g.tool({ name: "bash", input: { command: "bin/probe alpha" } }),
          g.tool({ name: "bash", input: { command: "bin/probe bravo" } }),
          g.tool({ name: "bash", input: { command: "bin/probe charlie" } }),
        ], { until: "any" });
        g.model({ prompt: "Say which host won." });
      ` });
    JS
    D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => script })], [])
  end

  def test_composed_nothing_names_the_graph_verbs_it_saw
    assert_equal true, P.composed_nothing(D.trace(W::LINEAR_GRAPH, W::LINEAR_TASKS, []))
    assert_match(/over-reach: r1t0:task, r1t1:task/, P.composed_nothing(D.trace(W::FIVE_GRAPH, W::FIVE_TASKS, [])))
    assert_match(/\{"read" => 1\}/, P.compose_reached(D.trace(W::LINEAR_GRAPH, [D.tool("r1t0", "read", after: ["r1"])], [])))
    assert_equal true, P.loop_completed(D.trace(W::LINEAR_GRAPH, [], []))
    assert_match(/rests "needs_attention"/, P.loop_completed(D.trace(W::LINEAR_GRAPH, [], [], status: "needs_attention")))
  end

  # The declared set under a style is rho's own (the compose scorer's
  # `tool_names`): `bash` and `grep` are in it, the text bench's
  # `probe_host` is not, and `compose` is spelled by the kernel's name
  # under `nexus` and by its alias under `workflow`.
  def test_the_declared_names_follow_the_style_fact
    nexus = P.declared_names(D.trace(W::LINEAR_GRAPH, [], []))
    assert_includes nexus, "bash"
    assert_includes nexus, "grep"
    assert_includes nexus, "compose"
    refute_includes nexus, "probe_host"
    workflow = P.declared_names(D.trace(W::LINEAR_GRAPH, [], [], facts: { "style" => "workflow" }))
    assert_includes workflow, "Workflow"
    refute_includes workflow, "compose"
  end

  # THE COMPOSE SCORER'S SET IS THE CALLING ROUND'S: a sealed request of any OTHER round — a
  # member's continuation keyed `r5` carrying the member's narrowed set — never scores the script;
  # the style's set stands in for it, and the calling round's own sealed request is the set the
  # model saw.
  def test_declared_names_score_against_the_round_that_made_the_compose_call
    members = (2..5).map { |i| D.n("r#{i}", "model_task", spine: false) }
    graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task"), *members], [%w[r1 r1t0]])
    trace = D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.model({ prompt: \"x\" });" })], [],
      facts: { "style" => "nexus" })
    narrowed = { "task_key" => "r5", "entries" => [],
                 "request_options" => { "tools" => %w[edit grep read].map { |name| { "type" => "function", "function" => { "name" => name } } } } }
    assert_equal E2E::TaskBench::DeclaredSet.names(style: "nexus"), P.declared_names(trace.with(sealed: narrowed))
    refute_equal %w[edit grep read], P.declared_names(trace.with(sealed: narrowed))
    assert_equal %w[edit grep read], P.declared_names(trace.with(sealed: narrowed.merge("task_key" => "r1")))
    assert_includes P.declared_names(trace), "bash", "no sealed request: the style's set"
  end
end
