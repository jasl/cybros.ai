# REACH: a bash row (the model ran the command at all). SUCCESS: the
# gallery's `repeat_brake?` — a mainline round refused expansion for
# repeat_call_loop after rounds that brought nothing new (the identical
# `cat status.txt` with the unchanged NOT READY), the loop held
# halt_failure for a person. Which round trips is free; a model that
# varies its call is red with that finding (the brake never fires).
Expected.new(
  reach: ->(trace) { trace.tool_rows("bash").any? ? true : "no bash row: the model called #{trace.called.inspect}" },
  success: ->(trace) { Gallery.repeat_brake?(*trace.triple) },
  facts: { "identical_rounds" => ->(trace) { trace.mainline_rounds.count { |r| trace.fan_signature(r["key"]) == [["bash", "{\"command\":\"cat status.txt\"}"]] } } }
)
