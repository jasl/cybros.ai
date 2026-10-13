# REACH: an `ask` row. SUCCESS: the gallery's `ask_human?` (the await
# answered, a completed round reads it, the feed called for a person).
# The verification says whether the answer was USED: a model that asks,
# is answered, and writes something else has not used it.
Expected.new(
  reach: ->(trace) { trace.tool_rows("ask").any? ? true : "no ask: the model called #{trace.called.inspect}" },
  success: ->(trace) { Gallery.ask_human?(*trace.triple) },
  conduct: { "asked_for_the_codeword" => ->(trace) { trace.fact(:asked_prompt).to_s.match?(/codeword/i) ? true : "the ask's prompt: #{trace.fact(:asked_prompt).inspect}" } }
)
