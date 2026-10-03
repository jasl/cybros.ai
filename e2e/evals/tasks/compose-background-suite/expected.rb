# REACH: a compose call. SUCCESS on the strong tier: O4's picture under the detached default: the
# suite beside a [lint, fix] pair in ONE parallel — the fix reads the lint alone and nothing waits on
# the suite; steps after the fix may extend that chain — and the branch completed. The
# discrimination this objective exists for is `suite; lint; fix`, which makes the fix wait on the
# suite. A `start_process` launch is read as no wait on the suite, whatever its budget
# (`Shape::LAUNCHES`), while a step that names its answer reads the suite's output. On the floor:
# usable generation by a compose call of the run (`usable_on_call` the first-call record); the
# picture rides as a fact on both tiers, and the explicit-read columns (`reads`) beside it.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.compose_bar(trace, "O4") },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "O4") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O4") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O4") } }
)
