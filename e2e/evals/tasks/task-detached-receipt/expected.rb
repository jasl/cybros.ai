Expected.new(
  reach: lambda do |trace|
    trace.task_rows.any? ? true : "no `task` call: turn 1 called #{trace.fact(:turn_1_called).inspect}"
  end,
  success: lambda do |trace|
    shape = Gallery.detached_receipt?(*trace.triple)
    next shape if shape == true || trace.fact(:receipt_woke_a_turn) != false || trace.fact(:wake_passive) != true

    "#{shape} — the call asked `wake: \"passive\"`, so no turn told the person whether the suite passed"
  end,
  facts: { "reply_final_with_background" => ->(trace) { trace.fact(:reply_final_with_background) == true },
           "receipt_woke_a_turn" => ->(trace) { trace.fact(:receipt_woke_a_turn) == true },
           "d4_right" => ->(trace) { Predicates.d4_right(trace, TaskBench::Objectives::SUITE) } }.merge(DOOR_FACTS)
)
