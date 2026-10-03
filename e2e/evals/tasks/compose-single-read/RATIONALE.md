# compose-single-read

**Measures.** The control of the compose family: a question one `read`
answers must compose nothing. The reach column here reads "did it reach
for a plain tool" and the success column "did it keep its hands off the
graph verbs" — so a model that composes a one-step script is `reached:
true, succeeded: false` with `compose_zero: false` on the record, the
same cell the text bench calls `compose_zero`.

**Converts.** `e2e/support/compose_bench/objectives.rb:93` (O5, `picture:
nil`, "must compose 0: one read_file call"); `task_bench/objectives.rb:79`
(the task family's control, `task_zero`) — this is the compose side of
the same over-reach question.

**Dimensions.** reach = any tool row; success = no `compose` row and no
`task` row; `compose_zero`, `task_zero`, `answered_warn` are facts.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled.
- **model conduct** — "no tool call: the model answered in text" (it
  guessed); "over-reach: r1t0:compose on one read's worth of work".
- **kernel finding** — a round `failed` with a kernel error key on a
  one-read loop; an `attention_required` nobody scripted.
