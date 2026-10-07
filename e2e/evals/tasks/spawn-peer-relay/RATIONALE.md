# spawn-peer-relay

**Measures.** The peer half of `spawn`: a spawn addressed to another agent by its
@handle (`agent:` is the address, the kernel never scans prose for
`@`) with `wait: true`, the paired reply as the call's own result, and
the person's answer read off it. The reach dimension is SP1's (the lead
names the peer, no tool named); the `spawn` text's `agent`/`wait` are NEW
bytes measured by the SP rows and this row, never tuned.

**Converts.** `e2e/support/task_bench/objectives.rb` SP1 (the peer by
handle) with `wait: true`; the columns are the spawn row's own
(`tool_input.agent`, `tool_input.wait`, `status`) and `rho result`'s text.
The fixture is task-mail's `lib/calc.rb` alone: `sub` is `a + b` on line 3.

**Harness requirement.** This task needs two daemon homes in the same
steward-created `account_wide` workspace, with the peer registered as
`@reviewer`. Rho supports adopting that room through `--workspace` or
`RHO_WORKSPACE`, and the principals endpoint exposes member handles. The
evals runner does not yet provision this second agent home: the task loads,
but an ordinary evals invocation cannot establish its required peer. Treat
that missing setup as a lane failure, not a model result. The deterministic
spawn and runner-mode journeys exercise peer delivery separately.

**Dimensions.** reach = a `spawn` row addressed to `@reviewer`; success =
waited, the row completed, the reply names line 3; `agent`, `waited`,
`line_named` are facts. No verification (the peer only reads).

## Reading a red

- **lane bug** — a missing `@reviewer` (`principal_unknown`) or a peer
  without room access (`answerer_not_eligible`); a harness `error`, or a
  deadline before the paired reply settles. A wait's expiry detaches the
  child and reports the timeout; it is not a paired reply.
- **model conduct** — "no `spawn` call: the model called {task: 1}" or
  "{read: 1}" (it reviewed the file itself); "the spawn named no peer"
  (a subagent where the lead named the reviewer); "the spawn did not
  wait" (the reply then arrives in a later turn and the person's reply
  carries no line); "the reply did not name line 3" (the peer's answer
  was not relayed into the reply).
- **kernel finding** — the peer spawn `completed` with `wait: true` and
  the reply names no line: the paired `<task_result … conversation=…>`
  did not reach the continuation's sealed request (read the sealed
  request in the artifact); the peer's reply arrived as mail beside the
  paired result (a double delivery).
