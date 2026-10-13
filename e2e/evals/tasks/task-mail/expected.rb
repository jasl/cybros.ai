reran = ->(trace) { Array(trace.fact(:turn_2_bash_commands)).any? { |c| c.match?(/all\.rb|calc_test|_test\.rb/) } }
named = ->(trace) { trace.fact(:turn_2_reply).to_s.include?("test_subtracts") }
Expected.new(
  reach: lambda do |trace|
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
           "d4_right" => ->(trace) { Predicates.d4_right(trace, TaskBench::Objectives::SUITE) } }.merge(DOOR_FACTS)
)
