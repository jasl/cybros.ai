# THE task-mail TWIN ON A SPAWN. REACH: turn 1 spawned a child (a `spawn` row). SUCCESS: the spawn
# did not wait (the person said not to), the kernel mailed the child's reply as `origin: child`, the
# mail woke a turn, that turn sits on the timeline before turn 2, and turn 2 named the failing test
# FROM the reply without re-running the suite — the task family's six facts, read on a child's reply
# instead of a receipt. The child's fix is the verification's. The wake is the model's to choose,
# as task-mail's is: a reply every spawn asked `wake: "passive"` for (the driver's `wake_passive`)
# owes no woken turn — it joins the history as a message turn, and turn 2 must read it there;
# `reply_woke_a_turn` stays on the record as a fact.
reran = ->(trace) { Array(trace.fact(:turn_2_bash_commands)).any? { |c| c.match?(/all\.rb|calc_test|_test\.rb/) } }
named = ->(trace) { trace.fact(:turn_2_reply).to_s.include?("test_subtracts") }
spawn_rows = ->(trace) { trace.tool_rows("spawn") }
Expected.new(
  reach: ->(trace) { spawn_rows.call(trace).any? ? true : "no `spawn` call: turn 1 called #{trace.fact(:turn_1_called).inspect}" },
  success: lambda do |trace|
    next "the spawn waited (wait: true): the person said not to wait" if trace.fact(:spawn_waited) == true
    owed = { "child_replied" => "the kernel mailed no child reply (input_accepted{origin: child}) within 300 s",
             "reply_woke_a_turn" => "the child's reply woke no turn",
             "mail_in_turn_2_history" => "the child's reply turn is not before turn 2 on the timeline" }
    owed = owed.except("reply_woke_a_turn") if trace.fact(:wake_passive) == true
    missing = owed.find { |name, _why| trace.fact(name) != true }
    next missing.last if missing
    next "turn 2 did not name test_subtracts: #{trace.fact(:turn_2_reply).to_s.strip[0, 80].inspect}" unless named.call(trace)
    next "turn 2 re-ran the suite" if reran.call(trace)

    true
  end,
  facts: { "named_the_failing_test" => named, "reran_the_suite" => reran,
           "spawn_calls" => ->(trace) { spawn_rows.call(trace).size },
           "spawn_agent" => ->(trace) { spawn_rows.call(trace).map { |row| trace.input_of(row)["agent"] }.compact },
           "child_receipts" => ->(trace) { trace.receipts } }
)
