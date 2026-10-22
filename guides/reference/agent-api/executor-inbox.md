---
description: The executor inbox protocol — reading addressed rows, exclusive claims, bound attachments, deadline extension, write-once commits, expiry, cable push, progress frames, operator requests, lifecycle hook tasks and delegated compaction.
---

# Executor inbox

The runner protocol lives on the executor plane and nowhere else: the credential names the executor, and that executor's own inbox is the scope. A workspace never is, and a member bearer holds none of these doors. Four verbs: read the inbox, claim a row, commit its answer, and listen for the push that says a row appeared. The shapes are captured in `contracts/nexus/v1/executor_inbox.json`.

The address itself — kinds, discovery, announcement, captures — is on [Executor](executor.md). Child work under a claim is on [Executor operations](executor-operations.md).

## Routes

```http
GET  /agent_api/v1/executor/inbox?after={cursor}&limit={n}
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
GET  /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
GET  /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}
GET  /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}/bytes
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/extend
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/commit
POST /agent_api/v1/executor/progress
WS   /agent_api/v1/cable
```

## Read the inbox

### Endpoint

```http
GET /agent_api/v1/executor/inbox?after={cursor}&limit={n}
```

This address's view of the work the kernel addressed to it, across every live run of its account: level-triggered and complete. The inbox is state, not a queue. Answered work leaves, and a runner that slept, crashed, restarted or missed a push discovers work by reading it. The cursor is opaque; the page is bounded (default 50, maximum 200); a cursor that does not parse is `400 parameter_invalid`.

### Response

```json
{
  "tasks": [
    {
      "kind": "tool_call",
      "run_public_id": "01900000-0000-7000-8000-00000000000a",
      "workspace_public_id": "01900000-0000-7000-8000-000000000001",
      "conversation_public_id": "01900000-0000-7000-8000-00000000000c",
      "parent_public_id": null,
      "task_key": "r1t0",
      "tool_name": "read",
      "tool_input": { "path": "note.txt" },
      "tool_call_id": "call_1",
      "started_at": "2026-09-07T10:00:00Z",
      "deadline_at": "2026-09-07T10:00:30Z",
      "timeout_ms": 30000,
      "claimed": false,
      "addressed_to": { "role": "runner", "executor_public_id": "01900000-0000-7000-8000-000000000002" }
    },
    {
      "kind": "ask",
      "run_public_id": "01900000-0000-7000-8000-00000000000a",
      "workspace_public_id": "01900000-0000-7000-8000-000000000001",
      "conversation_public_id": "01900000-0000-7000-8000-00000000000c",
      "parent_public_id": null,
      "task_key": "r2t0-ask-1",
      "prompt": "Migrate users.email to citext now, or in the maintenance window?",
      "options": ["Now", "In the maintenance window"],
      "multi": false,
      "started_at": "2026-09-07T10:00:04Z",
      "deadline_at": "2026-09-08T10:00:04Z",
      "timeout_ms": 86400000,
      "claimed": false,
      "addressed_to": { "role": "agent", "executor_public_id": "01900000-0000-7000-8000-000000000003" }
    },
    {
      "kind": "tool_call",
      "run_public_id": "01900000-0000-7000-8000-00000000000a",
      "workspace_public_id": "01900000-0000-7000-8000-000000000001",
      "conversation_public_id": null,
      "parent_public_id": null,
      "task_key": "r3t0",
      "tool_name": "memory_read",
      "tool_input": { "path": "workspace/notes.md" },
      "scope": {
        "bindings": [
          { "name": "workspace", "scope": "workspace", "access": "read_write", "workspace_public_id": "01900000-0000-7000-8000-000000000001" },
          { "name": "user", "scope": "user", "access": "read_write", "user_public_id": "01900000-0000-7000-8000-000000000003" }
        ]
      },
      "tool_call_id": "call_3",
      "started_at": "2026-09-07T10:00:09Z",
      "deadline_at": "2026-09-07T10:00:39Z",
      "timeout_ms": 30000,
      "claimed": false,
      "addressed_to": { "role": "tool_provider", "executor_public_id": "01900000-0000-7000-8000-000000000030" }
    }
  ],
  "pagination": { "next_after": "…" }
}
```

### Row kinds

| `kind` | What it is | How it ends |
| --- | --- | --- |
| `tool_call` | A parked tool call | Claim, then commit |
| `ask` | A model's question to a person | The member `resolution` door, or the clock |
| `approval` | A tool call resting for an approver | `approve` or `deny` on the member plane, or the clock |

A `tool_call` row carries `tool_name`, `tool_input` and `tool_call_id`.

An `ask` row may carry `fields` for a [typed question](run-steps.md#typed-questions), answered through the member resolution door with `answer`. It otherwise carries `prompt`, with `options` (one string each) and `multi` when the ask gave them, and no `tool_*` field. It is never claimed and never committed here: `claimed` stays `false` for as long as it stands, and the claim and commit doors answer `not_claimable_kind`. It parks up to 24 hours. It is listed only when the run has a declaring agent; a person's own standalone run addresses its ask to nobody.

An `approval` row is a tool call resting for an approver under a profile's `ask` or `rules` mode, listed for the addressed agent with its `tool_name`, `tool_input` and — the one row kind that carries it — the frozen `effect_profile` the approver reads. Its `deadline_at` is 24 hours out; it is never claimed and never committed here (`409 not_claimable_kind`). Under `bypass` no row ever rests, and a human's own standalone run addresses it to nobody.

An `ask` and an `approval` row are notices: machines claim and commit tool calls on this plane, and people decide questions and approvals on the member plane ([Runs](runs.md)), where the deciding principal is recorded. Carry a kind you do not know.

### Row fields

**`tool_alias`** — on a row whose call the model made under an alias of a kernel tool ([Profile](profile.md)): the spelling the model used, beside `tool_name`, the kernel's wire name. Absent on every other row.

**`workspace_public_id`** — required and non-null on every inbox and claim task: the workspace owning its run, including standalone execution, child conversations, asks and approvals. Use this kernel-owned scope when executing; a later default workspace does not change existing work. Ordinary metadata; it does not broaden `scope`.

**`conversation_public_id`** — the run's conversation, or an explicit `null` for a standalone run. What a call starts on a runner follows the conversation: the runner tracks a process it started by the conversation and ends it when the conversation's feed says `conversation_ended` ([Conversations](conversations.md)).

**`parent_public_id`** — the parent conversation's public id for a child conversation, or `null` for a root conversation or standalone run. Retained after the parent is reaped.

**`addressed_to`** — the executor the kernel addressed the call to at its start, or the role alone (`{ "role": "tool_provider" }`) for a pool row. Written at dispatch. `target` separately exposes the runner selected at acceptance; changing a default changes neither.

**`scope`** — accompanies kernel-named tools dispatched to an external provider. For an overridden memory tool it is `{ "bindings": [ … ] }`: each entry has `name`, `scope`, `access` and the corresponding `conversation_public_id`, `workspace_public_id`, `user_public_id` or `agent_public_id` (the answering agent's own row). The path's first segment selects `name`; the provider keys its memory by that entry's scope and public uuid, never by a guessed default. The set comes from the execution's frozen configuration with unavailable sources omitted; an empty set grants no roots; read-only bindings cannot author documents; the kernel refuses missing-root and read-only mutation calls before dispatch; unqualified list and grep search only supplied bindings; `tool_input` passes through unchanged. For a source-routed `skill` row, `scope` retains `{ workspace_public_id, conversation_public_id | null, user_public_id }`. Other rows have no scope.

**`timeout_ms`** — the park's budget on every row, the number `deadline_at` is cut from: a tool row's step-authored `timeout_ms`, else the announced entry's, else the kernel default; an ask's or a wait's own, clamped to 24 hours; an approval row's 24-hour hold. It never moves — a claim re-arms `deadline_at`, an extension moves `deadline_at` — so an executor can name the budget it was held to without reading a clock.

**`claimed`** — whether any executor ever claimed the row in this generation. A claimed generation is never re-granted, so a runner returning from a crash sees the work it holds and leaves it to its own deadline.

An executing claimant recovers a missed cancellation through the claim read below; absence from this list alone does not cancel a claim.

## Claim

### Endpoint

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
```

Exactly one executor may execute a parked call; this is where that is decided, atomically under the row's lock. Claiming is the fetch: the happy path is push → claim → run → commit with no listing at all, and the list remains the truth and the recovery path.

### Grant conditions

| Condition | Refusal when it fails |
| --- | --- |
| The row is addressed to this executor, or is a pool row this `tool_provider` announced the name of | `409 not_addressed_here` — a kernel tool carries no addressee, and a row addressed to another executor of the account is not absence |
| The row is a `tool_call` | `409 not_claimable_kind` for an ask or an approval |
| The row is a `dispatched` park on a run that can still be answered | `409 task_not_claimable` once it settled or its run stopped |
| Nobody ever claimed it in this generation | `409 already_claimed` — a lapsed generation is not re-granted; the sweep settles the tool by its frozen effect profile |
| The executor is still eligible for the run's frozen answering principal | `409 not_eligible` |
| The run's creator still holds write standing on its workspace | `409 not_authorized` |

Commit retains the creator's write-standing check; an existing claimant may still report its result during its manager's shutdown (below).

An application address may serve its Agent and that Agent's named Agents
under the same live Human steward. The named Agent remains the execution
principal; sharing the address supplies no additional tools, memory or member
authority. Removal or steward transfer closes new claims and task-operation
admission without revoking the parent application's transport credential.

### Response

```json
{ "task": { "…": "…" }, "claim": { "claim_token": "…", "deadline_at": "2026-09-07T10:00:30Z" } }
```

`task` is the same executable row the inbox lists, including `workspace_public_id`, `tool_input` and `tool_call_id`.

The token rotates on every claim, so a runner returning from the dead cannot settle over whoever holds the work. A claim stands until the park's own deadline — one clock, no lease, no heartbeat — and taking the work restarts that clock, so the holder gets a full deadline rather than one already spent. Exclusivity is by token, never by the caller's standing: concurrent claim requests from the same address compete, and the same address claiming twice is refused like anyone else; this does not make copied credentials separate identities. Waiting for children or a person keeps this same claim and renewal contract. An observation window ending does not complete the tool; its resource limits remain the executing runtime's.

## Read bound attachments

### Endpoints

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}/bytes
Claim-Token: <the token granted to this execution>
```

### Response

The descriptor is the ordinary `{ "upload": { public_id, filename, content_type, byte_size, created_at } }`. The bytes resource streams the original file, supports HTTP `Range` (`206`) and never redirects to a signed storage URL. Both use `Cache-Control: no-store`; the proof appears only in the header and is not returned.

### Rules

The exact executor and token must still own a `dispatched` claim whose deadline has not passed: a mismatched proof is `409 not_claimant`, an elapsed or settled claim `409 claim_inactive`, a missing proof `400 parameter_missing`. The run and task are scoped to the executor's account; a missing, fileless or unbound file answers `404 not_found` without a descriptor.

A file must be bound by the upload join to an input or result node of this run, to this run's exact conversation variant prompt, or to a prior active variant reachable on the conversation's assembly surface, which supplies its prompt and content attachments and its run's result captures. The history scope honors fork boundaries and concealment, excludes future turns and inactive variants, and stays available across compaction when a summary retained the reference. Native-media omission does not revoke a bound reference. Another staged file in the account, or a capture from an unrelated run, is not enough. Publishing a result still requires the committing executor's own capture.

The capability belongs to the existing claim, so a pause or a default-runner change does not require new work or a member credential. Reads take no domain locks and neither renew a deadline nor settle work; ordinary authentication and rate limits apply; each read checks its claim before streaming; revocation does not recall bytes already transferred. The runner's `file_import` uses these resources and keeps only reconstructible working files; Nexus remains the durable attachment owner.

## Read an existing claim

### Endpoint

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
Claim-Token: <the token granted to this execution>
```

Available to every executor kind. The proof is the `Claim-Token` header, never a query or body field.

### Response

```json
{ "claim": { "active": true } }
```

Nexus first matches the row's claimant executor and original token, then reports whether the task remains `dispatched`. The read neither renews the claim nor changes its deadline; it acquires no domain lock, writes no domain state and schedules no work. Responses use `Cache-Control: no-store` and never return the token or executable input.

| Observation | Response |
| --- | --- |
| Exact claimant and token, task still dispatched | `200`, `active: true`. Pause, needs-attention and graceful canceling do not invalidate existing work. |
| Exact claimant and token, task settled | `200`, `active: false`. Stop this local execution, including when its force-stop notification was lost. |
| Different claimant, wrong token, or an old token after retry under the same task key | `409 not_claimant`. Stop the old execution. |
| Missing task, missing or tombstoned run, or a run outside the executor's account | `404 not_found`. The bound claim is no longer available. |
| Missing or blank `Claim-Token` | `400 parameter_missing`, naming the header without echoing it. |

The proof does not depend on current inbox membership, tool announcements, the conversation's current default runner or eligibility for new work. A claimed task survives a default-runner change or its manager's pending shutdown until its own lifecycle settles. A read observes persisted status and does not project an elapsed deadline; deadline settlement remains authoritative.

Poll while the local execution remains active, even with the cable connected. Read errors, `429`, malformed responses and transport failures are not proof of cancellation: retain the execution context, resources and deadline, honor `Retry-After`, and let terminal credential-loss handling act on its own authority. A failed read does not release local admission capacity; the handler's actual yield or exit owns that. Cancellation must target the original execution, not a new claim later issued under the same task key. The reference runner checks every five seconds; larger pools increase the interval. The best-effort local deadline rule under [Expiry](#expiry) applies to these reads.

Claim reads have a separate caller budget of 600 per minute; claim `POST`s have the ordinary 6,000. Both keep the source-IP backstop; a `429` carries an integer-seconds `Retry-After`.

## Extend

### Endpoint

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/extend
```

### Request

```json
{ "claim_token": "…", "timeout_ms": 300000 }
```

Only the row's current claimant may extend — the executor that took the row and the token its claim minted (`409 not_claimant` for any other address or token, including one from an older execution) — on a row that is a claimed `dispatched` park on a live run with an uncut execution source (`409 not_extendable` for an unclaimed, settled or queued row, an ask, or a stopped execution). A claim at or past its current deadline is also `409 not_extendable`, even before the sweep settles it; the refusal changes neither the task nor its clock and emits no event. Pause and a repair hold preserve the ability to renew.

`timeout_ms` is the new budget from now: the deadline becomes now plus it, bounded by the tool's announced `timeout_ms` when the tool announced one and by the kernel's hour (3,600,000 ms) either way (`409 extension_too_long`); a value that is not a positive integer is `422 invalid_timeout_ms`. There is no count limit and no overall run deadline: a live claimant may keep extending, while task cancellation or a run force-stop can settle the park, and once the claimant stops extending the current deadline applies.

### Response

The same `{ task, claim: { claim_token, deadline_at } }` a grant gives, with `deadline_at` moved; nothing rotates. The write moves the one clock the claim owns, so the sweep's frontier follows it. The row's `timeout_ms` is unchanged: the budget does not move, the clock under it does. The extension is narrated on the run's stream as `task_deadline_extended { task_key, deadline_at, by, timeout_ms }` with `by` the claimant's public id.

During pause the persisted deadline uses the frozen run clock; the returned `task.deadline_at` and `claim.deadline_at` map the remaining window to wall time so a live executor keeps its timer and renewal path, and resume shifts the stored clock once by the pause duration. A commit arriving after a deadline the claimant did not move stays an expiry: extension prevents one, never bypasses it.

## Commit a result

### Endpoint

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/commit
```

### Request

```json
{
  "claim_token": "…",
  "content": "…",
  "structured_content": { "…": "…" },
  "result_type": "complete",
  "is_error": false,
  "outcome": "completed",
  "title": "read note.txt",
  "metadata": { "…": "…" }
}
```

Only `claim_token` is required; `outcome` defaults to `completed`. The door settles tool calls alone: an `ask` or an `approval` row answers `409 not_claimable_kind`, as on the claim door, and is decided on the member plane.

**Two axes.** `is_error: true` on a completed outcome is a tool that ran and errored: data the continuation reads, marked so an error never reads as an answer. `outcome: "failed"` is a tool that could not run at all (`tool_failed`) and takes the task's own `on_failure` policy.

**Three channels, one meaning each.**

| Field | Meaning |
| --- | --- |
| `content` | MCP's `CallToolResult.content`: a string, or a list of blocks of two kinds — `{ "type": "text", "text" }` and `{ "type": "resource_link", "uri": "nexus://uploads/<public_id>", "name", "mimeType"?, "size"?, "title"?, "description"? }` (MCP's `ResourceLink`; `name` required). The `uri` names this executor's own capture ([Publish a capture](executor.md#publish-a-capture)) or a capture retained by this task's sealed operation observation, else `422 unknown_result_upload` with the park standing; any other scheme is `invalid_content`. This is the only channel a model reads: text blocks as their text and non-media links as standard MCP `resource_link` JSON, in block order; links to bound image and PDF uploads (identified by the upload's detected type, not the link's `mimeType`) as one attachment-only message after the round's last result when the current model accepts that media type, else as a ruled index line. Later turns retain those attachments with the round, subject to model selection, history budget, pruning and compaction. A structure-only result has empty text. |
| `structured_content` | MCP's `structuredContent`: any JSON value, including explicit `null` and `false`. An omitted field is absent; an explicit `null` is a stored value. Stored whole, served on the task read, never rendered to a model; a runner that wants the model to read its structure puts the words in `content`. A kernel-created lifecycle hook task additionally interprets the decision object described under [Lifecycle hook tasks](#lifecycle-hook-tasks); an ordinary tool's structured output is opaque even with the same keys. |
| `metadata` | The model-invisible carrier: a JSON object bounded by `envelope_bound`, served on the task read, with one reserved key, `checkpoint`. |

`title` is the UI's one-line header for a collapsed row, under [Runs](runs.md)'s grammar.

### Checkpoints

The value under `metadata.checkpoint` is the announcing runner's own record of its environment before the call ran, stored and served verbatim — any JSON object. rho-runner writes `{ hash, store }` (an opaque manifest hash in the runner's SQLite store and the store's id; `outside: [paths]` when the call's target lay outside the root, `ignored: [paths]` when it was gitignored), or `{ skipped, bytes, files }` when it declined to capture. The kernel reads whether a `hash` is present and interprets nothing else; the row's claimant (`claimed_by_executor_public_id`) is the runner that wrote it.

A runner that captures also announces `checkpoint_restore` (a write-kind tool taking `{ checkpoint, store? }`) and `checkpoints` (a read taking `{}`, `{ run }`, `{ from, to }` or `{ checkpoint }`, each with an optional `store`), described to nobody so no model declares them; a member reaches them through a request run. The store identifier selects the original work root, and an unknown store refuses rather than falling back to the default root. Without a selector, restore and diff use the current root, while a record list can find a run across stores. Restore first commits a fresh undo and refuses before changing files if a displaced path was not captured (an ignored or oversized file). A cancelled restore can be partial; its undo remains discoverable through `checkpoints`. Retention removes expired records and unreferenced content. Checkpoint storage has no Git-format import or fallback.

### Settlement

For ordinary tools the commit is write-once and the answer is the settle's own `{ task }`. A second commit under the same token after the settle is `200` with the task unchanged (`idle`): a retry after a lost response is never a second answer. A wrong, rotated or lapsed token is `409 stale_claim`; a task not yet dispatched is `409 task_not_running`.

The deadline wins: an answer arriving after the park expired settles the task by the expiry rule — `timed_out`, or `uncertain` for a claimed non-replayable call — and its content is discarded. The address proves the door before the token proves the claim: a commit from an executor the row does not name, or on a pool row from any member but its claimant, is `409 not_addressed_here` whatever token it carries.

Payload refusals leave the park standing: `422 invalid_outcome`, `result_too_large` (1 MB), `invalid_result_type`, `invalid_title`, `invalid_metadata`, `metadata_too_large`, the content grammar's `invalid_content`, `unsupported_content_kind` and `too_many_content_blocks`, and `unknown_result_upload` (whole or nothing; a merely known id grants no access). One refusal does not: `422 result_unstorable` — bytes storage can never hold the result (a NUL, invalid UTF-8) — refuses the report and closes the park, the task settling `failed` with `error.key: result_unstorable` and the guard's word in `error.detail`. A typed refusal is final; the bytes are the runner's to clean before it submits. A commit refused by transport — a dropped connection, a `429` — is safe to retry under the same token while the deadline stands.

A claimed task may still commit while its executor's controlling human is shutting down: the current transport and the task's own claim token prove the result, and the new-admission eligibility check does not reject it. New claims stay closed and an unclaimed ask still requires current eligibility. Explicit executor revocation and the creator's write-standing check still apply. Agent removal advances its application's credential epoch immediately, so an old transport credential cannot use this rule to bypass the fence. A late result cannot replace a force-stop terminal state.

A tool with accepted operations additionally requires all attached work to have settled and been observed or explicitly released. An exact retry by its final claimant returns the stored result even after the claim deadline; changed content refuses `final_result_conflict`; previous-generation tokens remain stale. See [finalization](executor-operations.md#commit-the-final-result).

### Answering an ask

An ask is answered on the member plane: `POST …/runs/{run_public_id}/tasks/{task_key}/resolution` ([Runs](runs.md)) by a member with write standing, with no token for a model's own ask. `content` is the answer the model reads as `<answer task="…">` on its next round; `outcome: "failed"` escalates through the ask's own policy (a kernel ask halts). The settle records who answered. A second answer is `200` with the task as it stands.

## Expiry

The sweep and a commit arriving at or after a park's deadline use one settlement rule:

| Claim state | Settlement |
| --- | --- |
| Never claimed | `timed_out` (`error.key: tool_timeout`): nothing started, whatever the profile |
| Claimed, replayable profile (a `read_only` or `pure` kind, or `intrinsic` idempotency) | `timed_out`: a re-run is harmless, so the model may re-issue the call from its envelope or a person may `retry` it |
| Claimed, any other profile | `uncertain` (`error.key: tool_uncertain`; `error.detail` says the effect may have happened): nothing re-runs it blind. The run reads it as a failure — absorbed into the model's envelope, or holding the run for a person's `retry` (a new generation keeping the accepted runner target) or `abandon` |

A tool never re-queues itself at expiry. Its accepted child operations and observations remain durable; expiry settles the parent and cancels attached work; each child keeps its own deadline and effects. No renewal or operation trace reconstructs a lost handler, VM or external handle.

The runner derives its handler deadline from the current claim, reserving time to submit. At that local deadline it requests cancellation and attempts to commit `completed` with `is_error: true` and this stable text: "The tool timed out: its granted execution deadline passed before it returned a result. Cancellation was requested; external effects may be incomplete. Check its effect before calling it again." Process tools own their process cleanup; the shared deadline path does not promise that every handler or external process stopped or that an effect was undone. A handler that ignores cancellation keeps its context and resources until its actual exit; a late result cannot replace the settled outcome. Local deadline handling is best effort while a control HTTP request or credential refresh is in flight: the request must have a finite timeout, which may exceed the task's remaining time; afterwards the deadline and cancellation path resumes without extending the park. No aggregate probe deadline or extra concurrency is required to align the HTTP and task budgets.

The kernel may settle an unanswered claim before a live runner completes this path, as when the runner died or lost its network; the frozen effect profile decides `timed_out` versus `uncertain`. A handler with no clamp of its own — a tool provider's, the delegated compaction — is what extension is for: the runner extends at half the park and again at each half while the handler runs; a tool that clamps itself (bash) never extends.

## Push

`AgentAPI::V1::ExecutorInboxChannel`, subscribed with no params over the cable whose bearer is the transport credential. A member bearer holds no executor identity and is rejected. Two frames, nothing executable:

| Frame | Payload | Meaning |
| --- | --- | --- |
| `work_available` | `{ type, kind, role, run_public_id, task_key, tool_name? }` | A row is addressed to this executor: which and where, never what. The role selects the service on the address; a runner claims that row directly instead of paging; a wide fan publishes one frame per member; a pool row's frame reaches every member's stream and the first claim takes it. An ask's frame is `{ type: "work_available", kind: "ask", role: "agent", run_public_id, task_key }` — the agent's notice that a model is waiting on a person; nothing claims it. |
| `work_canceled` | `{ type, run_public_id, task_key }` | To the claimant when the kernel cancels a row it holds (a stop, a branch cancel): the runner stops the handler, and its commit afterwards is `idle`. |

The socket closes when the credential stops being usable — a re-pair, a revoke, a lineage loss — within the connection's authority check interval; the stream name carries no epoch. HTTP remains authoritative: the inbox recovers work discovery and the claim read recovers cancellation for work already executing. A missed frame is detected by the relevant read, never inferred from inbox absence.

## Progress

### Endpoint

```http
POST /agent_api/v1/executor/progress
```

### Request

`{ frame }`, fenced by a source claim.

| Frame | Shape |
| --- | --- |
| Tool progress | `{ run_public_id, task_key, claim_token, text_tail?, structured? }`; requires the current claimant; a settled task drops further frames |
| Process progress | `{ conversation_public_id \| run_public_id, process_id, source: { run_public_id, task_key, claim_token }, lines[], exit? }`; the nested source identifies the task that started the process, and its target, claimant, token and host must match |

A process's original claim remains proof after settlement; a default-runner change neither revokes it nor authorizes another runner. Retry rotates the claim and detail collection removes the evidence, after which stale process frames refuse without terminating the process; an explicitly targeted `read_process` call remains available. Tokens stay private and are never broadcast.

### Response

`202` for every well-formed frame. The kernel stamps `type`, `executor_public_id`, `at` (milliseconds) and, inside a claim, `tool_name`; the payload is `text_tail` / `structured` on `executor_progress` and `lines[]` / `exit` on `process_output`. A body over `envelope_bound` is `422 frame_too_large`; a key of neither kind, or a payload member of the wrong type, `422 invalid_frame`. One frame per key per `min_interval_ms` per kernel process (`size_bounds`, `progress_min_interval_ms`): a faster poster is answered `202` and the frame dropped, never refused.

Frames go out on the host's `progress` feed (`items: "progress"` on the host's events channel) under the envelope `{ frame }`, never `{ event }`. Nothing is stored in the primary database and nothing replays; a late subscriber sees what follows. The kernel's own frames on the same feed are [Runs](runs.md)'s; the feed's vocabulary is listed once under [Conversations](conversations.md).

## Requests addressed as tasks

An executor surface is either a capture the executor publishes or a request addressed to it as a task. A request for something only this executor can answer — a file's bytes, a process's log — is a tool call like any other: a one-task standalone run a member creates and starts on the task-grained surface ([Runs](runs.md): `POST …/runs` with `steps: [{ tool: { name, input, route: { kind: "runner", runner_executor_public_id }, timeout_ms? } }]`, `prompt_mechanism: raw`, `approval_mode: bypass`, then `POST …/start`), whose deliverable is that step. The row is granted by its origin unless the run's `approval_rules` deny it or name `author` with `ask`.

It lists on this inbox as a `tool_call` row with `conversation_public_id: null`, is claimed, extended and committed by the doors above, expires by the sweep at its own deadline (the step's `timeout_ms`, else the announced park, else the kernel default), and its answer is read on the member task read — `content` (a `resource_link` when the answer is a capture), `title` and `metadata`. There is no second door and no second kind: a runner announces a capability as a tool (a `read_only` profile for a read, without `description` or `input_schema` so no model is handed it) and serves it; a name it did not announce refuses `tool_not_served` at acceptance, and withdrawal before delivery fails the task with the same code. Presence is never consulted: an offline runner's request waits out its deadline and settles `timed_out`. A deliverable that does not complete holds the run `needs_attention deliverable_unresolved`; the Ruby SDK's managed `runs.start_tool_call` and `wait_for_tool_result` composition reads the terminal task and `stop`s the run behind a failed one. The TypeScript and Rust tool-result waiters leave that lifecycle command to the application.

## Lifecycle hook tasks

A profile's [lifecycle hooks](../../build/lifecycle-hooks.md) run as ordinary `tool_call` rows. The configured executor tool must be announced normally; it need not appear in the profile's model-facing `tool_definitions`. Claim, approval, extension, timeout, cancellation and commit use the same protocol; there is no separate hook inbox.

The kernel supplies `tool_input` with `event` (`turn_start`, `pre_compact`, `post_compact` or `stop`), `task_key` of the triggering task, `run_public_id`, `conversation_public_id` (`null` for standalone execution), `output_preview` and `output_size_bytes` (both may be `null` before output exists). A mid-turn `pre_compact` adds `compaction_trigger` (`manual`, `usage`, `wall` or `overflow`) and nullable `overshoot_bytes` and `overshoot_tokens`; the token count is present only for a token limit, and its byte estimate does not prove the tokens a prune can free. The row's own `task_key` identifies the hook task to claim and commit; the key inside `tool_input` identifies its source.

Acknowledge:

```json
{ "claim_token": "…", "content": "Review complete.", "structured_content": { "continue": false } }
```

Only a `stop` hook may request another model round:

```json
{
  "claim_token": "…",
  "content": "A follow-up is needed.",
  "structured_content": { "continue": true, "feedback": "Run the focused regression check before finishing." }
}
```

The decision object requires boolean `continue` and permits one other key, `feedback`: text without NUL, at most 16 KiB, required to be nonblank when continuing. Other events require `continue: false`. Only the server-owned hook marker gives the result control meaning; a matching field or tool name on an ordinary call does not. Stop feedback becomes the next model round's prompt, bounded by the declaration's `max_continuations`.

A malformed decision settles the hook `failed` with `invalid_hook_result`; `is_error: true` yields `hook_error`; exceeding the continuation bound yields `stop_hook_limit`; requesting continuation without a model round to inherit yields `hook_requires_model`. These are terminal task results, not a request to retry the commit. Ordinary `outcome: failed` and deadline expiry keep the usual tool failure rules. Hook failures hold for explicit repair: retry re-executes the hook, abandon releases its hold. Force-stop cancels pending hook tasks immediately without a hook veto.

## Delegated compaction

The kernel's own summarizer is the shipped default. An agent whose declared `compaction_policy` is `{ "mode": "delegate", "tool_name": "…" }` receives each compaction as an inbox row instead: a `tool_call` naming the policy's `tool_name`, addressed to the execution principal's serving application as an application tool (an Agent address is never a runner target), with `tool_input` `{ history, retained_tail, conversation, turn, task }` on a run-backed turn, `{ history, retained_tail, run_public_id, task }` on a standalone run, and `{ history, retained_tail, conversation, turn }` between turns — the history rendered as pointers, the tail verbatim. The agent claims and commits it like any tool row: the summary text as `content`, which the round reads in place of the history it replaced; `outcome: "failed"` when it could not summarize, after which the round fails on size. A `completed` answer marked `is_error` is never read as a summary. The address must announce the name, or the row fails at start `tool_not_served`.

A delegate nobody answered — the agent died holding the claim, or never claimed it — settles at the deadline by the expiry rule, and the kernel appends its own summarizer once in its place, narrated `context_compacted { mode: "kernel", trigger: "fallback", fallback_from: <the delegate's key>, fallback_reason: "tool_timeout" | "tool_uncertain" }` ([Run compaction](run-compaction.md)); a second failure is the honest size failure. A delegate on a run with no declaring agent — a person's own standalone run — is refused at the append door, `invalid_steps` with `delegate_requires_agent` ([Runs](runs.md)).

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | An inbox page; a claim granted or read; an extension; a commit applied or idle |
| `202 Accepted` | — | A well-formed progress frame, broadcast or dropped for cadence |
| `400 Bad Request` | `parameter_missing` `parameter_invalid` | A missing or blank `Claim-Token`; an inbox cursor that does not parse |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not an executor-transport credential |
| `404 Not Found` | `not_found` | A run or key this credential's account does not hold; an unbound, missing or fileless attachment |
| `409 Conflict` | `not_addressed_here` `already_claimed` `task_not_claimable` `not_claimable_kind` `stale_claim` `task_not_running` `not_eligible` | The claim and commit doors' refusals: the row names another addressee or a pool this executor is not a member of (or, at commit, a pool row it did not claim); was ever claimed; is no longer a claimable park; is an ask or an approval; the token is dead; the task is not yet dispatched; the executor lost eligibility |
| `409 Conflict` | `not_authorized` | The run's principal lost write standing — a fact about the row's run, not this credential |
| `409 Conflict` | `claim_inactive` | An attachment read names an elapsed or settled execution |
| `409 Conflict` | `not_claimant` | The source task, claimant and token do not match the posting executor (attachments, the claim read, extend, progress) |
| `409 Conflict` | `not_extendable` `extension_too_long` | The row is not a claimed `dispatched` park on a run that can still be answered, or the new budget exceeds the tool's announced `timeout_ms` or the kernel's hour |
| `422 Unprocessable Content` | `invalid_timeout_ms` | The extend door's `timeout_ms` is not a positive integer |
| `422 Unprocessable Content` | `frame_too_large` `invalid_frame` | A progress frame over `envelope_bound`; a frame keyed by neither a task nor a process, or a payload member of the wrong type |
| `422 Unprocessable Content` | `invalid_outcome` `result_too_large` `invalid_result_type` `invalid_title` `invalid_metadata` `metadata_too_large` `invalid_content` `unsupported_content_kind` `too_many_content_blocks` `unknown_result_upload` | A commit payload refusal, or a `resource_link` naming a capture that is not this executor's own; the park stands |
| `422 Unprocessable Content` | `result_unstorable` | The result's bytes can never be stored; the report is refused and the park closes, the task settling `failed` with `error.key: result_unstorable` |
| `429 Too Many Requests` | `rate_limited` | The caller budget or the source-IP backstop is spent; `Retry-After` is a whole number of seconds |
