# workflow-barrier-free-pipeline

**Measures.** The barrier-free pipeline: three sources with
different latencies, each normalised the moment ITS fetch lands, merged
at the end — O7's picture with a disk outcome. The compose sibling
(`compose-three-stage-pairing`) says "author this as one script"; this
text states the work only, so the door is the model's choice and the
task door's inability to pair is the finding it records.

**Converts.** `e2e/support/compose_bench/objectives.rb:106` (O7's
picture, the scorer) plus a verification; `bin/fetch` answers a, b, c
after 1, 4, 7 seconds with unique values.

**Dimensions.** reach = a door, or the plain concurrent fan — a round of
`bash` rows each running `bin/fetch`, or one row running it in two
background jobs or more (`… &`, `( … ) &`, a loop whose body ends on `&`:
a `for` over two words or more, or over a list the text does not count —
a substitution, a glob, a brace — or a `while`/`until`) started before a
`wait` with none between them (`… & wait` inside a loop, or `a & wait;
b & wait`, waits on each before the next: a sequence); `fetch_fan_round`
is its round. A reached door the
pairing cannot be read on: the task door and the plain concurrent fan
are the recorded door, the picture is not read. success = O7's exact picture on the plan
the compose script placed AND the branch completed; task pass = `merged.txt` carries the
three normalised records; `door`, `score`, `loop_style` are facts. On
the floor tier success is usable generation instead
(`Predicates.compose_usable`): a compose call of the run settled without an
error, placed a node, every stage source parses, and a placed node is
not a stage that failed on its own script; the picture rides as the
`picture` fact on both tiers, `usable_on_call` (the first call that met
the bar) beside it.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no compose call, no round fanned two task calls
  and no concurrent fetch fan" (no door: it ran the pipelines in
  sequence — a `for` loop, `a && b && c`, one fetch a round); "the task
  door cannot pair a fetch with its own normaliser" (the recorded door: a
  task fan or the plain concurrent fan, whose `task_pass` true reads as a
  disagreement); "(silent: over_sync)" — fetches in one fan,
  normalisers in a second;
  "(silent: missing_steps)" — the normalise folded into the fetch's own
  command (`sh bin/fetch a | awk …`), no step of its own; "(silent:
  over_read_named)" — a merge naming the raw fetches beside the
  normalisers; "(silent: blind_model)" — a model normaliser or merge that
  names nothing and reads its prompt alone (a step reads only what it
  names, so a merge naming the three normalisers reads them however they
  are spelled). A normaliser may be a model step, a value stage
  reading its fetch, or a tool after its fetch (`sh bin/normalise a`,
  which reads the file its fetch wrote); a `cat` merge is a tool where
  the picture has a model step or a value stage, and reads
  `edit_as_tool`.
- **kernel finding** — a right script whose pairs did not complete;
  `kernel_check` not true — a composed step handed something it did not
  name;
  on the strong tier, `task_pass: false` beside a green predicate (the merge step wrote no
  file: read its output in the artifact — a model step cannot write a
  file, so the SPINE must have written merged.txt from the merge's
  result; a green shape with no file says the receipt never reached it).
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
