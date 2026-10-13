# REACH: the context overflowed on a FACT. SUCCESS: at least one
# fact-triggered repair SUMMARIZED in kernel mode (a k-row model_task
# completed under its round) — the observation B51 owes — with no
# fallback, every round completed, the loop completed. A run whose every
# wall pruned is red HERE with that finding: the corpus was sized so the
# prunable bytes cannot cover the overshoot (the RATIONALE's arithmetic)
# and a prune-only trace says the sizing, or the arm, is not what the
# arithmetic says. CONDUCT: pointers never values.
fact_triggers = %w[wall usage overflow]
Expected.new(
  reach: lambda do |trace|
    trace.compactions.any? { |p| fact_triggers.include?(p["trigger"]) } ? true :
      "the context never overflowed on a fact: #{trace.compaction_tally.inspect} over #{trace.tasks.size} tasks"
  end,
  success: lambda do |trace|
    summaries = trace.compactions.select { |p| p["mode"] == "kernel" && fact_triggers.include?(p["trigger"]) }
    next "no kernel summary on a fact trigger: every wall pruned (#{trace.compaction_tally.inspect})" if summaries.empty?

    key = summaries.first["summary_task_key"]
    node = trace.node(key)
    next "the summary #{key.inspect} is not on the graph" if node.nil?
    next "#{key} is #{node["kind"]}/#{node["status"]}, not a completed model_task" unless node.values_at("kind", "status") == %w[model_task completed]
    next "a fallback fired: #{trace.compaction_tally.inspect}" if trace.compactions.any? { |p| p["trigger"] == "fallback" }
    # The harness's own stop (`creator_requested`) is never a round that did not complete; the
    # loop's status names it below.
    completed = Predicates.every_round_completed(trace)
    next completed unless completed == true

    Predicates.loop_completed(trace)
  end,
  conduct: { "pointers_never_values" => lambda do |trace|
    leaked = Predicates.summaries(trace).find { |_key, body| body.to_s.match?(/tail-\h{12} of part-\d{2}\.txt/) }
    leaked ? "the summary #{leaked.first} reproduced a value from a file body" : true
  end },
  facts: { "columns" => ->(trace) { Predicates.compaction_columns(trace, minimum_after: 0) },
           "checks" => ->(trace) { trace.fact(:checks) } }
)
