---
title: Conversation inputs
description: The durable waiting room — posting a message or a reply, every input field, attachments, the speaker envelope, kernel mail and the queue's edit surface.
---

# Conversation inputs

Every caller-authored message rides `POST …/inputs` with an
`Idempotency-Key`. The accepted row is the durable waiting room, and a
drain materializes it into a turn: messages immediately when the lane is
idle, while `direct_reply` heads become a running assistant turn.

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/reorder
```

## Create an input

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs
```

### Request

```json
{
  "input": {
    "kind": "direct_reply",
    "text": "optional prompt riding as the final user message",
    "model": { "model": "openai_api/gpt-6.1-sol", "reasoning_enabled": true, "reasoning_effort": "medium" },
    "configuration": {},
    "tool_names": ["read_file", "write_file"],
    "approval_mode": "ask",
    "delivery_mode": "queue",
    "deliver_in": "20m",
    "context_mode": "assembled",
    "history": { "max_entries": 20, "token_budget_share": 0.5 },
    "expected_context_revision": 4,
    "expected_tail_turn_public_id": "0198…",
    "answering_user_public_id": "@lark"
  }
}
```

### Response

`202` with the accepted row. Within the 24-hour replay window, the same
key and request return the original complete acceptance, including text,
raw instructions, assembly intent and authored steps, even after the
queued input has been edited or consumed. `Idempotency-Replayed` is
`false` for a new acceptance and `true` for a replay. A changed request
with that key returns `409 idempotency_envelope_mismatch`.

The receipt adds no separate prompt-size ceiling: submitted content and
the compiled request retain their own storage and model-window limits.
Long inline text, declared variable values and raw instructions are
accepted under the same rules on create and PATCH; an assembled prompt
that exceeds its storage wall when materialized remains a blocked input
that can be edited or deleted.

## Which engine answers

The answering Agent determines the reply's engine: the input's
`answering_user_public_id` when supplied, otherwise the conversation's
stored answerer. A peer's post uses that addressee's configuration, not
the poster’s. An inline `execution_declaration` supplies the configuration
for this execution without creating or changing the answering User.

For peer-sent work or a reply addressed away from the stored answerer,
the addressee's declared `default_model` precedes conversation history and
the submitted initiator model. If that implicit preset is unavailable,
context estimate and materialization scan its captured ordered
`fallback_models`, subject to the captured `model_selection` constraints.
Ordinary inputs to the stored answerer keep their submitted initial model.
The [model recovery contract](models.md#model-selection-and-recovery) defines
permitted switches and unavailable candidate skips.

For an ordinary reply, an Agent with explicit `tool_definitions`,
imported `kernel_tools`, lifecycle hooks or Runner imports enabled
produces a kernel Run. Runner imports are enabled when
`runner_executor_public_ids` is nonempty and `runner_tool_names` is not
`[]`. An Agent with none of these, or a Human answerer, produces a direct
`conversation_reply` model invocation. Nonempty input `steps` also
require the run-backed engine; its ordinary approval-mode requirement
still applies, and `approval_mode_required` blocks materialization when
no mode is declared. Kernel result-mail replies use a run even when the
receiving Agent has neither tools nor hooks, so their failed model tasks
remain repairable.

A backing run starts `running`. Its first round seals the assembled
request with the Agent's tools, narrowed by the input's `tool_names`, and
freezes its compaction, hook, approval and memory policy. An explicit
`tool_names: []` removes tools for that turn while retaining the
declaring Agent's run engine. The variant reports `source: "run"`, and
turn events carry `run_public_id`. A client submits the input, not a
separate `POST …/runs`.

Both engines use the same timeline assembly. `context_mode: "raw"`, or an
Agent declaring `prompt_mechanism: "raw"`, instead uses the input's own
entries.

## Input fields

See [Conversation input fields](conversation-input-fields.md) for every
field an input carries — attachments, `kind`, `steps`, the model and the
addressee, delivery and scheduling, the context and tool fields, inline
text, history and variables — and for how history fits itself to the
window.

## Fences and bounds

**Freshness fences.** `expected_context_revision` refuses `stale_context`
and `expected_tail_turn_public_id` refuses `stale_timeline`, both
synchronously at accept.

**The queue bound.** The caller-authored queue bound refuses `409
input_queue_full` synchronously, and peer mail counts. The kernel's own
`task_result` mail is not counted against the bound but can meet it — a
refused mail is retried, never dropped.

## Kernel mail

See [Kernel mail](conversation-kernel-mail.md) for the inputs the kernel
writes itself: a background result after the reply is final, a spawned
child's relayed reply, receipt batching, and what happens when mail cannot
run.

## Blocked heads

A head the drain cannot serve parks as `state: "blocked"` with its reason
— `unknown_model`, `estimated_input_exceeds_model_limit`,
`author_not_authorized` (the author may no longer write here; the repairs
are the delete, or the author's write standing restored, since an edit
changes the words and never the author) and the others named above. The
park is durable, narrated on the event stream, and holds the queue behind
it in FIFO order.

## The waiting room

### Read the queue

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs
```

It reads the queue in read order — the kernel's own rows first, then
arrival — with each row's text and `lock_version`.

While a row is `pending` or `blocked` it stays a principal's to change: a
person's word and a peer's `send` (`origin: agent`) alike, since the
recipient's queue is theirs to manage. Unless it is the kernel's: a row
with `origin: task_result | child` is immutable to the person, and every
verb below refuses it `409 kernel_input_immutable`.

Stopping its source execution withdraws pending result mail and cancels
undelivered derived replies. An already-consumed combined worker report
belongs to its receiving conversation and survives an individual source
Stop. Canceling an individual task changes that task's result, and an owed
canceled result can still be delivered.

### Edit an input

```http
PATCH /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs/{public_id}
```

It edits content (`text` or raw `entries`) and its pictures
(`attachments`), the initial model, `configuration`, `execution_declaration`,
`model_selection`, `fallback_models`, `tool_names` (`[]`
is no tools; the whole declaration by name restores it), `steps` (a
supplied array replaces the queued work; omission or null keeps it, and
`[]` clears it), `visible_in_context`, `context_mode`, `history`,
`reasoning_replay`, and `deliver_at` or `deliver_in`. An optional
`expected_lock_version` CAS refuses `stale_object` on a miss.

**Attachments on an edit.** Absent keeps the binding: an edit that carries
new `text` re-composes the message from that text plus the pictures the
row already binds, so the fix for a blocked head never loses one. `text:
""` clears the words while keeping those pictures, `[]` unbinds, and a
list rebinds in that order, beside the row's words when the edit carries
none. Never beside raw `entries`.

**Intents are replaced whole.** A PATCH naming `history` or
`reasoning_replay` replaces the whole stored intent with exactly what it
sent; an intent you want kept must ride along.

**Times.** Absent keeps the time, a time reschedules, and `deliver_in:
"0s"` makes the row due now — the same two bounds as on create.
Rescheduling a blocked head into the future immediately lets other due
rows drain, and the edited row still wakes at its new time.

**Editing a blocked head is the unblock path**: the edit is the fix, the
row returns to `pending`, and the drain re-judges it.

`kind`, `role` and the sender stamp are create-frozen.

**A held steer** has one timing edit: `input: {delivery_mode:
"steer_now"}`, optionally with `expected_lock_version`. It promotes the
existing row and wakes its execution without changing its content or
target. Repeating that promotion while the row remains held is accepted;
an already-consumed row is `404 not_found`. Other fields beside the
promotion refuse `409 steering_held`. Changing a queued row's delivery
mode, or downgrading an immediate steer, refuses `422 validation_failed`
naming `delivery_mode`. Other edits of held steers still refuse
`steering_held`, and `DELETE` cancels one.

**Model controls** can omit the reference, as in `model:
{reasoning_enabled: false}`. Omitted or `null` controls keep the queued
selection; naming a different reference resets unspecified controls to
that model's defaults.

### Delete an input

```http
DELETE /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs/{public_id}
```

It gives a row up before it materializes. Deleting a `steering` row is the
steer-cancel verb, and a scheduled row included: the delete is its cancel.

### Reorder the queue

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs/reorder
```

`inputs: [public_id, …]` renumbers the person's rows among their own
positions. The list must name every one of them exactly, else
`queue_changed`, so nothing reorders behind the caller's back. A kernel id
in the list is `kernel_input_immutable`, and a kernel row's position is
never rewritten.

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The queue, or an edited row. |
| `202 Accepted` | — | An input was accepted. |
| `204 No Content` | — | A queued row was given up. |
| `400 Bad Request` | `parameter_invalid` | A malformed upload id, steering selector or wall-clock `deliver_at`; a scalar `tool_names`; `slot` and `position` together; an unknown or malformed `history` key. |
| `403 Forbidden` | `not_authorized` | A post or an edit without write standing on the conversation. |
| `404 Not Found` | `not_found` | The workspace, conversation or input is not visible to the caller, or a promoted steer was already consumed. |
| `409 Conflict` | `idempotency_envelope_mismatch` | The key was used with a different request. |
| `409 Conflict` | `conversation_archived` | New independent input to an archived conversation; an exact live-Run guarded steer and accepted execution mail may continue. |
| `409 Conflict` | `input_queue_full` | The caller-authored queue bound is met. |
| `409 Conflict` | `stale_context`, `stale_timeline` | A freshness fence did not match. |
| `409 Conflict` | `steering_target_changed` | The pinned run is not the reply's running candidate. |
| `409 Conflict` | `steering_held` | An edit of a held steer beyond the `steer_now` promotion. |
| `409 Conflict` | `kernel_input_immutable` | A verb aimed at a `task_result` or `child` row. |
| `409 Conflict` | `queue_changed` | A reorder that does not name every one of the caller's rows. |
| `409 Conflict` | `stale_object` | The `expected_lock_version` did not match. |
| `413 Payload Too Large` | `content_too_large` | `steps` over 1 MiB of canonical JSON. |
| `422 Unprocessable Content` | `unknown_input_upload` | An unknown, another creator's or a fileless upload id. |
| `422 Unprocessable Content` | `attachments_not_steerable` | `attachments` beside a steering mode. |
| `422 Unprocessable Content` | `deliver_at_in_past`, `deliver_at_too_far`, `deliver_at_ambiguous`, `deliver_at_not_steerable` | The delivery time is out of bounds, doubly stated, or beside a steering mode. |
| `422 Unprocessable Content` | `steering_guard_requires_steer` | `expected_steering_run_public_id` without a steering mode. |
| `422 Unprocessable Content` | `principal_unknown`, `answerer_not_eligible` | The addressee is nobody's name, or may not answer here. |
| `422 Unprocessable Content` | `validation_failed` | A field outside its vocabulary or its lane: a malformed `execution_declaration`, `model_selection` or `fallback_models`, a loosened `approval_mode`, a `tool_names` outside the assembled surface, `steps` on a kind that refuses them, `variables` outside `assembly`, `inline_position_unplaced`, `inline_role_unplaced`, `variable_undeclared`. The message names the field. |
