# Statuses

## Task statuses

`waiting | needs_approval | running | dispatched | awaiting_input | completed | failed | canceled | timed_out | uncertain | skipped`

A status names who is being waited on; the task's kind names what the wait is.

| Status | Who is waited on |
| --- | --- |
| `waiting` | A dependency |
| `needs_approval` | An approver — a model-composed tool call resting at the approval stage |
| `running` | The kernel: a round driving a provider call, or a kernel tool |
| `dispatched` | A holder outside the kernel with a bearer proof: a claimed tool call, or an await whose resolution token left in a receipt |
| `awaiting_input` | A person nobody handed anything to: a model's question through `ask` |
| `completed`, `failed`, `canceled`, `timed_out` | Terminal |
| `uncertain` | A claimed, non-replayable tool call whose executor expired with no result; a person's `retry` or `abandon` decides |
| `skipped` | A `propagate` failure upstream |

Each kind declares its own machine; a client that predates a status treats an unknown one as live.

## Failure policies

`on_failure` is `propagate` (skip not-yet-started descendants; joins treat the skip as settled non-success), `absorb` (settle in the failing write; dependents proceed) or `halt` (adjudication hold).

## Failure keys

`error: { key, detail? }` on a failed task. The keys and their recovery are listed in [Errors and recovery](../build/errors-and-recovery.md): `approval_denied`, `approval_expired`, `tool_failed`, `tool_timeout`, `tool_uncertain`, `tool_not_served`, `executor_revoked`, `await_failed`, `await_timeout`, `provider_http_error`, `provider_error`, `provider_overloaded`, `attempt_budget_spent`, `provider_model_unavailable`, `provider_context_overflow`, `context_overflow`, `model_refused`, `model_capability_unavailable`, `missing_input`, `round_expansion_refused`, `input_source_unavailable`, `foreign_tool_history`, `hook_requires_model`, `run_canceled`, `join_loser_canceled`.

## Run statuses

`pending | running | paused | needs_attention | canceling | completed | canceled`

There is no `failed`: a reasoned cancel is the run failing, and the turn derives its own failed state from a hold or that cancel. `needs_attention` carries `attention: { reason, blocked_task_keys }` with reason `halt_failure`, `awaiting_human` or `deliverable_unresolved`; a hold has no clock.

## Turn and variant

A turn's candidate (`active_variant`) and a separately running regeneration (`running_variant`). A variant reports its source (`generated`, `edited`, `imported`, `fallback` with `origin_variant_public_id`) and its terminal outcome. After retention, `details_pruned_at` marks expired evidence.

## Inputs

Pending, `blocked` (with `blocked_reason`), consumed into a turn (read `…/materialization`), or deleted. Delivery modes: `queue`, `steer`, `steer_now`.

## Workspaces

`active | archiving | archived | restoring`; a deleted workspace is a tombstone absent from every surface.

## Conversations

The working list, the archive (`conversation_ended` with `reason: archived`, restorable) and the tombstone (`reason: tombstoned`).

## Schedules

`active | paused | canceled | completed`; `completed` means a one-time clock was dispatched and its child may still be running. `last_error_code: execution_in_progress` records a skipped recurrence.

## Executors

`status: active | revoked`; `presence: online | offline | not_yet_seen` (display only); `credential_epoch` advances on re-pair.

## Envelope caps

64 steps per request, 32 members per fan and per follower's wait, 33 reads per model step, 1 MiB payload; 1 MiB canonical JSON for `tool_definitions`; 64 KiB for `compaction_policy` and `approval_rules`.
