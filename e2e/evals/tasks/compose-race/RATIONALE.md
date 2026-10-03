# compose-race

**Measures.** O3 through `exe/rho`: the `until` line. Three probes at
once, the first success ends the fan (`until: "any"`), the losers are
cancelled, one model step names the winner. `probe_host` is the text
bench's tool and not rho's, so the fixture ships `bin/probe <host>` with
per-host sleeps (bravo answers first) and the instruction names bash; the
picture's three tool steps stay three.

**Converts.** `e2e/support/compose_bench/objectives.rb:59` (O3 — `gate:
false` on the text bench; here it is scored like the rest, the ledger
carries the number).

**Dimensions.** reach = a `compose` row; success = O3's exact picture
(the join row, then a step after it reading the three probes — a model
step, or a value stage naming the race itself, `results: [race]`, which
waits on the join alone and reads what the race selected) AND the branch
completed with the losers `canceled`; conduct = `no_wrong_winner`: the
reply read as the claim "which host won" (`Claims::RaceWinner`) — red
when it ties alpha or charlie to winning, and red, unreadable, when it
never ties bravo to it; a loser named with its fate or its timing, or a
probe's command line, carries no claim, since a race has one winner.
Every compose-race reply of v10 and v11 reads as a person reads it
(`e2e/support/fixtures/claims/race_on_record.json`): the three that named
alpha — v10 kimi-k3 #3 and glm-5.3 #3, which read a stage's list order,
and v11 glm-5.3-flash #3, whose probes ran in sequence outside the race —
red, the replies that corrected a stage's wrong answer green. `named_bravo`
is a fact (the reply mentions bravo), never a pass condition, kept one
column so v12 reads against v11's mention, and so are
`authored_labels` (the run labelled its probes itself — an echo beside
each probe or a stage per probe adding its host; the envelope's `<call>`
line names each result's call, so a label is work the model did not need),
`success_filter` (each race member throws on its probe's failure, since
the race counts a completed call as a success whatever its `is_error`
says), `hedged_brief` (a composed brief told to say the winner cannot
be named) and `losers_completed` (per race the call placed, the arms that
completed beyond what its `until` needed — a loser a reader naming a
member kept alive; 0 when the race stopped its losers). The probe's
output names its host, so `named_bravo` here cannot tell the `<call>`
line from the output; compose-race-anon, whose probes name nothing, can.
On the floor tier
success is usable generation instead (`Predicates.compose_usable`): a
compose call of the run settled without an error, placed a node, every
stage source parses, and a placed node is not a stage that failed on its
own script; the picture rides as the `picture` fact on both tiers,
`usable_on_call` (the first call that met the bar) beside it.

**What a model after the race is delivered.** A step reads only what it
names: a model step after the race naming nothing reads its prompt alone,
and one naming the race — `results: [race]` — reads the selection
captured when the race settled, so no loser, and no arm's step that is
not the selection, ever reaches it. That is the kernel check every record
carries, never a pass condition: `composed_reads` is, per model step a
compose call placed, what the kernel owes it — its `result_from`, each
name read as `TaskResultProjection.referenced` reads it (a race its
selection, a failed race its partial winners then itself), once each and
in order — and what it handed it by position (`positional`, always empty);
`composed_requests` is the bytes beside it, each composed step's sealed
request off the task's request door counted over its tail (`envelopes`,
the `tasks` they name, the `canceled` among them, the `assistant` entries,
`bytes`); `kernel_check` is true when every request carried exactly what
its step is owed, else the first difference in words, nil when no request
was read.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call"; "(silent: missing_join)" — it
  wrote an `all` fan and waited for every probe; "(silent:
  over_read_named)"; "(silent: blind_model)" — the step after the race
  names nothing and reads its prompt alone;
  "the script was refused script_error: … a member of the race on line N"
  (bucket `race_member`) — the step after the race named a probe in
  `results:` or `after:`, a wait that would keep a loser running and read
  list order; the repair the sentence names is `results: [race]`, which
  waits on the join alone and reads what it selected; `no_wrong_winner` red —
  the reply named a loser the winner, or never tied bravo to winning.
- **kernel finding** — a right script whose losers did not settle
  ("r1t0-parallel-1(running) did not complete under r1t0": the cancel
  did not land); a round `failed` with a kernel error key; `kernel_check`
  not true — a composed step handed a loser, an arm's step outside the
  selection, anything by position, or an assistant entry.
- **on the floor** — the predicate is usable generation by a compose call
  of the run, never the picture. Its red — no call met the bar — is model
  conduct and names the first call's failure, one of: the kernel refused
  the call (the script's own error), it placed nothing, a stage does not
  parse, or nothing it placed stands (the stages that did its work failed
  on their own scripts); a call that did not complete names its error key,
  read as the kernel-finding bullet says. `usable_on_call` records the
  first call that met the bar — above 1, the first call missed and a
  recovery later in the run met it — and the `picture` fact carries the
  strong tier's reading with its buckets — a `task_pass` apart from the
  predicate is read against those two, never as a picture the scorer
  called wrong.
