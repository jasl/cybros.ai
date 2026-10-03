# REACH: a compose call. SUCCESS on the strong tier: O1's picture (three model members in one
# parallel, one model after it reading all three) on the plan the kernel placed for the script the
# model wrote — valid first, exact edges and reads — and the branch the kernel ran under the call
# completed. On the floor: usable generation by a compose call of the run. The picture rides as a
# fact on both tiers, beside the call that first met the floor's bar (`usable_on_call`, the
# first-call record), the score's columns, the script's text reading among them, and the
# explicit-read columns (`reads`).
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.compose_bar(trace, "O1") },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "O1") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O1") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O1") } }
)
