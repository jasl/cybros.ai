# REACH: the authored keys exist (the loop was created and started).
# SUCCESS: the gallery's `halt_retry?` — gate-1 timed out and abandoned
# (its error kept), gate-2 retried and answered, work completed as the
# deliverable, waiting on both. Exact by construction.
Expected.new(
  reach: ->(trace) { trace.node("gate-1") && trace.node("gate-2") ? true : "the authored gates are not on the graph: #{trace.graph["nodes"].map { |n| n["key"] }.inspect}" },
  success: ->(trace) { Gallery.halt_retry?(*trace.triple) }
)
