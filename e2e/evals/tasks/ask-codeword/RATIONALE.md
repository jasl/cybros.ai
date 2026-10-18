# ask-codeword

**Measures.** The half of the loop the coding turn cannot reach: the
model is given a task it CANNOT finish without asking, the run holds,
a person answers through `rho answer`, and the model uses the answer.
"Did it ask" and "did it use the answer" are one check on disk.

**Converts.** `e2e/test/live_human_in_the_loop_test.rb:45-118` (the task,
the ask surfacing on the daemon, `rho answer`, the file) with the
`answer_ask` driver; the codeword is the seed's secret, never a constant.

**Dimensions.** reach = an `ask` row; success = `Gallery.ask_human?`;
conduct = `asked_for_the_codeword` (the prompt it asked); task pass =
`greeting.txt == seed.secret`.

## Reading a red

- **lane bug** — `error` ("the model never asked" after 300 s is the
  driver's flunk: with `reached: false` it is conduct, with an `ask` row
  on the trace and no attention it is the daemon's), or the deadline
  before a round settled.
- **model conduct** — "no ask: the model called {write: 1}" (it guessed);
  `task_pass: false` with the predicate green (asked, answered, wrote
  something else).
- **kernel finding** — "the ask r1t0-ask-1 was not answered: running"
  after `rho answer` succeeded; "the feed never called for a person".
