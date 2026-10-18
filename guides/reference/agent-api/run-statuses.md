---
title: Run statuses and failure
description: What each task status names, the three failure policies and the attention hold, every typed error key, and the run statuses and envelope caps.
---

# Run statuses and failure

Where a task is, who is being waited on, what happens when one fails and
what a client reads to repair it. The verbs that end a hold — retry,
abandon, approve, deny, cancel — are on [Runs](runs.md).

## Task statuses

Task statuses: `waiting | needs_approval | running | dispatched |
awaiting_input | completed | failed | canceled | timed_out | uncertain |
skipped`.

## What a status names

A status names who is being waited on, and the task's kind names what the
wait is; neither derives from the other. `waiting` is a dependency (the
engine's own word for it is `queued`). `needs_approval` is an approver:
the stage is the tool call's alone — the one
kind whose effect reaches the person's own files and shell; a model round
is admitted by the admission plane and has no stage. Under `bypass` the
stage is crossed and granted in one transaction and never observed at
rest; under `ask` or `rules` a model-composed call the rules do not
decide rests there, addressed to the host's agent application, listed on
its inbox as kind `approval`, announced on the run as
`approval_required` while the turn stays `running`, and ended by
`approve`, `deny`, the 24 h park clock (`timed_out approval_expired`
under its own `on_failure`) or a stop, which cancels it with the rest of
the unstarted work (`error.key: run_canceled`). `running` is the
kernel doing it — a round driving a provider call, or a kernel tool
executing in one of our own jobs. `dispatched` is a holder outside the
kernel that was handed a bearer proof: a tool call advertised to a
runner, or an await whose `resolution_token` rode out in an append
receipt. `awaiting_input` is a person nobody handed anything to: the
tokenless await a model requests through a task operation. `uncertain` is the sweep's
word for a claimed, non-replayable tool call whose executor expired with
no result: its effect may have happened, so nothing re-runs it blind — a
person's `retry` or `abandon` decides ([Executor inbox](executor-inbox.md) "Expiry").

Each kind declares its own machine, so this list is a union rather than a
menu — a join is never `running`, and an unknown
status must be treated as live rather than finished by any client that
predates it.

## Failure policies

For ordinary failures, `propagate` skips its not-yet-started
descendants (transitively); joins treat a skipped source as a settled
non-success. `absorb` satisfies dependents and resolves in the failing
write; `halt` is the adjudication hold: the run finishes what can
still run, and at quiescence with an unresolved failure it becomes
`needs_attention` (`attention.reason: halt_failure`) until someone
adjudicates — and **the ask has no clock**, so a run resting there stands
until a person decides. The deciding verbs are `retry` (run the failed
task again under its own lineage), `abandon` (settle the failure as
resolved so the run moves past it) and `compact` (repair a round by
authoring a summarizer for it). A client computes the candidates from the
trace by the kernel's own rule — `status ∈ {failed, timed_out, uncertain}`
with no `failure_resolution` and an effective failure policy other than
`absorb` (an absorbed failure is settled immediately and neither verb accepts it) —
rather than from `attention.blocked_task_keys`,
with the one edge exception the barrier paragraph states: a `halt`
loser whose every consumer is a settled `any|quorum` barrier or a task
canceled by that race (`join_loser_canceled`) is absorbed and never a
candidate. A failure earlier in a canceled branch therefore cannot hold
the run after the race has its answer. A `run_out` branch with an
unfinished consumer still follows its own failure policy. The person then
retries, abandons, or appends the repair — an applied append releases
the hold back to `running` (the scheduler judges the repair; if the
rest still cannot resolve, the run re-holds). A
resolved graph whose deliverable did not complete holds as
`deliverable_unresolved` — the kernel never synthesizes an answer. **The
ask has no clock:** a hold stands until a
human answers it — the references all idle indefinitely, and a user
away at dinner must not return to a dead run whose fix was one retry
click. Abandonment is the retention/tombstone story, never a sweep.

`conversation_cost_limit_reached` on a `model_task` is a repairable control failure
with effective policy `halt`, even when it was authored `absorb` or `propagate`.
`on_failure` still reports the authored policy. Dependents stay waiting, and
explicit adjudication and settled race-loser rules keep their precedence.
Raise or clear the [Conversation cost limit](conversations.md#cost-limits), then
retry the refused task; changing the setting alone does not restart it.

## A model's question

A model's question announces from `running`, as `awaiting_human`: the
task itself sits in `awaiting_input`, and the run STAYS `running`, so a
run holding an ask is not quiescent and the reason is what tells a
person apart from a run busy doing the work.
(`awaiting_human` is the run's attention reason; `awaiting_input` is the
task's status. Two axes, deliberately two words.) Only the asks nobody holds a key to — an
ask a CLIENT authored was handed its `resolution_token` in a receipt,
so somebody already arranged to answer it, and announcing it would nag
an operator about a rendezvous they set up on purpose. The
`attention_required` item's `blocked_task_keys` names the question for
this reason, and the pending failures for `halt_failure`; a stamp
already standing is never replaced, so a halt failure outranks an ask. 
## Error keys

A failed task carries `error: {key, detail?}`.

| Key | Meaning |
| --- | --- |
| `provider_http_error` | The provider answered with an error status |
| `provider_model_unavailable` | A provider HTTP 401, 403 or 404 |
| `provider_context_overflow` | The provider refused the request for length |
| `context_overflow` | The composed request exceeds the storage bound, the signal a client's compaction consumes |
| `missing_input` | A task with nothing to ask, including a splice whose last word would be the assistant's own |
| `input_source_unavailable` | A source the task reads is gone |
| `round_expansion_refused` | The model's calls could not be authored into a fan, so the round failed rather than vanishing |
| `provider_error` | The provider completed its exchange but reported an abnormal generation finish (`finish_quality: error`) |
| `model_refused` | The provider declined the step, below |
| `provider_overloaded` | The provider was overloaded on every attempt, below |
| `provider_transient_exhausted` | Retryable transport, stream or server failures exhausted the route budget |
| `model_route_spent` | A retry tried to renew a refused or exhausted route |
| `attempt_budget_spent` | The attempt budget ended without an eligible recovery classification |
| `conversation_cost_limit_reached` | The Conversation's known cost reached its limit before a priced attempt was admitted |
| `model_capability_unavailable` | The model does not offer something the request asks for — declared tools on a lane without `tool_calls` |
| `tool_failed`, `tool_timeout`, `tool_uncertain` | The parked tool call's three |
| `await_failed`, `await_timeout` | The parked await's two |
| `executor_revoked` | The executor an unclaimed call was addressed to was removed first — a `failed` row under its own `on_failure`, like `tool_not_served` |
| `run_canceled` | Every row a stop took before it started |

`provider_context_overflow` arms a compaction repair rather than a retry,
and only reaches a client as a failure once the round is already repaired
or has no history to summarize.

On `provider_error` the step fails, the reported usage remains billed,
and partial answer text, reasoning and tool calls are discarded. No round
expands, no automatic retry is spent, and no declared fallback runs. The
error detail names the provider's finish word.

### model_refused

The provider declined the step: its classifier refused the request or the
answer (`finish_quality: refused`), or a content-protection stop blocked
the content (`blocked`). The call completed and was billed, but the step
has no answer.

A classifier refusal can requeue the step on the next eligible route in
its captured `fallback_models`. The task returns to `waiting`; its
`result.model_change` names the replaced route and `reason: model_refused`,
with the provider's category when supplied. Content protection does not
permit switching. A missing, exhausted or impermissible chain leaves the
failure standing.

The round retains the provider's refusal evidence and billed usage.
The task's `error.detail` describes the terminal outcome when no candidate
can answer. Completed tools are not repeated. A manual retry cannot renew
a refused route: `model_route_spent` refuses that repair; a different
unspent route must satisfy the captured constraints.

### provider_overloaded

The provider said it was overloaded — HTTP 503 or 529, or Anthropic's
streamed `overloaded_error` — on **every** attempt the step's budget
spent. A budget spent on any other transient answer among them is
`provider_transient_exhausted`, and a rate limit (429) is never overload: it
waits out the lane's `Retry-After` floor and retries within the budget.

After its bounded attempts are exhausted, this failure can advance to the
next permitted captured fallback. `model_change` uses
`reason: provider_overloaded`. Mixed retryable transport/server exhaustion
uses `provider_transient_exhausted` instead. There is no result-mail-only
switch to the recipient's current default, and a task retry cannot multiply
a route's provider-attempt budget.

See [Model selection and recovery](models.md#model-selection-and-recovery)
for availability skips, constraints, same-model identity and whole-chain
limits.

The switched step stays on the fallback for the rest of its turn, but
work it starts — a composed member, a `delegate_task` delegate, the model
a spawn or send names by default — begins on the model its lineage was
configured with.

## Run statuses

A run is `pending | running | paused | needs_attention | canceling |
completed | canceled`. There is no `failed`: a reasoned cancel is the run
failing, and the turn shape derives its `failed` from a hold or that
cancel.

## Envelope caps

64 steps per request, 32 members per fan and per follower's wait
(`too_wide_a_fan`), 33 reads per model step (`too_many_reads`), 1 MiB
payload. These are request hygiene, not totals: there are deliberately no
per-run size limits, and concurrency is the admission plane's business.

A stored body's entry count is a storage sanity bound — 32,768, above
what 1 MiB of the smallest entries can hold — so a composed round under
the byte wall is never refused for its count. `content_items_too_many` is
corruption protection, never a wall.

Values the row store cannot hold (NUL bytes, exponent-form numbers)
refuse typed at compile. Both write doors, create and append, require
write standing on the workspace: the same gate as every other write
surface.
