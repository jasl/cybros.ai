# Scheduled jobs

A scheduled job stores a prompt, an explicit execution policy, and a clock on a
main conversation. At each due occurrence Nexus creates a new ordinary child
conversation and accepts its first input atomically with the schedule advance.
The main conversation may continue working. The child's original answer returns
through the existing asynchronous child-result input path, which queues until
the main conversation can answer.

All paths below start at
`/agent_api/v1/workspaces/:workspace_public_id/conversations/:conversation_public_id/scheduled_jobs`.
The member plane and the parent conversation's access rules apply. Listing and
reading require readable access; creating, editing, and lifecycle commands
require writable access. A scheduled job is scoped to that exact conversation.

```http
GET   /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs
POST  /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs
GET   /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs/{job_id}
PATCH /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs/{job_id}
POST  /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs/{job_id}/pause
POST  /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs/{job_id}/resume
POST  /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs/{job_id}/cancel
GET   /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/scheduled_jobs/{job_id}/executions
```

| Method | Path suffix | Result |
| --- | --- | --- |
| `GET` | empty | `{scheduled_jobs: [...], pagination: {next_after}}` |
| `POST` | empty | `201 {scheduled_job: {...}}`; requires `Idempotency-Key` |
| `GET` | `/:public_id` | `{scheduled_job: {...}}` |
| `PATCH` | `/:public_id` | Optimistic edit; requires `scheduled_job.expected_lock_version` |
| `POST` | `/:public_id/pause` | Pause future occurrences |
| `POST` | `/:public_id/resume` | Resume at the next future occurrence |
| `POST` | `/:public_id/cancel` | Cancel future occurrences and any still-queued last execution |
| `GET` | `/:public_id/executions` | `{executions: [...], pagination: {next_after, last_cursor}}` |

## Intent and rules

Create and edit use a `scheduled_job` envelope:

```json
{
  "scheduled_job": {
    "name": "Morning mail",
    "prompt": "Summarize unread email and report the important items.",
    "rule": {"kind": "daily", "local_time": "09:00", "time_zone": "Asia/Shanghai"},
    "model": {"model": "provider/model", "reasoning_effort": "medium"},
    "configuration": {},
    "tool_names": ["mail_search"],
    "approval_mode": "ask"
  }
}
```

`prompt`, `rule`, and `model.model` are required at creation. `name` is optional
and at most 255 characters. Optional `answering_user_public_id` addresses an
eligible Agent; omission uses the parent's answerer. Optional
`speaker_actor_public_id` preserves an ingress speaker controlled by the creator.
`configuration`, `tool_names`, and `approval_mode` have the ordinary input door's
validation and narrowing rules. An empty tool list remains empty. A null tool
restriction uses the profile's current declaration at execution.

`source_agent_loop_public_id` and `source_task_key`, when supplied together at
creation, identify a task hosted by the main conversation. These immutable weak
references record provenance. Their old execution does not own the job's future
lifetime, and stopping it does not cancel the schedule.

There are three rule shapes:

| Kind | Fields | Meaning |
| --- | --- | --- |
| `once` | `run_at` | One future ISO 8601 instant with explicit UTC offset |
| `interval` | `every_seconds`, `starts_at` | Anchored integer interval from 60 through 31,536,000 seconds |
| `daily` | `local_time`, `time_zone` | `HH:MM` in an IANA time zone |

An initial or explicitly reset clock must land within the ordinary input future
bound of ten years. Timestamp rules normalize to UTC with up to six fractional
digits. Daily rules skip a local time that does not exist during a daylight
saving gap; a repeated local time uses its first occurrence once. Resuming an
expired one-time rule requires creating a new job or editing its rule while it
is paused. Completed and canceled jobs cannot be edited or resumed.

## Dispatch and management

A fixed minutely sweep discovers indexed due rows with a bounded cursor. A lost
enqueue is recovered by later sweeps. The parent conversation row serializes
dispatch against edits, pause, and cancel. Repeated delivery of the same due
occurrence creates one child. After downtime, missed occurrences coalesce into
one execution and the clock advances to the next future occurrence.

A job has at most one unfinished execution. If its previous child still has
its scheduled input queued or its original execution live, a due recurrence advances without starting
another child and records `last_error_code: "execution_in_progress"`. Each new
child inherits the parent's current memory context, access carrier, runner, and
billing subject. The saved prompt, model, tool restriction, approval mode, and
answerer remain the explicit job intent. Changed authority or an unavailable
input policy cannot silently broaden that intent.
Later exchanges or manual regeneration in a reusable child do not hold the
schedule's next occurrence. A side conversation cannot own a scheduled job.

Pause affects future occurrences and leaves an already accepted execution alone.
Cancel also removes the last child's scheduled input if it is still queued. If
that input has already become a turn, the running child remains under the
ordinary conversation/loop stop controls. Repeating pause, resume, or cancel
when it is already in that state is idempotent. A stale edit returns
`409 stale_object`; a forbidden edit or resume of a terminal schedule returns
`422 scheduled_job_finished`.

The schedule states are `active`, `paused`, `canceled`, and `completed`.
`completed` means a one-time clock has been dispatched; its child can still be
queued, running, blocked, failed, or completed. Execution failure belongs to that
child and does not imply that a recurring schedule is canceled.

## Execution projection and callbacks

The job resource includes its UUIDs and intent, `status`, `lock_version`,
`next_run_at`, `last_enqueued_at`, `last_input_public_id`, `last_error_code`,
`last_execution`, and creation/update timestamps. The deterministic response
fixtures are in `contracts/nexus/v1/scheduled_jobs.json`.

`last_execution` and the execution list follow the caller's current access to each
child and omit deleted children. A hidden latest child makes `last_execution`
null; the job's own accepted-input snapshot remains unchanged.

Each execution row contains `child_conversation_public_id`, `input_public_id`,
`turn_public_id`, `agent_loop_public_id`, `scheduled_for`, `status`, and
`created_at`. The input UUID is present from atomic birth. Before materialization,
the turn and loop UUIDs are null. A tool-less reply has a turn and model invocation
but may never have a loop. Those missing identities remain null. `scheduled_for`
is the nominal occurrence, while `created_at` is the actual child birth time.

Both lists use the API's bounded opaque keyset pagination. Execution listings
also return `last_cursor` for the last row, including a non-overflowing page; an
empty page preserves the requested `after` checkpoint. This supports polling
for new executions without replaying old children. Poll the child itself to
observe changes to an already discovered execution.

The callback retains the original scheduled answer, including a provider fallback;
later manual edits or regeneration do not substitute their text. The pending
report retains its execution details until relay succeeds. Acceptance and the
child turn's relay stamp commit together, so repeated recovery does not enqueue
duplicate reports. Queue saturation or temporarily unavailable authority leaves
the report available for retry. After execution detail retention expires, a
provider fallback's durable result still determines the execution projection.

The callback's `callback_result` fixes that worker's conversation, accepted input,
turn and exact final variant UUIDs, plus its original requester actor. Materialized
callbacks retain the descriptor in the turn's `callback_sources`; the worker's
input UUID remains its independent task ID. Compatible worker finals can share
one parent report. Each source is checked before consumption; stopping one source
afterward does not cancel that combined report. External per-worker delivery
uses its own fixed final, while the combined report remains in the main
conversation. See [kernel mail](conversations.md#inputs--the-one-front-door) for the batching
and provenance contract.

The model-facing `<task_result>` envelope names the job and child UUIDs, the
result status, and the child's nominal `scheduled_for` in UTC ISO 8601 with six
fractional digits. Before the answer, a `<prompt>` line carries the first 80
characters of the retained original accepted request, escaped by the same rule
as the answer. This source brief remains available even when job creation was a
command with no message in the main conversation's history. Later edits to the
job's prompt or rule do not change an accepted occurrence's source. The brief is
a bounded identity hint, not the complete task or a guarantee that its one-time
or recurring intent appears within those characters; `scheduled_for` is not the
actual execution or completion time.

A repairable `needs_attention` hold has no final callback yet. Repairing that
original execution can still produce its result. If an edit replaces a held
original, the old execution is stopped and its pending callback follows the
ordinary source-stop rule. Deleting the receiving main conversation or its
workspace releases the pending report's retention obligation.

The callback's durable source stamp names the actual child execution loop, when
one exists. It never names the old loop that created the job. The child
conversation UUID remains the precise source for a tool-less execution. The
main conversation consumes callbacks through its ordinary input door; callback
acceptance itself does not bypass an ongoing reply.

The execution child remains reusable. A later queued `send` from its parent
opens a separate reply obligation, correlated to that sending loop and task and
returned on its answerer, model, tools, approval and wake policy. It does not
replace the scheduled answer or keep the occurrence unfinished. A steer joins
the existing turn and its original obligation. A person's independent exchange,
a third-party request, or a grandchild's callback stays local to the child;
none automatically becomes another scheduled report to the main conversation.
