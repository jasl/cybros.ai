# task-fan-five

**Measures.** The fan of five through `exe/rho`, waited or detached: one
`task` per file in ONE message, the merge naming all five, no second task
for a delegated file, no graph verb inside a branch. The compose sibling
(`shape-fan-join`) names the verb; this text does not — it says "a
separate agent, all at once", testing whether a model reaches for `task`.
The run is read at the quiet point (`settle_receipts`: every loop the
receipts woke has settled and no task of any of them is live), and the
merge is read on the first reply that names all five, turn 1's or a
receipt-woken turn's (`replies`, every loop on the feed with what `rho
result` printed, turn 1's first); `waited` and `merge_turn` are facts.

**Converts.** `e2e/test/live_task_mail_test.rb:142-170` (`run_fan`:
`task_calls_in_first_message`, `merge_names_all_five`,
`no_second_task_per_file`, `graph_verbs_inside_branches`, `per_file`) with
the `settle_receipts` driver (the gallery's `plain` driver through bench
version 13); the fixture is `fan_project!` (`:245-264`).

**Dimensions.** reach = ≥ 5 `task` rows fanned by r1; success = the
merge names all five AND `per_file <= 1` AND no graph verb in a branch
AND the loop completed; `per_file`, `task_calls_in_a_later_round`,
`orphans_named` (on the reply the merge is read on), `waited` (any `task`
row `wait: true`) and `merge_turn` (`primary`, `woken-N`, or nil when no
recorded reply names all five) are facts.

**What the record cannot see.** `read_trace` reads the primary loop's
graph and tasks (`e2e/support/evals/member_plane.rb:382-391`), so
`per_file` and `graph_verbs_inside_branches` cannot see a woken turn's
re-delegation. When no reply names all five, the red reads the run's
`reply`: the last loop's under `settle_receipts`, turn 1's on a
`plain`-driver record. Through bench version 13 the `plain` driver
stopped once the tasks settled, so a woken merge that had not finished
by then is not on those records — a detached fan whose merge came later
reads red on turn 1's promise there; a record from before the lane
recorded `replies` holds turn 1's reply alone, and `merge_turn` reads it
alone.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "2 task call(s) in the first message, not five"
  (it looked first, then fanned — `task_calls_in_a_later_round` says so);
  "a second task for c.rb"; "the merged reply names no lib/e.rb" — read
  `waited` and `merge_turn` beside it: on a record from bench version 13
  or earlier, a detached fan with `merge_turn: nil` may have merged after
  the stop (above).
- **kernel finding** — five branches opened and one never settled (the
  loop rests `running` past the deadline with `waiting_on` set: read
  `loop_status`); a round `failed` with a kernel error key; "1 graph
  verb(s) inside a branch" is the MODEL's (a branch's declared set drops
  the graph verbs — a `task` row a round not marked the spine's made (the
  kernel's `spine: false`) is a kernel finding: the branch was offered a
  verb it must not have).
