# Claims and results

The runner protocol lives on the executor plane and nowhere else. Four verbs: read the inbox, claim a row, commit its answer, and listen for the push that says a row appeared.

## Bootstrap

```http
GET /agent_api/v1/executor
```

Answers which delivery address this credential is: `public_id`, `kind` (`agent_application`, `runner` or `tool_provider`), `status`, `display_name` and `credential_epoch`. Nothing is submitted; the response names no execution principal, because the address only receives work and each inbox row freezes the agent whose authority it uses.

## Read the inbox

```http
GET /agent_api/v1/executor/inbox?after={cursor}&limit={n}
```

This address's complete, level-triggered view of the work addressed to it across every live run of its account. Each row carries its `kind` (`tool_call`, `ask`, `approval`), `run_public_id`, `workspace_public_id`, `conversation_public_id`, `task_key`, `tool_name`, `tool_input`, `tool_call_id`, `deadline_at`, `timeout_ms`, `claimed` and `addressed_to`. Drain each bounded scan to its end, then start the next from the beginning.

## Claim

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
```

Exactly one executor may execute a parked call, decided atomically under the row's lock. The grant requires that the row is addressed to this executor (or is a pool row this provider is a member of), is a `tool_call`, is a dispatched park on a run that can still be answered, and has never been claimed in this generation. The executor must still be eligible for the run's frozen answering principal, and the run's creator must still hold write standing on its workspace.

| Refusal | Meaning |
| --- | --- |
| `409 not_addressed_here` | Addressed to another executor, or a kernel tool with no addressee |
| `409 not_claimable_kind` | An ask or an approval |
| `409 task_not_claimable` | Already settled, or its run stopped |
| `409 already_claimed` | Somebody claimed it in this generation |
| `409 not_eligible`, `409 not_authorized` | Eligibility or write standing lost |

A grant answers `{ task, claim: { claim_token, deadline_at } }` — the executable row beside the token. **The token rotates on every claim**, so a runner returning from the dead cannot settle over whoever holds the work. A claim stands until the park's own deadline — one clock, no lease, no heartbeat — and taking the work restarts that clock.

## Extend

A claimant still at work as the deadline nears may extend it: the same clock moved, bounded and narrated as `task_deadline_extended`, never a second timer. Waiting for children or a person keeps this same claim and renewal contract.

## Read the claim

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
Claim-Token: …
```

Recovers a missed cancellation. The read proves the claimant and token and projects dispatched state; it neither grants nor renews work. Cancel the original execution on `inactive`, `missing` or `not_claimant`. Inbox absence, pause and a changed default never revoke an existing claim.

## Commit

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/commit
```

```json
{
  "claim_token": "…",
  "content": "…",
  "structured_content": { "…": "…" },
  "is_error": false,
  "outcome": "completed",
  "title": "read note.txt",
  "metadata": { "…": "…" }
}
```

Only `claim_token` is required; `outcome` defaults to `completed`. **Two axes on every answer:**

- `is_error: true` on a completed outcome is a tool that *ran* and errored — data the model reads and self-corrects from.
- `outcome: "failed"` is a tool that could not run at all (`tool_failed`), which takes the task's own failure policy.

Collapsing the two costs the model its chance to fix its own call.

Three channels, one meaning each: `content` is MCP's `CallToolResult.content` — a string, or text blocks and `resource_link` blocks naming this executor's captures — and the only channel a model reads; `structured_content` is any JSON value, stored whole and served on the task read, never rendered to a model; `metadata` is the executor's own. Image and PDF captures reach the model as attachments when the current model accepts that media type.

A claimed task may still commit while its manager is shutting down; the claim token and current transport prove it. A late result cannot replace a force-stop terminal state.

## Expiry

A claim that passes its deadline with no result is settled by the sweep according to the task's frozen effect profile: a replayable call fails `tool_timeout` and may retry; a non-replayable call becomes `uncertain` — its effect may have happened, so nothing re-runs it blind — and a person's `retry` or `abandon` decides.

## Push

The executor inbox channel on `/agent_api/v1/cable` delivers `work_available` (a run, a task key and a tool name, nothing executable) and `work_canceled` to the claimant so a stopped row's handler stops with it. Keep polling while subscribed.

## Child operations

Every claimed tool may use the task operation protocol to accept child work — a question to a person, a hosted language runtime, further tool calls — under its existing claim, observe their results and publish its own final result. The handler stays alive while waiting and renews the ordinary deadline. This is how rho's `code` tool and `ask` from inside a tool work.

Field tables for every verb, the extend and progress doors, lifecycle hook tasks and delegated compaction are in the [Executor inbox reference](../reference/agent-api/executor-inbox.md); the child operation protocol is in [Executor operations](../reference/agent-api/executor-operations.md).


## Attach an interactive transport

An explicitly interactive handler can exchange bounded WebRTC descriptions and check current
interaction permission under its original claim. See [Task realtime](../reference/agent-api/task-realtime.md)
for both credential planes, the one-second authorization window and rho-runner's `context.realtime`.
The handler retains the same resource and execution ownership through Pause and temporary network
loss. Existing Stop and native cleanup still decide when that resource can be released.
