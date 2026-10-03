# live_task_mail's `mail`, its columns as facts. REACH: turn 1 started a
# `task`, and the job did not go through compose — no compose row in or
# before the round that handed it out (`Predicates.job_not_composed`); a
# compose after the task is `compose_after_task`, a fact. `d4_right` is the
# D4 door objective's rule over that round (one background `task` naming
# the suite, no `start_process`, no compose), `door_calls` its rows. SUCCESS: the reply went final with the branch running (`rho
# watch` said `background:`), the kernel mailed the receipt, the mail
# woke a turn, the mail sits in turn 2's history, turn 2 named the
# failing test FROM the mail and did not re-run the suite. THE WAKE IS
# THE MODEL'S TO CHOOSE here: the instruction asks only for the count now
# and turn 2's answer later, so a run whose every call asked `wake:
# "passive"` (the driver's `wake_passive`) owes no woken turn — the
# receipt joins the history as a message turn, and turn 2 must read it
# there; `receipt_woke_a_turn` stays on the record as a fact.
reran = ->(trace) { Array(trace.fact(:turn_2_bash_commands)).any? { |c| c.match?(/all\.rb|calc_test|_test\.rb/) } }
named = ->(trace) { trace.fact(:turn_2_reply).to_s.include?("test_subtracts") }
Expected.new(
  reach: lambda do |trace|
    composed = Predicates.job_not_composed(trace)
    next composed unless composed == true

    trace.task_rows.any? ? true : "no `task` call: turn 1 called #{trace.fact(:turn_1_called).inspect}"
  end,
  success: lambda do |trace|
    owed = { "reply_final_with_background" => "the reply waited for the suite (no `background:` line on rho watch)",
             "mailed" => "the kernel mailed no receipt within 300 s", "receipt_woke_a_turn" => "the receipt woke no turn",
             "mail_in_turn_2_history" => "the receipt's turn is not before turn 2 on the timeline" }
    owed = owed.except("receipt_woke_a_turn") if trace.fact(:wake_passive) == true
    missing = owed.find { |name, _why| trace.fact(name) != true }
    next missing.last if missing
    next "turn 2 did not name test_subtracts: #{trace.fact(:turn_2_reply).to_s.strip[0, 80].inspect}" unless named.call(trace)
    next "turn 2 re-ran the suite" if reran.call(trace)

    true
  end,
  facts: { "named_the_failing_test" => named, "reran_the_suite" => reran,
           "d4_right" => ->(trace) { Predicates.d4_right(trace, TaskBench::Objectives::SUITE) },
           "compose_after_task" => ->(trace) { Predicates.compose_after_task(trace) } }.merge(DOOR_FACTS)
)
