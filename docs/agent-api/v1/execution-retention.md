# Conversation execution retention

Nexus keeps conversation text while reclaiming completed execution detail. The
Account's `execution_details_retention_days` defaults to `90`; a positive integer
changes the window and `null` disables future cleanup. A Human administrator
manages this through [Account retention](../../platform-api/v1/retention.md).
Increasing the window or disabling cleanup cannot restore deleted evidence.

## What is retained

Conversation turns and variants, their original `prompt`, final `content`, original model
selection, and landed follow-up messages remain. Landed follow-ups use the
variant's `steers` content body: immutable fragment references and their upload
bindings, in message order. Forked histories continue to reference the retained
turns. Ordinary conversation visibility, overrides and access rules still apply.

The nightly job prunes conversation-backed runs after `completed_at`, not after
a reply's earlier `delivered_at`: background work must finish first. Direct,
tool-less reply invocations age from `terminal_at` after their result has settled
onto the variant. Every variant's own execution ages independently, including
regenerated candidates. Pending model work, settlement receipts and outstanding
delegation results prevent collection until they finish.

The job removes the execution graph, task input/output and tool result bodies,
sealed provider requests/responses, reasoning traces, invocation attempts, and
invocation-owned output files. It keeps the run's public identity and terminal
state. Usage records retain their existing billing lifetime, and the conversation's
`usage_summary` retains cumulative tokens and known cost after execution detail
is removed. It includes every recorded candidate and background call; choosing
another candidate or undoing a turn does not subtract spending. Standalone runs
and inference requests keep their existing lifecycle; this setting governs conversation
execution only.

Conversation event replay still has its independent 30-day lifetime. Selecting a
shorter execution window does not shorten that replay window, so a recent event
may still contain an execution preview. Orphan fragments are collected by the
existing fragment reaper; PostgreSQL vacuum makes dead-row space reusable later.
Retention is not a promise that disk files shrink immediately.

## Reading expired execution

A retained variant includes `details_pruned_at` when its execution evidence has
expired. A run's overview and index include the same timestamp; the overview
still returns its terminal status, with no tasks. These fields are absent while
evidence remains available.

The Run or variant's `runner_effects` becomes:

```json
{"status":"unavailable","runners":[],"reason":"execution_details_pruned"}
```

This is different from `untouched`: the old runner checkpoint can no longer be
established. A fork-point effect projection is also unavailable when an expired
later run in the source's reachable history could have changed a Runner. Nexus does not
invent a checkpoint or claim that no filesystem write occurred.

Graph, phases, transcript, task detail and task/lifecycle mutation routes on an
expired run return `410` with error code `execution_details_pruned`. The
variant's sealed-request and stored-reasoning routes return the same response. Regenerating an
expired original returns `409` with that code; it cannot replay the original
request and tool configuration. Posting a new conversation input still works:
it creates a new execution using current configuration and retained history.

For subsequent prompt assembly, expired history renders its original question,
retained follow-ups and final answer instead of replaying the removed tools.
The existing history budget still applies. Follow-ups are read in a bounded
newest-message window (100 per variant); all original fragments remain stored
and searchable. A fork copies the same retained bodies without copying the
removed execution graph.

## Cleanup operation

`Conversations::PruneExecutionDetailsJob` runs nightly. Each hop materializes a
bounded, indexed source window, advances past retained owners and carries its
cutoff into the next hop. The next nightly pass revisits earlier blockers.
Disabling retention stops further hops. Each owner is serialized in the same
conversation-before-execution lock order used by materialization and convergence,
so ordinary materialization does not observe partially removed detail. An active
first round whose history request has not been sealed retains its source graphs,
including inherited sources. Fork readers additionally verify the selected run
markers after assembling their fixed history window; if retention committed
during that read, they rebuild from retained text before sealing the request.
Already-sealed active turns do not keep old graphs alive indefinitely.

The service only operates on its selected Account. It does not require a new
ledger, a separate schedule authority, or an operator-triggered cleanup command.
