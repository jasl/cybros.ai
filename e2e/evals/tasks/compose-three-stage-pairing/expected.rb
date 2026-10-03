# REACH: a compose call. SUCCESS on the strong tier: O7's picture — three
# [fetch, normalise] pairs at once, each normaliser (a model step, a tool or
# a value stage) its own step reading its own fetch alone, then a merge
# reading the three normalisers (a model step or a value stage) — and the
# branch completed. On the floor: usable generation by a
# compose call of the run (`usable_on_call` the first-call record); the
# picture rides as a fact on both tiers, and the explicit-read columns
# (`reads`) beside it.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.compose_bar(trace, "O7") },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "O7") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O7") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O7") } }
)
