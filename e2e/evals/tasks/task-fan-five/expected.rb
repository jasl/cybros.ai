# live_task_mail's `fan`: REACH: five `task` calls in the FIRST message
# (fanned by r1). SUCCESS: the merged reply names all five files, no file
# was delegated twice, no graph verb inside a branch, the loop completed.
# THE MERGE IS READ WHERE IT LANDED: a waited fan merges in turn 1, a
# detached one in a turn a receipt woke, so the merge is the first reply
# naming all five in the order the run recorded them at the quiet point
# (`replies`: turn 1's, then each woken turn's) — else the run's `reply`:
# the last loop's under `settle_receipts`, turn 1's on a `plain`-driver
# record (all a trace from before the lane recorded `replies` holds).
# `merge_turn` names the turn (`primary`, `woken-N`; nil when no reply
# named all five) and `waited` whether any call waited: facts, never a pass
# condition. `orphans_named` counts on the reply the merge is read on.
files = %w[a b c d e]
names_all = ->(text) { files.all? { |f| text.include?("#{f}.rb") } }
merge = lambda do |trace|
  replies = trace.fact(:replies)
  turns = replies.nil? ? [["primary", trace.reply]] : replies.values.each_with_index.map { |text, i| [i.zero? ? "primary" : "woken-#{i}", text.to_s] }
  turns.find { |_turn, text| names_all.(text) }
end
merged = ->(trace) { merge.(trace)&.last || trace.reply }
Expected.new(
  reach: lambda do |trace|
    n = Predicates.first_round_task_rows(trace).size
    n >= 5 ? true : "#{n} task call(s) in the first message, not five: #{trace.first_round_rows.map { |r| r["tool_name"] }.tally.inspect}"
  end,
  success: lambda do |trace|
    reply = merged.(trace)
    missing = files.reject { |f| reply.include?("#{f}.rb") }
    next "the merged reply names no lib/#{missing.first}.rb" unless missing.empty?

    twice = Predicates.per_file(trace, files.map { |f| "#{f}.rb" }).select { |_f, n| n > 1 }
    next "a second task for #{twice.keys.join(", ")}" unless twice.empty?

    inside = Predicates.graph_verbs_inside_branches(trace)
    next "#{inside} graph verb(s) inside a branch" unless inside.zero?

    Predicates.loop_completed(trace)
  end,
  facts: { "task_calls_in_first_message" => ->(trace) { Predicates.first_round_task_rows(trace).size },
           "task_calls_in_a_later_round" => lambda do |trace|
             (trace.spine_calls.select { |r| r["tool_name"] == Trace::TASK } - Predicates.first_round_task_rows(trace)).size
           end,
           "per_file" => ->(trace) { Predicates.per_file(trace, files.map { |f| "#{f}.rb" }) },
           "orphans_named" => ->(trace) { files.count { |f| merged.(trace).include?("orphan_#{f}") } },
           "waited" => ->(trace) { trace.task_rows.any? { |r| trace.input_of(r)["wait"] == true } },
           "merge_turn" => ->(trace) { merge.(trace)&.first } }.merge(DOOR_FACTS)
)
