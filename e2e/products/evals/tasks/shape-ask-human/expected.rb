# REACH: an `ask` row. SUCCESS: the gallery's `ask_human?` — an await
# under the call, answered, feeding a completed round; the feed called
# for a person once. Which round asks is free.
Expected.new(
  reach: ->(trace) { trace.tool_rows("ask").any? ? true : "no ask: the model called #{trace.called.inspect}" },
  success: ->(trace) { Gallery.ask_human?(*trace.triple) }
)
