# REACH: a compose call. SUCCESS on the strong tier: O7b's picture —
# [test, summary] beside a member that fans lint and types into one summary
# (three bracket levels), and a report after the fan reading the two
# summaries — and the branch completed. On the floor: usable generation by
# a compose call of the run (`usable_on_call` the first-call record); the
# picture rides as a fact on both tiers, and the explicit-read columns
# (`reads`) beside it.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.compose_bar(trace, "O7b") },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "O7b") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O7b") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O7b") } }
)
