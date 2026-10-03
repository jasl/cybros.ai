# compose-three-stage-pairing

**Measures.** O7 (T4, the nested-sequence clause) through `exe/rho`: a
pair written as a sequence INSIDE a parallel — `[fetch, normalise]` three
times — so each normaliser starts when its own fetch is done and reads it
alone: a model step, a `g.script` value stage whose `results:` name its
fetch, or a tool after its fetch (`sh bin/normalise a` reads the file the
fetch wrote, so a tool there reads what it waits on); a normalise folded
into the fetch's own command is no step of its own and reads
`missing_steps`. A merge after the fan reads the three normalisers — a
model step or a `g.script` value stage whose `results:` name them. A step
reads only what it names, so a merge is handed the three normalised sets
however its normalisers are spelled, and a model normaliser or merge
naming nothing reads its prompt alone. The fixture's `bin/fetch` answers
a, b, c after 1, 4 and 7 seconds, one raw record each.

**Converts.** `e2e/support/compose_bench/objectives.rb:106` (O7; `gate:
false` on the text bench — recorded there, scored here like the rest).
The network fetches become `sh bin/fetch <name>`; the picture's three
tool steps stay three.

**Dimensions.** reach = a `compose` row; success = O7's exact picture AND
the branch completed; the score's columns are facts. No verification: the
merged list is the merge step's output, in the artifact. On the floor
tier success is usable generation instead (`Predicates.compose_usable`):
a compose call of the run settled without an error, placed a node, every
stage source parses, and a placed node is not a stage that failed on its
own script; the picture rides as the `picture` fact on both tiers,
`usable_on_call` (the first call that met the bar) beside it.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call"; "(silent: over_sync)" — three
  fetches in one fan, then three normalisers in a second fan (each waits
  on all three fetches); "(silent: over_read_named)" — a normaliser names
  every fetch, or a merge names the raw fetches beside the normalisers;
  "(silent: blind_model)" — a normaliser or the merge names nothing and
  reads its prompt alone. "(silent: over_read_positional)" is never the
  model's: it is the kernel check's finding below.
- **kernel finding** — a right script whose pairs did not complete; a
  round `failed` with a kernel error key; `kernel_check` not true — a
  composed step handed something it did not name.
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
