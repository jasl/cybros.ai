own_reads = lambda do |trace|
  mainline = Trace.mainline_keys(trace.graph)
  round_of = ->(row) { mainline.index(Array(row["after"]).first) }
  dispatched = trace.task_rows.filter_map(&round_of).min
  reads = trace.mainline_calls.select { |r| r["tool_name"] == "read" && trace.input_of(r)["path"].to_s.include?("lib/") }
  reads.partition { |row| dispatched.nil? || round_of.(row) > dispatched }
end
Expected.new(
  reach: ->(trace) { Predicates.reached_a_door(trace) },
  success: ->(trace) { Predicates.receipt_loop(trace) },
  conduct: { "did_not_judge_itself" => lambda do |trace|
    judged, = own_reads.(trace)
    judged.empty? ? true : "the mainline read #{judged.map { |r| trace.input_of(r)["path"] }.uniq.join(", ")} itself"
  end },
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "loop_style" => ->(trace) { Predicates.loop_style(trace) },
           "waited" => ->(trace) { trace.task_rows.any? { |r| trace.input_of(r)["wait"] == true } },
           "refuters" => ->(trace) { trace.task_rows.size },
           "read_before_dispatch" => ->(trace) { own_reads.(trace).last.size } }.merge(DOOR_FACTS)
)
