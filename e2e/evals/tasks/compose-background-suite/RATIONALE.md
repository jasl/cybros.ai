# compose-background-suite

**Measures.** O4 through `exe/rho`: a step nothing should wait on goes in
the same `g.parallel` as the rest and no later step reads it. The fixture
ships a 40-second `bin/rails test` and a `bin/rubocop` stand-in that names
two offences in `app/models/user.rb`, so the fix step has real lines to
edit. Success is the picture scored on the plan the kernel placed for the
script; the branch's completion is the kernel's part.

**Converts.** `e2e/support/compose_bench/objectives.rb:78` (O4, the
picture `suite | [lint → fix]`, `fix` reads `lint` alone; steps after the
fix may extend that chain — a re-lint, a report reading the fix and the
lint — while nothing waits on or reads the suite).

**A launch is read as no wait.** A `start_process` suite answers when
its `wait_seconds` run out (at most 60), when the suite exits, or at the
first line its `wait_for` matches, and past the answer the suite runs on
as a process. The references' background shells return a handle at once
and nothing waits on it; a launch is this grammar's nearest spelling of
that. So the picture reads no wait out of a launch (`Shape::LAUNCHES`),
whatever its budget: `suite_waited_on` and `over_sync` never fire on one,
and the record's `graph` still shows the wait as written. The cost is
stated here: the fixture's suite runs 40 s and prints nothing before
it ends, so a launch whose `wait_seconds` outlasts those 40 s answers
only once the suite has finished (its receipt says `exited`). It waited
out the whole suite and still reads as no wait. None did on v13, where
the longest budget was 30 s. The launch's answer is the suite's first
output (the model asked for those seconds to peek), so a step that NAMES
it reads suite output: `over_read_named` stands, and so does `extra_steps` for
a step that is no extension of `[lint → fix]`. The reading is
deliberately lenient — the models were not adapted to this grammar — so
the fault it keeps is reading the suite, never the spelling of "don't
wait".

**Dimensions.** reach = a `compose` row; success = O4's exact picture
(`suite_waited_on` is the bucket that fails it) AND the branch completed;
the score's columns are facts. No verification: whether the two offences
were fixed is the fix step's own output, recorded in the artifact. On the
floor tier success is usable generation instead
(`Predicates.compose_usable`): a compose call of the run settled without an
error, placed a node, every stage source parses, and a placed node is not
a stage that failed on its own script; the picture rides as the `picture`
fact on both tiers, `usable_on_call` (the first call that met the bar)
beside it.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled (note the
  suite alone is 40 s; the deadline is 600).
- **model conduct** — "no compose call" (it ran the suite with `bash` and
  waited, or `start_process`); "(silent: suite_waited_on)" — `suite; lint;
  fix` in sequence with the suite run to completion (a `start_process`
  launch in its place is read as no wait, whatever its budget);
  "(silent: over_read_named)" — the fix or a report names the suite, its
  launch receipt included; "(silent: blind_model)" — the fix names nothing
  and reads its prompt alone, never the lint before it;
  "(silent: extra_steps)" — a step that is no extension of the chain: one
  after the fix that waits on or reads the suite, or one between the lint
  and the fix.
- **kernel finding** — a right script whose suite member did not complete
  once the reply went final (the detached branch's settlement); a round
  `failed` with a kernel error key; `kernel_check` not true — a composed
  step handed something it did not name.
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
