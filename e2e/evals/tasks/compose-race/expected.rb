# REACH: a compose call. SUCCESS on the strong tier: O3's picture — a race
# (`until: "any"` or 1) over three probes with the join row between, then a
# step naming the winner that waits on the join alone — and the branch
# completed (a race CANCELS its losers; canceled is a settled member). On
# the floor: usable generation by a compose call of the run
# (`usable_on_call` the first-call record); the picture rides as a fact on
# both tiers. CONDUCT: `no_wrong_winner` — the reply ties bravo, the host
# that answered first, to winning and ties neither alpha nor charlie to it
# (`Claims::RaceWinner`, fail-closed: a reply that never ties bravo to
# winning is red; a race has one winner, so tying bravo claims it alone,
# and a probe's command line names no claim). `named_bravo` (the reply
# mentions bravo) rides one column as a fact beside it, so v12 reads
# against v11's mention. Recorded beside: whether the run labelled its
# probes itself (`authored_labels`) or made each probe fail itself so a
# failed one cannot win (`success_filter`) — the work the envelope's
# `<call>` line and the race's success rule leave to the model; a brief
# written to say the winner cannot be named (`hedged_brief`); and the race
# arms that completed beyond what its `until` needed — losers something
# kept alive past the race (`losers_completed`, 0 when the race stopped
# them all). And the explicit-read columns (`reads`, `Predicates.reads`):
# what each composed step named, what came back to the caller, and the
# over-read split. What each composed step was delivered is the kernel
# check every record carries (`composed_reads` against the sealed
# requests' `composed_requests`, `kernel_check`): a step after a race
# reads the race only by naming it, as its selection.
Expected.new(
  reach: ->(trace) { Predicates.compose_reached(trace) },
  success: ->(trace) { Predicates.compose_bar(trace, "O3") },
  conduct: { "no_wrong_winner" => ->(trace) { Claims::RaceWinner.check(trace.reply) } },
  facts: { "score" => ->(trace) { Predicates.score_compose(trace, "O3") },
           "picture" => ->(trace) { Predicates.compose_picture(trace, "O3") },
           "usable_on_call" => ->(trace) { Predicates.usable_on_call(trace) },
           "named_bravo" => ->(trace) { trace.reply.include?("bravo") },
           "authored_labels" => ->(trace) { Predicates.authored_labels(trace) },
           "success_filter" => ->(trace) { Predicates.success_filter(trace) },
           "hedged_brief" => ->(trace) { Predicates.hedged_brief(trace) },
           "losers_completed" => ->(trace) { Predicates.losers_completed(trace) },
           "reads" => ->(trace) { Predicates.reads(trace, "O3") } }
)
