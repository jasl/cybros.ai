# REACH: the context overflowed on a FACT — a `context_compacted` with a
# wall/usage/overflow trigger. SUCCESS: every repair named a mode and a
# fact trigger from the closed vocabularies, at least one mid-turn repair
# named its round, no fallback, every round completed, the loop
# completed (live_long_session's assertions; the arm's choice recorded).
# CONDUCT: pointers never values — no summary body carries a file's
# body-only token. The family's columns are facts; `work_survived` is the
# verification.
fact_triggers = %w[wall usage overflow]
Expected.new(
  reach: lambda do |trace|
    trace.compactions.any? { |p| fact_triggers.include?(p["trigger"]) } ? true :
      "the context never overflowed on a fact: #{trace.compaction_tally.inspect} over #{trace.tasks.size} tasks"
  end,
  success: lambda do |trace|
    odd = trace.compactions.reject { |p| %w[prune kernel delegate].include?(p["mode"]) && (fact_triggers + %w[manual]).include?(p["trigger"]) }
    next "a compaction outside the vocabularies: #{odd.first.inspect}" unless odd.empty?
    next "no mid-turn repair named its round: #{trace.compactions.inspect[0, 200]}" unless trace.compactions.any? { |p| p["task_key"] }
    next "a fallback fired: #{trace.compaction_tally.inspect}" if trace.compactions.any? { |p| p["trigger"] == "fallback" }
    # The harness's own stop (`creator_requested` on the running step, `loop_canceled` on a queued
    # round) is never a round that did not complete; the loop's status names it below.
    completed = Predicates.every_round_completed(trace)
    next completed unless completed == true

    Predicates.loop_completed(trace)
  end,
  conduct: { "pointers_never_values" => lambda do |trace|
    leaked = Predicates.summaries(trace).find { |_key, body| body.to_s.match?(/body-\h{12} of doc-\d{3}\.txt/) }
    leaked ? "the summary #{leaked.first} reproduced a value from a file body" : true
  end },
  facts: { "columns" => ->(trace) { Predicates.compaction_columns(trace, minimum_after: 0) },
           "checks" => ->(trace) { trace.fact(:checks) } }
)
