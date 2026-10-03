# handoff-mid-conversation

**Measures.** `rho handoff` mid-conversation:
turn 1 on rho's own runner, the binding moved to a runner-mode rho on a
second home over the same tree, turn 2's bash running THERE — proved by
the second home's own log, never by `rho ps`. The model's part is two
trivial turns; the capability is the deployment's.

**Converts.** `e2e/test/live_handoff_test.rb:25-105` with the `handoff`
driver (`daemon.runner_home: true` starts the second home; `turns:` is
the person's turn 2). Every assertion of the lane is a fact here:
`handed_off`, `tree_synced`, `turn_2_bash_rows`, `turn_2_bash_on_runner`,
`runner_log_claimed_turn_2`, `own_runner_idle_after`.

**Dimensions.** reach = turn 1's bash rows completed; success = the six
facts, the first false one named; task pass = `hello.txt == hello`.

## Reading a red

- **lane bug** — `error`: the runner-mode home did not pair (`start_runner_rho!`
  flunked), `rho handoff` refused, "the receipt woke no turn" from the
  driver's wait; or the deadline before a round settled.
- **model conduct** — "turn 1 ran no shell command" (it wrote the file
  and replied); "turn 2 ran no shell command".
- **kernel finding** — "turn 2's bash was not claimed by the runner-mode
  rho" (the row was addressed elsewhere: the binding did not move);
  "rho's own runner claimed a row after the handoff"; a `runner_task_failed`
  in either home's log (read the copied logs).
