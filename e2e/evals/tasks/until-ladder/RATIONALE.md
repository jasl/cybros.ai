# until-ladder

**Measures.** `rho do --until`: the daemon runs the acceptance command
when the model ends its turn; a failing check hands the model the output
and another attempt, a passing one closes the loop with a summary. The
check is stateful on purpose (fails once, passes from the second run) so
the whole ladder is proved without the model failing at anything.

**Converts.** `e2e/test/live_until_test.rb:23-78` (the task, the check,
the `until:` line pin, the checks on `rho watch`) and the gallery's
`until_gate` shape (`shapes.rb:494`, predicate `Gallery.until_gate?`
`:225-244`) with the `until` driver (the flags are the task's).

**Dimensions.** reach = any tool row; success = `Gallery.until_gate?`;
conduct = `did_not_run_the_check`; task pass = `note.txt == hello` and
`.check-count >= 2` (`check.sh` restored first); `checks` (the watch's
lines) is a fact.

## Reading a red

- **lane bug** — `error` from the `until:` line assertion (the flags did
  not print), or the deadline before a round settled.
- **model conduct** — "no tool call"; `conduct.did_not_run_the_check:
  false` (it climbed the ladder alone — the count then reads ≥ 2 for the
  wrong reason).
- **kernel finding** — "work-3 was planted after a pass"; "hold-1 is not
  a resolved await_task"; "summary is not the completed deliverable round";
  "work-2 does not name check-1 and hold-1" (nothing crosses an append by
  position, so a round the gate planted without `results:` never read the
  check's output — rho's `Until::Gate#round` or the door's `results:`).
