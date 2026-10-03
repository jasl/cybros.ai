# task-background-suite

**Measures.** T2 through `exe/rho`: a `task` call for the suite WITHOUT
`wait: true` (the default is the background; the opt-in is the wait)
while the lint runs direct. The offline probe scores the emitted message;
here the rows are the trace's, with `tool_input.wait` joined. The
40-second suite stand-in and the two-offence lint are the compose
sibling's fixture.

**Converts.** `e2e/support/task_bench/objectives.rb:63` (T2: `suite_in_background`,
`lint_direct`, `one_task_for_the_suite`, `no_start_process`).

**Dimensions.** reach = a `task` row, and no compose row in or before the
round that handed the job out; success = T2's four booleans over the rows;
`task_calls`, `suite_in_background`, `d4_right` (the D4 door objective's
rule over that round: one background `task` naming the suite, no
`start_process`, no compose), `compose_after_task` and `door_calls` are
facts. No verification.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no `task` call: the model called {bash: 2}" (it
  ran the suite itself and waited 40 s); "the job went through compose
  (compose_one): r1 called {compose: 1, bash: 1}" (a compose in or before
  the round that handed the job out — a compose after the `task` is
  `compose_after_task`, a fact); "the suite's task waited (wait:
  true)"; "start_process was used for a command whose result was needed"
  (the task needs a result from this command).
- **kernel finding** — the suite's detached task never delivered its
  receipt (`facts.receipts: 0` after the reply went final — read with the
  feed in the artifact); a round `failed` with a kernel error key.
