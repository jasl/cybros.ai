# Schedules

A scheduled job stores a prompt, an explicit execution policy and a clock on a main conversation. At each due occurrence Nexus creates an ordinary child conversation and accepts its first input atomically with the schedule advance. The main conversation may keep working; the child's original answer returns through the asynchronous child-result input path and queues until the main conversation can answer.

For a later instruction in the **same** conversation, use a queued input with `deliver_at` instead. It waits for the turn boundary and runs once; an absolute time permits exact replay.

## Routes

```http
GET   /agent_api/v1/workspaces/{workspace_id}/schedules
GET   /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/schedules
POST  /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/schedules
GET   …/schedules/{job_id}
PATCH …/schedules/{job_id}
POST  …/schedules/{job_id}/pause
POST  …/schedules/{job_id}/resume
POST  …/schedules/{job_id}/cancel
POST  …/schedules/{job_id}/run
GET   …/schedules/{job_id}/executions
```

The workspace-level index lists the jobs of every conversation the caller can read. Listing and reading require readable access; creating, editing and lifecycle commands require writable access. Creation requires an `Idempotency-Key`; edits carry `schedule.expected_lock_version`.

## Create

```json
{
  "schedule": {
    "name": "Morning mail",
    "prompt": "Summarize unread email and report the important items.",
    "rule": { "kind": "daily", "local_time": "09:00", "time_zone": "Asia/Shanghai" },
    "model": { "model": "provider/model", "reasoning_enabled": true, "reasoning_effort": "medium" },
    "configuration": {},
    "tool_names": ["mail_search"],
    "approval_mode": "ask"
  }
}
```

`prompt`, `rule` and `model.model` are required. Optional `answering_user_public_id` addresses an eligible agent (default: the parent's answerer); `speaker_public_id` preserves an ingress speaker. `configuration`, `tool_names` and `approval_mode` follow the input door's narrowing rules. `source_run_public_id` and `source_task_key` record provenance without owning the job's lifetime.

| Rule | Fields | Meaning |
| --- | --- | --- |
| `once` | `run_at` | One future ISO 8601 instant with an explicit UTC offset |
| `interval` | `every_seconds`, `starts_at` | Anchored integer interval from 60 through 31,536,000 seconds |
| `daily` | `local_time`, `time_zone` | `HH:MM` in an IANA time zone; a nonexistent local time during a DST gap is skipped |

## Dispatch

- A minutely sweep discovers due rows. Repeated delivery of the same occurrence creates one child; missed occurrences after downtime coalesce into one.
- A job has at most one unfinished execution. While the previous child is still queued or live, a due recurrence advances without starting another and records `last_error_code: "execution_in_progress"`.
- Each child inherits the parent's current memory context, access, runner and billing subject; the saved prompt, model, tools, approval mode and answerer remain the job's explicit intent.
- `run` starts one execution now under the saved intent without changing `next_run_at` or the status; it answers `409 execution_in_progress` while the previous child is unfinished.
- Pause affects future occurrences; cancel also removes the last child's input if still queued. A running child uses the ordinary stop controls.

States are `active`, `paused`, `canceled` and `completed`; `completed` means a one-time clock was dispatched, and its child may still be queued, running, blocked or failed. A stale edit returns `409 stale_object`; editing or resuming a terminal job returns `422 schedule_finished`.

## Executions and callbacks

The job carries `status`, `lock_version`, `next_run_at`, `last_enqueued_at`, `last_input_public_id`, `last_error_code` and `last_execution`. Each execution row names `child_conversation_public_id`, `input_public_id`, `turn_public_id`, `run_public_id` (null before materialization, and null for a tool-less reply that never needs a run), `scheduled_for` and `created_at`. Executions paginate with an opaque keyset and return `last_cursor` for polling new rows without replaying old ones.

The callback retains the child's original answer, including a provider fallback; later edits or regeneration in the child never substitute their text. The model-facing `<task_result>` envelope names the job, the child, the result status and `scheduled_for`, preceded by a `<prompt>` line with the first 80 characters of the original request. A held child with a repairable failure has no callback yet; repairing it still produces the result.

The execution child remains reusable: a later `send` from the parent opens a separate reply obligation and never replaces the scheduled answer.

The complete contract is the [Schedules reference](../reference/agent-api/schedules.md). See [Schedules](../use/schedules.md) for rho's browser, Telegram and CLI controls over the same resource.
