# task-grep-three-control

**Measures.** The task family's over-reach control through `exe/rho`:
three greps are the model's own work — several in one message, no
`task`, no `compose`. The reach column reads whether the run read the
three files, the success column reads the restraint, so a model that
delegated three greps is `reached: true, succeeded: false` with
`task_zero: false` on the record.

**Converts.** `e2e/support/task_bench/objectives.rb:79` (T5 control:
`task_zero`, `compose_zero`, `two_calls_in_message`). The fixture: three
configs, two with `debug: true`.

**Dimensions.** reach = the run's calls, over EVERY round, covered the
three files (`Coverage`: a read of the path; a grep of a file, or of the
folder under a glob that holds it; a content reader in bash naming a file,
a glob over it, or the folder when recursive, read from the command's
`workdir` or `cd`; a delegation naming them — `ls`, `find` and `rg --files`
cover nothing, and so does a call that did not complete or a read or grep
that answered an error). One grep of `config` reads all three, so a
single call reaches; a first round spent listing the folder still reaches
when a later round reads, and its delegation is then scored as the
over-reach. success = no `task` and no `compose` row; conduct =
`named_db_and_cache`; `task_zero`, `compose_zero`, `calls_in_first_round`
(did the model fan in one message), `covered` and `covered_in_first_round`
are facts.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "the calls covered 2 of the 3 files
  (config/cache.yml unread)"; "over-reach: r1t0:task, r1t1:task, r1t2:task
  on one read's worth of work"; the reply naming the wrong files.
- **kernel finding** — a fanned round `failed` with a kernel error key.
