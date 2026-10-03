# task-mail

**Measures.** The cross-turn half of the tools' bench: a background task
that outlives the reply, the kernel's mail, the woken turn, and the
person's turn 2 reading the mail from history instead of re-running the
suite. Every column of `live_task_mail`'s `mail` objective is a FACT on
the record; the reach dimension is the model's willingness to reach
for `task` in a neutral wording (no tool named). The wake is the model's
to choose: the instruction asks for the count now and turn 2's answer
later, never for a reply when the suite ends, so a call that asked
`wake: "passive"` — the receipt joins the history as a `message` turn
and starts no reply — is as right as one that woke a turn, provided turn
2 reads the receipt from that history.

**Converts.** `e2e/test/live_task_mail_test.rb:85-124` (`run_mail`:
`task_started`, `reply_final_with_background`, `mailed`,
`receipt_woke_a_turn`, `mail_in_turn_2_history`, `named_the_failing_test`,
`reran_the_suite`) with the `say_second_turn` driver and `turns:` (the
person's turn 2, said once the woken turn ended). The fixture is
`mail_project!` (`:195-223`): `Calc.sub` is wrong, `test/all.rb` sleeps 45 s.

**Dimensions.** reach = a `task` row, and no compose row in or before the
round that handed the job out; success = the six booleans, the
first false one named — `receipt_woke_a_turn` owed only when a call left
the wake `auto` (`wake_passive` false); `named_the_failing_test`,
`reran_the_suite`, `turn_1_called`, `turn_2_reply`, `wake_passive` and a
passive run's `receipt_woke_a_turn` are facts; `d4_right` (the D4 door
objective's rule over that round: one background `task` naming the suite,
no `start_process`, no compose), `compose_after_task` and `door_calls`
are facts beside the door's.

## Reading a red

- **lane bug** — `error` ("the receipt woke no turn" raised past 300 s
  with a mail on the feed and the wake left `auto` is the lane's own
  wait), or the deadline before a round settled.
- **model conduct** — "no `task` call: turn 1 called {start_process: 1}"
  (the neutral wording reads as a process); "the job went through
  compose (compose_one): r1 called {compose: 1, bash: 1}" (a compose in or
  before the round that handed the job out — a compose after the `task`
  is `compose_after_task`, a fact); "the reply waited
  for the suite"; "turn 2 re-ran the suite"; "turn 2 did not name
  test_subtracts".
- **kernel finding** — `task_started` and `reply_final_with_background`
  true and "the kernel mailed no receipt" (the mail is owed); "the
  receipt woke no turn" with `wake_passive` false (an `auto` receipt
  wakes an idle conversation); "the receipt's turn is not before turn 2
  on the timeline" (receipt inputs drain before later human inputs — a
  passive receipt's `message` turn the same).
