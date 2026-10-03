# task-detached-receipt

**Measures.** The detached shape, told the verb ("a background
task" alone reads as `start_process`, so the shape's text names `task`
and says not `start_process`): the branch root under the call, the
continuation unreachable from it, the receipt as kernel mail, the woken
turn completed. The instruction asks to be told whether the suite passed
once it finishes, so the woken turn is owed: only a receipt that wakes a
turn can say it, and a call that asked `wake: "passive"` (the receipt
recorded as history, no reply started) misses the instruction. The
neutral-wording twin is `task-mail`, whose instruction leaves the wake
open.

**Converts.** The gallery's `detached_receipt` shape
(`e2e/support/gallery/shapes.rb:500`, predicate `Gallery.detached_receipt?`
`:257-280`, the fixture `mail_files` `:371`) with the `say_second_turn`
driver and no `turns:`.

**Dimensions.** reach = a `task` row, and no compose row in or before the
round that handed the job out; success = `Gallery.detached_receipt?`,
a passive wake's red naming the wake; `reply_final_with_background`,
`receipt_woke_a_turn`, `wake_passive`, `d4_right` (the D4 door objective's
rule over that round: one background `task` naming the suite, no
`start_process`, no compose), `compose_after_task` and `door_calls` are
facts.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no background task was started (no `task` call)";
  "the job went through compose (compose_one): r1 called {compose: 1,
  bash: 1}" (a compose in or before the round that handed the job out — a
  compose after the `task` is `compose_after_task`, a fact);
  "every task branch reaches its call's continuation: the model waited
  (`wait: true`)"; "only 1 loop completed on the feed: the receipt woke no
  turn — the call asked `wake: "passive"`, so no turn told the person
  whether the suite passed" (the instruction miss).
- **kernel finding** — "no input_accepted{origin: task_result}: the kernel
  never mailed the receipt" with a detached branch on the graph; "only 1
  loop completed on the feed: the receipt woke no turn" with the wake
  left `auto`.
