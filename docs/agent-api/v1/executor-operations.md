# Executor task operations

Status: live Agent API resource. This is a language-neutral, task-scoped execution
protocol. Any Agent implementation can use it through these HTTP resources. A
language runtime may compile its own operations into this protocol; Nexus owns
acceptance, dependency scheduling, observations and result settlement.

An ordinary externally claimed ToolTask may accept subordinate work, observe its
results and publish its own final result. Its original claim remains the execution
owner while waiting; the ordinary deadline extension protocol keeps that claim live.
The task's accepted model and tool context bounds which child work it can author.

The routes are:

```text
GET  /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/operations
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/operations
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/observation
```

They use the ordinary executor transport bearer. The claim proves authority for this
one task; it grants neither member API access nor arbitrary graph editing. New operations
require the current claimant, an unexpired claim, a Run in `running` state, live execution
origin, executor eligibility and the run principal's write standing. Observations reconcile
already accepted work: they retain the claim, live executor, source and write-standing
checks while allowing Pause, repair holds and graceful Stop. Both writes serialize with
dispatch, expiry, cancellation and Stop under the run lock. Old claim tokens cannot
accept or observe work after a new generation is granted.

## Read the execution trace

```http
GET .../operations?after=0&limit=100
Claim-Token: <current claim token>
```

`after` defaults to zero; `limit` defaults to 100 and is clamped to 1–200. Both use the
shared nonnegative integer parser, with maximum 2147483647 and a `400` refusal for
invalid values. The matching last claim may read its trace even after its deadline
expires; mutation has stricter live-claim requirements.

```json
{
  "operations": {
    "context": {"tools": [], "model_defaults": {}},
    "trace": [],
    "position": 0,
    "next_after": null
  }
}
```

Context inherits the immutable model declaration that authored this tool. A standalone
member-authored tool may provide `model_defaults` on its tool step. Tools are the
complete frozen declarations, including aliases; children resolve against that scope.
Runner entries retain `route: {kind: "runner", runner_executor_public_id, tool_name}`
beside their exact callable schemas. Routing metadata never reaches the model provider.
Model defaults carry the inherited model, configuration, instructions, compaction and
failure policies. The nested model selection carries independent
`reasoning_enabled` and `reasoning_effort` controls, including an explicit false
switch; see [Models](models.md#reasoning-selection). An operation may narrow
tool names but cannot add undeclared ones. A standalone task without a declaring
model or explicit `model_defaults` cannot author model work; an empty tool context
permits no child tools.
`context.environment`, when present, contains the originating
`default_runner_executor_public_id`, `executors` and `runner_candidates` rows
with `{runner_executor_public_id, display_name, environment}`, and
`skills: [{name, description, callable, source, executor_public_id}]`.
`executors` contains the selected Runner and Runners referenced by explicit
tool routes; `runner_candidates` preserves eligible candidates in declaration
order without importing their tools. Executor environments are opaque data.
This context is frozen for the execution and does not duplicate routes or schemas.

Children preserve the parent's author origin, approval rules, billing and frozen
tool authority. A single `tool` operation names its inherited callable and has
no second target selector. A nested tool step may repeat `route` only when it
exactly matches the inherited route; a change is `tool_route_mismatch`. A
model-generated program never becomes a member-authored approval grant.

The trace interleaves acceptance and observation events by monotonically increasing
task-local `position`. `position` is the current end, even on a partial page;
`next_after` is the last returned position when more events remain. Fetch all pages
when recovering an accepted operation response. No live graph status is a substitute
for a recorded observation. Internal numeric database identifiers never appear on this wire.

## Accept one operation

```http
POST .../operations
Content-Type: application/json

{"claim_token":"…","operation":{"key":"op_0","request":{"kind":"tool","name":"read_file","input":{"path":"README.md"}}}}
```

`key` is 1–64 ASCII letters, digits, underscores or hyphens, starting with a letter or
digit, unique within the parent task across claim generations. `operation.request` is
this endpoint's explicit opaque JSON object exception, read from the JSON body and
retained as the operation's identity. Its complete canonical JSON value participates
in replay matching, including refused fields. It must fit
the ordinary `envelope_bound`. Invalid outer identity/shape/size refuses without
acceptance. Semantic failures of a recognized request are recorded as operation
refusals and are observable by the program. Unknown top-level request fields are a
durable `unknown_fields` refusal; tool `input` remains the tool's opaque JSON payload.

| Request kind | Request fields |
| --- | --- |
| `tool` | `name`, `input`, optional `timeout_ms` |
| `model` | `input` with the public model-step fields; `model` may be a model name or selector object; `tools` is a list of inherited names |
| `ask` | `input` with the public ask-step fields |
| `wait` | `input` with the public wait-step fields |
| `steps` | `input` as a step array, or `{steps: [...]}` |
| `replace` | `input: {operation_key, tasks: [local_key_or_task_key], steps: [...]}` |
| `cancel` | `input: {operation_key, tasks?: [local_key_or_task_key]}` |
| `join` | `input: {operations: [operation_key], until?: "all"\|"any"\|positive_integer, losers?: "cancel"\|"run_out"}` |
| `background` | `input: {steps: [...], lifetime?: "turn"\|"conversation", wake?: "auto"\|"passive"}`, or `{operation_key, lifetime?, wake?}` to release existing work |

Steps use the [Run grammar](runs.md). One operation is bounded to 64
authored steps, with the existing per-task dependency and byte bounds. These are
submission bounds, never a cumulative operation/work cap. A batch validates and
accepts atomically; its external effects still execute as ordinary independent tasks.
Local keys resolve to newly allocated task keys; receipts provide that mapping. Raw
edge operations and changes outside this parent's accepted work are unavailable.

Replacement accepts only selected future tasks that have not started. It atomically
publishes a new batch, rewrites surviving future dependencies/reads and cancels the
selected old tasks. The old definitions and results remain historical facts. Dispatch
and replacement have one winner under the same lock. Started work is refused as
`task_already_started`, without partial mutation. Cancellation of started work is a
separate operation and retains the ordinary uncertainty of already initiated effects.

Each operation retains the result identities in its accepted receipt. Replacing the
original operation's final task makes that original observation report its cancellation;
observe the replacement operation for the new result. Rewiring future consumers does
not rebind an existing operation or its Promise to different result identities.

A background launch returns its acceptance receipt immediately. Releasing an existing
operation records `released_operations` in the new receipt and observation; it does
not manufacture a result for the released operation. Live tasks inherit the explicit
background lifetime/wake; completed historical task facts remain intact. Background
defaults to conversation lifetime and the parent's wake mode. Ordinary attached child
results remain behind the parent's final-result boundary; released results use the
existing wake/mail delivery rules.

The response is `201` for first acceptance and `200` for exact replay:

```json
{"operation":{"type":"operation","position":1,"key":"op_0","request":{"kind":"tool","name":"read_file","input":{"path":"README.md"}},"receipt":{"task_keys":["…"],"result_task_keys":["…"],"steps":[],"keys":{},"background":false}}}
```

A semantic refusal replaces `receipt` with `refusal: {code, message}`. The receipt or
refusal and all child mutations commit together. Losing the HTTP response never
licenses a new operation identity. Retrying the same identity and request returns
the stored event; changed content returns `409 operation_mismatch`.

## Publish the next observation

```http
POST .../observation

{"claim_token":"…","after":1}
```

Nexus selects the earliest accepted ready operation and seals its outcome before
returning it. Refusals and background receipts are immediately ready; other results
wait for their authoritative result boundary, including model expansions and joins.

```json
{"observation":{"type":"observation","position":2,"key":"op_0","outcome":{"status":"completed","is_error":false,"output_present":true,"output":"…","content":[{"type":"text","text":"…"}],"structured_content":null,"structured_content_present":false,"error":null,"run_public_id":"…","task_key":"…"}},"position":2}
```

No ready operation returns `observation: null`. A recorded business refusal uses
`refusal` instead of `outcome`. Batch/replace/join/cancel outcomes carry `results`, an
array of result envelopes. A selection may carry `selected`. `is_error` remains data
and does not itself become a transport failure or thrown exception. `output_present`
distinguishes missing output; `structured_content_present` distinguishes an absent
structured value from explicit JSON null. False is also retained. Content uses the
existing text/resource-link contract and captures remain attached to the sealed
observation body. Later repair of the original child output cannot change a recorded
observation. Trace retention is owned by the parent task's existing retention lifecycle.

Joins expand nested joins into their selected result envelopes in completion order.
A completed `all` join includes failed and canceled sources; `any` and quorum joins
retain their captured winners even when a losing source later completes. A canceled
join reports its own cancellation without exposing its unfinished sources.

Retrying an older `after` returns the next already-recorded observation, if one
exists. The returned `position` is that observation's position, so advancing it
does not skip subsequent recorded events. Otherwise a changed trace returns
`409 operation_position_changed`; reload the trace rather than inventing an order. HTTP/auth/claim failures are runtime control
outcomes, not catchable business refusals.

## Wait while retaining execution ownership

An empty observation is a finite read, not completion or failure. The executor keeps
its handler and cancellation owner alive, observes again later, and uses the ordinary
`POST .../extend` deadline command before expiry. Waiting for a child, approval or
Human answer does not require output or CPU activity before renewal. Each granted
extension remains within the announced timeout or the kernel's one-hour bound.
`timeout_ms` is the renewable claim window, not a cumulative evaluation budget.

A waiting handler must yield local capacity needed by its child while retaining its
execution state. The language or tool runtime owns that local scheduling. Resource
limits remain at their owners: a requested process timeout or VM computation limit
is separate from the renewable claim window.

Nexus does not replay parent source after an executor or VM disappears. An expired
claim follows the ordinary effect profile: replayable work times out for explicit
retry; a possibly escaped effect becomes `uncertain`. An adapter may inspect and
reconnect to the same external work only when that work's own protocol supports it.
A missing response never authorizes launching a replacement. Accepted operation
receipts and observations remain readable; they are not a runtime checkpoint.

Pause freezes the Run's deadline clock. An existing claimant can still observe accepted
results and renew its claim; executor responses project the frozen remaining window onto
wall time for the live handler. A new operation during Pause returns `409 execution_paused`
without accepting it. Retain the same operation key and request while waiting for Resume.
Graceful Stop permits observations and final settlement but rejects new child operations
with `execution_stopped`. Force Stop cancels the parent and its owned child work. Released
work retains its original Run/Conversation Stop ownership.

## Commit the final result

Use the ordinary `POST .../commit` content contract. First success requires the live
claim and no attached unobserved operation or unfinished child. Explicit background
ownership is the sole exemption. Failure settles the parent and cancels remaining
attached work; accepted background obligations retain their ownership. A committed
final result is write-once: the final claim's exact retry returns the stored result;
a different final result returns `409 final_result_conflict`. Expiry does not turn an
uncommitted or unknown result into success.

An active claim may commit its final result during graceful Stop or pause. These
states permit no new child operations. Forced Stop and a cut source execution still
fence final publication.

An exact retry still proves the final claimant and token, even after that
claim's deadline. A previous generation's token remains stale. The digest covers
the submitted content, structured-value presence and value, result type, outcome,
error flag, title and metadata; JSON object key order is immaterial. Explicit
`structured_content: null` is a value, distinct from omitting the field.

A final `resource_link` may name the committing executor's own capture or a capture
retained by this parent's sealed operation observations. This lets a program return
media produced by a different child executor. Merely knowing an upload id, or
observing it through another parent task, grants no final-result binding authority.

## Refusals

The normal executor authentication/status codes apply. Additional `409` control codes
include `operation_mismatch`, `operation_position_changed`, `claim_expired`,
`execution_paused`, `execution_stopped`, `pending_children`, and `final_result_conflict`. `invalid_operation_key`, `invalid_operation` and
`operation_too_large` are `422`. Accepted semantic refusals are trace events, not HTTP
errors; their `code` and `message` are durable program-visible data.
