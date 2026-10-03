# A completed judge panel may use a compose fan/join or task branches that all return, whether
# waited or detached. A waited judge returns inline and owes no mail receipt. Record receipt and
# wait style separately; success also requires the reply to identify the hidden verifier's winner,
# b.
Expected.new(
  reach: ->(trace) { Predicates.reached_a_door(trace) },
  success: lambda do |trace|
    shape = trace.compose_rows.any? ? Gallery.fan_join?(*trace.triple) : Predicates.fan_completed(trace)
    next shape if shape in String

    trace.reply.match?(/winner:\s*b/i) ? true : "the reply does not name b as the winner: #{trace.reply.strip[0, 80].inspect}"
  end,
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "loop_style" => ->(trace) { Predicates.loop_style(trace) },
           "waited" => ->(trace) { (trace.task_rows + trace.compose_rows).any? { |r| trace.input_of(r)["wait"] == true } },
           "judges" => ->(trace) { trace.task_rows.size + trace.compose_rows.sum { |r| trace.under(r["key"]).count { |n| n["kind"] == "model_task" } } } }.merge(DOOR_FACTS)
)
