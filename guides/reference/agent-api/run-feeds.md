---
title: Run feeds
description: A run's durable event stream, every item it narrates, and the ephemeral transcript and progress feeds on its own channel.
---

# Run feeds

One hosted event plane: a run narrates onto its host's feed.

A standalone run is its own host, so `GET …/runs/{id}/events` and
`RunEventsChannel` serve its narration under `resource: {type: "run",
public_id}`. A conversation-hosted run narrates onto its conversation's
feed ([Conversation feeds](conversation-feeds.md)), under `resource:
{type: "conversation"}` with `run_public_id`, `turn_public_id` and
`variant_public_id` on every item. Those are the originating run's
identities, including for background work after a successor turn or
regeneration starts; they do not follow the displayed variant. Standalone
items carry `run_public_id` without turn or variant keys.

A conversation-backed run's own address refuses `409
conversation_hosted`, and the channel rejects the same way: serving the
conversation's whole stream under a run id would hand a follower other
turns' items.

## Routes

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/events
WS  /agent_api/v1/cable
```

## Replay

One vocabulary, one `cvei` cursor prefix, one 30-day age-out, on both
hosts. Sequences are allocated contiguously from 1 within each host and
are never reused after items expire, so a replay gap can mean expired
history even while the run is running. A follower that outlived the
window refreshes from durable tasks and outputs; replay cannot recover
expired items.

Items render identically over REST and over the cable, so one reconnect
algorithm serves both. Narration is written once per transaction, so one
logical change — a cancel is a run status plus every task it settled —
arrives as one envelope with contiguous sequences.

Items are replay evidence, not the record: the tasks and their outputs
are the durable truth, and items age out after 30 days while the run
lives.

## What a run narrates

The run's item types come from the one closed vocabulary
[Events](../events.md) lists. `input_*` and `context_compacted` are
shared; the rest of that list never appears on a run host.

### turn_status

Where the run is, written under the run lock at every run status write,
including the ones nobody asked for: a hold, an authority cut, a drain
escalation. `{run_public_id, run_status, failure_reason?,
attention_reason?}`, where `run_status` is the run row's own word
(`pending | running | paused | needs_attention | canceling | completed |
canceled`).

On a standalone run the same write also carries the turn shape, `status`
and `failure_reason_key?`, because its rows are the truth and nothing can
contradict them. On a conversation host it carries `turn_public_id` and
`turn_kind` — the turn row's own `kind`, `direct_reply` on an answer and
`compaction_summary` on the kernel's between-turn summary, what a
follower waiting on a person's turn reads to tell the summarizer's run
from the answer's — and no `status`, the turn's row being the converger's
to narrate under the conversation lock in its own `turn_status`.

The reader rule: `status` present means the turn moved; absent means a
run-state note and no turn transition. A turn-shaped `failed` is a level:
a `needs_attention` run renders it, and a retry or an answer narrates
`running` again.

### task_status

`{task_key, kind, lifetime, wake, status, after?, on_failure, error_key?,
failure_resolution?, approval?, model_change?}` on every task transition,
birth included — a follower reading only the stream learns about newly
appended tasks here.

`on_failure` rides it so a follower computes the candidate rule without
the trace: an `absorb` failure stamps nothing. `approval` is the task
read's own `{origin, decided_by?, decided_at}` block, present from the
crossing that decided the call; a denial narrates the failure first and
the fact on the next item.

`after` is the authored list the task hangs from — the trace row's
`after`, a root carrying none — and rides every item; a queued round is
narrated again when a branch forwards onto it, `after` grown. The trace's
`waiting_on` is live and derived: a follower computes it from `after` and
the statuses it holds, and never reads it off an item.

An automatic model switch carries `model_change: {from, to, reason,
category?}` with complete provider/model references and the triggering
refusal, exhausted retryable provider failure, or availability reason.
It moves to the next permissible route in the execution's captured list,
not the answering profile's current default or current fallback setting.

The switch changes the next execution. The task's `result` keeps the
same fact without `to`, because the row's own `model` names it. Previous
`round_result` items retain the models that actually made those calls;
the event history records the sequence of switches. An optional
`model_skips: [{model, reason}]` lists candidates skipped without a
provider call or excluded by captured constraints.

### task_readdressed

`{task_key, role, executor_public_id?, deadline_at, detail?}` records
withdrawal of an unavailable agent delivery address from a held approval,
preserving the Human's decision door. It does not move the task's Runner
target; host preference changes emit `default_runner_changed` separately.

### task_deadline_extended

`{task_key, deadline_at, by, timeout_ms}`: the row's claimant extended
its own park ([Executor inbox](executor-inbox.md#extend)), the one clock
moved to `deadline_at`. `by` is the claimant's public id and `timeout_ms`
what it asked for, so a watcher can say "the runner asked for N more
minutes".

### round_result

`{task_key, status, model, finish_quality?, refusal_category?,
error_key?, error_detail?, input_truncation_suspected?}` when a model
step settles.

`error_detail` is what the provider answered — its HTTP status and
sentence, then its code and type when named, never a raw body — the same
text the failed task carries as `error.detail`. An abnormal generation
finish carries `status: failed`, `finish_quality: error`, `error_key:
provider_error`, and a diagnostic naming its finish word.

On a declined finish (`finish_quality: refused | blocked`) the round
reads what the provider said and the task what the work came to:
`error_key` is absent, the call not having failed; `refusal_category` is
the provider's own word, absent when it named none; `error_detail` is the
provider's explanation for people; and `status` is the task's `failed`
beside it — whose `error.detail` is the kernel's sentence for a reading
model instead — or `waiting` when the captured fallback chain requeues
it. The same request is never re-sent to the same model automatically,
and a person may retry it on another.

`input_truncation_suspected` is present, and `true`, only when the round
reported fewer input tokens than its source by more than its own tail
explains.

### usage

`{task_key, input_tokens, output_tokens, reasoning_tokens?, total_tokens,
cache_read_tokens?, cache_creation_tokens?}`, appended with the round it
paid for. The cache counters are the round's own reuse: a tool run
re-sends its whole prefix every round, so a transcript that cannot show
them cannot be tuned.

### attention_required

`{reason, blocked_task_keys, blocked_task_overflow?}` is the call to act.
`reason` is one of `halt_failure | deliverable_unresolved |
awaiting_human | approval_required`, carrying the tasks an adjudicator
can retry or abandon, the question to answer, or the calls to approve or
deny. No deadline rides it — a hold has no clock, and an ask's or a held
call's `deadline_at` is on its task. The key list is capped at 32 with
the remainder counted in `blocked_task_overflow`; the trace answers "all
of them".

An await serves the question it was authored with. `GET …/tasks/{key}`
carries `prompt` for any kind authored with one — the text the kernel
sealed as that node's input: an `await_task`'s question (a model
composing `ask` authors it), a model step's prompt, authored or
client-appended. A spliced continuation has no authored input and carries
none, and a tool task's authored side is `tool_input`. The resolution
token is not there and never will be: it travels only in the creator's
receipt.

### input_materialized

`{input_public_id, queue_position, task_key, run_public_id}` when a bound
input landed in a round's sealed request; on a conversation host,
`turn_public_id` too.

A steer the run ended without landing — by stop, cancel, completion or
being replaced — is released as `input_edited{state: pending, reason:
steer_target_settled}` instead, never dropped. A hold releases nothing: a
steer typed before it stays bound and lands with the retry.

A queued word found at quiescence binds the follow-up head first,
`input_edited{state: steering, reason: follow_up_bound}`, and the kernel
plants one more mainline round for it to land in — so a queued input
lands before the turn-shaped `completed`, never after.

### context_compacted

`{turn_public_id?, run_public_id, task_key, summary_task_key?, mode,
trigger}` when a round was repaired for size: `task_key` the round made
to fit, `summary_task_key` the summarizer it waits on (absent on a prune,
which appends nothing), `mode` `prune | kernel | delegate`, `trigger`
`usage | wall | overflow | manual | fallback`, and on a
conversation-hosted run the turn.

A `fallback` item is the kernel's summarizer appended once in place of a
delegate nobody answered, carrying `fallback_from` (the expired
delegate's key) and `fallback_reason` (`tool_timeout | tool_uncertain`).

It is the one repair a watcher cannot infer: the round pauses, a task
nobody authored appears, and the next round answers from a summary — or
from cleared results — instead of the history it had. The same item, with
`summary_turn_public_id` in place of the task keys, is what a
conversation narrates for a repair between turns
([Conversation context](conversation-context.md#automatic-repair)).

## Subscribe

`AgentAPI::V1::RunEventsChannel` with `{workspace_id, run_id, items?:
"events"|"lifecycle"|"transcript"|"progress"}`, for a standalone run
only: a conversation-hosted run's channel is its conversation's, and this
one rejects `conversation_hosted`.

`events` carries every item. `lifecycle` carries only `turn_status` and
`attention_required` — where the turn stands and when it needs a human,
the same narrowing on both hosts — so a console holding many runs is not
handed every task transition to decode and discard.

## The progress feed

`items: "progress"` subscribes the run's ephemeral feed: what is
happening right now.

The executor's frames ride it ([Executor](executor.md): a `bash` tail
under its current claim, a process's output under its retained source
claim), and the kernel's own three ride beside them.

| Frame | Carries | Meaning |
| --- | --- | --- |
| `round_started` | `task_key`, `mainline`, `attempt`, `model`, `request_bytes` | A model attempt was dialled |
| `step_started` | `task_key`, `tool_name`, `status` | A tool row was dispatched, run or held |
| `step_claimed` | `task_key`, `tool_name`, `executor_public_id` | An executor took it |

An approval-gated call says `step_started` twice — held, then released —
and a reader upserts the call's live status. These are three facts no row
or settled item carries at that instant; a round's or a call's end is the
settled `round` or `call` snapshot on `transcript`, whose `started_at`
and `completed_at` are the timing.

Every frame carries the host's keys (`run_public_id`, `task_key`; on a
conversation host `turn_public_id` and `variant_public_id` beside them)
and `at` in milliseconds. The envelope is `{frame}`, never `{event}`:
nothing on it is durable, nothing replays, and a subscriber sees what
follows its subscription. A `hidden` task reaches this feed exactly as it
reaches the transcript — not at all. The pack lists the feed's five words
once (`conversations.json#/progress_frame_types`).

## The transcript feed

`transcript` is the human feed: one stream over the host, in the
vocabulary [Conversation feeds](conversation-feeds.md) owns. A standalone
run's rides its own channel; a conversation-hosted run's rides its
conversation's, where a run address no channel serves would otherwise
have swallowed it.

While a round runs it carries `text_delta`, `reasoning_delta`,
`tool_call_started` and `tool_call_arguments_delta` — a call announces
itself on its first fragment, so a collapsed row can name its target
before the arguments finish. When a task settles it carries the `round`
or `call` snapshot, the same row the paginated read would have served
under the same task key, and on a conversation host the settled `turn`
follows.

A settled `round` is the thread row the transcript page serves, with
`mainline`, its `calls` and `branches` included, so a client upserts the
thread by `task_key`. Every item carries `run_public_id` and `task_key`,
which is how a client upserts it in place; on a conversation host
`turn_public_id` and `variant_public_id` ride beside them, the seam's
turn, and on a run host those are the absent ones.

### Five laws

**Nothing here is durable.** A saturated transport must not be able to
truncate a transcript, which is only true when the deltas were never the
record.

**A delta may not create a row.** A delta for a task the subscriber has
not seen is dropped, and the paginated read repairs it.

**Completion wins.** The snapshot replaces whatever the deltas
accumulated.

**A reset voids an attempt.** A provider retry emits `stream_reset`,
voiding what that attempt streamed, so a follower never splices two
attempts into one answer; an attempt that streamed nothing public emits
no marker. Its `reason` is `retry`; `refused` when the attempt ended in
an answer the provider declined, of which the kernel stores none, so a
follower drops what streamed of it, an announced call included; and
`failed` when the attempt failed with nothing retrying it, a budget spent
mid-stream, which the kernel stores none of either.

**The feed is a tail, not a log.** A subscriber joining a running run
receives what happens from then on and is never backfilled; history comes
from the window. A task whose `visibility` is `hidden` reaches neither
half of the feed, exactly as it reaches neither the window; on a
conversation host a `hidden` or concealed turn silences its run's items
the same way.

The reference implementation of those laws ships in the Ruby SDK as
`CybrosAgent::Api::TranscriptAccumulator`. A client that re-implements it
owes the same three answers — append, discard, replace-on-settle — and
the same arithmetic: a bounded preview is a tail, so the settle
comparison counts what was accumulated rather than testing the buffer as
a prefix.
