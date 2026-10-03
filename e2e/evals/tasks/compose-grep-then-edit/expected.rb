# REACH: a compose call. SUCCESS on the strong tier: O2's picture — three
# greps at once, then the edit decided on what they said (the "cannot know
# yet" sentence: a model step reading the greps, or a tool a stage placed
# after reading them; never a tool written before they answered), steps
# after the edit that extend its chain admitted (O2's tail; never an edit
# tool no stage decided) — and the branch completed. On the floor: usable
# generation by a compose call of the run (`usable_on_call` the first-call
# record); the picture rides as a fact on both tiers, and the explicit-read
# columns (`reads`) beside it. Verification: the rename on disk.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.compose_bar(trace, "O2") },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "O2") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O2") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O2") } }
)
