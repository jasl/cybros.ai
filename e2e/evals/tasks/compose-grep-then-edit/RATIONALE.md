# compose-grep-then-edit

**Measures.** O2 through `exe/rho`: the step that cannot be spelled before
the greps answer must be decided on what the three greps said — a MODEL
step reading them, or a tool a `g.script` stage placed after reading them —
never an `edit` tool guessed in advance. Success is the picture scored on
the plan the kernel placed for the model's script, plus the kernel's run of
it; task pass is the rename on disk with the other two files untouched.

**Converts.** `e2e/support/compose_bench/objectives.rb:44` (O2, its
picture: `g1 g2 g3 → e`, `e` — a model step, or a tool a stage decided —
reads all three; steps after `e` may extend its chain). The three model
files are the fixture; only `team.rb` defines `full_name`.

**The tail.** As O4 admits steps after its fix, O2 admits steps after its
edit (`tail: "e"`): each waits on the edit, waits on and reads nothing but
the edit and the greps, and nothing the labels took waits on it — a verify
grep, a report, a closing value stage. They extend the dataflow the
objective exists for; Codex and opencode run a check after a patch. One
consequence, stated plainly: the tail's label goes to the FIRST step
decided on the greps, so a `read` of the defining file that a stage placed
after reading the greps takes the edit's place, and the real edit and the
verify after it read as its extensions — the file is read before it is
edited, as Claude Code's Read-before-Edit asks. A tool between the greps
and the edit that no stage decided — written before the greps answered —
reads nothing, takes no label and stays `extra_steps`. Nor is an edit
tool no stage decided ever an extension: an `edit` or `write` the script
wrote, or a stage that read nothing placed, was fixed before the greps
answered — the guessed edit this objective exists for — so past a model
step that read the greps, which may only have reported them, it is still
`extra_steps`, as it is after a decided edit. An edit a stage placed after
reading extends the chain as a verify does. Beyond that the tail reads
dataflow, never what a step does: a shell command past the edit reads as a
verification whatever it runs, since the picture reads no command, so a
`sed -i` that guessed the right file after a step that only reported is the
one guessed edit it cannot see — the files on disk (task pass) read the
rest. A picture with a tail sets no value apart, so a closing stage that
waits on nothing is an extra step. The reading is deliberately lenient —
the models were not adapted to this grammar — so the fault it keeps is an
edit tool not decided on the greps, never the habit of checking one's
work.

**Dimensions.** reach = a `compose` row; success = exact O2 picture AND the
branch completed; task pass = `team.rb` defines `display_name` and not
`full_name`, `user.rb`/`account.rb` byte-identical; the score's columns
are facts. On the floor tier success is usable generation instead
(`Predicates.compose_usable`): a compose call of the run settled without an
error, placed a node, every stage source parses, and a placed node is not a
stage that failed on its own script; the picture rides as the `picture`
fact on both tiers, `usable_on_call` (the first call that met the bar)
beside it.

## Reading a red

- **lane bug** — `error` on the record, or the deadline before any round settled.
- **model conduct** — "no compose call" (it grepped and edited itself);
  "(silent: edit_as_tool)" — the rename is a tool that read nothing: the
  script wrote `g.tool({name: "edit"})` (or a sed/perl `bash`) before the
  greps answered, or a stage that read nothing placed it. A tool a
  `g.script` stage placed after reading the greps is O2's edit — on the
  executed reading it reads what the stages above it read — so such a run
  is red only for what else it placed ("(silent: extra_steps)": a blind
  step between the greps and the edit, a blind `edit`/`write` anywhere, a
  closing stage that waits on nothing; a verification after the edit is
  the tail's); "(silent: edit_as_stage)" — a `g.script` stage reading
  the greps stands in the edit's place and nothing after it could have
  decided the edit: no model step and no editing tool among the steps the
  tail admitted past it. O2's picture admits no script there, and a
  picture with a tail sets no value apart, so the stage takes the edit's
  label and every step after it extends the chain. On the plan that ran,
  that stage placed nothing, so no edit was decided on the greps. The
  static reading beside it reads the same for a stage that did place the
  edit, since the text cannot see what a stage places. Before the tail
  such a plan read `missing_steps` (the stage dropped out as the plan's
  answer) or `extra_steps, over_read` (a model step after it read it —
  the bucket a step's `results:` now spell `over_read_named`),
  and under the tail `wrong_task_read` until this bucket: version 13's
  re-read moved five readings here (the static readings of glm-5.3 #2
  and #3 and deepseek-flash #3, kimi-k3 #2's static and executed);
  "(silent: wrong_task_read)" — the fallback bucket, named where no
  sharper one fits; for such a plan, what is left is a stage a later
  model step reads — that model's filter, where the static reading cannot
  tell whether the model decided the edit (version 13's kimi-k3 #3 and
  glm-5.3-flash #2, both exact on the executed reading); `task_pass:
  false` beside a green predicate with the edit step's output naming the
  wrong file.
- **kernel finding** (strong tier) — `task_pass: true` beside a red predicate (the rename
  landed through a picture the scorer calls wrong: read the lowered graph
  in `facts.score` before trusting either); a round `failed` with a kernel
  error key; the branch under a right script not completing.
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
