# compose-rendezvous

**Measures.** T5, the rendezvous through a shared tool mid-point:
migrate and seed joined before the dump, two reviews after the dump,
one merge after both reviews. The picture's reads are the prompt's:
"neither may see the other's output", so each review reads its own head
and the dump, and the merge reads the two reviews. `results:` writes
that read set — peers in one group, each naming its inputs — and a
step reads nothing else: written order is a wait, never a read, so a
review naming nothing reads its prompt alone. The text bench records the shape without gating
(`gate: false`). Here the same: success is "a valid script the kernel
ran to completion"; whether the picture was exact is the fact `exact`.

**Converts.** `e2e/support/compose_bench/objectives.rb` (T5).

**Dimensions.** reach = a `compose` row; success = valid first AND the
branch completed (`Predicates.compose_accepted`); `exact` and the
score's columns are facts. No verification. On the floor tier success
is usable generation instead, and the branch still gates it
(`Predicates.compose_floor`): a compose call of the run settled without
an error, placed a node, every stage source parses, and a placed node
is not a stage that failed on its own script — AND the branch of the
call that met that bar completed, since usable generation alone reads
a member that failed at run time as a node that stands. The picture
rides as the `picture` fact on both tiers, `usable_on_call` (the first
call that met the bar) beside it, so the floor cell prints `usable n/m
· picture n/m` as its siblings' do. The `picture` fact is on the strong
tier's records too, from the column that added it on: a census that
finds the picture cells by that fact counts rendezvous from there.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call"; "the script was refused …" (it
  wrote something the builder rejects). An `exact: false` fact is NOT a
  red; read its `silent` bucket: `over_read_named` is a review that names
  the other head or a merge that names more than the two reviews,
  `blind_model` a review or merge that names nothing and reads its prompt
  alone, `extra_steps` the tee-and-cat pair (`[cat own.log, review]` per
  review — the cat is a wait, and the review still reads only what it
  names), `over_sync` a review that waits on the other, `missing_steps` a
  script cut short.
- **kernel finding** — a valid script whose branch did not complete;
  `kernel_check` not true, or `over_read_positional` — a composed step
  handed something it did not name.
- **on the floor** — the predicate is usable generation by a compose call
  of the run, never the picture, and that call's branch completed. Its
  red — no call met the bar — is model conduct and names the first
  call's failure, one of: the kernel refused the call (the script's own
  error), it placed nothing, a stage does not parse, or nothing it placed
  stands (the stages that did its work failed on their own scripts); a
  call that did not complete names its error key, and a usable call
  whose branch did not complete names the member ("r1t0-model-2(failed)
  did not complete under r1t0"), both read as the kernel-finding bullet
  says. `usable_on_call` records the first call that met the bar — above
  1, the first call missed and a recovery later in the run met it — and
  the `picture` fact carries the strong tier's reading with its buckets.
