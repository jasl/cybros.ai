# spawn-subagent-suite

**Measures.** The task-mail twin on a SPAWN: a persistent subagent — a fresh copy of the caller with
no `agent` — handed a slow suite and left to work, the kernel's mail of its
reply (`input_accepted{origin: child}`, drained first like any receipt),
the woken turn, and the person's turn 2 reading the failing test off the
child's reply instead of re-running the suite. The reach dimension is
the SP0 wording ("a fresh agent you can keep talking to" — no tool named);
the `spawn`/`send`/`status`/`cancel` texts are NEW bytes measured by the
SP rows and this row, never tuned. The child's fix of `Calc.sub` is the
hidden verification (the graded test files are restored first). The wake
is the model's to choose, as task-mail's is: a spawn that asked `wake:
"passive"` has its child's reply join the history as a `message` turn
with no reply started, which is right provided turn 2 reads it there.

**Converts.** `e2e/support/task_bench/objectives.rb` SP0 (the subagent
spawn with no `agent`) and `e2e/evals/tasks/task-mail` (its columns —
`child_replied`, `reply_woke_a_turn`, `mail_in_turn_2_history`,
`named_the_failing_test`, `reran_the_suite` — on a child's reply). The
driver is `spawn_reply` (`e2e/support/evals/drivers.rb`): the
`say_second_turn` twin keyed on the `spawn` row and `origin: child`,
because a detached `spawn` row settles at once (unlike a detached `task`,
live until its branch ends) and `settle_receipts`' quiet read would
return before the child replied. The fixture is task-mail's: `Calc.sub`
is wrong, `test/all.rb` sleeps 45 s.

**Dimensions.** reach = a `spawn` row; success = the three owed facts,
the first false one named — `reply_woke_a_turn` owed only when a spawn
left the wake `auto` (`wake_passive` false) — then turn 2's two reads;
`spawn_waited`, `spawn_agent`, `spawn_calls`, `child_receipts`,
`turn_1_called`, `wake_passive` and a passive run's `reply_woke_a_turn`
are facts;
task pass = the verification (`Calc.sub` subtracts under the fixture's
own test).

## Reading a red

- **lane bug** — `error` (the deadline before a round settled; "the
  receipt woke no turn" raised past 300 s with a child reply on the
  feed and the wake left `auto` is the lane's own wait), or a
  verification that raised.
- **model conduct** — "no `spawn` call: turn 1 called {task: 1}" (the
  wording read as a one-shot job — SP3's line) or "{bash: 2}" (it ran
  the suite itself and waited 45 s); "the spawn waited (wait: true)"
  (the person said not to); "turn 2 re-ran the suite"; "turn 2 did not
  name test_subtracts"; an `agent` on the spawn (a peer where a subagent was
  asked for — `spawn_agent` on the record); the verification red with the
  reply claiming a fix (the child edited the test, restored before
  judging).
- **kernel finding** — a `spawn` row completed and "the kernel mailed
  no child reply within 300 s" (the child's reply is owed as mail,
  `Mail.child_reply`); "the child's reply woke no turn" with
  `wake_passive` false; "the child's reply turn is not before turn 2 on
  the timeline" (child reply inputs drain before later human inputs — a
  passive reply's `message` turn the same); the child's bash
  ran outside the project (the environment root did not follow the
  spawn — `child_receipts` 1 with the verification red and no edit under
  lib/); a round `failed` with a kernel error key.
