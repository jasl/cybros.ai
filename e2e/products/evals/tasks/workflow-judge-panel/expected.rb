Expected.new(
  reach: ->(trace) { Predicates.reached_a_door(trace) },
  success: lambda do |trace|
    shape = Predicates.fan_completed(trace)
    next shape if shape in String

    trace.reply.match?(/winner:\s*b/i) ? true : "the reply does not name b as the winner: #{trace.reply.strip[0, 80].inspect}"
  end,
  facts: { "door" => ->(trace) { Predicates.door(trace) }, "loop_style" => ->(trace) { Predicates.loop_style(trace) },
           "waited" => ->(trace) { trace.task_rows.any? { |r| trace.input_of(r)["wait"] == true } },
           "judges" => ->(trace) { trace.task_rows.size } }.merge(DOOR_FACTS)
)
