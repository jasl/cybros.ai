require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"
require "tmpdir"

# THE SCORECARD AND ITS CLASSES, PINNED: `classify` is a pure function over the record — a lane
# bug, model conduct, a kernel finding, a disagreement, a provider's refusal that stood, the cache
# bar, or nil for green — and the writer renders
# one file per model from a label's records, refusing to mix bench digests in one table. Every drawn
# record is `Drawing.record`'s, in the lane's own shape.
class EvalsScorecardTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  S = E2E::Evals::Scorecard
  BENCH = EvalsFixtureBench.read

  def test_a_green_record_has_no_class
    assert_nil S.classify(D.record)
    assert_nil S.classify(D.record(task_pass: nil)), "a task without verification is green on the other dimensions"
  end

  # A FAMILY WITH NO REACH DIMENSION (terminal-bench, Agents-on-Rails): `reached: nil` is "not
  # read", never a red — task pass is the one number; the family table and its rows print `—` where
  # nothing was read, the pass column as it is.
  def test_a_family_with_no_reach_dimension_is_read_on_task_pass_alone
    passed = D.record(task: "chess-best-move", family: "terminal-bench", reached: nil, succeeded: nil, task_pass: true)
    failed = D.record(task: "chess-best-move", family: "terminal-bench", reached: nil, succeeded: nil, task_pass: false, run: 2)
    assert_nil S.classify(passed)
    assert_equal S::MODEL_CONDUCT, S.classify(failed)
    assert_equal "verification failed", S.reason_of(failed)
    assert_nil S.disagreement(passed), "one scorer alone can never disagree"
    lines = S.family_section("terminal-bench", [passed, failed], bench: BENCH)
    assert_includes lines, "## terminal-bench — reach — · success-when-reached — · task pass 1/2 (50%) · compactions survived 0/2 · cache — (no floor)"
    assert_includes lines, "| chess-best-move | nexus | 2 | — | — | 1/2 | — | 3.0 | — | 0.01 USD | — | — | — |"
    assert_includes lines, "- chess-best-move nexus #2: model conduct — verification failed"
    assert_equal S::LANE_BUG, S.classify(passed.merge("error" => "build_failed: docker build alexgshaw/x failed")), "an image that never built is the lane's"
  end

  # A LANE BUG: the driver raised, or the deadline hit before the model's
  # first round settled — fix the harness, never re-tune the task.
  def test_a_harness_error_or_an_early_deadline_is_a_lane_bug
    assert_equal S::LANE_BUG, S.classify(D.record(reached: false, error: "RuntimeError: rho do failed"))
    stalled = D.record(reached: false, stopped: "deadline", facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 0 })
    assert_equal S::LANE_BUG, S.classify(stalled)
    moving = D.record(reached: true, succeeded: false, stopped: "deadline",
      facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 14 })
    assert_equal S::MODEL_CONDUCT, S.classify(moving), "the model's rounds were still moving: it did not finish"
    # A cost stop with NOTHING read is the deadline's situation: the same one sentence.
    nothing_read = D.record(reached: false, stopped: "cost_stop", facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 0 })
    assert_equal S::LANE_BUG, S.classify(nothing_read)
    assert_equal S::LANE_BUG, S.classify(nothing_read.merge("facts" => {})), "no rounds_settled fact at all reads as nothing settled"
    # THE PERSON'S INTERRUPT: the salvage line is written so the spend is visible; the class is the
    # lane's whatever settled — a Ctrl-C says nothing about the model, and the cell is re-run.
    interrupted = D.record(reached: true, succeeded: false, task_pass: nil, stopped: "interrupted",
      facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 14 })
    assert_equal S::LANE_BUG, S.classify(interrupted)
    assert_equal "stopped: interrupted", S.reason_of(interrupted)
    # A PREDICATE THAT RAISED read nothing of the run: the harness failed to score it (v10's first
    # compose `script` step, "no verb"), so the record is the lane's whatever the model did — and a
    # record written before this rule reads the same, because the ledger classifies live.
    unscored = D.record(reached: false, succeeded: nil, reason: "#{S::PREDICATE_RAISED} ArgumentError: no verb: [\"script\"]",
      facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 4 })
    assert_equal S::LANE_BUG, S.classify(unscored)
  end

  # A DEADLINE OVER A LIVE STREAM IS THE MODEL'S: a stop before any round settled is the lane's
  # unless the loop's window shows the model still streaming when it landed (`facts.in_flight`,
  # `WorldLog.in_flight` — the last delta at most STREAM_LIVE_SECONDS before the stop, or at or
  # after it). Its kind reads mid-round, apart from a deadline over settled rounds, and its line
  # names the stream; the spend stays unknown, since no round settled to carry a usage. No fact,
  # no frame, a stream that went quiet, no stop time: the lane's, as before.
  def test_a_deadline_over_a_live_stream_is_the_models_and_a_silent_or_stalled_stream_stays_the_lanes
    facts = { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 0 }
    stream = { "task_key" => "r1", "frames" => 1679, "last_frame_age_s" => 22.9, "attempts" => 1 }
    unspent = { "rounds" => 1, "calls" => 0, "cost_amount" => nil, "input_tokens" => 0, "output_tokens" => 0, "compactions" => {} }
    mid = D.record(task: "compose-background-suite", family: "compose", reached: false, succeeded: nil, task_pass: nil, stopped: "deadline",
      reason: "no compose call: the model called {}", facts: facts.merge("in_flight" => stream), efficiency: unspent)
    failed = mid.merge("verdict" => mid["verdict"].merge("task_pass" => false))
    verified = mid.merge("verdict" => mid["verdict"].merge("task_pass" => true))
    assert_equal S::MODEL_CONDUCT, S.classify(mid)
    assert_equal ["deadline (mid-round)", "deadline (mid-round, failed)", "deadline (mid-round, verified)"],
      [mid, failed, verified].map { |row| S.kind_of(row) }
    assert_equal "- compose-background-suite nexus #1: model conduct — deadline (mid-round, failed) — 1,679 frames, " \
                 "the last 22.9 s before the stop; spend unknown — no compose call: the model called {}", S.red_line(failed)
    # A delta that landed at or after the stop is the stream at its liveliest: the age stays signed on
    # the fact, and the line says which side of the stop it fell on.
    after = failed.merge("facts" => facts.merge("in_flight" => stream.merge("frames" => 4060, "last_frame_age_s" => -0.2)))
    assert_equal S::MODEL_CONDUCT, S.classify(after), "a delta after the stop: the stream was live"
    assert_equal "deadline (mid-round, failed) — 4,060 frames, the last 0.2 s after the stop; spend unknown", S.kind_line(after)

    lane = ->(fact) { S.classify(mid.merge("facts" => fact.nil? ? facts : facts.merge("in_flight" => fact))) }
    assert_equal S::LANE_BUG, lane.(nil), "no fact: the stream was not read"
    assert_equal S::LANE_BUG, lane.({ "frames" => 0, "last_frame_age_s" => nil }), "no frame: a hang or a dead runner"
    assert_equal S::LANE_BUG, lane.({ "frames" => 5, "last_frame_age_s" => 61.0 }), "a stream that went quiet before the stop"
    assert_equal S::LANE_BUG, lane.(stream.merge("last_frame_age_s" => nil)), "no stop time to age the stream against"
    assert_equal "deadline", S.kind_of(mid.merge("facts" => facts)), "a lane's deadline keeps its kind"
  end

  # MODEL CONDUCT: reach false, reached and not succeeded, a conduct fact
  # false, a verification red, a cost stop with rounds settled — the class
  # the floor fills.
  def test_reach_success_conduct_verification_and_a_cost_stop_are_model_conduct
    assert_equal S::MODEL_CONDUCT, S.classify(D.record(reached: false, succeeded: nil, reason: "no compose call"))
    assert_equal S::MODEL_CONDUCT, S.classify(D.record(succeeded: false, task_pass: nil, reason: "a join_task on a linear loop"))
    assert_equal S::MODEL_CONDUCT, S.classify(D.record(conduct: { "ran_the_file" => false }))
    assert_equal S::MODEL_CONDUCT, S.classify(D.record(task_pass: false, succeeded: false))
    assert_equal S::MODEL_CONDUCT, S.classify(D.record(stopped: "cost_stop"))
    assert_equal "conduct: ran_the_file", S.reason_of(D.record(conduct: { "ran_the_file" => false }))
    assert_equal "stopped: cost_stop", S.reason_of(D.record(stopped: "cost_stop"))
  end

  # A KERNEL FINDING outranks conduct: a round failed with a kernel error
  # key other than the brake's or a designed cancel's, an attention
  # outside the driver's scripted step, a fallback compaction.
  def test_a_failed_round_an_unscripted_attention_or_a_fallback_is_a_kernel_finding
    failed = D.record(facts: { "round_errors" => { "expand_failed" => 1 }, "attention_reasons" => {}, "rounds_settled" => 3 })
    assert_equal S::KERNEL_FINDING, S.classify(failed)
    assert_equal "a round failed: expand_failed", S.kernel_signal(failed)
    brake = D.record(succeeded: false, task_pass: nil, driver: "brake",
      facts: { "round_errors" => { E2E::Gallery::EXPANSION_REFUSED => 1 }, "attention_reasons" => { "halt_failure" => 1 }, "rounds_settled" => 4 })
    assert_equal S::MODEL_CONDUCT, S.classify(brake), "the brake's own key and its scripted halt are the model's conduct"
    unscripted = D.record(facts: { "round_errors" => {}, "attention_reasons" => { "approval_required" => 1 }, "rounds_settled" => 3 })
    assert_equal S::KERNEL_FINDING, S.classify(unscripted)
    assert_equal "attention_required outside the scripted step: approval_required", S.kernel_signal(unscripted)
    pumped = unscripted.merge("driver" => "pump")
    assert_nil S.classify(pumped), "the pump scripts approval_required"
    asked = D.record(driver: "answer_ask", facts: { "round_errors" => {}, "attention_reasons" => { "awaiting_human" => 1 }, "rounds_settled" => 3 })
    assert_nil S.classify(asked)
    fallback = D.record(efficiency: { "rounds" => 9, "calls" => 8, "compactions" => { "kernel/wall" => 1, "prune/fallback" => 1 }, "compactions_survived" => 2 })
    assert_equal S::KERNEL_FINDING, S.classify(fallback)
    assert_equal "a fallback compaction: prune/fallback", S.kernel_signal(fallback)
    assert_equal S::LANE_BUG, S.classify(failed.merge("error" => "boom")), "a raised driver is read first"
  end

  # THE KERNEL CHECK IS A KERNEL FINDING, READ BEFORE A RAISED PREDICATE'S LANE BUG: the check's own
  # words (`facts.kernel_check` a String), or a composed step the kernel handed anything by position
  # (`facts.composed_reads[*].positional`). A positional read on a stage-free compose picture raises
  # inside the predicate, and that record is the kernel's, never the lane's. `true` (every request
  # read carried what its step is owed) and nil (none read; a record from before the fact) signal
  # nothing.
  def test_the_kernel_check_is_a_kernel_finding_read_before_a_raised_predicate
    facts = D.record.fetch("facts")
    checked = D.record(facts: facts.merge("kernel_check" => "step m1: owed [a, b], carried [b, a]"))
    assert_equal S::KERNEL_FINDING, S.classify(checked)
    assert_equal "the kernel check: step m1: owed [a, b], carried [b, a]", S.kernel_signal(checked)
    positional = D.record(facts: facts.merge("composed_reads" => { "m1" => { "positional" => ["r1t0"] }, "m2" => { "positional" => [] } }))
    assert_equal S::KERNEL_FINDING, S.classify(positional)
    assert_equal "a composed step read by position: m1", S.kernel_signal(positional)

    raised = checked.merge("verdict" => checked["verdict"].merge("reached" => false, "succeeded" => nil),
      "reason" => "#{S::PREDICATE_RAISED} E2E::ComposeBench::Executed::Drifted: the plan is not the script's")
    assert_equal S::KERNEL_FINDING, S.classify(raised), "the kernel check outranks the lane bug of a predicate that raised"
    assert_equal "the kernel check: step m1: owed [a, b], carried [b, a]", S.reason_of(raised)
    assert_equal S::LANE_BUG, S.classify(raised.merge("facts" => facts)), "with no check on the record, the raise is the lane's"
    assert_equal S::LANE_BUG, S.classify(checked.merge("error" => "boom")), "a raised driver is read first"
    assert_equal S::LANE_BUG, S.classify(checked.merge("stopped" => "interrupted")), "the person's interrupt is read first"

    clean = D.record(facts: facts.merge("kernel_check" => true, "composed_reads" => { "m1" => { "owed" => [], "positional" => [] } }))
    assert_nil S.classify(clean)
    assert_nil S.kernel_signal(clean)
    assert_nil S.classify(D.record(facts: facts.merge("kernel_check" => nil, "composed_reads" => nil)))
    assert_equal S::LANE_BUG, S.classify(raised.merge("facts" => facts.merge("kernel_check" => true))), "a clean check leaves the raise the lane's"
  end

  # THE HARNESS'S OWN STOP IS NEVER A FAILED ROUND ON THE RED LINE: `rho stop` after the cost stop
  # or the deadline stamps `creator_requested` on the running step and `loop_canceled` on the queued
  # rows (`Predicates::HARNESS_STOP`), and kimi exit-long #2's line read "a round failed:
  # creator_requested" over the record's own reason "check-1 canceled". A stopped record subtracts
  # the stop's keys; the same keys on a record NOT stopped by the harness still signal.
  def test_a_harness_stops_keys_are_not_a_failed_round_on_a_stopped_record
    stopped = D.record(succeeded: false, task_pass: false, stopped: "cost_stop", reason: "check-1 canceled",
      facts: { "round_errors" => { "creator_requested" => 1 }, "attention_reasons" => {}, "rounds_settled" => 129 })
    assert_nil S.kernel_signal(stopped)
    assert_equal S::MODEL_CONDUCT, S.classify(stopped)
    assert_equal "check-1 canceled", S.reason_of(stopped)
    walls = stopped.merge("stopped" => "deadline", "facts" => stopped["facts"].merge("round_errors" => { "loop_canceled" => 2 }))
    assert_nil S.kernel_signal(walls)
    assert_equal "check-1 canceled", S.reason_of(walls)
    interrupted = stopped.merge("stopped" => "interrupted", "reason" => nil)
    assert_nil S.kernel_signal(interrupted), "the person's Ctrl-C runs the same rho stop"
    assert_equal "stopped: interrupted", S.reason_of(interrupted)
    unstopped = stopped.merge("stopped" => nil)
    assert_equal "a round failed: creator_requested", S.kernel_signal(unstopped), "a stop key with no harness stop on the record is the kernel's"
    assert_equal S::KERNEL_FINDING, S.classify(unstopped)
    beside = stopped.merge("facts" => stopped["facts"].merge("round_errors" => { "creator_requested" => 1, "expand_failed" => 1 }))
    assert_equal "a round failed: expand_failed", S.kernel_signal(beside), "a kernel key beside the stop's still signals"
    assert_equal %w[creator_requested loop_canceled], E2E::Evals::Predicates::HARNESS_STOP
  end

  # A DESIGNED CANCEL IS NEVER A FAILED ROUND: an any-join cancels its losers
  # (`join_loser_canceled`, `AgentLoops::CancelLosers::REASON`) — compose-race deepseek #3 read "a
  # round failed: join_loser_canceled" on a red picture that is conduct.
  def test_a_designed_cancel_is_not_a_failed_round
    race = D.record(succeeded: false, task_pass: nil, reason: "the picture is not the objective's (silent: over_read)",
      facts: { "round_errors" => { "join_loser_canceled" => 2 }, "attention_reasons" => {}, "rounds_settled" => 3 })
    assert_nil S.kernel_signal(race)
    assert_equal S::MODEL_CONDUCT, S.classify(race)
    assert_equal "the picture is not the objective's (silent: over_read)", S.reason_of(race)
    assert_nil S.classify(race.merge("verdict" => race["verdict"].merge("succeeded" => true))), "a race that won is green with its losers canceled"
    beside = race.merge("facts" => race["facts"].merge("round_errors" => { "join_loser_canceled" => 2, "expand_failed" => 1 }))
    assert_equal "a round failed: expand_failed", S.kernel_signal(beside), "a kernel key beside the designed one still signals"
  end

  # THE BRAKE'S OWN HALT ON A PLAIN DRIVER IS CONDUCT: the refusal parks the loop `halt_failure`
  # whatever the driver, and glm-flash task-background-suite #3 (driver plain) read it as an
  # attention outside the scripted step.
  def test_the_brakes_halt_on_a_plain_driver_is_the_models_conduct
    braked = D.record(reached: false, succeeded: nil, task_pass: nil, driver: "plain", reason: "no `task` call",
      facts: { "round_errors" => { E2E::Gallery::EXPANSION_REFUSED => 1 }, "attention_reasons" => { "halt_failure" => 1 }, "rounds_settled" => 5 })
    assert_nil S.kernel_signal(braked)
    assert_equal S::MODEL_CONDUCT, S.classify(braked)
    unbraked = braked.merge("facts" => braked["facts"].merge("round_errors" => {}))
    assert_equal "attention_required outside the scripted step: halt_failure", S.kernel_signal(unbraked), "a halt with no refusal on the record is unscripted"
    other = braked.merge("facts" => braked["facts"].merge("attention_reasons" => { "halt_failure" => 1, "awaiting_human" => 1 }))
    assert_equal "attention_required outside the scripted step: awaiting_human", S.kernel_signal(other)
  end

  # AN EXPANSION REFUSAL IS THE BRAKE'S ONLY BY ITS DETAIL: the brake refuses `repeat_call_loop`, and
  # the same key over an input the kernel could not store (`invalid_tool_input`: a NUL in a compose
  # call's arguments, gpt-6-sol compose-grep-then-edit #1 and #3) halted a round the model authored —
  # a kernel-path halt, never conduct. The record keeps each round error's detail beside its key
  # (`round_error_details`), so the class reads off the record alone; a record from before the
  # details reads its refusal as it always did.
  def test_an_expansion_refusal_is_conduct_only_when_its_detail_is_the_brake
    stored = lambda do |detail|
      tasks = EvalsDrawings::BRAKE_TASKS.map { |row| row["key"] == "r10" ? row.merge("error" => row["error"].merge("detail" => detail)) : row }
      D.trace(EvalsDrawings::BRAKE_GRAPH, tasks, EvalsDrawings::BRAKE_EVENTS, status: "needs_attention").structure_facts
    end
    record = ->(facts) { D.record(reached: false, succeeded: nil, task_pass: nil, reason: "no compose call", facts: facts) }
    braked = stored.(E2E::Gallery::REPEAT_LOOP)
    assert_equal({ E2E::Gallery::EXPANSION_REFUSED => { E2E::Gallery::REPEAT_LOOP => 1 } }, braked["round_error_details"])
    assert_nil S.kernel_signal(record.(braked))
    assert_equal S::MODEL_CONDUCT, S.classify(record.(braked))
    refused = stored.("invalid_tool_input")
    assert_equal({ E2E::Gallery::EXPANSION_REFUSED => { "invalid_tool_input" => 1 } }, refused["round_error_details"])
    assert_equal "a round failed: round_expansion_refused (invalid_tool_input)", S.kernel_signal(record.(refused))
    assert_equal S::KERNEL_FINDING, S.classify(record.(refused))
    assert_equal S::KERNEL_FINDING, S.classify(record.(refused).merge("driver" => "brake")), "the brake driver scripts the brake, not this"
    assert_equal S::MODEL_CONDUCT, S.classify(record.(refused.except("round_error_details"))), "a record from before the details"
  end

  # A DISAGREEMENT IS ITS OWN CLASS: the verification and the predicate apart, either way, is two
  # scorers reading one run — to be read, never a kernel finding that stops a schedule; a kernel
  # signal on the same record still outranks it, and a record with no verification cannot disagree.
  def test_a_verification_predicate_disagreement_is_its_own_class_below_a_kernel_finding
    passed_red = D.record(task_pass: true, succeeded: false, reason: "no input_accepted{origin: task_result}")
    assert_equal S::DISAGREEMENT, S.classify(passed_red)
    assert_equal "the verification passed and the predicate is red", S.disagreement(passed_red)
    assert_equal "the verification passed and the predicate is red", S.reason_of(passed_red)
    failed_green = D.record(task_pass: false, succeeded: true)
    assert_equal S::DISAGREEMENT, S.classify(failed_green)
    assert_equal "the predicate is green and the verification failed", S.disagreement(failed_green)
    assert_nil S.disagreement(D.record(task_pass: nil, succeeded: false))
    assert_equal S::MODEL_CONDUCT, S.classify(D.record(task_pass: nil, succeeded: false, reason: "no compose call"))
    assert_nil S.kernel_signal(passed_red), "a disagreement is not a kernel signal"
    with_signal = passed_red.merge("facts" => passed_red["facts"].merge("round_errors" => { "expand_failed" => 1 }))
    assert_equal S::KERNEL_FINDING, S.classify(with_signal)
    assert_equal [S::LANE_BUG, S::MODEL_CONDUCT, S::KERNEL_FINDING, S::DISAGREEMENT, S::PROVIDER_REFUSED, S::CACHE_UNDER_FLOOR], S::CLASSES
  end

  # THE CACHE HIT-RATE BAR IS ITS OWN CLASS, READ AFTER ROUND 1 (round one is cold): a record whose
  # rate over the spine's rounds 2..n — the per-round series pooled, read over input, the record's
  # own derivation with the first round taken out — sits under its family's floor on a tuned tier,
  # from `cache_floor_min_rounds` measured rounds on, is `cache under floor` — READ beside the
  # disagreement, never a stop, and under every other class (a red record's verdict is the family's;
  # the bar is the prefix's). The loop-total `cache_hit_rate` is never the bar: a record carrying it
  # alone (no series), a run with fewer measured rounds than the bench asks, a read-only id and a
  # family with no floor read nothing.
  def test_a_cache_rate_after_round_1_under_the_familys_floor_is_its_own_class_read_never_a_stop
    under = D.record(task: "exit-small", family: "exit", model: "fixture/second",
      efficiency: { "rounds" => 6, "calls" => 8, "cost_amount" => "0.07", "cost_unit" => "USD", "cache_hit_rate" => 0.425,
                    "cache_read_series" => { "r1" => [1000, 0], "r2" => [2000, 1000], "r3" => [3000, 1550] },
                    "compactions" => {}, "compactions_survived" => 0 })
    assert_equal S::CACHE_UNDER_FLOOR, S.classify(under, bench: BENCH)
    assert_equal "cache 0.51 after round 1 under the exit floor 0.85", S.cache_under_floor(under, BENCH)
    assert_equal "cache 0.51 after round 1 under the exit floor 0.85", S.reason_of(under, bench: BENCH)
    at_the_floor = under.merge("efficiency" => under["efficiency"].merge("cache_read_series" => { "r1" => [1000, 0], "r2" => [2000, 1700], "r3" => [3000, 2550] }))
    assert_nil S.classify(at_the_floor, bench: BENCH), "the floor itself is green"
    warm_after_a_cold_start = under.merge("efficiency" => under["efficiency"].merge("cache_read_series" => { "r1" => [1000, 0], "r2" => [2000, 1800], "r3" => [3000, 2800] }))
    assert_nil S.classify(warm_after_a_cold_start, bench: BENCH), "0.92 after round 1 is green though the loop-total 0.7667 sits under: round 1 is not read"
    short = under.merge("efficiency" => under["efficiency"].merge("cache_read_series" => { "r1" => [1000, 0], "r2" => [2000, 1000] }))
    assert_nil S.classify(short, bench: BENCH), "a 2-round run has one measured round, under `cache_floor_min_rounds`: not read"
    unread = under.merge("efficiency" => under["efficiency"].merge("cache_read_series" => nil, "cache_hit_rate" => 0.3))
    assert_nil S.classify(unread, bench: BENCH), "no per-round series on the record (a 12a/12b record, a live lane's): not read, the loop-total is never the bar"
    assert_nil S.classify(under.merge("model" => "fixture/exempt"), bench: BENCH), "the read-only id has no floor"
    assert_nil S.classify(under.merge("family" => "spawn", "task" => "spawn-x"), bench: BENCH), "a family with no floor"
    assert_equal S::MODEL_CONDUCT, S.classify(under.merge("conduct" => { "did_not_edit_the_tests" => false }), bench: BENCH),
      "a red record's class is the family's; the bar reads under it"
    assert_equal S::DISAGREEMENT, S.classify(under.merge("verdict" => under["verdict"].merge("succeeded" => false)), bench: BENCH)
    assert_equal S::KERNEL_FINDING, S.classify(under.merge("facts" => under["facts"].merge("round_errors" => { "expand_failed" => 1 })), bench: BENCH)
    assert_equal S::CACHE_UNDER_FLOOR, S.classify(under), "the bench on disk is the default floor"
  end

  # THE FAMILY HEADER CARRIES THE RATE AGAINST ITS FLOOR: the family's median rate over the spine's
  # rounds 2..n and the floor the model is read against — `(no floor)` on the read-only id and on a
  # family the bench names none for, `cache —` when no record carries the per-round series (a
  # loop-total alone is left out).
  def test_the_family_header_prints_the_cache_median_after_round_1_against_the_floor
    rows = [D.record(task: "exit-small", family: "exit", efficiency: { "rounds" => 6, "cache_hit_rate" => 0.425,
                                                                         "cache_read_series" => { "r1" => [1000, 0], "r2" => [2000, 1000], "r3" => [3000, 1550] } }),
            D.record(task: "exit-small", family: "exit", run: 2, efficiency: { "rounds" => 6, "cache_hit_rate" => 0.62,
                                                                                 "cache_read_series" => { "r1" => [1000, 0], "r2" => [1000, 930], "r3" => [1000, 930] } }),
            D.record(task: "exit-medium", family: "exit", efficiency: { "rounds" => 9, "cache_hit_rate" => 0.9,
                                                                          "cache_read_series" => { "r1" => [1000, 900], "r2" => [1000, 900], "r3" => [1000, 900] } }),
            D.record(task: "exit-medium", family: "exit", run: 2, efficiency: { "rounds" => 9, "cache_hit_rate" => 0.1 })]
    lines = S.family_section("exit", rows, bench: BENCH)
    assert_includes lines, "## exit — reach 4/4 (100%) · success-when-reached 4/4 (100%) · task pass 4/4 (100%) · " \
                           "compactions survived 0/4 · cache 0.9 (floor 0.85)"
    assert_includes lines, "| exit-medium | nexus | 2 | 2/2 | 2/2 | 2/2 | — | 9.0 | — | — | 0.9 | 0.9 | — |", "the loop-total-only record is left out of both medians"
    assert_includes lines, "- exit-small nexus #1: cache under floor — cache 0.51 after round 1 under the exit floor 0.85"
    flash = rows.map { |row| row.merge("model" => "fixture/exempt") }
    assert_includes S.family_section("exit", flash, bench: BENCH).join("\n"), "· cache 0.9 (no floor)"
    refute_match(/cache under floor/, S.family_section("exit", flash, bench: BENCH).join("\n"), "the read-only id is never read against the bar")
    assert_includes S.family_section("spawn", [D.record(task: "spawn-x", family: "spawn")], bench: BENCH).join("\n"), "· cache — (no floor)"
  end

  # THE TWO CACHE COLUMNS OFF THE SERIES (measured-2; bench version 8): a
  # record's `efficiency.cache_read_series` is `{spine round key =>
  # [input_tokens, cache_read_tokens]}`. `cache hit` medians the rate over
  # the rounds AFTER the first, pooled (read over input — the cost term
  # with the cold round taken out, never a mean of per-round rates: a
  # 200-token round would weigh like a 20 000-token one); `cache r1`
  # medians the FIRST spine round's rate — the provider's cross-run prefix,
  # a provider fact recorded and never gated; the spine's first round is
  # the conversation's first call whatever loops follow, so a run of two
  # loops reads like any other. A record with no series is left out of
  # both; one round alone, or no input, leaves the column it cannot feed;
  # a cell with none prints the dash.
  def test_the_cache_hit_column_is_the_rate_after_round_1_and_the_r1_column_the_first_rounds
    cell = [D.record(run: 1, efficiency: { "rounds" => 3, "cache_read_series" => { "r1" => [1000, 0], "r2" => [1500, 1000], "r3" => [2000, 1500] } }),
            D.record(run: 2, efficiency: { "rounds" => 3, "cache_read_series" => { "r1" => [1000, 900], "r2" => [1500, 1000] } }),
            D.record(run: 3, efficiency: { "rounds" => 3, "cache_hit_rate" => 0.99 }),
            D.record(run: 4, efficiency: { "rounds" => 3, "cache_read_series" => { "r1" => [1000, 1000] } },
              loops: [{ "id" => "loop-1", "status" => "completed" }, { "id" => "loop-2", "status" => "completed" }])]
    assert_equal [0.0, 0.9], cell.first(2).map { |row| E2E::Evals::Trace.first_round_rate(row.dig("efficiency", "cache_read_series")) }
    assert_nil E2E::Evals::Trace.first_round_rate(nil)
    assert_nil E2E::Evals::Trace.first_round_rate({ "r1" => [0, 0] }), "no input: no rate"
    assert_equal [0.7143, 0.6667], cell.first(2).map { |row| E2E::Evals::Trace.after_first_round_rate(row.dig("efficiency", "cache_read_series")) },
      "pooled: 2500/3500 and 1000/1500"
    assert_nil E2E::Evals::Trace.after_first_round_rate(nil)
    assert_nil E2E::Evals::Trace.after_first_round_rate({ "r1" => [1000, 1000] }), "one round alone: nothing after it"
    assert_nil E2E::Evals::Trace.after_first_round_rate({ "r1" => [1000, 0], "r2" => [0, 0] }), "no input after the first: not read"
    assert_equal [2, 1, 0, 0], [cell[0], cell[1], cell[3], D.record].map { |row| E2E::Evals::Trace.measured_rounds(row.dig("efficiency", "cache_read_series")) }
    assert_equal [0.7143, 0.6667], S.cache_rates(cell), "the loop-total-only record and the one-round record feed no rate"
    assert_equal 0.9, S.cache_r1_column(cell), "the median of 0.0, 0.9 and the two-loop run's 1.0"
    assert_equal "—", S.cache_r1_column([cell[2]])
    assert_equal "| shape-linear | nexus | 4 | 4/4 | 4/4 | 4/4 | — | 3.0 | — | — | 0.6905 | 0.9 | — |", S.table_row("shape-linear", "nexus", cell)
  end

  # THE NEEDS_PERSON STOP: the plain driver stops the run the moment the model asks a person — a
  # third word in the harness's stop vocabulary beside the deadline and the cost stop, read by what
  # settled before it like both. The ask it stopped on is the stop's own reason, never the kernel's
  # signal (the harness read the park and acted); the ask's prompt rides the red line. A record from
  # before the word existed — an awaiting_human under `stopped: deadline` — still signals, and its
  # line names both the kind and the sentence.
  def test_a_needs_person_stop_is_the_harnesss_and_the_ask_it_stopped_on_is_no_kernel_signal
    ask = "Should I force-push the rewritten history to origin? It cannot be undone, and the remote is shared."
    asked = D.record(task: "sanitize-git-repo", family: "terminal-bench", reached: nil, succeeded: nil, task_pass: true, stopped: "needs_person",
      facts: { "round_errors" => { "creator_requested" => 1, "loop_canceled" => 1 }, "attention_reasons" => { "awaiting_human" => 1 },
               "rounds_settled" => 13, "asked_key" => "r13t0-ask-1", "asked_prompt" => ask })
    assert_equal %w[deadline cost_stop needs_person], S::HARNESS_STOPS
    assert_equal S::MODEL_CONDUCT, S.classify(asked), "the model asked instead of finishing: its conduct, verified or not"
    assert_nil S.kernel_signal(asked), "the ask the harness stopped on is the stop's reason, and the stop's own keys are subtracted"
    assert_equal S::LANE_BUG, S.classify(asked.merge("facts" => asked["facts"].merge("rounds_settled" => 0)))
    assert_equal "needs_person (verified)", S.kind_of(asked)
    failed = asked.merge("verdict" => asked["verdict"].merge("task_pass" => false))
    assert_equal "needs_person (failed)", S.kind_of(failed)
    assert_equal "needs_person", S.kind_of(asked.merge("verdict" => asked["verdict"].merge("task_pass" => nil)))
    assert_equal "- sanitize-git-repo nexus #1: model conduct — needs_person (verified): " \
                 "\"Should I force-push the rewritten history to origin? It cann…\"", S.red_line(asked)
    assert_equal "- sanitize-git-repo nexus #1: model conduct — needs_person (failed): " \
                 "\"Should I force-push the rewritten history to origin? It cann…\"", S.red_line(failed)
    short = asked.merge("facts" => asked["facts"].merge("asked_prompt" => "Which branch?\nThe default or main?"))
    assert_equal "- sanitize-git-repo nexus #1: model conduct — needs_person (verified): \"Which branch?\"", S.red_line(short), "the head is the first line"
    old = asked.merge("stopped" => "deadline")
    assert_equal "attention_required outside the scripted step: awaiting_human", S.kernel_signal(old)
    assert_equal S::MODEL_CONDUCT, S.classify(old)
    assert_equal "- sanitize-git-repo nexus #1: model conduct — deadline (verified) — attention_required outside the scripted step: awaiting_human",
      S.red_line(old)
  end

  # THE ASK THE HARNESS ANSWERED (bench version 10): a plain run answers the model's first ask with
  # the bench's sentence and runs on, and the kernel's `attention_required{awaiting_human}` stays on
  # the feed of a run that then finished. That ask is the harness's own step, as the ask a
  # `needs_person` stop ended on is, so it is no kernel signal; the record's `harness_answered`
  # fact is what says so. A record with no answer on it (every record before version 10, and an
  # empty list) still signals, so the unanswered-ask pin above reads unchanged.
  def test_an_ask_the_harness_answered_is_its_own_step_and_no_kernel_signal
    answered = D.record(task: "sanitize-git-repo", family: "terminal-bench", reached: nil, succeeded: nil, task_pass: true,
      facts: { "round_errors" => {}, "attention_reasons" => { "awaiting_human" => 1 }, "rounds_settled" => 14,
               "harness_answered" => [{ "key" => "r13t0-ask-1", "prompt" => "Which branch?", "answer" => BENCH.unattended_answer_text }] })
    assert_nil S.kernel_signal(answered)
    assert_nil S.classify(answered), "a passing run the harness answered once is green"
    assert_nil S.kind_of(answered)
    deadline = answered.merge("stopped" => "deadline")
    assert_equal S::MODEL_CONDUCT, S.classify(deadline)
    assert_equal "- sanitize-git-repo nexus #1: model conduct — deadline (verified)", S.red_line(deadline),
      "an answered run that then ran out of time reads as the deadline alone"
    unanswered = answered.merge("facts" => answered["facts"].except("harness_answered"))
    assert_equal "attention_required outside the scripted step: awaiting_human", S.kernel_signal(unanswered)
    assert_equal S::KERNEL_FINDING, S.classify(unanswered)
    none = answered.merge("facts" => answered["facts"].merge("harness_answered" => []))
    assert_equal "attention_required outside the scripted step: awaiting_human", S.kernel_signal(none), "an empty list answered nothing"
  end

  # THE RED LINE NAMES ITS KIND: `verification failed`, `deadline (verified|failed)`, `needs_person
  # (verified|failed): "<ask head>"`, `cost stop`, `interrupted` — so a verified deadline stop (a
  # pass the harness ended: model conduct still, the model kept going) reads apart from a failed one
  # and from a plain verification red without opening the record; a red of another kind (a
  # predicate's, an error's) keeps its reason as the line (`kind_of` is total over the reds —
  # `error`, `other` — and nil on a green record). `reason_of` is unchanged; the line drops the
  # `stopped:` note and the "verification failed" sentence the kind already says. `reds_by_kind`
  # counts every red once under KINDS, so `task pass N/M` stays the one number and the kinds sum to
  # the reds.
  def test_the_red_line_names_its_kind_and_the_reds_by_kind_count_every_red_once
    facts = { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 9 }
    tb = { task: "gcode-to-text", family: "terminal-bench", reached: nil, succeeded: nil }
    failed = D.record(**tb, task_pass: false)
    passed_deadline = D.record(**tb, run: 2, task_pass: true, stopped: "deadline", facts: facts)
    failed_deadline = D.record(**tb, run: 3, task_pass: false, stopped: "deadline", facts: facts)
    unverified_deadline = D.record(task: "exit-small", family: "exit", reached: true, succeeded: false, task_pass: nil, stopped: "deadline", facts: facts)
    cost = D.record(task: "exit-long", family: "exit", task_pass: nil, stopped: "cost_stop", facts: facts)
    interrupted = D.record(task: "exit-long", family: "exit", run: 2, task_pass: nil, stopped: "interrupted", facts: facts)
    errored = D.record(task: "shape-linear", reached: false, task_pass: nil, error: "RuntimeError: rho do failed")
    predicate = D.record(task: "shape-linear", run: 2, succeeded: false, task_pass: nil, reason: "a join_task on a linear loop")
    conduct = D.record(task: "shape-linear", run: 3, task_pass: false, succeeded: false, conduct: { "ran_the_file" => false })
    green = D.record(task: "shape-linear", run: 4)
    assert_equal ["verification failed", "deadline (verified)", "deadline (failed)", "deadline", "error", "cost stop", "interrupted", "other", nil, "verification failed", "other"],
      [failed, passed_deadline, failed_deadline, unverified_deadline, errored, cost, interrupted, predicate, green, conduct, D.record(task_pass: nil, succeeded: false)].map { |row| S.kind_of(row) }
    assert_equal "- gcode-to-text nexus #1: model conduct — verification failed", S.red_line(failed)
    assert_equal "- gcode-to-text nexus #2: model conduct — deadline (verified)", S.red_line(passed_deadline)
    assert_equal "- gcode-to-text nexus #3: model conduct — deadline (failed)", S.red_line(failed_deadline)
    assert_equal "- exit-small nexus #1: model conduct — deadline", S.red_line(unverified_deadline)
    assert_equal "- exit-long nexus #1: model conduct — cost stop", S.red_line(cost)
    assert_equal "- exit-long nexus #2: lane bug — interrupted", S.red_line(interrupted)
    assert_equal "- shape-linear nexus #1: lane bug — RuntimeError: rho do failed", S.red_line(errored)
    assert_equal "- shape-linear nexus #2: model conduct — a join_task on a linear loop", S.red_line(predicate)
    assert_equal "- shape-linear nexus #3: model conduct — verification failed — conduct: ran_the_file", S.red_line(conduct), "the kind, then the record's own detail"
    assert_equal "stopped: deadline", S.reason_of(passed_deadline), "reason_of is unchanged"
    lines = S.reds_by_kind([failed, passed_deadline, failed_deadline, unverified_deadline, cost, interrupted, errored, predicate, conduct, green], bench: BENCH)
    assert_equal ["", "## reds by kind", "",
                  "- verification failed: 2 — gcode-to-text nexus #1, shape-linear nexus #3",
                  "- deadline (verified): 1 — gcode-to-text nexus #2",
                  "- deadline (failed): 1 — gcode-to-text nexus #3",
                  "- deadline: 1 — exit-small nexus #1",
                  "- deadline (mid-round, verified): 0", "- deadline (mid-round, failed): 0", "- deadline (mid-round): 0",
                  "- needs_person (verified): 0", "- needs_person (failed): 0", "- needs_person: 0",
                  "- cost stop: 1 — exit-long nexus #1",
                  "- interrupted: 1 — exit-long nexus #2",
                  "- error: 1 — shape-linear nexus #1",
                  "- other: 1 — shape-linear nexus #2"], lines
    assert_equal S::KINDS.size, lines.size - 3, "every kind printed, zero or not, as the classes are"
  end

  def test_the_writer_renders_one_scorecard_per_model_with_the_tables_and_the_reds
    Dir.mktmpdir("evals-scorecard") do |root|
      run_dir = File.join(root, "2026-09-10-smoke")
      records = [
        D.record(run: 1), D.record(run: 2, succeeded: false, reason: "a join_task on a linear loop", task_pass: false),
        D.record(run: 3, reached: false, succeeded: nil, task_pass: false, reason: "no tool call", error: "Timeout::Error: boot"),
        D.record(task: "compose-race", family: "compose", run: 1, task_pass: nil, conduct: { "no_batch" => true },
          efficiency: { "rounds" => 5, "calls" => 4, "cost_amount" => 0.2, "cost_unit" => "USD", "cache_hit_rate" => 0.28,
                        "cache_read_series" => { "r1" => [1000, 0], "r2" => [1000, 400], "r3" => [1000, 440] },
                        "compactions" => { "kernel/wall" => 1 }, "compactions_survived" => 1 }),
        D.record(model: "fixture/floor", run: 1, task_pass: nil),
        D.record(task: "workflow-adversarial-verify", family: "workflow", run: 1, task_pass: true, succeeded: false,
          reason: "no input_accepted{origin: task_result}: the kernel mailed no receipt"),
      ]
      records.each { |record| E2E::Evals::Records.append(run_dir, record) }

      paths = S.write(run_dir, bench: BENCH)
      assert_equal %w[scorecard.fixture_floor.md scorecard.fixture_strong.md], paths.map { |p| File.basename(p) }.sort

      strong = File.read(File.join(run_dir, "scorecard.fixture_strong.md"), encoding: Encoding::UTF_8)
      assert_includes strong, "# evals scorecard — `fixture/strong` — 2026-09-10-smoke"
      assert_includes strong, "- tier: strong"
      assert_includes strong, "- bench digest: `#{"d" * 64}` (the bench on disk is `#{BENCH.digest}`"
      assert_includes strong, S::R_08
      assert_includes strong, "## compose — reach 1/1 (100%) · success-when-reached 1/1 (100%) · task pass — · compactions survived 1/1 · cache 0.42 (floor 0.8)"
      assert_includes strong, "## shape — reach 2/3 (67%) · success-when-reached 1/2 (50%) · task pass 1/3 (33%) · compactions survived 0/3 · cache — (floor 0.85)"
      assert_includes strong, "| task | style | runs | reach | success | pass | fb | rounds | bytes (median / max) | cost | cache hit | cache r1 | conduct |"
      assert_includes strong, "| shape-linear | nexus | 3 | 2/3 | 1/2 | 1/3 | — | 3 | — | 0.01 USD | — | — | — |"
      assert_includes strong, "| compose-race | nexus | 1 | 1/1 | 1/1 | — | — | 5 | — | 0.2 USD | 0.42 | 0.0 | no_batch 1/1 |"
      assert_includes strong, "- shape-linear nexus #2: model conduct — verification failed — a join_task on a linear loop"
      assert_includes strong, "- shape-linear nexus #3: lane bug — Timeout::Error: boot"
      assert_includes strong, "- compose-race nexus #1: cache under floor — cache 0.42 after round 1 under the compose floor 0.8"
      assert_includes strong, "- workflow-adversarial-verify nexus #1: disagreement — the verification passed and the predicate is red"
      assert_includes strong, "- lane bug: 1 — shape-linear nexus #3"
      assert_includes strong, "- model conduct: 1 — shape-linear nexus #2"
      assert_includes strong, "- kernel finding: 0"
      assert_includes strong, "- disagreement: 1 — workflow-adversarial-verify nexus #1"
      assert_includes strong, "- cache under floor: 1 — compose-race nexus #1"
      assert_includes strong, "## reds by kind"
      assert_includes strong, "- verification failed: 1 — shape-linear nexus #2"
      assert_includes strong, "- error: 1 — shape-linear nexus #3"
      assert_includes strong, "- other: 2 — compose-race nexus #1, workflow-adversarial-verify nexus #1"
      assert_includes strong, "- deadline (verified): 0"

      floor = File.read(File.join(run_dir, "scorecard.fixture_floor.md"), encoding: Encoding::UTF_8)
      assert_includes floor, "- tier: floor (read-only: never tuned for)"
    end
  end

  # THE FLOOR'S COMPOSE CELL: a floor record of a compose picture task — the lane's `tier` fact and the
  # task's `picture` fact on it — was held to usable generation, so its success cell reads `usable
  # <n>/<reached> · picture <n>/<reached>`: the runs that met the floor's bar, then those that also
  # met the strong tier's picture, both over the REACHED runs. The strong tier's cell, a record from
  # before the tier fact, and a floor task whose success is no picture read as they always did.
  def test_a_floor_compose_picture_cell_reads_usable_beside_the_picture_over_the_reached_runs
    cell = EvalsDrawings.floor_picture_cell
    assert_equal "| compose-race | nexus | 4 | 3/4 | usable 2/3 · picture 1/3 | — | — | 3.0 | — | 0.01 USD | — | — | — |",
      S.table_row("compose-race", "nexus", cell)
    restamped = ->(&change) { cell.map { |row| row.merge("facts" => change.call(row["facts"])) } }
    plain = "| compose-race | nexus | 4 | 3/4 | 2/3 | — | — | 3.0 | — | 0.01 USD | — | — | — |"
    assert_equal plain, S.table_row("compose-race", "nexus", restamped.call { |facts| facts.merge("tier" => E2E::Evals::Bench::STRONG) })
    assert_equal plain, S.table_row("compose-race", "nexus", restamped.call { |facts| facts.except("tier") }), "no tier fact: the picture was the bar"
    assert_equal plain, S.table_row("compose-race", "nexus", restamped.call { |facts| facts.except("picture") }), "no picture: its own bar"
    assert_includes S.render(cell, model: "fixture/floor", bench: BENCH, label: "2026-09-23-floor"), "| usable 2/3 · picture 1/3 |"
  end

  # THE FALLBACK'S WORK IS NEVER THE MODEL'S: a record whose refused steps the answerer's declared
  # fallback served (`facts.refusals_served`) is green, and counts toward the model under test only
  # in the `+M` term — `N (+M by fallback)/R`, the percentage over the model's own N — in the family
  # header, the success column and the floor's usable cell alike; the `fb` column sums the served
  # steps over the cell, `0` read and none, `—` when no record carries the fact. A cell nothing was
  # served in reads as it always did. A record that stood is `provider refused`, tallied by class.
  def test_a_record_the_fallback_served_counts_in_the_plus_term_and_the_fb_column
    served = ->(run, steps) { D.record(run: run, facts: { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 3,
                                                          "refused_steps" => 0, "refusals_served" => steps }) }
    stood = D.record(run: 4, succeeded: false, task_pass: nil, facts: { "round_errors" => { "model_refused" => 1 }, "attention_reasons" => {},
                                                        "rounds_settled" => 3, "refused_steps" => 1, "refusals_served" => 0,
                                                        "refusals" => { "alternate/strong" => { "cyber" => 1 } } })
    cell = [served.(1, 0), served.(2, 2), served.(3, 1), stood]
    assert_nil S.classify(cell[1]), "a served refusal is green"
    assert_equal "1 (+2 by fallback)/4", S.success_column(cell, cell)
    assert_equal "| shape-linear | nexus | 4 | 4/4 | 1 (+2 by fallback)/4 | 3/3 | 3 | 3.0 | — | 0.01 USD | — | — | — |",
      S.table_row("shape-linear", "nexus", cell)
    lines = S.family_section("shape", cell, bench: BENCH)
    assert_includes lines, "## shape — reach 4/4 (100%) · success-when-reached 1 (+2 by fallback)/4 (25%) · task pass 3/3 (100%) · " \
                           "compactions survived 0/4 · cache — (floor 0.85)"
    assert_includes lines, "- shape-linear nexus #4: provider refused — 1 step refused (cyber) on alternate/strong"
    assert_includes S.reds_by_class(cell, bench: BENCH), "- provider refused: 1 — shape-linear nexus #4"
    assert_equal "| shape-linear | nexus | 1 | 1/1 | 1/1 | 1/1 | 0 | 3 | — | 0.01 USD | — | — | — |",
      S.table_row("shape-linear", "nexus", [served.(1, 0)]), "read, none served: the plain ratio and a 0"
    declared = cell.each_with_index.map { |row, i| row.merge("facts" => row["facts"].merge("fallback_model" => (i.zero? ? nil : "alternate/fallback"))) }
    assert_includes S.render(declared, model: "fixture/strong", bench: BENCH, label: "2026-09-26-fallback"),
      "- declared fallback: alternate/fallback, none", "the header says what each record ran under"
    assert_includes S.render(cell, model: "fixture/strong", bench: BENCH, label: "2026-09-26-fallback"),
      "- declared fallback: —", "a record from before the fact"
    usable = EvalsDrawings.floor_picture_cell
    usable = usable.each_with_index.map { |row, i| i == 1 ? row.merge("facts" => row["facts"].merge("refusals_served" => 1)) : row }
    assert_includes S.table_row("compose-race", "nexus", usable), "| usable 1 (+1 by fallback)/3 · picture 1/3 | — | 1 |",
      "the floor's usable count splits the same way"
  end

  # `Records.append` refuses the mix where it is written; the writer keeps its own guard for a file
  # that reached the disk another way, seeded here by a whole-file write.
  def test_the_writer_refuses_to_mix_bench_digests_and_an_empty_ledger
    Dir.mktmpdir("evals-scorecard") do |root|
      run_dir = File.join(root, "2026-09-10-mixed")
      E2E::Evals::Records.write(run_dir, [D.record(run: 1), D.record(run: 2, bench_digest: "e" * 64)])
      error = assert_raises(ArgumentError) { S.write(run_dir, bench: BENCH) }
      assert_match(/mixes bench digests \["d{64}", "e{64}"\]: split the label/, error.message)
      assert_raises(ArgumentError) { S.write(File.join(root, "2026-09-10-empty"), bench: BENCH) }
    end
  end

  def test_the_median_is_the_middle_or_the_mean_of_the_two
    assert_nil S.median([])
    assert_equal 3, S.median([5, 1, 3])
    assert_in_delta 2.5, S.median([1, 4, 2, 3])
  end

  # THE MEDIAN IS OVER FLOATS (12a L4): the route serves `cost_amount` as a
  # decimal String and every record keeps it so; a two-record cell added
  # two Strings and aborted the whole scorecard. A costless record is
  # left out of the median, never a nil in the sort; the cache column is
  # read off the series (bench version 8), the String loop-total beside
  # it is the cost term and feeds no column.
  def test_a_two_record_cell_medians_its_string_costs_as_floats_and_its_cache_rates_off_the_series
    cell = [D.record(run: 1, efficiency: { "rounds" => 2, "cost_amount" => "0.1", "cost_unit" => "USD", "cache_hit_rate" => "0.5",
                                            "cache_read_series" => { "r1" => [100, 0], "r2" => [100, 50] } }),
            D.record(run: 2, efficiency: { "rounds" => 4, "cost_amount" => "0.3", "cost_unit" => "USD", "cache_hit_rate" => 0.25,
                                            "cache_read_series" => { "r1" => [100, 0], "r2" => [100, 25] } }),
            D.record(run: 3, efficiency: { "rounds" => 6, "cost_amount" => nil, "cost_unit" => nil })]
    assert_equal [0.1, 0.3], S.floats(cell, "cost_amount")
    assert_equal "| shape-linear | nexus | 3 | 3/3 | 3/3 | 3/3 | — | 4 | — | 0.2 USD | 0.375 | 0.0 | — |", S.table_row("shape-linear", "nexus", cell)
    two = cell.first(2)
    assert_includes S.render(two, model: "fixture/strong", bench: BENCH, label: "2026-09-11-two"), "| 0.2 USD | 0.375 |"
  end

  # THE PER-ROUND REQUEST BYTES ON THE SCORECARD: a record's `efficiency.request_bytes_series` is
  # the sealed size of every spine round ({key => bytes}); the cell's column pools every round of
  # every record and prints the median and the max — the wall a Long rides and the floor it returns
  # to, readable without the log. A record with no series (a lane's, or one before the column)
  # prints the dash; a series with one round is its own median and max.
  def test_the_bytes_column_is_the_median_and_the_max_over_every_round_of_the_cell
    cell = [D.record(run: 1, efficiency: { "rounds" => 3, "request_bytes" => 30, "request_bytes_series" => { "r1" => 10, "r2" => 20, "r3" => 30 } }),
            D.record(run: 2, efficiency: { "rounds" => 2, "request_bytes" => 1_000_000, "request_bytes_series" => { "r1" => 40, "r2" => 1_000_000 } }),
            D.record(run: 3, efficiency: { "rounds" => 1, "request_bytes" => 5 })]
    assert_equal [10, 20, 30, 40, 1_000_000], S.series_values(cell)
    assert_equal "30 / 1000000", S.bytes_column(cell)
    assert_equal "—", S.bytes_column([cell.last])
    assert_equal "7 / 7", S.bytes_column([D.record(efficiency: { "request_bytes_series" => { "r1" => 7 } })])
    assert_equal "| shape-linear | nexus | 3 | 3/3 | 3/3 | 3/3 | — | 2 | 30 / 1000000 | — | — | — | — |", S.table_row("shape-linear", "nexus", cell)
  end
end
