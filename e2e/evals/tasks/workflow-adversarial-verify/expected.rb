# Reach requires an orchestration call. A task-based solution succeeds through a receipt wake and
# completed loops; a waited fan is recorded but does not demonstrate that iterative flow. Compose
# instead succeeds through its completed branch because it owes no detached receipt. Hidden
# verification checks exactly the three false claims. The conduct reads the spine's own calls off
# the kernel's spine mark: a refuter's rounds are keyed `rN` too. JUDGING IS A READ AFTER DISPATCH:
# the spine's read of lib/ made by a round later, in the spine's order, than the round that made the
# first `task` or `compose` call is the spine checking what it handed out. One made by an earlier
# round is the code's shape a brief needs. One made beside the dispatch, in that round, briefs
# nothing, since the briefs were written in the same turn; it is not read as judging, because no
# refuter could have answered yet. That is the lenient choice. Both count as `read_before_dispatch`,
# the reads made no later than the dispatch. With nothing handed out, every such read is the spine's
# own verdict.
own_reads = lambda do |trace|
  spine = Trace.spine_keys(trace.graph)
  round_of = ->(row) { spine.index(Array(row["after"]).first) }
  dispatched = (trace.task_rows + trace.compose_rows).filter_map(&round_of).min
  reads = trace.spine_calls.select { |r| r["tool_name"] == "read" && trace.input_of(r)["path"].to_s.include?("lib/") }
  reads.partition { |row| dispatched.nil? || round_of.(row) > dispatched }
end
Expected.new(
  reach: ->(trace) { Predicates.reached_a_door(trace) },
  success: ->(trace) { Predicates.receipt_loop(trace) },
  conduct: { "did_not_judge_itself" => lambda do |trace|
    judged, = own_reads.(trace)
    judged.empty? ? true : "the spine read #{judged.map { |r| trace.input_of(r)["path"] }.uniq.join(", ")} itself"
  end },
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "loop_style" => ->(trace) { Predicates.loop_style(trace) },
           "waited" => ->(trace) { (trace.task_rows + trace.compose_rows).any? { |r| trace.input_of(r)["wait"] == true } },
           "refuters" => ->(trace) { trace.task_rows.size + trace.compose_rows.sum { |r| trace.under(r["key"]).count { |n| n["kind"] == "model_task" } } },
           "read_before_dispatch" => ->(trace) { own_reads.(trace).last.size } }.merge(DOOR_FACTS)
)
