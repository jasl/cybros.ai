# Events

One closed vocabulary of 25 event types is shared by conversations and standalone runs. Every item names its host as `resource: { type: "conversation" | "run", public_id }` and carries a host-local ascending sequence; not every type appears on every host.

## Durable events

| Type | Carries | Meaning |
| --- | --- | --- |
| `input_accepted` | `origin`, `authored_by: { kind, handle, display_name }`, `answering_user_public_id`, `sender_conversation_public_id`, `deliver_at`, `run_public_id`, `task_key`, optional `expected_steering_run_public_id` | An input was accepted |
| `input_edited` | `deliver_at`, `reason: follow_up_bound \| steer_target_settled` | An input was changed, or a kernel transition re-timed it |
| `input_deleted` | `input_public_id`, `queue_position`, `steer_canceled`, optional `expected_steering_run_public_id` | An input was removed |
| `input_materialized` | `input_public_id`, `queue_position`, `turn_public_id`, `variant_public_id`, `run_public_id`, `task_key` for a consumed steer | An input became a turn, or a steer entered a model request |
| `input_blocked` | `blocked_reason` | A drain refusal, or `run_held` |
| `turn_created` | `answering_user_public_id` | A turn exists |
| `turn_status` | | The turn's status changed |
| `turn_variant` | | A candidate was added, activated or edited |
| `task_status` | | A task changed status |
| `round_result` | | A model round settled |
| `usage` | | Usage was recorded for an invocation |
| `attention_required` | `reason`, `blocked_task_keys` | The run needs a person: `halt_failure`, `awaiting_human`, `deliverable_unresolved`, `approval_required` |
| `context_trimmed` | `history_selected`, `history_skipped`, `history_skipped_reason` | Assembly left history out |
| `context_compacted` | `mode: prune \| kernel \| delegate`, `trigger: usage \| wall \| overflow \| manual \| fallback`, `run_public_id`, `turn_public_id`, `summary_turn_public_id` or `summary_task_key`, `fallback_from`, `fallback_reason` | A compaction repair was armed |
| `fork_created` | | A fork exists |
| `visibility` | | A visibility change |
| `soft_delete` | | A turn or input was soft-deleted |
| `turn_deleted` | | A turn was deleted |
| `reasoning_replay_downgraded` | | Reasoning replay was switched off for this conversation |
| `default_runner_changed` | `executor_public_id`, `previous_executor_public_id`, `by` | The conversation's default runner changed; no task is readdressed |
| `task_readdressed` | `task_key`, `role`, `executor_public_id`, `deadline_at`, `detail` | A held approval's agent delivery address was withdrawn; the person's door still answers |
| `task_deadline_extended` | `task_key`, `deadline_at`, `by`, `timeout_ms` | A claimant extended its own park |
| `access_changed` | `default`, `entries: [{ user_public_id, level }]`, `by`, `kind` | The access carrier was replaced |
| `conversation_ended` | `reason: archived \| tombstoned`, `conversation_public_id` | The last item a tombstoned feed carries |
| `handle_changed` | `user_public_id`, `old`, `new` | A member was renamed; the one type that rides a member's own rows and neither host's feed |

## Replay

```http
GET …/events?after={cursor}&limit={n}
```

Opaque cursors (`cvei`-prefixed on conversations), ascending sequences, `next_after` (null on an empty page) and the committed `watermark` a follower freezes to bound its drain. The watermark survives item expiry; an empty page whose watermark is beyond your consumed sequence means progress is no longer replayable. The retention window is 30 days.

## Cable channels

| Channel | Subscription | Envelope |
| --- | --- | --- |
| Conversation events | `items: "events"` | `{ event }` — the durable items above |
| | `items: "lifecycle"` | `{ event }` narrowed to `turn_status`, `attention_required`, `conversation_ended` |
| | `items: "progress"` | `{ frame }` — ephemeral tool and process output and kernel timings; nothing durable, nothing replayed |
| Transcript | | Text deltas, resets and settled snapshots for a turn or task; no replay log |
| Run events | | The same vocabulary at a standalone run's own address |
| InferenceRequest events | | The request's execution state and usage |
| Executor inbox | executor-keyed | `work_available` (run, task key, tool name) and `work_canceled` |

Progress is limited to one frame per key per 250 ms per kernel process; excess cadence is acknowledged and dropped.

Payload details, the transcript and progress frame vocabularies and the retention rules are in [Conversation feeds](agent-api/conversation-feeds.md) and [Run feeds](agent-api/run-feeds.md).
