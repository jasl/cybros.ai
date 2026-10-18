---
title: Conversation feeds
description: The conversation's durable event replay and its ephemeral transcript and progress feeds, their payloads and their recovery rules.
---

# Conversation feeds

A conversation publishes three feeds over one host. The **event feed** is
durable: items are committed with the rows they narrate, replayed over
HTTP and mirrored on the cable. The **transcript feed** carries what a
turn is saying while it says it, and the settled body when it finishes.
The **progress feed** carries what is happening while it happens. Only
the first is replayable; the other two are tails.

One hosted plane: a standalone run publishes the same three streams at its
own address ([Runs](runs.md)), so every durable item names its host as
`resource: {type: "conversation" | "run", public_id}` and the event
vocabulary is one closed list across both. Not every type appears on
every host.

## Routes

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/events
WS  /agent_api/v1/cable
```

## Replay the event feed

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/events?after={cursor}&limit={n}
```

### Request

| Parameter | Meaning |
| --- | --- |
| `after` | An opaque `cvei`-prefixed cursor from a previous page. Omitted, the page starts at the beginning of the retained window. |
| `limit` | 1–200; default 100. |

### Response

`200` with the page and its pagination. Sequences are host-local and
ascending, and this mirrors the InferenceRequest replay contract.

```json
{ "events": [ { "public_id": "…", "sequence": 41, "cursor": "cvei_…", "type": "turn_status", "resource": { "type": "conversation", "public_id": "…" }, "occurred_at": "2026-09-08T00:00:00Z", "payload": { "…": "…" } } ],
  "pagination": { "next_after": "cvei_…", "watermark": 41 } }
```

`pagination.next_after` names the last returned item and is `null` on an
empty page.

`pagination.watermark` is the committed allocation a follower freezes to
bound its drain. It survives item expiry: an empty page with a watermark beyond the
follower's consumed sequence means committed progress is no longer
replayable. Refresh the projection from the host's durable state in that
case — do not invent events, and do not derive an opaque cursor from the
watermark.

## Subscribe

`AgentAPI::V1::ConversationEventsChannel` on `/agent_api/v1/cable`, with
`workspace_id`, `conversation_id` and `items`. Four feeds ride that one
channel:

| `items` | Envelope | Carries |
| --- | --- | --- |
| `events` (the default) | `{event}` | Every projected durable item |
| `lifecycle` | `{event}` | `turn_status`, `attention_required`, `conversation_ended` |
| `transcript` | `{type, …}` | Deltas and settled snapshots, below |
| `progress` | `{frame}` | Ephemeral frames, below |

A console takes `lifecycle`, a debugger `events`, a chat surface
`transcript`: nobody decodes what they will discard.

Subscription checks the same visibility as REST, and `none` rejects like
absence. Changing the conversation's access list does not disconnect an
already subscribed socket, while subsequent REST reads use the new access
immediately; a client that requires immediate removal of a live
subscription closes it. Workspace authority withdrawal is different: the
kernel requests disconnection of member sockets so they reconnect and
resubscribe under current authority. That notification is best effort —
durable replay and REST enforce current access independently.

## Event payloads

The closed vocabulary of 25 types is listed in [Events](../events.md).
What each item carries on a conversation host:

**`input_accepted`** carries `origin`, `authored_by: {kind, handle,
display_name}` and `answering_user_public_id` — the addressee — on every
row; `sender_conversation_public_id` on a stamped row; `deliver_at` as an
ISO 8601 time on a scheduled row; and `run_public_id` with `task_key` on
kernel mail, on an agent's `send`, and on a receipt drained in-run, where
no `input_public_id` rides.

A pinned steer additionally carries `expected_steering_run_public_id`, the
exact target execution fixed on the accepted input. This differs from
`run_public_id`, which identifies the sending execution when present.
Acceptance alone does not prove consumption or a successful response.

**`input_edited`** carries the saved `deliver_at` as an ISO 8601 time when
an input PATCH set one, including a text-only edit that retains the
schedule and a `deliver_in: "0s"` edit that makes it due now; untimed
inputs omit the field. A kernel transition may carry `reason`:
`follow_up_bound`, a queued word bound as the head a kernel-planted round
will drain, or `steer_target_settled`, a steer released to the queue when
its run ended without landing it.

**`input_deleted`** carries `input_public_id`, `queue_position` and
`steer_canceled`. A pinned steer also carries its
`expected_steering_run_public_id`. A true `steer_canceled` records a canceled
steer, but does not identify who canceled it or why; target completion can
also remove an unconsumed pinned steer.

**`input_materialized`** carries `input_public_id`, `queue_position` and,
when it opens a conversation turn, `turn_public_id`, `variant_public_id`
and a nullable `run_public_id` in the same event. A steer consumed into a
model round names that execution and additionally carries `task_key`; a
standalone run has no conversation turn or variant. Keep these identities
to follow the original execution across later regenerations. The Ruby
SDK's `CybrosAgent::InputMaterialization` consumes replay pages and
accepts a recovery callback to the materialization read when event
retention leaves a gap.

For a consumed steer, the exact input, Run and `task_key` identify the consuming
Task. They do not prove that the model followed the correction or
that the request succeeded. An absent Input is insufficient evidence of
consumption: without a matching retained materialization or cancellation
event, its processing result is unknown. Older accepted or deleted events
without a target field cannot establish a pinned target.

**`input_blocked`** carries `blocked_reason`: a drain refusal, or
`run_held` — the tail is a hold and this row predates it or addresses
another answerer.

**`turn_created`** carries `answering_user_public_id` on every kind: who
answered a reply turn, and the conversation's answerer at creation on a
message or summary turn.

**`context_trimmed`** is narrated only when assembly left history out, and
carries `history_selected`, `history_skipped` and
`history_skipped_reason`. An untrimmed assembly's evidence is the sealed
request itself.

**`context_compacted`** says a repair was armed for a context that would
not fit: `mode: prune|kernel|delegate`, `trigger:
usage|wall|overflow|manual|fallback`, `run_public_id` and
`turn_public_id`; between turns `summary_turn_public_id`, the summary turn
appended; on a run-backed turn's own round `task_key` and, when it
summarizes, `summary_task_key`. One item, one builder, on either host. A
`fallback` item is the kernel's summarizer appended once in place of a
delegate nobody answered, and carries `fallback_from` — the expired
delegate's key — and `fallback_reason`, `tool_timeout` or
`tool_uncertain`.

**`default_runner_changed`** is a host preference event carrying
`{executor_public_id, previous_executor_public_id?, by}`; the new executor
may be null. It readdresses no task.

**`task_readdressed`** clears a held approval's agent delivery address
instead of failing the row, so the person's door still answers
([Runs](runs.md)). It does not move the task's Runner target.

**`task_deadline_extended`** is a run item on the host feed: a claimant
extended its own park, `{task_key, deadline_at, by, timeout_ms}`, with
`by` the claimant's public id ([Executor inbox](executor-inbox.md)).

**`access_changed`** is a host item: the carrier was replaced,
`{default, entries: [{user_public_id, level}], by, kind}`, with `by` the
caller's public id and `kind` its kind, `human` or `agent`. An unchanged
set is never narrated.

**`conversation_ended`** is a host item, and the end is a persisted event:
the row and its event are committed together, so followers can recover the
lifecycle transition through replay. It carries `{reason: archived |
tombstoned, conversation_public_id}` and is narrated by archive and by
DELETE in the verb's own transaction on every member of the tree they
stamp, naming the member itself. A tombstone's item is the last item its
feed ever carries: the cable delivers it, the next poll is the family
`404`, and the reap destroys the row later. An archived feed remains
readable and accepted work can still settle into the archived row. Followers
responsible for execution or result delivery continue through archive until
their work settles. Archival visibility does not mean that execution has
completed or stopped. Unarchive narrates nothing and retains the historical
archive item; that item never terminates an execution follower.

**`handle_changed`** is the one type in the vocabulary that is a member
item and appears on neither host's feed. A member was renamed —
`{user_public_id, old, new}` — narrated on the member's own rows
([Profile](profile.md)).

`turn_status`, `turn_variant`, `task_status`, `round_result`, `usage` and
`attention_required` are the run-backed turn's own items, keyed by
`task_key` ([Runs](runs.md)).

## turn_status on a conversation host

`turn_status` carries either Turn state or run state, and `status` is
optional.

**The converger** narrates the Turn's row after each settle:
`{turn_public_id, turn_kind, variant_public_id, run_public_id, status,
variant_status, failure_reason_key?}` and, on a hold, `error_key` (the
newest failure) and `blocked_task_keys` (what an adjudicator can act on).
`status` is the Turn's settled state and `variant_status` the sample's own
terminal, so a failed regeneration narrates `completed`/`failed`.

**A declined answer** is a failed sample though its call completed:
`variant_status` is `failed`, `failure_reason_key` is `model_refused`, and
`finish_quality` (`refused | blocked`) and the provider's
`refusal_category` (absent when it named none) ride beside them. It never
replaces a completed sample and never moves the context revision. When the
answering profile's fallback re-asks it, that same item says `status:
"running"` and carries `model_change {from, to, reason: "model_refused" |
"provider_overloaded", category?}` — the one `turn_status` of the switch,
beside the fallback candidate's `turn_variant`.

**Edit and activation** publish the Turn's current `status` and selected
`variant_status`, even when selecting another completed candidate leaves
the status unchanged.

**The run**, under its own lock, narrates where it is at every status
write: `{turn_public_id, turn_kind, variant_public_id, run_public_id,
run_status, failure_reason?, attention_reason?}` with no `status`. A
follower treats a missing `status` as no turn transition. A reply with no
backing run carries no run keys.

**`turn_kind`** — the turn row's own `kind` — rides every `turn_status` a
conversation host narrates: the materializer's `running`, the run's notes,
the converger's settle, a regeneration's, a cancel's, an edit's or an
activation's. It is `direct_reply` on an answer and `compaction_summary`
on the kernel's between-turn summary, so a follower that posted a word
behind a summary tells the summarizer's run from its own turn's without
reading the turn.

## Item identity

Every item narrated by a run carries `run_public_id`; on a conversation
host it also carries `turn_public_id` and `variant_public_id` from that
run's own variant, even when another turn or regenerated candidate is
running. These identify the event's source, not the currently displayed
answer. Task-grained items also carry `task_key`, which is local to the
source run. A standalone run has no turn or variant identity, and a direct
reply has no run identity.

## Retention and gaps

Items age out after 30 days while the conversation lives, even if a turn
is still running. Sequence allocation never rewinds when items expire, so
replay may have a gap after a follower's last seen sequence. Expired items
cannot be recovered by replay: refresh from the durable timeline and the
run's tasks instead of treating the stream as an archive.

## The transcript feed

The event feed carries where a turn got to; `items: "transcript"` on the
same channel carries what it is saying. One stream over the host — a
direct reply and a run-backed turn publish here, a standalone run on its
own channel ([Runs](runs.md)) — in one vocabulary of three kinds of item.

### Deltas, while a reply runs

`text_delta` (`text`), `reasoning_delta` (`kind`, `text`),
`tool_call_started` (`call_id`, `name`, published on a call's first
fragment so a row can be drawn before its arguments finish),
`tool_call_arguments_delta` (`call_id`, `delta`), and `stream_reset`.
Every item names its `turn_public_id` and `variant_public_id`.

`stream_reset` carries a `reason`:

| Reason | Meaning |
| --- | --- |
| `retry` | A transient retry threw this attempt's streamed output away; discard what you accumulated rather than splicing two attempts together |
| `refused` | The attempt ended in an answer the provider declined, which the kernel stores none of; discard the same way |
| `failed` | The attempt failed and nothing retries it, a budget spent mid-stream included, so the reply holds none of it |

### The settled task, when a run-backed round or call terminalizes

`{"type": "round", "task_key": …, "round": {…}}` and `{"type": "call",
"task_key": …, "call": {…}}`, carrying the same row the run's paginated
transcript serves, under the task key the deltas carried.

### The settled turn, after execution settles or a completed candidate is selected

`{"type": "turn", "turn": {…}}` carrying the same projection a `GET
…/turns` page serves, under its `turn_public_id` — so the sealed body
replaces the accumulator, as an event rather than a rule every client
re-implements against a separate read. A run-backed turn's snapshot
carries the run's `rounds`.

The top-level `variant_public_id` identifies the candidate whose execution
settled, or the candidate selected by edit or activation;
`run_public_id` is also present when that source candidate is run-backed.
Selection does not imply a new run completion, and a manual edit has no
backing run. These keys identify the frame's source, while
`turn.active_variant` is the displayed answer: a canceled or terminally
failed regeneration can carry the new candidate's keys around the retained
original answer. Match the source before replacing an execution's
accumulator, so a delayed snapshot from an earlier candidate cannot settle
a new one.

### A preview is not the body

`round.text_preview` is truncated by construction, with `text_bytes`
beside it saying how much there was. What replaces an accumulator is the
turn's `active_variant.content`, never a round's preview: a follower that
replaced on `round` would silently truncate what a person is reading. On a
standalone run there is no `turn` item at all — the deltas are everything
that was said, and no remainder follows them.

The three questions every consumer answers — what to do with a delta, with
a `stream_reset`, and with the settled body — are implemented once in the
Ruby SDK as `CybrosAgent::Api::TranscriptAccumulator` (`accumulate`,
`reset`, `replace_on_settle`). A client that writes its own must answer
the same three, and must count what it accumulated rather than compare
against a bounded buffer: a preview held to N bytes is a tail of a longer
answer, and `settled.start_with?(preview)` is false for every reply past
N.

### Nothing here is durable

The transcript is a tail, not a log. A subscriber joining a running reply
gets what happens from then on, nothing is backfilled, and a delta that
never arrives costs a frame of latency, never a fact: the variant and its
content are the record, `GET …/turns/{public_id}` is the recovery path for
a known turn, and a timeline window discovers turns when no UUID is known.

A `hidden` or concealed turn is off this feed as it is off the timeline,
its run's rounds included; a `hidden` task is off it on both hosts. This
suppresses conversation content, not execution: background results still
persist, and durable task events and the run's own trace remain.

A run-backed turn's rounds stream here, on the conversation the turn
belongs to: its deltas and its settled `round` and `call` items carry
`run_public_id` and `task_key` beside `turn_public_id` and
`variant_public_id`. Those two keys are additive and absent for a direct
reply; on a run host — a standalone run's own channel —
`turn_public_id` and `variant_public_id` are the absent ones.

## The progress feed

`items: "progress"` on the same channel carries what is happening while it
happens: one feed over the host, a standalone run's on its own channel
([Runs](runs.md)), under the envelope `{frame}` and never `{event}`. Five
frame types ride it, listed once in the contract pack
(`conversations.json#/progress_frame_types`):

| Frame | Carries | Meaning |
| --- | --- | --- |
| `round_started` | `task_key`, `mainline`, `attempt`, `model`, `request_bytes` | A model attempt was dialled |
| `step_started` | `task_key`, `tool_name`, `status` | A tool row was dispatched, run or held |
| `step_claimed` | `task_key`, `tool_name`, `executor_public_id` | An executor took it |
| `executor_progress` | [Executor](executor.md) | A claimant's own narration |
| `process_output` | [Executor](executor.md) | A process printed |

An approval-gated call says `step_started` twice, held then released, and
a reader upserts the call's live status.

Every frame carries the host's keys. Task frames use `run_public_id` and
`task_key`, with `turn_public_id` and `variant_public_id` on
conversation-hosted kernel frames. Process output uses its host's
`conversation_public_id` or `run_public_id`, plus `process_id` and
`executor_public_id`; its private source claim never reaches the feed.
Every frame includes `at` in milliseconds.

A frame is minted only for a fact no row and no settled item carries at
that instant. A round's or a call's end is never a frame — it is the
settled `round` or `call` on the transcript feed, whose `started_at` and
`completed_at` are the timing. A compaction's arming is the durable
`context_compacted`. A direct reply narrates `turn_status`, its deltas and
its settled `turn`, and mints no frame.

The transcript feed's laws hold here, inherited: nothing is durable, a
frame is stored nowhere and replays never; a frame never creates a row,
it narrates one the window already serves or a claimant a task read
already names; completion wins, the settled snapshot replaces a live mark;
and the feed is a tail, so a subscriber sees what follows its
subscription. A `hidden` task reaches this feed exactly as it reaches the
transcript — not at all — and on a conversation host a `hidden` or
concealed turn silences its run's frames the same way.

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The replay page. |
| `400 Bad Request` | `parameter_invalid` | A malformed cursor, or a `limit` that is malformed, nonpositive or above 200. |
| `404 Not Found` | `not_found` | The workspace or conversation is not visible to the caller. |
| `429 Too Many Requests` | `rate_limited` | The replay budget is spent ([Rate limits](../rate-limits.md)). |
