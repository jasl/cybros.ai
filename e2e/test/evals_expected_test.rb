require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

# EVERY TASK'S PREDICATE, PROVED ON PAPER BEFORE A PAID RUN (the gallery's two-sided rule): a green
# drawn trace in the task's own shape must be green on every dimension, and a wrong-shape trace must
# answer a String naming why — so a predicate that silently accepts everything, or reads a field the
# route does not serve, fails here and not after ten minutes of model time. The drawings are
# `E2E::Evals::Drawing`'s vocabulary: the route's node, edge, the joined task rows, the feed's items
# — one green and one red per task in `test/evals_drawings.rb`.
class EvalsExpectedTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)

  LINEAR_GRAPH = EvalsDrawings::LINEAR_GRAPH
  LINEAR_TASKS = EvalsDrawings::LINEAR_TASKS
  FAN_GRAPH = EvalsDrawings::FAN_GRAPH
  FAN_TASKS = [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.parallel([])" })].freeze

  # THE TWO-SIDED RULE: every task has a green and a red drawing
  # (`test/evals_drawings.rb`, one table per side).
  GREEN = EvalsDrawings::GREEN
  RED = EvalsDrawings::RED

  # NO REACH DIMENSION: an `Expected` drawn `reach: nil` answers nil on both predicate columns —
  # "not read" — with its conduct facts and columns read as ever; `success` is never consulted.
  def test_an_expected_with_no_reach_reads_neither_predicate_column
    unread = E2E::Evals::Expected.new(reach: nil, success: ->(_trace) { raise "never consulted" },
      conduct: { "quiet" => ->(trace) { trace.tasks.empty? || "a tool row" } }, facts: { "rows" => ->(trace) { trace.tasks.size } })
    verdict = unread.verdict(E2E::Evals::Trace.empty)
    assert_nil verdict.reached
    assert_nil verdict.succeeded
    assert_nil verdict.reason
    assert_equal({ "quiet" => true }, verdict.conduct_facts)
    assert_equal({ "rows" => 0 }, verdict.facts)
    refute_predicate verdict, :green?, "green needs a reach that was read"
    assert verdict.work_survived?(true), "the work survived by the verification's word"
    refute verdict.work_survived?(false)
    refute verdict.work_survived?(nil)
    read = E2E::Evals::Verdict.new(reached: true, succeeded: true, reason: nil, conduct: {})
    assert read.work_survived?(false), "a read success outranks the verification here"
    refute E2E::Evals::Verdict.new(reached: true, succeeded: false, reason: "x", conduct: {}).work_survived?(true)
  end

  def test_every_task_has_a_green_and_a_red_drawing
    assert_equal CORPUS.names.sort, GREEN.keys.sort, "every task has a hand-drawn green trace"
    assert_equal CORPUS.names.sort, RED.keys.sort, "every task has a wrong-shape trace"
  end

  def test_every_predicate_is_green_on_its_own_shape
    GREEN.each do |name, trace|
      verdict = CORPUS.find(name).expected.verdict(trace)
      assert verdict.reached, "#{name}: reach refused its own shape: #{verdict.reason}"
      assert_equal true, verdict.succeeded, "#{name}: success refused its own shape: #{verdict.reason}"
      assert_predicate verdict, :conduct_ok?, "#{name}: a conduct fact is red on its own shape: #{verdict.conduct_reasons.inspect}"
      assert_predicate verdict, :green?
      assert_nil verdict.reason
    end
  end

  # THE DOOR FACTS ride every door-family and control task beside `door` (`Predicates.door_kind`):
  # each answers a kind on the task's own green drawing — never a column's raised error — with its
  # round, the dispatch round and the dispatch round's calls. The scout's green drawing looks first
  # (its third column: a scout, then the door).
  DOOR_KINDS = {
    "workflow-adversarial-verify" => ["task_fan", 1], "workflow-judge-panel" => ["compose_steps", 1],
    "workflow-fan-out-finders" => ["compose_steps", 1], "workflow-barrier-free-pipeline" => ["compose_steps", 1],
    "workflow-loop-until-dry" => ["plain", nil], "workflow-scout-then-fan" => ["task_fan", 2, true],
    "task-fan-five" => ["task_fan", 1], "task-mail" => ["task_one", 1],
    "task-background-suite" => ["task_one", 1], "task-detached-receipt" => ["task_one", 1],
    "task-grep-three-control" => ["none", nil], "task-two-calls" => ["none", nil], "compose-single-read" => ["none", nil],
  }.freeze
  DOOR_COLUMNS = %w[door_kind door_read dispatch_round scout_then_door door_calls].freeze

  def test_the_door_facts_answer_a_kind_on_every_door_family_and_control_drawing
    assert_equal DOOR_COLUMNS, E2E::Evals::DOOR_FACTS.keys
    DOOR_KINDS.each do |name, (kind, dispatch, scouted)|
      facts = CORPUS.find(name).expected.verdict(GREEN.fetch(name)).facts
      assert_equal DOOR_COLUMNS, DOOR_COLUMNS & facts.keys, name
      assert_equal [kind, dispatch, scouted == true], facts.values_at("door_kind", "dispatch_round", "scout_then_door"), name
      assert_equal %w[round built members unread beside], facts.fetch("door_read").keys, name
      assert_equal dispatch.nil?, facts.fetch("door_calls").empty?, name
    end
    carried = CORPUS.names.select { |name| CORPUS.find(name).expected.facts.key?("door_kind") }
    assert_equal DOOR_KINDS.keys.sort, carried.sort, "the door facts ride the door family and its controls alone"
  end

  # BARRIER-FREE REACHES THE PLAIN CONCURRENT FAN (ruling 10's (b)): a round of `bash` rows each
  # running `bin/fetch`, or one row running it in the background twice or more with a `wait`, is a
  # reached door the pairing cannot be read on — success names the task door's sentence, `door_kind`
  # reads the round `plain`. A sequence is no fan — a `for` loop that runs one fetch after another —
  # and neither is a read of the script (`cat bin/fetch`).
  def test_barrier_free_reaches_the_plain_concurrent_fan_and_never_a_sequence
    task = CORPUS.find("workflow-barrier-free-pipeline").expected
    rows = task.verdict(EvalsDrawings.spine(%w[a b c].map { |source| EvalsDrawings.bash("sh bin/fetch #{source}") }))
    assert_equal [true, false], [rows.reached, rows.succeeded], rows.reason
    assert_match(/\Athe task door cannot pair a fetch with its own normaliser: /, rows.reason)
    assert_equal ["plain", ["bash"], nil], [rows.facts.fetch("door_kind"), rows.facts.dig("door_read", "beside"), rows.facts.fetch("dispatch_round")]
    assert_equal 1, rows.facts.fetch("fetch_fan_round")

    backgrounded = task.verdict(EvalsDrawings.spine([EvalsDrawings.bash("sh bin/fetch a | norm > a.txt & sh bin/fetch b | norm > b.txt & wait")]))
    assert_equal true, backgrounded.reached, backgrounded.reason
    assert_equal 1, backgrounded.facts.fetch("fetch_fan_round")

    looped = task.verdict(EvalsDrawings.spine([EvalsDrawings.bash(%(for s in a b c; do sh bin/fetch "$s" | norm; done))]))
    assert_equal false, looped.reached
    assert_match(/\Ano compose call, no round fanned two task calls and no concurrent fetch fan: \{"bash" => 1\}\z/, looped.reason)
    assert_nil looped.facts.fetch("fetch_fan_round")

    read = task.verdict(EvalsDrawings.spine([EvalsDrawings.bash("cat bin/fetch 2>/dev/null; ls bin 2>/dev/null")],
      [EvalsDrawings.bash("cat a.txt b.txt c.txt > merged.txt")]))
    assert_equal false, read.reached, "a read of bin/fetch runs nothing"
    assert_equal true, task.verdict(GREEN.fetch("workflow-barrier-free-pipeline")).reached, "a door is reached as before"
  end

  # THE D4 TASKS' REACH ADMITS NO COMPOSE (ruling 10's (c)): a job that went through compose — a
  # compose row in or before the round that handed it out — is unreached, its sentence naming the
  # kind; a compose AFTER the first `task` is `compose_after_task`, a fact, never reach. `d4_right`
  # is the door objective's rule over the dispatch round: one `task` there, in the background, whose
  # prompt names the suite, and no `start_process` or compose in or before that round.
  D4 = %w[task-mail task-background-suite task-detached-receipt].freeze
  ONE_STEP = 'g.tool({ name: "bash", input: { command: "ruby test/all.rb" } });'.freeze

  def test_the_d4_tasks_reach_no_job_that_went_through_compose
    count = EvalsDrawings.bash("ls lib | wc -l")
    D4.each do |name|
      task = CORPUS.find(name).expected
      composed = task.verdict(EvalsDrawings.spine([["compose", { "script" => ONE_STEP }], count]))
      assert_equal false, composed.reached, name
      assert_match(/\Athe job went through compose \(compose_one\): /, composed.reason, name)
      assert_equal [false, false], composed.facts.values_at("d4_right", "compose_after_task"), name
      beside = task.verdict(EvalsDrawings.spine([["task", { "prompt" => "run the suite: ruby test/all.rb" }], ["compose", { "script" => ONE_STEP }]]))
      assert_match(/\Athe job went through compose \(compose_one\): /, beside.reason, "#{name}: a compose beside the task is the job's door")
      green = task.verdict(GREEN.fetch(name))
      assert_predicate green, :green?, "#{name}: #{green.reason}"
      assert_equal [true, false], green.facts.values_at("d4_right", "compose_after_task"), name
    end

    mail = CORPUS.find("task-mail").expected
    late = mail.verdict(EvalsDrawings.spine([["task", { "prompt" => "run ruby test/all.rb" }], count], [EvalsDrawings.bash("ls")],
      [["compose", { "script" => ONE_STEP }]]))
    assert_equal true, late.reached, late.reason
    assert_equal [true, true], late.facts.values_at("compose_after_task", "d4_right"), "a compose after the door is conduct, not the door"
  end

  # D4 RIGHT IS THE DISPATCH ROUND'S DOOR: a waited task, two tasks, a task that does not name the
  # suite, a `start_process` beside it or in a round before it, each misses; no dispatch is no door.
  def test_d4_right_reads_the_dispatch_round
    suite = { "prompt" => "run ruby test/all.rb" }
    right = ->(*rounds) { CORPUS.find("task-mail").expected.verdict(EvalsDrawings.spine(*rounds)).facts.fetch("d4_right") }
    assert right.([["task", suite]])
    assert right.([EvalsDrawings.bash("ls lib | wc -l")], [["task", suite.merge("wait" => false)]]), "a count first, then the job"
    refute right.([["task", suite.merge("wait" => true)]]), "a waited task"
    refute right.([["task", suite], ["task", { "prompt" => "count lib/" }]]), "two tasks"
    refute right.([["task", { "prompt" => "count the files in lib/" }]]), "the task does not name the suite"
    refute right.([["task", suite], ["start_process", { "command" => "ruby test/all.rb" }]]), "a process beside the task"
    refute right.([["start_process", { "command" => "ruby test/all.rb" }]], [["task", suite]]), "a process before the task"
    refute right.([EvalsDrawings.bash("ruby test/all.rb")]), "the suite run in place: no dispatch"
    rails = ->(prompt) { CORPUS.find("task-background-suite").expected.verdict(EvalsDrawings.spine([["task", { "prompt" => prompt }]])).facts.fetch("d4_right") }
    assert rails.("Run bin/rails test and report"), "background-suite names its suite as its success does"
    refute rails.("Run bin/rubocop app")
  end

  # THE SCOUT FANS OVER WHAT IT LISTED (D6, `workflow-scout-then-fan`): a `lib/` name a spine
  # delegation's brief carries is GUESSED unless a read-class call of an earlier spine round returned
  # it — its text as the trace read joins it (`output`), by the file's own name, which `ls` and
  # `grep` print relative to the path they searched. A single task that discovers the files names
  # none; a compose that lists with `g.tool` and fans in a stage names none in its text; a fan over
  # a name the listing never returned is guessed whether or not the file exists (`names_not_on_disk`
  # beside), and so is a fan over on-disk names after a read that listed nothing.
  SCOUT = "workflow-scout-then-fan".freeze
  SCOUT_CALLERS = EvalsDrawings::SCOUT_CALLERS
  LISTED_THEN_STAGED = <<~JS.freeze
    const found = g.tool({ name: "grep", input: { pattern: "def call", path: "lib" } });
    g.script({ results: [found], script: "const files = results[0].output.split('\\\\n').filter((line) => line.length > 0); const reviews = files.map((file) => g.model({ prompt: 'Review ' + file + ': one line, your verdict.' })); g.parallel(reviews); return g.model({ prompt: 'Merge the reviews into one list.', results: reviews });" });
  JS

  def test_the_scout_fans_over_the_names_it_listed_and_never_over_guessed_ones
    task = CORPUS.find(SCOUT).expected
    green = task.verdict(GREEN.fetch(SCOUT))
    assert_predicate green, :green?, green.reason
    assert_equal [false, [], []], green.facts.values_at("fan_over_guessed_names", "names_guessed", "names_not_on_disk")
    assert_equal(SCOUT_CALLERS.to_h { |f| ["lib/#{f}.rb", 1] }, green.facts.fetch("per_file"))

    discovering = task.verdict(EvalsDrawings.spine([["task", { "prompt" => "Find every class under lib/ with a call method and review each." }]]))
    assert_predicate discovering, :green?, discovering.reason
    assert_equal ["task_one", false], discovering.facts.values_at("door_kind", "fan_over_guessed_names")

    staged = task.verdict(EvalsDrawings.compose_trace(LISTED_THEN_STAGED))
    assert_predicate staged, :green?, staged.reason
    assert_equal false, staged.facts.fetch("fan_over_guessed_names")

    zeta = task.verdict(EvalsDrawings.spine([EvalsDrawings::SCOUT_LS], EvalsDrawings.scout_reviews(SCOUT_CALLERS.first(4) + ["zeta"])))
    assert_equal [true, false], [zeta.reached, zeta.succeeded]
    assert_equal "fanned over guessed names: lib/zeta.rb", zeta.reason
    assert_equal [true, ["lib/zeta.rb"], ["lib/zeta.rb"]], zeta.facts.values_at("fan_over_guessed_names", "names_guessed", "names_not_on_disk")

    slug = ["read", { "path" => "lib/slug.rb" }, { "output" => "1\tmodule Slug\n2\t  module_function\n" }]
    unlisted = task.verdict(EvalsDrawings.spine([slug], EvalsDrawings.scout_reviews(SCOUT_CALLERS)))
    assert_equal "fanned over guessed names: #{SCOUT_CALLERS.map { |f| "lib/#{f}.rb" }.join(", ")}", unlisted.reason,
      "listed is what a listing returned, never what the model named"
    assert_empty unlisted.facts.fetch("names_not_on_disk"), "all five are on disk: a fact beside, never the rule"
  end

  # THE DISPATCH ROUND'S OWN DOOR, beside `door_kind`: a listing the look rule reads as a door (`ls
  # lib; echo ---; grep -l …`, a todo beside it) or three look rounds is still the scout before the
  # fan — `dispatch_door` kinds the round the work went out in and `dispatch_names` names the files its
  # briefs carry (one task handed the list names them all; a discovering one names none). A guess
  # whose round an earlier `task` preceded may be a listing the delegate returned, which the record
  # does not join: `guessed_after_a_delegate` names it for a hand read.
  def test_the_scout_records_the_dispatch_rounds_door_and_the_guesses_a_delegate_may_have_listed
    task = CORPUS.find(SCOUT).expected
    grep = EvalsDrawings::SCOUT_GREP.last.fetch("output")
    echoed = ["bash", { "command" => "ls lib; echo ---; grep -l 'def call' lib/*.rb" }, { "output" => grep }]
    plain = task.verdict(EvalsDrawings.spine([echoed], EvalsDrawings.scout_reviews(SCOUT_CALLERS)))
    assert_predicate plain, :green?, plain.reason
    assert_equal "plain", plain.facts.fetch("door_kind"), "the look rule reads the echoed listing as the door"
    assert_equal ["task_fan", 2, 5], plain.facts.fetch("dispatch_door").values_at("door_kind", "round", "members")
    assert_equal SCOUT_CALLERS.map { |f| "lib/#{f}.rb" }, plain.facts.fetch("dispatch_names")

    looks = [["ls", { "path" => "." }], EvalsDrawings::SCOUT_LS, EvalsDrawings::SCOUT_GREP]
    scouted = task.verdict(EvalsDrawings.spine(*looks.map { |call| [call] }, EvalsDrawings.scout_reviews(SCOUT_CALLERS)))
    assert_equal ["scout", "task_fan"], [scouted.facts.fetch("door_kind"), scouted.facts.dig("dispatch_door", "door_kind")]

    handed = task.verdict(EvalsDrawings.spine([EvalsDrawings::SCOUT_GREP],
      [["task", { "prompt" => "Review #{SCOUT_CALLERS.map { |f| "lib/#{f}.rb" }.join(", ")}: one line each." }]]))
    assert_equal ["task_one", 5], [handed.facts.dig("dispatch_door", "door_kind"), handed.facts.fetch("dispatch_names").size]
    discovering = task.verdict(EvalsDrawings.spine([["task", { "prompt" => "Find every class under lib/ with a call method and review each." }]]))
    assert_equal [], discovering.facts.fetch("dispatch_names")
    assert_nil task.verdict(EvalsDrawings.spine([EvalsDrawings::SCOUT_LS])).facts.fetch("dispatch_door"), "nothing went out"

    explore = ["task", { "prompt" => "List the files under lib/ that define a class with a call method." }]
    after = task.verdict(EvalsDrawings.spine([explore], EvalsDrawings.scout_reviews(SCOUT_CALLERS)))
    assert_equal SCOUT_CALLERS.map { |f| "lib/#{f}.rb" }, after.facts.fetch("guessed_after_a_delegate")
    assert_empty plain.facts.fetch("guessed_after_a_delegate")
  end

  # THE LISTING PRECEDES THE BRIEF THAT USES IT: a listing in the fan's own round briefs nothing (the
  # briefs were written in that turn); one in any EARLIER round does, the dispatch round's or a later
  # delegation's. A BRANCH'S OWN FAN is no spine brief: a discovering delegate that lists and fans on
  # its own names what it listed. REACH is a delegation; CONDUCT reads the spine's own `read` of
  # lib/ after the dispatch round — the spine reviewing what it handed out.
  def test_the_scout_reads_each_brief_against_the_listings_before_it
    task = CORPUS.find(SCOUT).expected
    beside = task.verdict(EvalsDrawings.spine([EvalsDrawings::SCOUT_LS, *EvalsDrawings.scout_reviews(SCOUT_CALLERS)]))
    assert_match(/\Afanned over guessed names: lib\/csv_out\.rb, /, beside.reason, "a listing beside the fan briefs nothing")

    discover = ["task", { "prompt" => "List which files under lib/ define a class with a call method.", "wait" => true }]
    later = task.verdict(EvalsDrawings.spine([discover], [EvalsDrawings::SCOUT_GREP], EvalsDrawings.scout_reviews(SCOUT_CALLERS)))
    assert_predicate later, :green?, later.reason
    assert_equal [1, false], later.facts.values_at("dispatch_round", "fan_over_guessed_names")

    branch = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r1t0-model-1", "model_task", spine: false),
                      *SCOUT_CALLERS.each_index.map { |i| D.n("r2t#{i}", "tool_task") }, D.n("r2", "model_task", deliverable: true)],
      [%w[r1 r1t0], %w[r1t0 r1t0-model-1], %w[r1t0 r2]])
    rows = [D.tool("r1t0", "task", after: ["r1"], input: { "prompt" => "Find and review every class with a call method under lib/." }),
            *SCOUT_CALLERS.each_with_index.map { |f, i| D.tool("r2t#{i}", "task", after: ["r1t0-model-1"], input: { "prompt" => "Review lib/#{f}.rb." }) }]
    delegated = task.verdict(D.trace(branch, rows, []))
    assert_predicate delegated, :green?, delegated.reason
    assert_empty delegated.facts.fetch("names_guessed"), "the branch's fan is the branch's"

    itself = task.verdict(EvalsDrawings.spine([EvalsDrawings::SCOUT_LS], [["read", { "path" => "lib/csv_out.rb" }]]))
    assert_equal false, itself.reached
    assert_match(/\Ano delegation: the spine reviewed lib\/ itself: /, itself.reason)
    checked = task.verdict(EvalsDrawings.spine([EvalsDrawings::SCOUT_LS, EvalsDrawings::SCOUT_GREP], EvalsDrawings.scout_reviews(SCOUT_CALLERS),
      [["read", { "path" => "lib/csv_out.rb" }]]))
    assert_equal "the spine read lib/csv_out.rb itself", checked.conduct_reasons.fetch("did_not_review_itself")
  end

  def test_every_predicate_names_why_on_a_wrong_shape
    RED.each do |name, (trace, expected_reason)|
      verdict = CORPUS.find(name).expected.verdict(trace)
      refute_predicate verdict, :green?, "#{name} accepted a wrong shape"
      assert_kind_of String, verdict.reason
      assert_match expected_reason, verdict.reason
    end
  end

  # shape-linear's dimensions, one by one: reach is any tool row; success
  # is the gallery's `linear?`; the conduct facts read row order and the
  # bash command — never a round count.
  def test_shape_linear_reach_is_any_tool_row_and_a_text_only_answer_reaches_nothing
    expected = CORPUS.find("shape-linear").expected
    text_only = D.trace(D.graph([D.n("r1", "model_task", deliverable: true)], []), [], [])
    verdict = expected.verdict(text_only)
    refute verdict.reached
    assert_nil verdict.succeeded, "success is not read when nothing was reached"
    assert_equal "no tool call: the model answered in text (1 rounds)", verdict.reason
    assert_equal({ "ran_the_file" => false, "wrote_before_running" => false }, verdict.conduct_facts)
  end

  def test_shape_linear_conduct_reads_the_command_and_the_row_order
    expected = CORPUS.find("shape-linear").expected
    reversed = [D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "ruby fizzbuzz.rb" }),
                D.tool("r2t0", "write", after: ["r2"], input: { "path" => "fizzbuzz.rb", "content" => "…" })]
    verdict = expected.verdict(D.trace(LINEAR_GRAPH, reversed, []))
    assert verdict.reached
    assert_equal true, verdict.succeeded, "the shape is still a chain"
    assert_equal({ "ran_the_file" => true, "wrote_before_running" => false }, verdict.conduct_facts)
    assert_equal "the run (r1t0) precedes the write (r2t0)", verdict.conduct_reasons.fetch("wrote_before_running")
    never_ran = [D.tool("r1t0", "write", after: ["r1"], input: { "path" => "fizzbuzz.rb" }),
                 D.tool("r2t0", "bash", after: ["r2"], input: { "command" => "ls" })]
    facts = expected.verdict(D.trace(LINEAR_GRAPH, never_ran, [])).conduct_reasons
    assert_match(/no bash row runs `ruby fizzbuzz.rb`/, facts.fetch("ran_the_file"))
    assert_equal "the file was never run", facts.fetch("wrote_before_running")
  end

  # A predicate that answers neither true nor a String is a bug spelled
  # out, never a silent pass; a raise is the lane's to catch.
  def test_a_predicate_answering_neither_true_nor_a_string_is_a_named_red
    expected = E2E::Evals::Expected.new(reach: ->(_trace) { nil }, success: ->(_trace) { true })
    verdict = expected.verdict(GREEN.fetch("shape-linear"))
    refute verdict.reached
    assert_equal "the predicate answered nil, not true or a String", verdict.reason
    assert_equal({}, verdict.conduct)
    truthy = E2E::Evals::Expected.new(reach: ->(_trace) { 5 }, success: ->(_trace) { true }).verdict(GREEN.fetch("shape-linear"))
    refute truthy.reached
    assert_equal "the predicate answered 5, not true or a String", truthy.reason, "a truthy answer is not a green"
  end

  # The trace's counts and facts read off the drawing (the record's
  # efficiency and structure columns), and the gallery's functions
  # delegate — the trace re-implements none.
  def test_the_trace_delegates_to_the_gallery_and_counts_for_the_record
    trace = GREEN.fetch("shape-linear")
    assert_equal 3, trace.rounds.size
    assert_equal 3, trace.spine_rounds.size
    assert_equal 2, trace.calls.size
    assert_equal({ "write" => 1, "bash" => 1 }, trace.called)
    assert_equal 3, trace.rounds_settled
    assert_equal ["r1t0"], trace.edges_into("r2")
    assert_equal true, trace.edge?("r2t0", "r3")
    assert_equal [], trace.nodes_of(kind: "join_task")
    assert_equal({ "rounds" => 3, "calls" => 2, "request_bytes" => nil, "request_bytes_series" => nil, "cache_read_series" => nil, "cost_amount" => 0.02,
                   "cost_unit" => "USD", "input_tokens" => nil, "output_tokens" => nil, "cache_read_tokens" => nil,
                   "cache_hit_rate" => nil, "cost_by_model" => nil, "compactions" => {}, "nudged" => nil, "swept" => nil },
      trace.efficiency)
    assert_equal({ "round_errors" => {}, "round_error_details" => {}, "attention_reasons" => {}, "untraced_attention_reasons" => {}, "rounds_settled" => 3,
                   "receipts" => 0, "called" => { "write" => 1, "bash" => 1 }, "loop_status" => "completed",
                   "leaked_calls" => nil, "reissued_calls" => 0, "refused_steps" => 0, "refusals" => {},
                   "refusals_served" => 0, "model_switches" => 0, "refusal_detail" => nil,
                   "composed_reads" => nil, "kernel_check" => nil }, trace.structure_facts,
      "no compose call placed a model step, so there is nothing to check")
    assert_equal [], trace.compose_rows
    assert_equal ["r1t0"], trace.first_round_rows.map { |row| row["key"] }
    assert_equal "", trace.reply
    events = [D.event("context_compacted", { "mode" => "kernel", "trigger" => "wall" }),
              D.event("context_compacted", { "mode" => "prune", "trigger" => "wall" }),
              D.event("attention_required", { "reason" => "halt_failure" })]
    with_events = D.trace(LINEAR_GRAPH, LINEAR_TASKS, events, facts: { turn_1_called: { "task" => 1 } })
    assert_equal({ "kernel/wall" => 1, "prune/wall" => 1 }, with_events.compaction_tally)
    assert_equal({ "halt_failure" => 1 }, with_events.attention_reasons)
    assert_equal({ "task" => 1 }, with_events.fact(:turn_1_called))
    assert_equal E2E::Evals::Trace::EMPTY_GRAPH, E2E::Evals::Trace.empty.graph
  end

  # THE SPINE IS THE KERNEL'S MARK: the graph route's `spine` on every round, never a key's shape —
  # a compose member's continuations are keyed `rN` too and read `false`; `rounds` on the record
  # counts the spine alone. A trace with no graph (a lane's record) has no mark to read and counts
  # every round, as the lanes always printed. THE PER-ROUND REQUEST BYTES: a round's task read
  # carries `request_bytes`, the stored size of its sealed body, and the trace read joins it onto
  # the round's row; the series on the record is `{spine round key => bytes}` in row order — a
  # branch's rounds and a round never scheduled (it has no number) left out; nil when no round
  # carries one (a lane's record, a trace read before the column).
  def test_the_request_bytes_series_is_the_spine_rounds_sealed_sizes_in_order
    graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task", spine: false),
                     D.n("r3", "model_task"), D.n("r4", "model_task", status: "waiting")], [%w[r1 r1t0], %w[r1t0 r3], %w[r3 r4]])
    tasks = [D.round("r1").merge("request_bytes" => 1_200), D.tool("r1t0", "compose", after: ["r1"]),
             D.round("r2").merge("request_bytes" => 300), D.round("r3").merge("request_bytes" => 48_900), D.round("r4", status: "waiting")]
    trace = D.trace(graph, tasks, [])
    assert_equal({ "r1" => 1_200, "r3" => 48_900 }, trace.request_bytes_series)
    assert_equal({ "r1" => 1_200, "r3" => 48_900 }, trace.efficiency.fetch("request_bytes_series"))
    assert_nil D.trace(graph, [D.round("r1"), D.round("r3")], []).request_bytes_series, "no round carries a size: not read"
    assert_nil E2E::Evals::Trace.empty.request_bytes_series
  end

  # THE PER-ROUND CACHE SERIES (measured-2, the cache audit of 2026-09-16):
  # a round's row carries its `usage` off the transcript read, and the
  # series on the record is `{spine round key => [input_tokens,
  # cache_read_tokens]}` in row order — the bytes series' rules: a branch's
  # round and a round with no usage left out, a wire that reported no cache
  # read on a round reads 0 there, nil when no round carries usage.
  def test_the_cache_read_series_is_the_spine_rounds_usage_in_order
    graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task"), D.n("r2", "model_task", spine: false),
                     D.n("r3", "model_task"), D.n("r4", "model_task", status: "waiting")], [%w[r1 r1t0], %w[r1t0 r3], %w[r3 r4]])
    tasks = [D.round("r1", usage: { "input_tokens" => 1_200, "cache_creation_tokens" => 1_100 }), D.tool("r1t0", "compose", after: ["r1"]),
             D.round("r2", usage: { "input_tokens" => 900, "cache_read_tokens" => 800 }),
             D.round("r3", usage: { "input_tokens" => 300, "cache_read_tokens" => 1_200, "cache_creation_tokens" => 150 }),
             D.round("r4", status: "waiting")]
    trace = D.trace(graph, tasks, [])
    assert_equal({ "r1" => [1_200, 0], "r3" => [300, 1_200] }, trace.cache_read_series)
    assert_equal({ "r1" => [1_200, 0], "r3" => [300, 1_200] }, trace.efficiency.fetch("cache_read_series"))
    assert_equal 0.0, E2E::Evals::Trace.first_round_rate(trace.cache_read_series), "the first spine round's rate: cold"
    assert_equal 4.0, E2E::Evals::Trace.after_first_round_rate(trace.cache_read_series), "the rounds after the first, pooled: r3 alone here"
    assert_equal 1, E2E::Evals::Trace.measured_rounds(trace.cache_read_series)
    assert_nil D.trace(graph, [D.round("r1"), D.round("r3")], []).cache_read_series, "no round carries usage: not read"
    assert_nil E2E::Evals::Trace.empty.cache_read_series
    refute D.round("r1").key?("usage"), "a drawn round carries usage only when drawn with it"
  end

  def test_the_spine_rounds_are_the_graphs_kernel_mark
    members = (2..5).map { |i| D.n("r#{i}", "model_task", spine: false) }
    graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task"), *members], [%w[r1 r1t0]])
    trace = D.trace(graph, [D.tool("r1t0", "compose", after: ["r1"], input: { "script" => "g.model({ prompt: \"x\" });" })], [])
    assert_equal 5, trace.rounds.size
    assert_equal ["r1"], trace.spine_rounds.map { |row| row["key"] }
    assert_equal 1, trace.efficiency.fetch("rounds")
    assert_equal({ "door" => "compose", "rounds" => 1, "receipts" => 0, "compose_calls" => 1, "task_calls" => 0, "bash_calls" => 0 },
      E2E::Evals::Predicates.loop_style(trace))
    assert_equal true, D.n("r1", "model_task").fetch("spine"), "a drawn round is the spine's unless drawn otherwise"
    assert_equal false, D.n("k1", "model_task", spine: false).fetch("spine")
    refute D.n("r1t0", "tool_task").key?("spine"), "the mark rides rounds alone"
    unmarked = E2E::Evals::Trace.draw(E2E::Evals::Trace::EMPTY_GRAPH, [D.round("r1"), D.round("r2")], [])
    assert_equal 2, unmarked.spine_rounds.size
  end

  # THE COMPOSE FAMILY'S SUCCESS IS THE OBJECTIVE'S PICTURE, scored on the
  # plan the script on the compose row placed: exact edges and reads for
  # its objective, a String naming the silent bucket for another
  # objective's script, the refusal for an invalid one (read on its text),
  # and the kernel's verdict beside it — a branch under the call that did
  # not complete is red on a right script.
  def test_the_compose_family_scores_the_script_and_reads_the_branch
    task = CORPUS.find("compose-review-angles")
    green = task.expected.verdict(GREEN.fetch("compose-review-angles"))
    assert_predicate green, :green?, green.reason
    assert green.facts.fetch("score")["first_time_right"]
    wrong = task.expected.verdict(EvalsDrawings.compose_trace(EvalsDrawings::SCRIPTS["O7"]))
    assert_match(/the picture is not the objective's \(silent: /, wrong.reason)
    invalid = task.expected.verdict(EvalsDrawings.compose_trace("g.tool({ name: \"bash\", command: \"x\" });", graph: EvalsDrawings::REFUSED_GRAPH))
    assert_match(/the script was refused/, invalid.reason)
    assert_equal "static", invalid.facts.fetch("score")["reading"], "a refused script is read on its text alone"
    stuck = D.composed(EvalsDrawings::SCRIPTS["O1"], status: { "model-4" => "failed" })
    failed = task.expected.verdict(EvalsDrawings.compose_trace(EvalsDrawings::SCRIPTS["O1"], graph: stuck))
    assert_equal "r1t0-model-4(failed) did not complete under r1t0", failed.reason
    unknown = task.expected.verdict(EvalsDrawings.compose_trace("g.tool({ name: \"probe_host\", input: { host: \"a\" } });",
      graph: EvalsDrawings::REFUSED_GRAPH))
    assert_match(/unknown_tool_name/, unknown.reason)
  end

  # EVERY COMPOSE ROW IS READ ON THE PLAN ITS SCRIPT PLACES: each green drawing is its own script's
  # executed drawing, so the reading is the executed one, and the static one agrees beside it.
  COMPOSE_OBJECTIVES = { "compose-review-angles" => "O1", "compose-grep-then-edit" => "O2", "compose-race" => "O3",
                         "compose-race-anon" => "O3", "compose-background-suite" => "O4", "compose-three-stage-pairing" => "O7",
                         "compose-two-source-fan-in" => "O7b", "compose-rendezvous" => "T5",
                         "workflow-barrier-free-pipeline" => "O7" }.freeze

  def test_every_green_compose_row_reads_the_plan_its_script_places
    COMPOSE_OBJECTIVES.each do |name, id|
      score = E2E::Evals::Predicates.score_compose(GREEN.fetch(name), id)
      assert_equal "executed", score["reading"], name
      assert score["first_time_right"], "#{name}: #{score["silent"].inspect}"
      assert score.dig("static", "first_time_right"), name
    end
  end

  # THE RACE CELLS RECORD WHAT THE ENVELOPE'S `<call>` LINE LEAVES TO THE MODEL, read on the compose
  # call's expanded plan by the text bench's reader (`ComposeBench::Endpoints`): the drawn race
  # carries no label, an echo beside each probe is one, a brief told to say the winner may be
  # unknown is a hedge, and a run with no compose call has nothing to read — nil, never false.
  def test_the_race_cells_record_the_labels_the_filter_and_the_hedge
    facts = %w[authored_labels success_filter hedged_brief]
    tagged = EvalsDrawings::SCRIPTS["O3"].gsub(%r{"bin/probe (\w+)"}, '"bin/probe \1 && echo HOST=\1"')
      .sub("Say which host responded first.", "Name the winner, or say WINNER: unknown.")
    %w[compose-race compose-race-anon].each do |name|
      expected = CORPUS.find(name).expected
      assert_equal [false, false, false], expected.verdict(GREEN.fetch(name)).facts.values_at(*facts), name
      assert_equal [true, false, true], expected.verdict(EvalsDrawings.compose_trace(tagged)).facts.values_at(*facts), name
      assert_equal [nil, nil, nil], expected.verdict(D.trace(LINEAR_GRAPH, LINEAR_TASKS, [])).facts.values_at(*facts), name
    end
  end

  # THE TWO MISREADINGS OF A DELIVERED CALL ride every record (`Trace#structure_facts`). A LEAKED call
  # is a settled round that made no tool call and wrote the `<call>` element as its call — on a line
  # of its own, outside a fence; a reply quoting the delivered line as its evidence is no leak. A
  # trace whose rounds carry no text counts none: nil, not read.
  def test_a_leaked_call_is_the_element_written_as_a_call_never_a_quote
    line = "#{E2E::PrintedEnvelope::CALL}bash {\"command\":\"bin/probe bravo\"}#{E2E::PrintedEnvelope::CALL_END}"
    graph = D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"),
                     D.n("r2", "model_task", deliverable: true, expansion_parent: "r1", input_from: %w[r1 r1t0])],
      [%w[r1 r1t0], %w[r1t0 r2]])
    probe = D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "bin/probe bravo" })
    leaked = ->(first, last) { D.trace(graph, [probe, D.round("r1").merge("output" => first), D.round("r2").merge("output" => last)], []).leaked_calls }

    {
      "bravo answered first; its result reads #{line}." => "quoted inside a sentence",
      "bravo answered first:\n`#{line}`" => "quoted in backticks on its own line",
      "bravo answered first:\n```\n#{line}\n```" => "quoted in a fence",
      "bravo won." => "no element at all",
    }.each { |reply, why| assert_equal 0, leaked.("probing", reply), why }
    assert_equal 1, leaked.("probing", "I will probe it again.\n#{line}"), "the element on its own line, and no call made"
    assert_equal 0, leaked.(line, "bravo won."), "a round that made its call wrote the element beside it, never instead"
    assert_nil D.trace(graph, [probe], []).leaked_calls, "no round's text read: not read, never zero"
  end

  # A REISSUED call runs again a composed tool step that the calling thread READ — the round that
  # made it, or one it continues — with the same name and input, after the step completed and with
  # nothing that may change the files settled between. v11 compose-background-suite kimi-k3 #3's
  # shape: a member step read the lint, edited the model, then linted again — verification after an
  # edit, never a misreading. The same thread with a read in place of the edit runs the lint again
  # for nothing it changed: one.
  def test_a_reissued_call_is_a_read_result_run_again_with_nothing_changed_between
    graph = D.graph(
      [D.n("r1", "model_task"), D.n("r2t0", "tool_task", expansion_parent: "r1"),
       D.n("r2t0-tool-1", "tool_task", expansion_parent: "r2t0"),
       D.n("r2t0-model-1", "model_task", spine: false, expansion_parent: "r2t0", input_from: ["r2t0-tool-1"],
         result_from: ["r2t0-tool-1"]),
       D.n("r3t0", "tool_task", expansion_parent: "r2t0-model-1"),
       D.n("r3", "model_task", spine: false, expansion_parent: "r2t0-model-1", input_from: %w[r2t0-model-1 r3t0]),
       D.n("r4t0", "tool_task", expansion_parent: "r3"),
       D.n("r4", "model_task", spine: false, expansion_parent: "r3", input_from: %w[r3 r4t0]),
       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1", input_from: %w[r1 r2t0 r4]),
       D.n("r2t1", "tool_task", expansion_parent: "r2")],
      [%w[r1 r2t0], %w[r2t0 r2t0-tool-1], %w[r2t0-tool-1 r2t0-model-1], %w[r2t0-model-1 r3t0], %w[r3t0 r3],
       %w[r3 r4t0], %w[r4t0 r4], %w[r4 r2], %w[r2t0 r2], %w[r2 r2t1]]
    )
    at = ->(second) { "2026-09-24T10:00:#{format("%02d", second)}Z" }
    lint = { "command" => "bin/rubocop app", "timeout" => 300 }
    rows = ->(between, *more) do
      [D.tool("r2t0", "compose", after: ["r1"], input: { "script" => "…", "wait" => true }),
       D.tool("r2t0-tool-1", "bash", after: ["r2t0"], input: lint).merge("created_at" => at.(1), "completed_at" => at.(2)),
       between.merge("created_at" => at.(4), "completed_at" => at.(4)),
       D.tool("r4t0", "bash", after: ["r3"], input: lint).merge("created_at" => at.(6), "completed_at" => at.(7)), *more]
    end
    edit = D.tool("r3t0", "edit", after: ["r2t0-model-1"], input: { "path" => "app/models/user.rb" })
    read = D.tool("r3t0", "read", after: ["r2t0-model-1"], input: { "path" => "app/models/user.rb" })

    assert_equal 0, D.trace(graph, rows.(edit), []).reissued_calls, "linted again after its own edit: verification"
    assert_equal 1, D.trace(graph, rows.(read), []).reissued_calls, "linted again with nothing changed: the result run again"
    other = D.tool("r3t0", "bash", after: ["r2t0-model-1"], input: { "command" => "bin/rails test" })
    assert_equal 0, D.trace(graph, rows.(other), []).reissued_calls, "another command between may have changed the files"
    assert_equal 1, D.trace(graph, rows.(edit.merge("status" => "canceled")), []).reissued_calls, "a canceled edit never finished"
    spine = D.tool("r2t1", "bash", after: ["r2"], input: lint).merge("created_at" => at.(9))
    assert_equal 1, D.trace(graph, rows.(read, spine), []).reissued_calls,
      "the spine read the member's answer, never the lint: its own run of it is no reissue"
    early = rows.(read).map { |row| row["key"] == "r4t0" ? row.merge("created_at" => at.(1)) : row }
    assert_equal 0, D.trace(graph, early, []).reissued_calls, "made before the step completed: beside it, never again"
  end

  # THE FLOOR IS HELD TO USABLE GENERATION WHERE SUCCESS IS A PICTURE: the lane's tier fact picks the
  # bar, so another objective's script — built, placed, completed — is green on the floor with the
  # picture's red riding as the `picture` fact and `usable_on_call` beside it, and red on the strong
  # tier and on a record with no tier fact, as it always read. The recorded-only rendezvous reads
  # usable generation on the floor too, and the usable call's branch must still complete — its
  # picture a fact on both tiers, never the bar. Every other compose and workflow task keeps its own
  # bar on the floor: the control and the doors that read receipts, fans or a reply.
  RECORDED = "compose-rendezvous".freeze
  PICTURE_TASKS = COMPOSE_OBJECTIVES.except(RECORDED).freeze
  FLOOR = { "tier" => E2E::Evals::Bench::FLOOR }.freeze

  def test_the_floor_reads_usable_generation_where_success_is_a_picture
    PICTURE_TASKS.each do |name, id|
      # The race cells' conduct reads the reply, so every drawn run answers the race right.
      trace = EvalsDrawings.compose_trace(EvalsDrawings::SCRIPTS[id == "O1" ? "O7" : "O1"], facts: { "reply" => "bravo won" })
      floor = CORPUS.find(name).expected.verdict(trace.with_facts(FLOOR))
      assert_predicate floor, :green?, "#{name}: #{floor.reason}"
      assert_match(/the picture is not the objective's/, floor.facts.fetch("picture"), name)
      assert_equal 1, floor.facts.fetch("usable_on_call"), name
      [trace.with_facts("tier" => E2E::Evals::Bench::STRONG), trace].each do |strong|
        verdict = CORPUS.find(name).expected.verdict(strong)
        assert_match(/the picture is not the objective's/, verdict.reason, name)
        assert_equal verdict.reason, verdict.facts.fetch("picture"), "#{name}: the picture fact is the strong bar's verdict"
      end
      right = CORPUS.find(name).expected.verdict(GREEN.fetch(name).with_facts(FLOOR))
      assert_equal true, right.facts.fetch("picture"), name
    end
    others = (CORPUS.select("compose-*") + CORPUS.select("workflow-*")).map(&:name) - PICTURE_TASKS.keys - [RECORDED]
    assert_equal %w[compose-single-read workflow-adversarial-verify workflow-fan-out-finders
                    workflow-judge-panel workflow-loop-until-dry workflow-scout-then-fan], others.sort
    others.each do |name|
      trace, reason = RED.fetch(name)
      verdict = CORPUS.find(name).expected.verdict(trace.with_facts(FLOOR))
      refute_predicate verdict, :green?, "#{name} kept its own bar on the floor"
      assert_match reason, verdict.reason, name
      refute verdict.facts.key?("picture"), "#{name}: no picture to carry"
    end
    stuck = D.composed(EvalsDrawings::SCRIPTS["T5"], status: { "model-2" => "failed" })
    rendezvous = CORPUS.find("compose-rendezvous").expected.verdict(EvalsDrawings.compose_trace(EvalsDrawings::SCRIPTS["T5"],
      graph: stuck, facts: FLOOR))
    assert_equal "r1t0-model-2(failed) did not complete under r1t0", rendezvous.reason, "the rendezvous's own bar on the floor"
    repaired = CORPUS.find(RECORDED).expected.verdict(EvalsDrawings.repaired_trace(EvalsDrawings::SCRIPTS["T5"], facts: FLOOR))
    assert_predicate repaired, :green?, "the rendezvous's floor reads the run: #{repaired.reason}"
    assert repaired.facts.key?("picture"), "the rendezvous's picture rides as a fact"
    red, reason = RED.fetch(RECORDED)
    unreached = CORPUS.find(RECORDED).expected.verdict(red.with_facts(FLOOR))
    refute_predicate unreached, :green?, "the rendezvous's red on the floor"
    assert_match reason, unreached.reason
  end

  # THE PANEL ON THE COMPOSE DOOR counts the model steps the call placed: the judges a stage placed
  # among them, never a review's own continuation rounds, which hang under the review.
  def test_the_compose_panel_counts_the_steps_the_call_placed
    task = CORPUS.find("workflow-judge-panel")
    rounds = (1..3).flat_map do |i|
      member = "r1t0-model-#{i}"
      [D.n("r#{i + 2}t0", "tool_task", expansion_parent: member),
       D.n("r#{i + 2}", "model_task", spine: false, expansion_parent: member, input_from: [member, "r#{i + 2}t0"])]
    end
    busy = EvalsDrawings::FAN_GRAPH.merge("nodes" => EvalsDrawings::FAN_GRAPH["nodes"] + rounds)
    reviewed = task.expected.verdict(EvalsDrawings.compose_trace(EvalsDrawings::SCRIPTS["O1"], graph: busy, facts: { "reply" => "winner: b" }))
    assert_predicate reviewed, :green?, reviewed.reason
    assert_equal 4, reviewed.facts.fetch("judges"), "three reviews and the verdict, never their rounds"

    judges = (1..4).map { |i| "01a0cb93-1c2e-7a10-8a52-6d0f41c1e00#{i}" }
    staged = D.graph(
      [D.n("r1", "model_task"), D.n("r1t0", "tool_task", expansion_parent: "r1"), D.n("r1t0-script-1", "script_task", expansion_parent: "r1t0"),
       *judges.map { |key| D.n(key, "model_task", spine: false, expansion_parent: "r1t0-script-1") },
       D.n("r2", "model_task", deliverable: true, expansion_parent: "r1")],
      [%w[r1 r1t0], %w[r1t0 r1t0-script-1], *judges.first(3).flat_map { |key| [["r1t0-script-1", key], [key, judges.last]] }, %w[r1t0 r2]]
    )
    placed = task.expected.verdict(EvalsDrawings.compose_trace('g.script({ script: "return 1;" });', graph: staged, facts: { "reply" => "winner: b" }))
    assert_predicate placed, :green?, placed.reason
    assert_equal 4, placed.facts.fetch("judges"), "the judges and the chair a stage placed are the call's"
  end

  # The control's columns read inverted on purpose: a compose on one
  # read's worth of work is reached-and-failed with `compose_zero: false`.
  def test_the_controls_read_restraint_as_success
    verdict = CORPUS.find("compose-single-read").expected.verdict(RED.fetch("compose-single-read").first)
    assert verdict.reached
    assert_equal false, verdict.succeeded
    assert_equal false, verdict.facts.fetch("compose_zero")
    control = CORPUS.find("task-grep-three-control").expected.verdict(GREEN.fetch("task-grep-three-control"))
    configs = %w[config/app.yml config/db.yml config/cache.yml]
    door = { "door_kind" => "none", "door_read" => { "round" => 2, "built" => nil, "members" => 0, "unread" => [], "beside" => [] },
             "dispatch_round" => nil, "scout_then_door" => false, "door_calls" => [] }
    assert_equal({ "task_zero" => true, "compose_zero" => true, "calls_in_first_round" => 3, "covered" => configs,
                   "covered_in_first_round" => configs }.merge(door), control.facts,
      "three greps are a look, so the round that answered is the control's door")
  end

  # The workflow family records the DOOR and asserts the loop, never a count.
  def test_the_workflow_family_records_the_door_and_asserts_the_receipt_loop
    finders = CORPUS.find("workflow-fan-out-finders").expected.verdict(GREEN.fetch("workflow-fan-out-finders"))
    assert_predicate finders, :green?, finders.reason
    assert_equal "compose", finders.facts.fetch("door")
    assert_equal 1, finders.facts.fetch("per_file").fetch("lib/auth.rb")
    verify = CORPUS.find("workflow-adversarial-verify").expected.verdict(GREEN.fetch("workflow-adversarial-verify"))
    assert_predicate verify, :green?, verify.reason
    assert_equal "task_fan", verify.facts.fetch("door")
    assert_equal 1, verify.facts.fetch("loop_style").fetch("receipts")
    waited = CORPUS.find("workflow-adversarial-verify").expected.verdict(D.trace(EvalsDrawings::FIVE_GRAPH, EvalsDrawings::FIVE_TASKS, []))
    assert_equal true, waited.facts.fetch("waited")
    assert_match(/no input_accepted/, waited.reason)
    # THE PANEL THAT WAITED is a panel: three judges fanned with `wait: true`, a waited chair, no
    # receipt, the reply naming b — green on the task door, the receipts and the spelling on the
    # record.
    panel = CORPUS.find("workflow-judge-panel").expected.verdict(EvalsDrawings.panel_trace)
    assert_predicate panel, :green?, panel.reason
    assert_equal "task_fan", panel.facts.fetch("door")
    assert_equal 0, panel.facts.fetch("loop_style").fetch("receipts")
    assert_equal true, panel.facts.fetch("waited")
    assert_equal 4, panel.facts.fetch("judges"), "three judges and the chair, every task row"
    unnamed = CORPUS.find("workflow-judge-panel").expected.verdict(EvalsDrawings.panel_trace(reply: "b is better"))
    assert_match(/the reply does not name b as the winner/, unnamed.reason)
    lost = EvalsDrawings.panel_trace(tasks: EvalsDrawings::PANEL_TASKS.map { |row| row["key"] == "r2t2" ? row.merge("status" => "failed") : row })
    assert_equal "r2t2(failed) did not complete: the fan never came back whole", CORPUS.find("workflow-judge-panel").expected.verdict(lost).reason
    dry = CORPUS.find("workflow-loop-until-dry").expected.verdict(RED.fetch("workflow-loop-until-dry").first)
    assert_match(/no iteration: 1 pass/, dry.reason)
    assert_match(/a shell loop over the queue/, dry.conduct.fetch("one_item_per_pass"))
  end

  # "THE SPINE DID IT ITSELF" READS THE KERNEL'S MARK (the v11 readout: every fan-out-finders grep and
  # 321 adversarial-verify reads the checks counted were the delegates'): a delegate's own rounds are
  # keyed `rN` and their calls `rNtM` off the loop-global counter, and the graph route marks those
  # rounds `spine: false`, so a call is the spine's when the round that made it is marked the
  # spine's. The spine's own read or grep after the fan stays red.
  def test_the_spine_did_it_itself_is_read_off_the_kernels_mark_never_a_keys_shape
    reads = %w[wallet ledger rate].map { |f| { "path" => "lib/#{f}.rb" } }
    verify = CORPUS.find("workflow-adversarial-verify").expected
    assert_equal true, verify.verdict(D.trace(*EvalsDrawings.delegated("read", reads), [])).conduct.fetch("did_not_judge_itself")
    judged = verify.verdict(D.trace(*EvalsDrawings.delegated("read", reads, own: [["read", { "path" => "lib/wallet.rb" }]]), []))
    assert_equal "the spine read lib/wallet.rb itself", judged.conduct.fetch("did_not_judge_itself")
    greps = %w[auth billing cache].map { |f| { "pattern" => "TOKEN", "path" => "lib/#{f}.rb" } }
    finders = CORPUS.find("workflow-fan-out-finders").expected
    assert_equal true, finders.verdict(D.trace(*EvalsDrawings.delegated("grep", greps), [])).conduct.fetch("did_not_search_itself")
    searched = finders.verdict(D.trace(*EvalsDrawings.delegated("grep", greps, own: [["grep", { "pattern" => "TOKEN", "path" => "lib" }]]), []))
    assert_equal "the spine grepped 1× itself", searched.conduct.fetch("did_not_search_itself")
    # task-fan-five: each delegate's two `task` calls are graph verbs inside a branch, and the one
    # `task` the spine made after its first-message fan is the one in a later round — the fan's own
    # calls carry r1's continuation number (`r2tN`), and r1 made them.
    five = CORPUS.find("task-fan-five").expected
    nested = five.verdict(D.trace(*EvalsDrawings.delegated("task", Array.new(5) { |i| { "prompt" => "brief #{i}" } },
      own: [["task", { "prompt" => "again" }]]), [], facts: { "reply" => EvalsDrawings::FIVE_REPLY }))
    assert_equal 5, nested.facts.fetch("task_calls_in_first_message")
    assert_equal 1, nested.facts.fetch("task_calls_in_a_later_round")
    assert_equal "10 graph verb(s) inside a branch", nested.reason
  end

  # JUDGING IS A READ AFTER DISPATCH: a brief needs the code's shape, so the spine's read of lib/ in a
  # round before the one that handed the first refuter out is briefing; one beside the dispatch, in
  # that round, informed no brief written in the same turn, and is left unjudged because no refuter
  # could have answered yet — the lenient choice. Both count as `read_before_dispatch`. A read in a
  # later round is the spine checking what it handed out. r1 reads wallet.rb, r2 dispatches two
  # refuters (and reads ledger.rb beside them), r3 reads rate.rb once a receipt woke it.
  def test_a_spine_read_before_the_dispatch_briefs_and_one_after_it_judges
    verify = CORPUS.find("workflow-adversarial-verify").expected
    refuters = [D.tool("r3t0", "task", after: ["r2"], input: { "prompt" => "Refute C1 from lib/.", "wait" => false }),
                D.tool("r3t1", "task", after: ["r2"], input: { "prompt" => "Refute C1 from lib/.", "wait" => false })]
    read = ->(key, round, file) { D.tool(key, "read", after: [round], input: { "path" => "lib/#{file}.rb" }) }
    drawn = lambda do |rows|
      graph = D.graph([D.n("r1", "model_task"), *rows.map { |row| D.n(row["key"], "tool_task") }, D.n("r2", "model_task"),
                       D.n("r3", "model_task"), D.n("r4", "model_task", deliverable: true)],
        [*rows.map { |row| [row["after"].first, row["key"]] }, %w[r1 r2], %w[r2 r3], %w[r3 r4]])
      verify.verdict(D.trace(graph, rows, []))
    end

    before = drawn.([read.("r2t0", "r1", "wallet"), *refuters])
    assert_equal({ "did_not_judge_itself" => true }, before.conduct_facts)
    assert_equal 1, before.facts.fetch("read_before_dispatch")
    beside = drawn.([read.("r2t0", "r1", "wallet"), *refuters, read.("r3t2", "r2", "ledger")])
    assert_equal({ "did_not_judge_itself" => true }, beside.conduct_facts)
    assert_equal 2, beside.facts.fetch("read_before_dispatch")
    after = drawn.([read.("r2t0", "r1", "wallet"), *refuters, read.("r4t0", "r3", "rate")])
    assert_equal "the spine read lib/rate.rb itself", after.conduct.fetch("did_not_judge_itself")
    assert_equal 1, after.facts.fetch("read_before_dispatch")
    undispatched = drawn.([read.("r2t0", "r1", "wallet")])
    assert_equal "the spine read lib/wallet.rb itself", undispatched.conduct.fetch("did_not_judge_itself"),
      "with nothing handed out, every read of lib/ is the spine's own verdict"
  end

  # The compaction family's columns are facts on the record, and the
  # pointer rule reads the summaries' bodies the lane stamps.
  def test_the_compaction_family_computes_its_columns_and_reads_the_summaries
    task = CORPUS.find("compaction-kernel-manual")
    verdict = task.expected.verdict(GREEN.fetch("compaction-kernel-manual"))
    assert_predicate verdict, :green?, verdict.reason
    columns = verdict.facts.fetch("columns")
    assert_equal({ "kernel/manual" => 1 }, columns.fetch("compactions"))
    assert_equal ["k1"], columns.fetch("summary_keys")
    assert_operator columns.fetch("summary_bytes"), :>, 40
    assert_nil columns.fetch("reread_rate"), "no read after the arm"
    assert_equal 0, columns.fetch("induced_rounds"), "two rounds after the arm is the stated minimum"
    leaked = GREEN.fetch("compaction-kernel-manual").with_facts("summaries" => { "k1" => "the last line was brief-0123abcd" })
    assert_match(/reproduced a value/, task.expected.verdict(leaked).conduct.fetch("pointers_never_values"))
    wall = CORPUS.find("compaction-wall-kernel").expected.verdict(GREEN.fetch("compaction-wall-kernel"))
    assert_predicate wall, :green?, wall.reason
    assert_equal({ "kernel/wall" => 1 }, wall.facts.fetch("columns").fetch("compactions"))
    assert_equal 0.0, wall.facts.fetch("columns").fetch("reread_rate"), "two reads after r5, neither seen before"
  end

  # THE ATTENTION IS THE TRACED LOOPS' (the v11 bench's compose-background-suite deepseek-flash #2):
  # the plain driver read the trace once the primary's tasks settled, a receipt woke a turn that
  # asked a person 19 s after that last wait, and the run's stop (12a L7) canceled it — the ask on a
  # loop the run never traced read as a kernel finding over a run that met its bar. A loop appended
  # after the stop (`traced: false`, `EvalsLaneTest#loops_after_stop`) keeps its ask apart as
  # `untraced_attention_reasons`, the model's word to nobody, never a signal; an ask on a traced loop
  # signals as ever, and an event naming no loop is the run's.
  def test_an_ask_on_a_loop_the_run_never_traced_is_kept_apart_and_signals_nothing
    events = [D.event("attention_required", { "reason" => "awaiting_human", "agent_loop_public_id" => "loop-3" }),
              D.event("attention_required", { "reason" => "halt_failure" })]
    loops = [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-3", "status" => "canceling", "traced" => false }]
    trace = D.trace(LINEAR_GRAPH, LINEAR_TASKS, events, loops: loops)
    assert_equal({ "halt_failure" => 1 }, trace.attention_reasons)
    assert_equal({ "awaiting_human" => 1 }, trace.untraced_attention_reasons)

    woken = D.trace(LINEAR_GRAPH, LINEAR_TASKS, events.first(1), loops: loops)
    record = { "driver" => "plain", "verdict" => { "reached" => true, "succeeded" => true }, "facts" => woken.structure_facts }
    assert_nil E2E::Evals::Scorecard.kernel_signal(record)
    assert_nil E2E::Evals::Scorecard.classify(record, bench: BENCH), "a green run stays green"
    traced = D.trace(LINEAR_GRAPH, LINEAR_TASKS, events.first(1), loops: loops.map { |row| row.except("traced") })
    assert_equal "attention_required outside the scripted step: awaiting_human",
      E2E::Evals::Scorecard.kernel_signal(record.merge("facts" => traced.structure_facts))
  end

  # A PASSIVE WAKE IS READ BY WHAT THE TASK ASKED FOR: every call asked `wake: "passive"`, so the
  # receipt (or the child's reply) joins the history as a `message` turn and wakes none — the
  # driver's `wake_passive` (the v11 bench's task-mail deepseek-flash #2, task-detached-receipt
  # kimi-k3 #2 and #3). task-mail and spawn-subagent-suite ask only for turn 2's answer, so a
  # passive run whose turn 2 named the failing test from that history is green, the woke-a-turn
  # fact a fact; task-detached-receipt asks to be told when the suite finishes, which only a woken
  # turn can say, so its passive run stays red and the sentence names the miss.
  def test_a_passive_run_is_green_where_turn_2_read_the_receipt_from_the_history
    EvalsDrawings::PASSIVE_GREEN.each do |name, trace|
      verdict = CORPUS.find(name).expected.verdict(trace)
      assert_predicate verdict, :green?, "#{name}: #{verdict.reason}"
      assert_nil verdict.reason, name
    end
  end

  def test_a_passive_run_still_owes_turn_2s_read_of_the_history
    {
      "task-mail" => "the receipt's turn is not before turn 2 on the timeline",
      "spawn-subagent-suite" => "the child's reply turn is not before turn 2 on the timeline",
    }.each do |name, why|
      passive = EvalsDrawings::PASSIVE_GREEN.fetch(name)
      expected = CORPUS.find(name).expected
      unread = expected.verdict(passive.with_facts("mail_in_turn_2_history" => false))
      assert_equal [false, why], [unread.succeeded, unread.reason], name
      rerun = expected.verdict(passive.with_facts("turn_2_bash_commands" => ["ruby test/all.rb"]))
      assert_equal [false, "turn 2 re-ran the suite"], [rerun.succeeded, rerun.reason], name
      unnamed = expected.verdict(passive.with_facts("turn_2_reply" => "status: completed\nI do not know"))
      assert_equal false, unnamed.succeeded, name
      assert_match(/\Aturn 2 did not name test_subtracts/, unnamed.reason, name)
    end
  end

  # The woken turn stays owed wherever a call left the wake `auto`: the receipt that woke nothing
  # there is the kernel's to explain, never excused by a fact the driver did not set.
  def test_a_run_whose_wake_was_auto_still_owes_the_woken_turn
    {
      "task-mail" => ["receipt_woke_a_turn", "the receipt woke no turn"],
      "spawn-subagent-suite" => ["reply_woke_a_turn", "the child's reply woke no turn"],
    }.each do |name, (fact, why)|
      expected = CORPUS.find(name).expected
      [{}, { "wake_passive" => false }].each do |wake|
        verdict = expected.verdict(GREEN.fetch(name).with_facts(wake.merge(fact => false)))
        assert_equal [false, why], [verdict.succeeded, verdict.reason], "#{name} #{wake.inspect}"
      end
    end
  end

  def test_task_detached_receipt_stays_red_on_a_passive_wake
    EvalsDrawings::PASSIVE_RED.each do |name, (trace, sentence)|
      verdict = CORPUS.find(name).expected.verdict(trace)
      assert verdict.reached, name
      assert_equal false, verdict.succeeded, name
      assert_match sentence, verdict.reason, name
    end
    woken = CORPUS.find("task-detached-receipt").expected.verdict(GREEN.fetch("task-detached-receipt").with_facts("wake_passive" => true))
    assert_equal true, woken.succeeded, "a run whose receipt woke a turn reads as before: #{woken.reason}"
  end

  # Every task's RATIONALE, instruction and expected agree on the door:
  # a task whose flags turn compose on carries the switch, the
  # authored halt has no instruction for a model, the pump tasks name a policy.
  def test_the_front_matter_agrees_with_the_family
    CORPUS.select("compose-*").each { |task| assert_equal({ "compose" => true }, task.flags, task.name) }
    assert_equal({ "approval" => "ask", "until" => "sh check.sh", "attempts" => 6 }, CORPUS.find("exit-long").flags)
    assert_equal "exit_long", CORPUS.find("exit-long").policy
    assert_equal "first_differs_denied", CORPUS.find("approval-reformulate").policy
    assert CORPUS.find("handoff-mid-conversation").runner_home?
    assert_equal 1, CORPUS.find("handoff-mid-conversation").turns.size
    assert_equal 1, CORPUS.find("task-mail").turns.size
    assert_equal "delegate", CORPUS.find("compaction-delegate-manual").compaction
    assert_equal %w[strong], CORPUS.select("compaction-wall-*").flat_map(&:tiers).uniq
  end
end
