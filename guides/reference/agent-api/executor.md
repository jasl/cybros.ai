---
description: The executor transport plane's bootstrap read, the three executor kinds, presence, routing of tool calls, discovery of addressable executors, the announcement of served tools, and captures.
---

# Executor

The executor resource is the transport plane's bootstrap read: a process asks **which delivery address it is**. The credential names the address and nothing is submitted. The response includes the application's owning Agent, registration kind and service roles so a client can check independently supplied API keys. These are registration facts: each inbox row separately freezes the Agent whose authority that work uses. An independent runner holds no member credential — it is a machine, not a principal — so the executor plane is complete on its own.

The inbox that takes work for this address is on [Executor inbox](executor-inbox.md); child operations under a claim are on [Executor operations](executor-operations.md).

## Routes

```http
GET  /agent_api/v1/executor
PUT  /agent_api/v1/executor/announcement
POST /agent_api/v1/executor/uploads
GET  /agent_api/v1/executors
GET  /agent_api/v1/executors?role=runner
GET  /agent_api/v1/executors/{public_id}
```

The first three take an executor-transport credential. The `executors` discovery routes take a member credential: they answer a principal's question, not an address's.

## Get this credential's executor

### Endpoint

```http
GET /agent_api/v1/executor
```

### Authentication

An executor-transport credential and nothing else. A member credential is refused with `401`, exactly as a transport credential is refused on [Profile](profile.md). A transport credential stops working when its token, lineage or address is revoked, when it expires, or when an epoch advance supersedes it; it is never fenced by reusing a member-credential check.

Removing an Agent synchronously fences its member credentials and advances its agent address's credential epoch: the address stays `active` with the same public id, but the old transport credentials return `401`, including for a previously claimed result. Related running work is force-stopped asynchronously; the removal response does not wait for it. An independent runner's address and credentials are not revoked by Agent removal, although tasks in a related run can be canceled by that run's force-stop.

An inactive Agent receives no new tool calls, asks or approval notices on its agent address, even when a live human authored the turn: a tool with no eligible provider fails `tool_not_served`, and asks and approvals keep their member-plane human door until their run stops. Restore reopens eligibility without waiting for cleanup; it neither revives old credentials nor resumes stopped work. A device-flow reconnect issues fresh credentials on the retained address.

Removing the controlling human uses the managed-resource shutdown protocol: admission closes immediately, bounded convergence stops managed work, and each resource acknowledges its shutdown generation. The human's `managed_resource_shutdown_generation` must equal the executor's `applied_human_shutdown_generation` before new admission resumes; this acknowledgment is independent of a stewarded Agent's `applied_steward_shutdown_generation`. Convergence runs in two passes. First, per run under the run's lock, every unclaimed inbox row addressed to the executor is failed — `status: failed`, `error.key: executor_revoked`, the same shape as `tool_not_served` at start — with the task's own `on_failure` applied: an `absorb` member's fan continues, a `propagate` row skips its successors, a `halt` row holds the run for a person's `retry` or `abandon`. A task held for approval instead loses its executor address and keeps the workspace writer's approval door. The recurring park sweep performs these transitions in bounded batches, including in paused runs, while ordinary deadlines stay paused. Second, the executor acknowledges and advances its epoch only once no outstanding row is addressed to or claimed by it; while work remains the pass answers `work_pending` and the next wake retries, and claimed rows settle by their own deadline and effect profile while their transport credential remains current. A pool row names no executor and is not canceled by this cleanup; it stays in the pool for another member unless its own run is stopped. Explicit address revocation fences transport synchronously and wakes the same sweep after commit.

There are no query or body parameters.

### Response

```json
{
  "executor": {
    "public_id": "01900000-0000-7000-8000-000000000002",
    "kind": "agent",
    "status": "active",
    "display_name": "MacBook Pro",
    "credential_epoch": 1,
    "agent_public_id": "01900000-0000-7000-8000-000000000001",
    "registration_identifier": null,
    "assignment_scope": null,
    "service_roles": ["agent", "runner"]
  },
  "measured_at": "2026-07-25T00:00:00Z"
}
```

| Field | Type | Description |
| --- | --- | --- |
| `executor.public_id` | UUIDv7 string | Public identifier of this delivery address, stable for the life of the address |
| `executor.kind` | string | `agent` (an Agent's current address), `runner` (a logical runner registration) or `tool_provider` (a runner-shaped registration that serves tools by name and claims from pools) |
| `executor.status` | string | `active` or `revoked` |
| `executor.display_name` | string | The name the client gave itself when it connected |
| `executor.credential_epoch` | integer | The current authority epoch. A winning replacement connection advances it and fences every credential carrying the previous epoch. |
| `executor.agent_public_id` | UUIDv7 string or `null` | The owning Agent for an application address; `null` for a Runner or Tool provider |
| `executor.registration_identifier` | string or `null` | Opaque, non-secret machine registration identifier; `null` for an application address |
| `executor.assignment_scope` | string or `null` | A machine's `user_private` or `account_wide` assignment; `null` for an application address or a retired private registration |
| `executor.service_roles` | string array | Currently announced roles on this address |
| `measured_at` | string | When the block was measured |

### Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The address |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not an executor-transport credential: a member bearer, a fenced epoch, a revoked runner |
| `429 Too Many Requests` | `rate_limited` | The caller budget or the source-IP backstop is spent; `Retry-After` is a whole number of seconds |

## What the address means for each kind

Every kind behaves the same way because each logical registration has at most one non-revoked current address and pairing. A request accepted here carries a transport credential naming one such address. This does not prove that one physical process holds the credential: copied credentials are indistinguishable and unsupported, and an IP address or User-Agent is never an identity key. There is no second current address for the same registration to compare against; the resource describes the address its work is directed to.

### Agent

The sole non-revoked address of its Agent while the Agent exists. OAuth connecting that Agent again re-pairs this exact address — same `public_id` — and advances `credential_epoch`, which stops the credential the previous device held. Issuing another API key for the address preserves the epoch and existing keys. After terminal revocation, a later connection creates a new address with a new public id rather than reviving revoked history.

The application also serves its [named Agents](profile-agents.md)
while both identities are active under the same Human steward. Each task keeps
the named Agent as its execution principal, with its own captured tools, approval
policy, memory and conversation scope. New claims and task operations recheck this
relationship. Removing or transferring a definition does not revoke the parent
application's credentials. Shared transport does not import the parent's memory
or announced skill documents.

An application may also announce a `runner` service. It uses the same UUID, epoch, transport
credential, inbox and presence as its `agent` service. Its own Agent and eligible
named Agents can select that UUID as a Runner target; other applications cannot, even under the
same Human. Tool namespaces are separate by role. Removing `services.runner` closes new Runner
admission while existing claims retain their settlement path. Restoring the role needs no re-pair. Transferring the application Agent's stewardship changes the controlling Human for both services; it does not transfer OS access or deployment control.

### Runner

One durable logical registration keyed by `(account_id, manager_id, registration_identifier)`. Each key has at most one non-revoked current address; assignment scope is not part of the identity. The program supplies a stable, non-secret installation identifier — normally its product constant plus an instance component persisted at first boot — and reconnects with the same identifier; separate installations use distinct identifiers. Nexus treats the whole string as opaque and the person never types it. When the key has a non-revoked address, connecting re-pairs it and fences the old device; when it has none, connecting creates a new address.

An independent runner serves principals eligible under its frozen assignment scope:

- `user_private` admits its manager and Agents that Human stewards.
- `account_wide` admits eligible principals across the Account.

The browser selects scope for a fresh registration; re-pair preserves it. Only a fresh
registration after terminal revocation may choose again. There is no scope-change command.
Suspending an account-wide runner's manager is not a scope change; Human removal uses the
shutdown-generation fence above.

### Tool provider

A runner-shaped registration connected on the device flow's machine branch with `executor_kind: tool_provider`: a manager human, an assignment scope chosen at browser connection, a transport-only credential and the runner's re-pair rule. It shares the runner's registration key, and the key is kind-blind — one live address per key across both machine kinds — so a provider needs its own identifier, its kind is frozen like its scope, and a re-pair naming the other kind for a live key is refused at connection. It supports `user_private` and `account_wide` with the same eligibility rules as a standalone runner.

What differs is addressing: a provider is never a conversation's default runner. It takes work from a pool by the names it announces ("Where a tool call goes", below). Reserved kernel namespaces are refused at the announcement door for every kind; an overridable kernel name — today the memory family's wire spelling — is admitted and stored, and addressed to the provider once a workspace opts in through `PUT …/workspaces/{id}/tool_provider_overrides`.

## Presence

Presence is display, never a gate. The executor description, a task read's `addressed_to` and the member console render `presence` beside `last_seen_at` and `connected_at`:

| Value | Meaning |
| --- | --- |
| `online` | The executor's inbox subscription is open on a socket that answers the server's pings |
| `offline` | No open subscription, and a contact sample exists |
| `not_yet_seen` | The address never contacted Nexus |

Marks are written at the subscription's edges: a newer connection replaces an older one's mark, an older connection's close never erases a newer one's, and every epoch advance and terminal revocation clears them. Which marks are live is the database's answer: every mark names the Nexus process that wrote it, each socket-serving process keeps a `nexus_servers` row alive with a 10-second internal heartbeat, and a mark is `online` only while its process's heartbeat is within 30 seconds. A graceful stop deletes the row and its marks read `offline` at once; a killed process's marks expire within 30 seconds; no boot clears a sibling's marks. A poll-only executor reads `offline` while working. Discovery filters by eligibility, never by presence, and `rho status` prints local truth for its own planes.

## Where a tool call goes

An authored runner step carries `route: { "kind": "runner", "runner_executor_public_id": "<uuid>" }`. Omitting the uuid resolves the conversation's default runner at acceptance; an absent default refuses `runner_target_required`. The resulting task exposes `target: { executor_public_id, display_name? }` even while it is waiting, held for approval, retried or no longer served by that runner. A missing or ineligible target fails explicitly; another runner never takes it. `addressed_to` describes current delivery and `claimed_by` the claimant; neither changes the accepted target.

A model-visible declaration separates its callable name and schema from delivery:

```json
{
  "type": "function",
  "function": { "name": "remote_read", "parameters": { "type": "object" } },
  "route": { "kind": "runner", "runner_executor_public_id": "<runner UUID>", "tool_name": "read" }
}
```

Every routed declaration names a concrete runner and served tool, so two runners may expose incompatible `read` schemas under different callable names. The model's provider receives the callable schema; Nexus keeps the routing metadata and lowers the call to the served tool at the named runner. Continuation children inherit these declarations and cannot replace their targets.

Without a runner route, kernel tools (`delegate_task`, `ask`, `memory_*`) run in the kernel, except explicitly overridden namespaces addressed to their workspace provider. Other names use the declaring agent's announced address, then an eligible tool-provider pool. Provider pool claims remain exclusive. Runner announcements never create a fallback by bare name.

`skill` uses the accepted skill source, including its executor and source name: the frozen catalog records which runner or agent owns each document, and kernel memory skills keep their workspace, Agent and explicitly selected Human sources. A later default change cannot change that source.

Tools and skill documents are looked up by `(executor UUID, role, name)`; an application's same-named tool cannot satisfy a Runner claim. A park's deadline uses the authored `timeout_ms`, then the announcement's value, then the kernel default. Tool arguments remain the executor's payload.

A run can accept tasks for several runners. A nullable default applies only when an authored step omits its target, and changing it never moves accepted work. Eligibility is checked at acceptance and again before delivery. Presence and readiness never select another target. Model-visible environment, tool declarations and skill sources stay frozen for the accepted execution.

## Discover addressable executors

### Endpoints

```http
GET /agent_api/v1/executors
GET /agent_api/v1/executors?role=runner
GET /agent_api/v1/executors/{public_id}
```

Member plane: the one surface here a member bearer takes, because it answers a principal's question — which executors may the acting principal address: a runner to select (`default_runner_executor_public_id` at conversation creation, `…/default_runner` to change future defaults), or a provider whose pool serves it. It sits at account level beside `tools` and `models`.

### Request

The listing contains addresses eligible for the acting principal: active, credential-ready,
not shutdown-pending, and admitted by application ownership or machine scope. Application
addresses are visible to their owning Agent and eligible named Agents. A credential-less or
revoked row is never offered.

`kind` filters registration identity: `agent`, `runner` or `tool_provider`.
`role` filters announced capability using those same three values. Filters intersect; omission
applies no filter. Use `role=runner` to discover all eligible environments, including application
addresses with Runner capability. Unknown filter values return `400 parameter_invalid`.

### Response

```json
{ "executors": [ { "public_id": "…", "kind": "runner", "display_name": "…", "status": "active", "assignment_scope": "user_private", "agent_public_id": null, "service_roles": ["runner"], "services": { "runner": { "tools": [], "documents": [], "environment": {} } }, "presence": "online", "last_seen_at": "…", "connected_at": "…" } ] }
```

The single read answers `{ "executor": { … } }` and conceals an ineligible or unknown id as `404`.

| Field | Description |
| --- | --- |
| `agent_public_id` | Owning Agent UUID for an application address; otherwise `null` |
| `service_roles` | Roles currently present in `services` |
| `services.<role>.tools` | Announced `{ name, effect_profile, timeout_ms?, description?, input_schema?, mcp? }` entries |
| `services.<role>.environment` | Opaque environment snapshot for that role |
| `services.<role>.documents` | Announced `{ name, description }` skill documents for that role |
| `presence`, `last_seen_at`, `connected_at` | Observations for display; never used to choose an executor |

## Announce what this executor serves

### Endpoint

```http
PUT /agent_api/v1/executor/announcement
```

Executor plane, with the same transport credential `GET /executor` takes. A whole replacement of the address's `services` map. Every update includes all roles the process still serves; this is not a per-role patch. The answer is the same description `GET /executor` renders; neither the served list, the environment nor the documents is readable back here — discovery reads them.

### Request

```json
{
  "services": {
    "agent": {
      "tools": []
    },
    "runner": {
      "tools": [
        {
          "name": "bash",
          "effect_profile": {
            "kind": "write",
            "destructive": true,
            "effect_scope": "open",
            "idempotency": "none",
            "reconciliation": "none"
          },
          "timeout_ms": 120000,
          "description": "…",
          "input_schema": {
            "type": "object"
          }
        }
      ],
      "environment": {
        "root": "/home/runner",
        "platform": "…",
        "fragments": [
          {
            "extension": "…",
            "text": "…"
          }
        ]
      },
      "documents": [
        {
          "name": "workspace-tools",
          "description": "…"
        }
      ]
    }
  }
}
```

| Field | Rules |
| --- | --- |
| `services` | Required object, replaced whole. An application requires `agent` and may include `runner`. A machine requires only its own registration role. Other roles are refused. |
| `services.<role>.tools` | Required; `[]` clears the list. One entry per served name. |
| `services.<role>.tools[].name` | The served tool name. Reserved kernel namespaces are refused; see below. |
| `services.<role>.tools[].effect_profile` | Required on every entry; exactly the kernel's effect vocabulary — `kind` (`pure`, `read_only`, `write`), `destructive`, `effect_scope` (`closed`, `open`), `idempotency` (`intrinsic`, `keyed`, `none`), `reconciliation` (`none`, `lookup`) — the closed values `GET /agent_api/v1/tools` publishes. |
| `services.<role>.tools[].mcp` | Optional `{server_key, tool_name}` with exact nonempty strings identifying an executor-hosted MCP source. The executor UUID supplies its connection namespace. This metadata adds no authority or route. MCP tools require explicit declarations and are excluded from automatic default-Runner imports. |
| `services.<role>.tools[].timeout_ms` | Optional positive integer; the deadline when the authored call names none. |
| `tools[].description`, `tools[].input_schema` | What the executor says about the tool, in the MCP `Tool` shape: a non-empty string and a JSON Schema object with `type: object`. Stored verbatim for an agent that authors a declaration from this runner. The kernel never derives a declaration from them and never validates a call against the schema: the declaration is the model's fact with its own writer, and the runner validates its own calls. A key present with the wrong shape is refused. A tool announced without them is served but described to nobody — the shape for a capability a person requests (a file's bytes, a process's log) that no model should be handed. |
| `services.<role>.environment` | An opaque document the kernel never interprets — rho sends `{ root, branch, worktree, platform, fragments: [{ extension, text }] }` — replaced whole by this verb (absent means `{}`), bounded at 64 KiB (`executor_environment_bound`), read back by discovery. It is a snapshot: re-announce it when it changes. |
| `services.<role>.documents` | The described documents this executor can load for a model — a project's skills, an MCP server's prompts and resources curated into this shape — as `{ name, description }`, replaced whole (absent means `[]`). `name` follows the skill name grammar (`[a-z0-9]` with single hyphens, at most 64); `description` is a non-empty string of at most 1024 bytes; the list is bounded by `envelope_bound`. |

Every externally claimed tool may use the [task operation protocol](executor-operations.md) to accept child work within its frozen context, observe it and publish its own final result. Waiting keeps the ordinary claim and cancellation owner and may renew its deadline through `extend`; the kernel does not replay a handler.

### Documents and the skill tool

Each declared runner skill callable contributes only its named runner's documents; a non-runner skill callable uses the agent's documents, then workspace and user `skills/` rows by precedence. The resulting source-qualified catalog is frozen in the execution. Eager skill callables render in the assembly's `skills` block; deferred ones expose their catalog through `tool_search`. Loading an announced document reaches its recorded executor's inbox as a `skill` row (`tool_name: "skill"`, `tool_input: { name }`, `scope`), so an executor announcing documents must also announce `skill` — a kernel name routed by its source; without it every load of its names fails `tool_not_served`. The executor answers the row with the body as the result's `content`; a name it no longer holds is an ordinary error result (`skill_unknown: <name>`). A withdrawn announcement withdraws its names at the next turn's block.

### Reserved and overridable names

The reserved namespaces `nexus.graph`, `nexus.human`, `nexus.conversation` and `nexus.tools` belong to the kernel in both spellings (`delegate_task`, `nexus.graph.delegate_task`, `ask`, `spawn`, `tool_search`, `tool_call`, …) and are refused with `422 reserved_namespace` on every kind.

An overridable kernel name — a live name outside the reserved namespaces, today exactly the memory family in its wire spelling (`memory_read`, `memory_write`, `memory_edit`, `memory_ls`, `memory_grep`, `memory_delete`) — is admitted and stored as announced. Its dotted canonical spelling (`nexus.memory.read`) is refused by the name format: a row's `tool_name` carries the wire spelling, so only that spelling can be served. Admission is a delivery fact only; addressing decides a kernel name in-process first, so the entry is never addressed until a workspace opts in to the provider, and until then it is inert on any executor kind.

### Effect on accepted work

Announcements describe capabilities and effect profiles. Accepted runner targets are validated against their named executor; unrouted non-kernel calls use the declaring agent or an eligible provider pool. At acceptance, Nexus may import the selected runner's exact model schemas through the Agent's declared tool sources. The accepted tool set is immutable: later announcements never merge into it or reshape its schemas.

### Replacement and work in flight

A re-pair does not move work the previous epoch already claimed:

- An inbox task addressed to this executor and not yet claimed: the new epoch claims it like any other task; the fenced old epoch cannot.
- A task the old epoch claimed: neither epoch continues it through the inbox. The row is never re-granted; it converges under its own deadline, and the sweep settles it by the tool's effect profile — `timed_out` (`tool_timeout`) for a replayable profile (a `read_only` or `pure` kind, or `intrinsic` idempotency), `uncertain` (`tool_uncertain`) for any other; an unclaimed row expires `timed_out` whatever its profile. Nothing re-queues itself: the model re-issues a replayable call from its envelope, or a person's `retry` re-addresses it.
- Accepted child-operation receipts and observations stay durable after owner loss but do not reconstruct the lost handler or grant a replacement claim.
- A committed result stays valid and its materialization continues without the old device.

After terminal transport-authority loss, the old host must stop taking new work and crossing new effect boundaries, stop live handlers at safe checkpoints, preserve local evidence, and must not automatically begin another device flow.

### Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The announcement replaced; the executor description |
| `400 Bad Request` | `parameter_missing` | No `services` |
| `401 Unauthorized` | `unauthorized` | A member bearer, or an unusable transport credential |
| `422 Unprocessable Content` | `reserved_namespace` | An entry names a kernel tool under a reserved namespace in either spelling; the message names the namespace; nothing is written |
| `422 Unprocessable Content` | `invalid_announcement` | An entry is profile-less, malformed, duplicate or out of vocabulary, its `description` or `input_schema` is wrong, `environment` is not an object, or a document entry is outside its shape; the message names `tools[i].<field>` or `documents[i].<field>`; nothing is written |
| `422 Unprocessable Content` | `validation_failed` | The complete services map is over the envelope bound, or the environment is over its bound |

## Publish a capture

### Endpoint

```http
POST /agent_api/v1/executor/uploads
Content-Type: multipart/form-data
```

The executor plane's door into the one upload ingest shared with the member door ([Uploads](uploads.md)).

### Request

`multipart/form-data` with one part, `upload[file]`. The bytes decide the type; `upload_bound` applies at the door.

### Response

`201` with the staged descriptor. The creator is this executor — an upload's creator is exactly one of a member (`creating_user`) or an executor (`creating_executor`) — and nothing on this plane reads it back. A capture is named by the result that carries it, as a `resource_link` block in the committed `content` ([Commit a result](executor-inbox.md#commit-a-result)); an upload nothing names is reclaimed after a day. Its bytes are served on the member plane by `GET /agent_api/v1/uploads/{public_id}/bytes` under the one upload rule: the creator, or a reader of a row that names it.

### Status codes

| Status | Code | Description |
| --- | --- | --- |
| `201 Created` | — | The descriptor of the staged capture |
| `400 Bad Request` | `parameter_missing` `parameter_invalid` | No `upload[file]` part, or one that is not a file |
| `413 Content Too Large` | `content_too_large` | Over `upload_bound`; nothing is staged |
| `401 Unauthorized` | `unauthorized` | A member bearer, or an unusable transport credential |

## Executor context

Executable tool rows returned by inbox, claim, extend and exact task reads include
an optional `executor_context`, an opaque JSON object independent of `tool_input`.
An explicitly authored singular `executor_context` takes precedence. Otherwise,
Nexus selects one value from the captured `executor_contexts` map using the first
applicable execution address:

| Task state | Map key |
| --- | --- |
| Claimed | Recorded claimant Executor UUID |
| Unclaimed with an accepted Runner target | Target Runner UUID |
| Dispatched directly to an application or override provider | Recorded addressee Executor UUID |
| Unclaimed provider pool row in an executor inbox | Authenticated viewing Executor UUID |

An unclaimed pool task's member-side detail omits context because no executor has
claimed it. Approval notifications do not establish an execution address; only an
already accepted Runner target can select a map value before approval. A denied
or expired approval does not turn its notification recipient into an executor.

If the execution address is not yet determined, or its key is absent from the
captured map, the field is omitted. Nexus never falls back to another address's
value, including the application's. An explicitly captured empty object remains
`{}`. Reads use the task's recorded address and claimant; they do not reroute the
task or resolve the application's current address.

Implementations apply their own payload contract before tool handlers and hooks.
The kernel preserves captured context across approval, retry and executor restart;
it does not interpret paths.
See [captured executor context](run-steps.md#captured-executor-context) for authoring.
