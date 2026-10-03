# compose-two-source-fan-in

**Measures.** O7b through `exe/rho`: the two-source fan-in inside a
per-item chain — `[test, ts]` beside `[parallel(lint, types), qs]`, then
`report` — three bracket levels, the deepest the static grammar is asked
for. The fixture's `bin/rails test` (30 s, one failure), `bin/rubocop`
(two offences) and `bin/srb tc` (one type error, exit 1) give each
summariser real output.

**Converts.** `e2e/support/compose_bench/objectives.rb:126` (O7b; `gate:
false` on the text bench).

**Dimensions.** reach = a `compose` row; success = O7b's exact picture
AND the branch completed; the score's columns are facts. No verification.
On the floor tier success is usable generation instead
(`Predicates.compose_usable`): a compose call of the run settled without an
error, placed a node, every stage source parses, and a placed node is not
a stage that failed on its own script; the picture rides as the `picture`
fact on both tiers, `usable_on_call` (the first call that met the bar)
beside it.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call"; "(silent: over_sync)" — the
  quality summary placed after the whole fan, waiting on the tests;
  "(silent: missing_steps)" — lint and types summarised separately;
  "(silent: over_read_named)" — the report's `results:` name the raw
  outputs beside the two summaries (the flat peers group read the three
  outputs by position before a step read only what it names; now the
  report naming the two summaries reads those alone, so that spelling is
  exact); "(silent: blind_model)" — a summary or the report names nothing
  and reads its prompt alone.
- **kernel finding** — a right script whose nested fan did not complete;
  `kernel_check` not true, or `over_read_positional` — a composed step
  handed something it did not name;
  `bin/srb`'s exit 1 refusing the pair (a failed tool member is a settled
  member: the summariser after it must still run — if it did not, the
  kernel's handling of a failed member inside a sequence is the finding).
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
