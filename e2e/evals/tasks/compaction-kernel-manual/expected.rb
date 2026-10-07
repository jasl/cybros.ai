# REACH: the manual door armed — a `context_compacted{trigger: manual}`
# on the feed. SUCCESS: the gallery's `compaction?(mode: kernel)` — a k1
# model_task hung under the queued round, the round completed from the
# summary. CONDUCT: pointers never values — no summary body carries the
# fixture's body-only token —. The family's columns are facts.
Expected.new(
  reach: ->(trace) { trace.compactions.any? { |p| p["trigger"] == "manual" } ? true : "the manual door never armed: #{trace.compaction_tally.inspect}" },
  success: ->(trace) { Gallery.compaction?(*trace.triple, mode: "kernel") },
  conduct: {
    "pointers_never_values" => lambda do |trace|
      tokens = Predicates.summaries(trace).values.flat_map { |body| body.to_s.scan(/brief-\h{8}/) }
      tokens.empty? ? true : "the summary reproduced a value from the file body: #{tokens.first}"
    end,
  },
  facts: { "columns" => ->(trace) { Predicates.compaction_columns(trace, minimum_after: 2) } }
)
