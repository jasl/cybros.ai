# task-two-calls

**Measures.** The independent-tool-calls task through `exe/rho`: several plain
calls in ONE message for a few independent reads — the thing neither
`task` nor `compose` is for. The offline probe scores one emitted
message; here the first round's fan is read off the trace (`after:
["r1"]`), and the over-reach half rides beside it.

**Converts.** `e2e/support/task_bench/objectives.rb:55` (G0, `calls.length
>= 2`) with the gallery's `plain` driver. The fixture: three files, only
`charlie.rb` defines `run` (`alpha.rb` defines `start`, `bravo.rb` `go`).

**Dimensions.** reach = ≥ 2 tool rows fanned by r1; success = the run's
calls covered every file (`Coverage`, the reader the three-grep control
shares: a read, a grep of the file or its folder, a content reader in bash,
a delegation naming it) AND no `task`/`compose` row; conduct =
`no_false_claim` (`Claims` over the reply: charlie.rb said to define `run`,
and every mention of alpha.rb or bravo.rb tied to its own method, denied, or
covered by an exclusive claim such as "only charlie.rb"; a reply that ties
either to `run` — outright, by "does too" or "so does", under a heading
naming `run`, in a table row, as `Alpha.run` — or never names charlie.rb is
red, and one the reader cannot read as a claim is red with a reason that
says so); `calls_in_first_round` and `named_charlie_only` (charlie.rb named
and no other file) are facts. Most correct replies list every file beside
its method, so `named_charlie_only` is false on them while `no_false_claim`
is true; the fact shows which replies the conduct re-read.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "the first round fanned 1 call(s), not two" (one
  read per round); "over-reach: r1t0:task …" (it delegated three reads);
  "lib/bravo.rb never covered by a call" (it answered without reading);
  `conduct.no_false_claim: false` with "the reply ties alpha.rb to `run`"
  (a false claim), "the reply never names charlie.rb", or "the reply could
  not be read as a claim" (the reply is on the record: read it).
- **kernel finding** — a fanned round `failed` with a kernel error key;
  a fan of three reads not all completed.
