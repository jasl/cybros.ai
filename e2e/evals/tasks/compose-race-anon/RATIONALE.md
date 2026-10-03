# compose-race-anon

**Measures.** What compose-race measures — O3 through `exe/rho`, the
`until` line — on probes whose output names no host: `bin/probe bravo`
prints `200 OK (2s)` where compose-race's prints `bravo: 200 OK (2s)`.
The instruction, the delays (bravo answers first), the bar, the conduct
and the facts are compose-race's — the bar, the conduct and the facts
from one file: this cell's `expected.rb` evaluates compose-race's.

**Why a second cell.** A tool result a model reads names the call that
produced it on the envelope's `<call>` line — the tool and the head of
its input, `<call>bash {"command":"bin/probe bravo"}</call>`. On
compose-race the probe's own output names its host too, so a run that
names the winner could have read either line, and the cell cannot tell
whether the `<call>` line did any work: two v10 runs named bravo only
because the output happened to spell it. Here nothing but the `<call>`
line names the host, so `named_bravo` on a run that authored no label of
its own (`authored_labels` false) is the line read, or a guess. compose-race
stays as it was, so its picture and its `named_bravo` column read against
v11's; `authored_labels` stays comparable across both cells because the
instruction forbids reading or running anything first — every script is
written before any output exists.

**Converts.** `e2e/support/compose_bench/objectives.rb:59` (O3), as
compose-race does.

**Dimensions.** reach = a `compose` row; success = O3's picture with the
branch completed on the strong tier, usable generation on the floor —
compose-race's, word for word; conduct = `no_wrong_winner`, compose-race's
claim reader (`Claims::RaceWinner`): the reply ties bravo to winning and
no loser. Facts: `named_bravo` (the reply mentions bravo);
`authored_labels` — the run labelled its probes itself, an echo
beside each probe (`bin/probe alpha && echo HOST=alpha`) or a stage per
probe adding its host (`ComposeBench::Endpoints`); `success_filter` —
each race member ends on a stage that throws on its probe's failure,
since the race counts a completed call as a success whatever its
`is_error` says, which `<call>` does not change; `hedged_brief` — a model
step the run composed was briefed to say the winner cannot be named;
`losers_completed` — compose-race's per-arm count of losers a race let
run on; `reads` — the explicit-read columns compose-race records. The
kernel check every record carries (`composed_reads`, `composed_requests`,
`kernel_check`: each composed step handed exactly what it names, a race
as its selection), and the leaked-call and re-issued-call counts
(`Trace#leaked_calls`, `Trace#reissued_calls`), read here as anywhere.

## Reading a red

As compose-race's. The bar is the picture; a reply that names a loser
the winner, or never ties bravo to winning, is `no_wrong_winner` red —
here, where no output names a host, the reply's claim reads the `<call>`
line or a guess.

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call"; a silent bucket
  (`missing_join`, `over_read_named`, `blind_model`, `over_sync`) —
  compose-race's readings.
- **kernel finding** — a right script whose losers did not settle; a
  round `failed` with a kernel error key; `kernel_check` not true, as
  compose-race reads it.
- **on the floor** — usable generation by a compose call of the run,
  never the picture, as compose-race reads it.
