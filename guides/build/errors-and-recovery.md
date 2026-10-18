# Errors and recovery

Failures appear at three layers: the HTTP request, a task inside a run, and a run or conversation as a whole. Each is read in a different place and recovered differently.

| Failure | Where to look |
| --- | --- |
| API request | The HTTP status and the `error` envelope |
| Task | The run's task read: `status` and `error: { key, detail? }`; the `task_status` event |
| Run | The run's `status` and `attention: { reason, blocked_task_keys }`; the `attention_required` event |
| Candidate answer | The turn's variant status; a failed or canceled candidate is terminal, not an answer |

## Request errors

Controller-handled failures use one JSON envelope on both API families:

```json
{ "error": { "code": "unauthorized", "message": "Unauthorized" } }
```

| Status | Code | Cause | What to do |
| --- | --- | --- | --- |
| `400` | `bad_request`, `parameter_missing`, `parameter_invalid` | Malformed JSON, a missing root, or a malformed, nonpositive or above-maximum scalar | Correct the request; values are never silently clamped |
| `401` | `unauthorized` | The credential is missing, expired, revoked, fenced or on the wrong plane — deliberately indistinguishable | Present a live credential of the right plane, or reconnect |
| `403` | `not_authorized`, `administrator_required`, `user_not_administrable` | Standing refused by name: a `read` principal writing, a non-administrator on an admin route, a target the caller cannot administer | Act as a principal with the required standing |
| `404` | `not_found` | A scoped-finder miss; an inaccessible or tombstoned record reads identically | Check the id and your access |
| `409` | `stale_object`, `already_claimed`, `not_addressed_here`, `task_not_claimable`, `execution_in_progress`, `budget_window_overlap`, `cost_unit_conflict`, `idempotency_envelope_mismatch`, … | The operation conflicts with current state | Refetch, then decide; never retry blindly |
| `410` | `execution_details_pruned` | Retention removed the execution's detail | Read the retained text; post a new input instead of regenerating |
| `422` | `validation_failed`, `invalid_steps`, `schedule_finished`, `unknown_result_upload`, … | The body is well-formed but refused by the resource | Correct the field the message names |
| `429` | `rate_limited` | The resource's budget is spent | Honor `Retry-After` (a whole number of seconds) |
| `5xx` | — | An unhandled application or upstream failure; the body may be JSON, non-JSON or empty | Classify by status; follow the resource's readback or idempotency behavior before repeating a mutation |

A failed connection or `5xx` does not prove that a write was rejected. Where a resource accepts `Idempotency-Key`, replay the same key and body: workspace, conversation, fork, input and store-entry creation replay the original status and body with `Idempotency-Replayed: true`.

## Task failures

Task statuses: `waiting | needs_approval | running | dispatched | awaiting_input | completed | failed | canceled | timed_out | uncertain | skipped`. A client that predates a status treats an unknown one as live. A failed task carries `error.key`:

| Key | Cause | Recovery |
| --- | --- | --- |
| `approval_denied` | A deny rule, or `rules` mode with no allow | Data the model reads; adjust rules for later turns |
| `approval_expired` (`timed_out`) | Nobody approved within 24 hours | The next round reads it; approve sooner next time |
| `tool_failed`, `tool_timeout`, `tool_uncertain` | The tool could not run, exceeded its deadline, or its executor expired with no result | `uncertain` means the effect may have happened; a person's `retry` or `abandon` decides |
| `tool_not_served`, `executor_revoked` | No eligible executor, or the addressed executor was removed | Select an eligible runner or reconnect the executor |
| `provider_http_error`, `provider_error`, `provider_overloaded`, `provider_transient_exhausted`, `attempt_budget_spent` | Provider failure or exhausted route budget | Only classified retryable exhaustion can advance through the captured fallback list; abnormal generation finishes remain terminal |
| `provider_model_unavailable` | Provider HTTP 401, 403 or 404 | Fix credentials, enablement or the model reference |
| `provider_context_overflow`, `context_overflow` | The request did not fit | Arms a compaction repair rather than a retry |
| `model_refused` | Classifier refusal or content protection | A classifier refusal may advance to the next permitted captured candidate; a content block cannot |
| `model_route_spent` | A retry named an already refused or exhausted route | Choose a different unspent route permitted by the captured intent |
| `conversation_cost_limit_reached` | Known Conversation cost reached its limit before priced admission | Raise or clear the limit, then retry the failed task |
| `model_capability_unavailable` | The model lacks something the request needs, e.g. tools | Choose another model |
| `await_failed`, `await_timeout` | A parked question or wait failed or expired | Decide the hold |
| `missing_input`, `round_expansion_refused`, `input_source_unavailable` | The step had nothing to ask or its calls could not be authored | Inspect the detail; author the repair |
| `run_canceled` | A stop took the row before it started | — |

Model recovery uses bounded provider attempts and the captured fallback list;
steps cannot add a retry budget. Neither manual retry nor a later profile edit
renews a refused or exhausted route. See [Model selection and recovery](../reference/agent-api/models.md#model-selection-and-recovery).
Ordinary failures use `propagate` (skip not-yet-started descendants), `absorb`
(settle immediately) or `halt` (hold for repair). A model task's cost-limit
refusal uses effective `halt`, while preserving its declared policy.

Retry and Abandon candidates have status `failed`, `timed_out` or `uncertain`
and no `failure_resolution`. Exclude authored `absorb` failures except a
`model_task` with `error.key: conversation_cost_limit_reached`. A settled race
loser is also excluded; [Failure policies](../reference/agent-api/run-statuses.md#failure-policies)
describes that edge rule. The Run's attention keys can also name asks and
approvals, so they are not the retry candidate list.

## Run holds

Run statuses: `pending | running | paused | needs_attention | canceling | completed | canceled`. There is no `failed`: a reasoned cancel is the run failing.

A run at `needs_attention` names its reason — `halt_failure`, `awaiting_human`, `deliverable_unresolved` — and the task keys it is blocked on. **A hold has no clock**: it stands until a person decides. The deciding verbs are `retry` (run the failed task again under its own lineage, optionally on another model), `abandon` (settle the failure so the run moves past it) and `compact` (repair a round by authoring a summarizer). An applied append releases the hold back to `running`; if the rest still cannot resolve, the run re-holds. Explicit retry resumes only the failed node; completed tools and child requests stay completed. Regenerating the whole turn is a separate operation and not the recovery mechanism for preserving completed work.

## Recovery procedures

**Transient failures** (rate limits, overload, timeouts): honor `Retry-After`, bound your attempts, and check the outcome before retrying a mutation — a failed turn may already have changed files or called external tools.

**A disconnected stream** confirms nothing. Reconnect, drain replay from your saved cursor, and read the turn or task over HTTP; see [Events and streaming](events-and-streaming.md).

**A refused input** is `blocked` with `blocked_reason`. Edit or delete it rather than submitting duplicates.

**A Conversation cost limit** holds the failed model task and its waiting
dependents. Read the Conversation, change `cost_limit` with its current
`lock_version`, then explicitly retry that task. Completed tools and results
stay intact. A direct reply has no graph to retry: read its `turn_status`
failure reason and Regenerate after adjustment. Changing the limit alone does
not restart work, and a Stop remains terminal. See [Usage and cost](usage-and-cost.md#limit-one-conversations-cost).

**An expired execution** (`410 execution_details_pruned`) keeps its text and terminal state. New inputs still work with the retained history; regeneration of the expired candidate returns `409`.

**Credentials**: a `401` is never explained. If a refresh rotation's outcome is uncertain, treat the connection as lost and start a new device authorization; never replay the old refresh token.
