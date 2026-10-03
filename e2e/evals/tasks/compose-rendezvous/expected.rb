# Recorded-only compose objective. Reach means a compose call. Success on the strong tier means its
# accepted script completed; on the floor, usable generation by a compose call of the run AND that
# call's branch completed (`usable_on_call` the first-call record). The exact graph is diagnostic:
# each review reads its own head and the dump, which `results:` writes and written order does not
# (a review naming nothing reads its prompt alone). A tee-and-cat workaround adds steps and hands
# the review nothing, so it is classified separately rather than mistaken for dependency isolation.
# The picture rides as a fact on both tiers, and the explicit-read columns (`reads`) beside it.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.recorded_bar(trace, "T5") },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "T5") },
           "exact" => ->(trace) { Predicates.score_compose(trace, "T5").then { |s| (s in Hash) && s["first_time_right"] } },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "T5") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "T5") } }
)
