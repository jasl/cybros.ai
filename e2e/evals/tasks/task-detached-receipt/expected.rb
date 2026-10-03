# REACH: a `task` row, and the job did not go through compose — no compose
# row in or before the round that handed it out (a compose after the task
# is `compose_after_task`, a fact); `d4_right` is the D4 door objective's
# rule over that round. SUCCESS: the gallery's `detached_receipt?` — the
# branch root under the call, the call's continuation NOT reachable from
# it (detached), the receipt accepted as kernel mail, a second loop
# completed on the feed. The woken turn is OWED: the instruction asks to be
# told whether the suite passed once it finishes, which only a turn the
# receipt wakes can say, so a receipt every call asked `wake: "passive"`
# for (the driver's `wake_passive`) is an instruction miss — red, its
# sentence naming the wake.
Expected.new(
  reach: lambda do |trace|
    composed = Predicates.job_not_composed(trace)
    next composed unless composed == true

    trace.task_rows.any? ? true : "no `task` call: turn 1 called #{trace.fact(:turn_1_called).inspect}"
  end,
  success: lambda do |trace|
    shape = Gallery.detached_receipt?(*trace.triple)
    next shape if shape == true || trace.fact(:receipt_woke_a_turn) != false || trace.fact(:wake_passive) != true

    "#{shape} — the call asked `wake: \"passive\"`, so no turn told the person whether the suite passed"
  end,
  facts: { "reply_final_with_background" => ->(trace) { trace.fact(:reply_final_with_background) == true },
           "receipt_woke_a_turn" => ->(trace) { trace.fact(:receipt_woke_a_turn) == true },
           "d4_right" => ->(trace) { Predicates.d4_right(trace, TaskBench::Objectives::SUITE) },
           "compose_after_task" => ->(trace) { Predicates.compose_after_task(trace) } }.merge(DOOR_FACTS)
)
