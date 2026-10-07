# Agent API Executor

Status: live Agent API resource.

Every claimed tool can use the [task operation protocol](executor-operations.md)
to accept child work and record observations under its existing claim. The
executor keeps its handler alive while waiting and renews the ordinary deadline.

The executor resource is the transport plane's bootstrap read: a process asks
**which delivery address it is**. The credential names the address; nothing is
submitted by the caller. The response does not name an execution principal:
the address only receives work, and each inbox row freezes the Agent
whose authority that work uses.

It exists so that the executor plane is complete on its own. A runner holds no
member credential and never will — it is a machine, not a principal — so an
executor bootstrap that had to call a member endpoint would be unimplementable
for half the programs this API serves.

## Get this credential's executor

### Endpoint

```http
GET /agent_api/v1/executor
```

### Authentication

This endpoint accepts an **executor-transport-plane** credential and nothing
else. A member credential is refused with `401`, exactly as a transport
credential is refused on [Profile](profile.md).

A transport credential is fenced by its own facts, never by reusing a
member-credential check: it stops working when its token, lineage, or address
is revoked, when it expires, or when an epoch advance supersedes it.

Removing an Agent synchronously fences its member credentials and
advances its Agent-application address's credential epoch. The address remains
`active`, with the same public id, but its old transport credentials return
`401`, including for a previously claimed result. Related running work is
force-stopped asynchronously; the removal response does not wait for terminal
task or run state. An independent Runner's address and credentials are not
revoked by Agent removal, although tasks in a related run can be canceled
by that run's force-stop. The affected work and recovery rules are described
in [Conversations](conversations.md#agent-removal).

An inactive Agent receives no new tool calls, asks or approval notices
on its Agent-application address, even when a live Human authored the turn.
Ordinary addressing applies: a tool with no eligible provider fails
`tool_not_served`; asks and approvals have their member-plane Human door until
their run stops. Restore reopens Agent eligibility without waiting for the
asynchronous cleanup; it neither revives old credentials nor resumes stopped
work. A DeviceFlow reconnect issues fresh credentials on the retained address.

Removing the controlling Human additionally uses the existing managed-resource
shutdown protocol: admission closes immediately, bounded convergence stops
managed work, and each resource acknowledges its shutdown generation. When
Agent convergence makes an Agent removed, the Agent credential cut
and asynchronous force-stop above apply. Other managed executors retain
transport until their truthful task/evidence convergence. This episode is durable:
the Human's `managed_resource_shutdown_generation` must equal the executor's
`applied_human_shutdown_generation` before new admission resumes. This
executor-side acknowledgment is independent of closing and acknowledging a
stewarded Agent through its `applied_steward_shutdown_generation`;
that Agent may exist without an executor. Managed-executor convergence is
two passes: first, per run under the run's own lock, every UNCLAIMED
inbox row addressed to the executor is FAILED — `status: failed`,
`error.key: executor_revoked`, the same shape as `tool_not_served` at start —
one narrated transition each, the task's own `on_failure` applied through the
one failure rule (an `absorb` member's fan continues, a `propagate` row
skips its successors, a `halt` row holds the run for a person's `retry` or
`abandon`). A task held for approval instead loses its executor address and
keeps the workspace writer's approval door. The recurring park sweep performs
these transitions in bounded batches, including in paused runs; ordinary
deadlines remain paused. Explicit address revocation fences transport
synchronously and wakes this same sweep after commit; the recurring sweep also
recovers a lost cleanup wake. For Human shutdown, the executor then acknowledges and
advances its epoch only once no outstanding row is addressed to or claimed by it.
While work remains, the pass answers `work_pending` and the next wake retries, and the
claimed rows settle by their own deadline and effect profile while their
transport credential remains current. This does not preserve an Agent
application's credentials after its Agent is removed. A pool row names no
executor and is not canceled by the addressed-row cleanup: it stays in the
pool for another member unless its own run is stopped.

There are no query or body parameters.

### Response

```json
{
  "executor": {
    "public_id": "01900000-0000-7000-8000-000000000002",
    "kind": "agent_application",
    "status": "active",
    "display_name": "MacBook Pro",
    "credential_epoch": 1
  },
  "measured_at": "2026-07-25T00:00:00Z"
}
```

| Field | Type | Description |
| --- | --- | --- |
| `executor.public_id` | UUIDv7 string | Public identifier of this delivery address. Stable for the life of the address. |
| `executor.kind` | string | `agent_application` — an Agent's current address, when connected — or `runner`, a logical Runner registration — or `tool_provider`, a logical registration shaped like a runner's (a manager Human, an identifier, a scope) that serves tools by name and claims from pools. |
| `executor.status` | string | `active` or `revoked`. |
| `executor.display_name` | string | The name this client gave itself when it connected. |
| `executor.credential_epoch` | integer | The current authority epoch of this address. A winning replacement Consume advances it and fences every credential carrying the previous epoch. |
| `measured_at` | string | When the block was measured. |

### What the address means for each kind

Every kind behaves the same way because each logical registration key has at
most one non-revoked current address and pairing. A request accepted here
necessarily carries a transport credential naming one such address. This does
not prove that one physical process holds the current credential: copied
credentials are indistinguishable and unsupported, and IP address or
User-Agent is never an identity key.

An `agent_application` address is the sole non-revoked address of its Agent while it exists. Connecting that profile again **re-pairs this exact
address** — same `public_id` — and advances `credential_epoch`, which stops the
credential the previous device held. After terminal address revocation, a
later successful connection creates a new address/public id rather than
reviving revoked history.

A `runner` address is one durable logical Runner registration. Distinct Runner
products and managers are unlimited, but each
`(account_id, manager_id, registration_identifier)` key has at most one non-revoked
current address; assignment scope is not part of that identity. The Runner
program supplies a stable, non-secret installation identifier, normally its
product constant plus an instance component persisted at first boot. Separate
installations use distinct identifiers; reconnecting the same installation
presents the same `registration_identifier`. Nexus treats the whole string as opaque,
and the person does not type or choose it. When that
key has a non-revoked address, Consume re-pairs this address and fences the old
device. When it has none, Consume creates a new address/public id. A Runner may
serve multiple Agents eligible under its logical-registration-frozen ACL:
`user_private` grants its manager default access, while `account_wide` permits
eligible Agents across the Account. Each task freezes the execution
principal and delivery executor, so this never creates an exclusive Agent
binding. Initial Browser Connect freezes scope for the new logical
registration; re-pair or physical-device replacement inherits it without a
selector, while a post-terminal-revoke new registration may choose again.
An in-process runner registered by the device flow's combined shape (an
agent that also serves as a runner on its own machine) is fixed
`user_private` at issuance and offers no selector at all. V1
has no scope-change command. Any future explicit change affects
only authorized discovery and tasks authored afterward; it does not move or
re-authorize an existing task.
Suspending an `account_wide` Runner's manager is not an ACL mutation or selector
input; Human removal uses the separate shutdown-generation fence above.

A `tool_provider` address is a Runner-shaped registration: connected on the device flow's machine branch with
`executor_kind: tool_provider`, it has a manager Human, an assignment scope
chosen at browser Connect, a transport-only credential, and the Runner's
re-pair rule — it shares the Runner key `(account_id, manager_id,
registration_identifier)`, which is kind-blind: one live address per key across
BOTH machine kinds, so a provider needs its own identifier, the kind is
frozen on the registration like its scope, and a re-pair naming the other
kind for a live key is invalidated at Consume. Its ACL is the Runner's
(`user_private` serves the runs of its manager and of the Agents that
Human stewards; `account_wide` serves the Account). What differs is how it is
addressed: a provider is never a host's default Runner — it takes work from a
POOL by the names it announces ("Where a tool call goes", below). The
reserved namespaces (`nexus.graph`, `nexus.human`, `nexus.conversation`, `nexus.tools`;
`Nexus::ToolRegistry::RESERVED_NAMESPACES`) are refused at the announcement
door for every kind; an OVERRIDABLE kernel name — today the memory family's
wire spelling — is admitted and stored, and addressed to the provider once a
workspace opts in through `PUT …/workspaces/{id}/tool_provider_overrides`
("Announce what this executor serves", below).

Nexus exposes authorized Runner discovery. The agent application selects targets
and declares each Runner tool as a callable with its own schema and route.
A Run can accept tasks for several Runners. A nullable host default applies
only when an authored Runner step omits its target; changing it never moves
accepted work. Eligibility is checked at acceptance and again before delivery.
Presence and readiness never select another target. Model-visible environment,
tool declarations, and skill sources remain frozen for the accepted execution.


Presence is display, never a gate. The executor description,
the task read's `addressed_to` and the member console render `presence`
beside `last_seen_at` and `connected_at`: `online` while the executor's
inbox subscription is open on a socket that answers the server's pings,
`offline` once it is not and a contact sample exists, `not_yet_seen` when
the address never contacted Nexus (the wire word is snake-case; the console
and rho print "not yet seen"). The marks are written at the subscription's
edges — a newer connection replaces an older one's mark, an older
connection's close never erases a newer one's — and cleared by every epoch
advance and the terminal revoke; which marks are LIVE is the database's
answer — every mark names the Nexus process that wrote it, each
socket-serving process keeps a `nexus_servers` row alive with a 10 s
Nexus-internal heartbeat (never a client heartbeat), and a mark is `online`
only while its process's heartbeat is within 30 s: a graceful stop deletes
the row and its marks read offline at once, a killed process's within 30 s,
and no boot ever clears a sibling's marks.
A poll-only executor reads `offline` while working, honestly. Discovery
filters by eligibility, never by presence; `rho status` prints local truth
for its own planes — kernel presence describes someone else's executor.

There is no second current address for the same logical registration to compare
yourself against: this resource describes the address to which its work is
directed.

### Where a tool call goes

An authored Runner step carries `route: {kind: "runner",
runner_executor_public_id?: UUID}`. Omission of the UUID resolves the host's
`default_runner` at acceptance; an absent default refuses `runner_target_required`.
The resulting task exposes `target: {executor_public_id, display_name?}` even while it is waiting,
held for approval, retried, or no longer served by that Runner.
A missing or ineligible target fails explicitly; another Runner never takes it.
`addressed_to` describes current delivery and `claimed_by` describes the claimant;
neither changes the accepted target.

A model-visible declaration separates its callable name/schema from delivery:

```json
{
  "type": "function",
  "function": {"name": "remote_read", "parameters": {"type": "object"}},
  "route": {"kind": "runner", "runner_executor_public_id": "<runner UUID>", "tool_name": "read"}
}
```

Every routed declaration names a concrete Runner and served tool. Two Runners
may expose incompatible `read` schemas under different callable names. The
model's provider receives the callable schema; Nexus retains routing metadata
and lowers calls to the served tool at the named Runner. Continuation children
inherit these declarations and cannot replace their targets.

Without a Runner route, kernel tools (`delegate_task`, `ask`, `memory_*`) run
in the kernel, except explicitly overridden namespaces addressed to their
Workspace provider. Other names use the declaring agent application's announced
address, then an eligible tool-provider pool. Provider pool claims remain
exclusive. Runner announcements never create a fallback by bare name.

`skill` uses the accepted skill source, including its executor and source name.
The frozen catalog identifies each declared callable and source, preserving which Runner or agent
application owns each document. Kernel memory skills retain their workspace
and user sources. A later default change cannot change that source.

The park's deadline uses the authored `timeout_ms`, then the announcement's
value, then the kernel default. Tool arguments remain the executor's payload.

## Discover the executors you may address

### Endpoints

```http
GET /agent_api/v1/executors
GET /agent_api/v1/executors?kind=runner
GET /agent_api/v1/executors/{public_id}
```

MEMBER plane — the one surface here a member bearer takes, because it
answers a PRINCIPAL's question: which executors may the acting principal
address — a Runner to select (`default_runner_executor_public_id` at create,
`…/default_runner` to change future defaults), a provider whose pool serves it. Account-level,
beside `tools` and `models`. The listing is the account's machine rows
filtered by eligibility for the acting principal (active, credential
ready, not shutdown-pending, `account_wide` or managed by the principal's
controlling Human): a credential-less row is never offered, a revoked one
never, a `user_private` machine only to its manager and the agents that
Human stewards. `kind=runner` or `kind=tool_provider` narrows; absent
lists both; anything else — `agent_application` included, an agent address
binds nothing and is nobody's to address — is 400 `parameter_invalid`. The
single read conceals an ineligible or unknown id as 404.

`{executors: [{public_id, kind, display_name, status, assignment_scope,
served_tools, environment, served_documents, presence, last_seen_at,
connected_at}]}` and `{executor: {…}}` for one. `served_tools` is the
announced list whole — `{name, effect_profile, timeout_ms?, description?,
input_schema?}` per entry — the declaration facts an agent reads to author
its declaration from a runner it did not load; `environment` is the announced
snapshot, opaque; `served_documents` is the announced documents list whole —
`{name, description}` per entry, the skills this executor can load for a
model ("Announce what this executor serves", below). Presence and `last_seen_at` are SHOWN and never used to choose:
discovery filters by eligibility, never by presence.

## Announce what this executor serves

### Endpoint

```http
PUT /agent_api/v1/executor/announcement
```

Executor plane; the same transport credential `GET /executor` takes. A whole
replacement of the list of tools this address serves, of the environment
its tools are bound to and of the documents it can load for a model,
`{tools: [{name, effect_profile, timeout_ms?, description?, input_schema?}],
environment?: {…}, documents?: [{name, description}]}`, answered with the
same description `GET /executor` renders — neither the served list, the
environment nor the documents is the executor's to read back. `tools: []`
clears the list.
`effect_profile` is required on every entry and carries exactly the kernel's
effect vocabulary (`kind`, `destructive`, `effect_scope`, `idempotency`,
`reconciliation`, the closed values `GET /tools` publishes); `timeout_ms`, when
given, is a positive integer the kernel uses as the deadline when the call
authored none.

Every externally claimed tool may use the [task operation protocol](executor-operations.md)
to accept child work within its frozen context, observe that work and publish its own
final result. Waiting retains the ordinary claim and cancellation owner; it may renew
its deadline through `extend`. The kernel does not automatically replay its handler.

`description` (a non-empty string) and `input_schema` (a JSON Schema object,
`type: object`) are what this executor says about the tools it serves — the
MCP `Tool` shape — stored verbatim for an agent that authors a declaration from
a runner it did not load. The kernel never derives a declaration from them and
never validates a call against the schema: the declaration (`profile.md`) is
the model's fact with its own writer, and the runner validates its own calls.
A key present with the wrong shape is refused, never dropped. A tool announced
WITHOUT them is served but describes itself to nobody — the shape a runner
uses for a capability a person requests (a file's bytes, a process's log) that
no model should be handed ("Requests", below).

`environment` is an opaque document — `{root, branch, worktree, platform,
fragments: [{extension, text}]}` is what rho sends — never interpreted by the
kernel, replaced whole with the list by this same verb (absent = `{}`), bounded
at 64 KiB (`executor_environment_bound`), and read back by discovery
(`GET /agent_api/v1/executors`, below), never here. It is a snapshot:
re-announce it when it changes.

`documents` is the third list this same verb replaces whole (absent = `[]`):
the DESCRIBED DOCUMENTS this executor can load for a model — a project's
skills; an MCP server's prompts and resources, curated by the executor into
this shape — as `{name, description}`, `name` under the skill name grammar
(`[a-z0-9]`, single hyphens, ≤ 64), `description` a non-empty string ≤ 1024
bytes; bounded by `envelope_bound`. Each declared Runner skill callable contributes
only its named Runner's documents. A non-Runner skill callable uses the Agent
application's documents, then workspace and user `skills/` rows by precedence.
The resulting source-qualified catalog is frozen in the execution. Eager skill
callables render in the assembly's `skills` block; deferred ones expose their
catalog through `tool_search`. Loading an announced document reaches its
recorded executor's inbox as a `skill` row (`tool_name: "skill"`,
`tool_input: {name}`, `scope`), so an executor announcing documents must also
announce `skill` (a kernel name routed by its source) — one without it fails
every load of its names `tool_not_served`. The executor answers the row with
the body as the result's `content`; a name it no longer holds is an ordinary
error result (`skill_unknown: <name>`). A withdrawn announcement withdraws its
names at the next turn's block. 422 `invalid_announcement` names
`documents[i].<field>`.

Announcements describe executor capabilities and effect profiles. Accepted Runner
targets are validated against their named executor. Unrouted non-kernel calls
use the declaring agent or eligible provider pool. At acceptance, Nexus may import
the selected Runner's exact model schemas through the Agent's declared tool
sources. Explicit declarations remain valid. The accepted tool set is immutable;
later announcements never merge into it or reshape its schemas.

Refusals: 422 `reserved_namespace` for a kernel name under a reserved
namespace in either spelling (`delegate_task`, `nexus.graph.delegate_task`, `ask`,
`spawn`, `tool_search`, `tool_call` — the namespaces `nexus.graph`, `nexus.human`,
`nexus.conversation`, `nexus.tools`, whose graph and frozen-context operations
belong to the kernel); 422
`invalid_announcement` naming the entry index and field for a
profile-less, malformed, duplicate or out-of-vocabulary entry, a bad
`description` or `input_schema`, a non-object `environment`, or a document
entry outside its shape (named `documents[i].<field>`); 422
`validation_failed` for a list over the envelope bound, an environment over
its bound or a documents list over the envelope bound; 400 `parameter_missing` without `tools`; 401 for a member bearer.

An OVERRIDABLE kernel name — a live one outside the reserved namespaces, today
exactly the memory family in its wire spelling (`memory_read`, `memory_write`,
`memory_edit`, `memory_ls`, `memory_grep`, `memory_delete`) — is admitted and
stored as announced. Its dotted canonical spelling (`nexus.memory.read`) is
refused by the name format like any other dotted name: a node's `tool_name`
carries the wire spelling, so only that spelling can be served. Admission is a
delivery fact only: addressing decides a kernel name in-process first, so the
entry is never addressed until a workspace opts in to the provider —
until then it is honest and inert, on any executor kind.

### What replacement means for work in flight

A re-pair does not move work the previous epoch already claimed:

- an inbox task addressed to this executor and not yet claimed: the new epoch
  claims it like any other task; the fenced old epoch cannot;
- an ordinary task the old epoch claimed: neither epoch continues it through the inbox.
  Its claimed row is never re-granted; it converges under its own deadline, and
  the sweep settles it by the tool's effect profile: `timed_out`
  (`tool_timeout`) for a replayable profile — a `read_only`/`pure` kind or
  `intrinsic` idempotency — and `uncertain` (`tool_uncertain`) for any other;
  an unclaimed row expires `timed_out` whatever its profile. Nothing re-queues
  itself: the model re-issues a replayable call from its envelope, or a
  person's `retry` re-addresses it;
- accepted child-operation receipts and observations stay durable after owner loss,
  but do not reconstruct the lost handler or grant a replacement claim;
- a committed result stays valid and its materialization continues without the
  old device.

After terminal transport-authority loss, the old host must stop taking new
work and crossing new effect boundaries, stop live handlers at safe
checkpoints, preserve local evidence, and must not automatically begin another
device flow.

## Captures — what this executor publishes

```
POST /agent_api/v1/executor/uploads
Authorization: Bearer sk-cybros-api-v1-...
Content-Type: multipart/form-data
```

The executor plane's door into the ONE
ingest (the member and session doors' twin, `uploads.md`): `multipart/form-data`,
one part `upload[file]`, the bytes decide the type, `upload_bound` at the door,
`201` with the staged descriptor, `413 content_too_large`. The creator is THIS
EXECUTOR — an upload row's creator is exactly one of a member (`creating_user`)
or an executor (`creating_executor`) — and nothing on this plane reads it back.
A capture is NAMED by the result that carries it: a `resource_link` block in
`content` (Commit, below); an upload nothing names is reclaimed after a day. Its
bytes are served on the member plane by `GET /agent_api/v1/uploads/{public_id}/bytes`
(`uploads.md`, one rule: the creator, or a reader of a row that names it).

## The inbox — where this address takes work

The runner protocol lives on the executor plane and nowhere else:
the credential names the executor, and the executor's own inbox is the scope
— a workspace never is, and a member bearer holds none of these doors. Four
verbs: read the inbox, claim a row, commit its answer, and listen for the push
that says a row appeared. The shapes are captured in
`contracts/nexus/v1/executor_inbox.json`.

### Read this executor's inbox

```http
GET /agent_api/v1/executor/inbox?after={cursor}&limit={n}
```

THIS ADDRESS's view of the work the kernel addressed to it, across every live
run of its account, level-triggered and COMPLETE:

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
      "addressed_to": { "role": "agent_application", "executor_public_id": "01900000-0000-7000-8000-000000000003" }
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
          {"name": "workspace", "scope": "workspace", "access": "read_write", "workspace_public_id": "01900000-0000-7000-8000-000000000001"},
          {"name": "user", "scope": "user", "access": "read_write", "user_public_id": "01900000-0000-7000-8000-000000000003"}
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

`kind` is `tool_call` for a parked tool row and `ask` for a model's question
addressed to the agent application: an ask row carries `prompt`
— the question a person answers — with `options` (the choices as data, one
string each) and `multi` (several may be taken) when the ask gave them, and no `tool_*` field, is NEVER claimed
(`claimed: false` for as long as it stands; the claim door answers
`not_claimable_kind`), parks up to 24 hours (`deadline_at`), and commits
below WITHOUT a `claim_token` — the address is the door. It is listed only
when the run has a declaring agent: a person's own standalone run
addresses its ask to nobody, and no inbox lists it. `approval` is a tool
call resting for an approver ([Runs](runs.md) "Approval"): it
lists under a profile's `ask` or `rules` mode for the addressed agent
application with its `tool_name`, `tool_input` and — the one row kind that
carries it — the frozen `effect_profile` the approver reads, `deadline_at`
24 hours out, `claimed: false` for as long as it stands; it is never
claimed (409 `not_claimable_kind`), and its end is `approve`/`deny` on the
member plane or the clock. A Human's own standalone run addresses it to
nobody, and no inbox lists it. Under `bypass` no row ever rests, so none is
ever listed. Carry a word you do not know. A row whose call the model made
under an ALIAS of a kernel tool ([Profile](profile.md)) carries `tool_alias`
— the spelling the model used — beside `tool_name`, the kernel's wire name;
absent on every other row.
`workspace_public_id` is a required non-null UUIDv7 on EVERY inbox and claim task:
the workspace owning its run, including standalone execution, child conversations,
asks and approvals. Consumers use this kernel-owned scope when executing the task;
a subsequently selected default workspace does not change existing work. It is
ordinary task metadata and does not broaden the separate `scope` stamp below.
`conversation_public_id` rides EVERY row: the run's conversation, or an
explicit `null` for a standalone run — the kernel saying whose row this
is, because what a call starts on a runner follows the conversation (the
runner tracks a process it started
by the conversation, never by a lookup of its own, and ends it when the
conversation's feed says `conversation_ended`,
[Conversations](conversations.md) "Events").
`parent_public_id` also rides every row: the parent Conversation's public ID
for a child conversation, or `null` for a root conversation or standalone run.
The child retains this structural reference even after the parent is reaped.
`addressed_to` names the executor the kernel addressed the call to at its
start — or the role alone, `{role: tool_provider}`, for a pool row — written
at dispatch. `target` separately exposes the Runner selected at acceptance.
Changing a default never changes that target or existing delivery.
`scope` accompanies kernel-named tools dispatched to an external provider.
For an overridden memory tool it is `{bindings: [...]}`: each resolved entry
contains `name`, `scope`, `access`, and the corresponding
`conversation_public_id`, `workspace_public_id`, or `user_public_id`. The path's
first segment selects `name`; the provider keys its memory by that entry's
scope and public UUID, never by a guessed default. The set comes from the
execution's frozen configuration with currently unavailable sources omitted.
An empty set grants no roots; read-only bindings cannot author documents.
The kernel refuses explicit missing-root and read-only mutation calls before
provider dispatch. Unqualified list and grep search only supplied bindings.
`tool_input` passes through unchanged.
For a source-routed `skill` tool, `scope` retains
`{workspace_public_id, conversation_public_id | null, user_public_id}`. A
standalone run has no conversation root. Other tool rows have no scope stamp.
`timeout_ms` is the park's budget on EVERY row, the number `deadline_at` is
cut from: a tool row's step-authored `timeout_ms`, else the announced
entry's, else the kernel's default; an ask's or a wait's own, clamped to 24
hours; an approval row's 24-hour hold. It is stated so an executor can name
the budget it was held to without reading a clock — the timed-out sentence
under "Expiry" names it — and it never moves: a claim re-arms `deadline_at`,
an extension moves `deadline_at`, and `timeout_ms` stays the budget the park
was authored with.
`claimed` says whether ANY executor ever claimed the row in this generation
— a claimed generation is never re-granted, so a runner returning from a crash can
see the work it holds and leave it to its own deadline. Answered work simply
leaves: the inbox is state, not a queue, and a runner that slept, crashed,
restarted or missed a work-available push discovers work by reading it.
An executing claimant uses the claim read below to recover a missed
cancellation; absence from this list alone does not cancel a claim. The cursor
is opaque; the page is bounded (default 50, max 200); a cursor that does not
parse is 400 `parameter_invalid`.

### Claim

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
```

Exactly one executor may execute a parked call, and this is where that is
decided, atomically under the row's lock. The grant needs four things, in the
door's words: the row is ADDRESSED TO THIS EXECUTOR — or is a pool row this
executor is a member of, a `tool_provider` that announced the name — (409
`not_addressed_here` otherwise — a kernel tool carries no addressee, and a row
addressed to another executor of the account is not absence), it is a `tool_call` (409
`not_claimable_kind` for an ask or an approval), it is a `dispatched` park on
a run that can still be answered (409 `task_not_claimable` once it settled or
its run stopped), and NOBODY EVER CLAIMED IT in this generation (409
`already_claimed` — a lapsed generation is not re-granted; the sweep settles the
tool according to its frozen effect profile).
The executor must still be eligible for the run's frozen
answering principal (409 `not_eligible`), and the run's creator must still hold
write standing on its workspace (409 `not_authorized`). Claim checks both.
Commit retains the creator's write-standing check; an existing claimant may
report its result during Human shutdown as described below.

Answers `{task, claim: {claim_token, deadline_at}}` — the same executable row
the inbox lists, including `workspace_public_id`, `tool_input` and
`tool_call_id`, beside the token.
CLAIMING IS THE FETCH: the happy path is push → claim → run → commit, with no
listing at all; the list remains the truth and the recovery path. THE TOKEN
ROTATES on every claim, so a runner returning from the dead cannot settle
over whoever holds the work; a claim stands until the park's OWN deadline —
one clock, no lease, no heartbeat — and TAKING THE WORK RESTARTS THAT CLOCK,
so the holder gets a full deadline rather than one already spent. A claimant
still at work on an ordinary tool when that deadline nears may EXTEND it ("Extend" below): the
same clock moved, bounded and narrated, never a second timer. Exclusivity is
by token, never by the caller's standing: concurrent claim requests from the
same address still compete, and the same address claiming twice is refused
like anyone else. This does not make copied credentials separate identities.
Waiting for children or a Human retains this same claim and renewal contract.
An observation window ending does not complete the tool; its resource limits remain
the responsibility of the executing runtime.

### Read bound attachments

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}/bytes
Authorization: Bearer <executor credential>
Claim-Token: <the token granted to this execution>
```

The descriptor returns the ordinary `{upload: {public_id, filename,
content_type, byte_size, created_at}}` shape. The bytes resource streams the
original file, supports HTTP `Range` (`206`), and never redirects to a signed
storage URL. Both reads use `Cache-Control: no-store`; the proof appears only
in the header and is not returned.

The exact executor and token must still own a `dispatched` claim whose park
deadline has not passed. A mismatched proof is `409 not_claimant`; an elapsed
or settled claim is `409 claim_inactive`; missing proof is `400 parameter_missing`.
The run and task are scoped to the executor's Account. Missing, fileless or
unbound files answer `404 not_found` without a descriptor.

A file must be bound by the existing ContentBody upload join to an input or
result node of this run, this run's exact conversation variant prompt, or
a prior active variant reachable on the conversation's assembly surface.
That prior variant supplies its prompt/content attachments and its run's
result captures. The history scope honors fork boundaries and concealment,
excludes future turns and inactive variants, and remains available across
compaction when a summary retained the reference. Native-media omission does
not revoke a bound file reference. Another staged file in the same Account,
or a capture from an unrelated run, is not enough. Result publication still
requires the committing executor's own capture as described above.

The capability belongs to the existing claim, so a pause or default Runner change
does not require acquiring new work or a member credential. Reads take no
domain locks and do not renew a deadline or settle work. Ordinary authentication
and rate limits still apply. Each new read checks its claim before streaming;
revocation does not recall bytes already transferred. The runner's `file_import`
uses these resources and keeps only reconstructible coding/cowork working files.
Nexus remains the durable attachment owner.

### Read an existing claim

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim
Authorization: Bearer <executor credential>
Claim-Token: <the token granted to this execution>
```

Available to every executor kind, including independent tool providers.
The proof is required in the `Claim-Token` header, not a query or body field.
The response contains only:

```json
{ "claim": { "active": true } }
```

Nexus first matches the row's claimant executor and original token, then
reports whether that task remains `dispatched`. The read neither renews
the claim nor changes its deadline. It acquires no domain row lock, writes
no domain state, and schedules no work; ordinary authentication-use sampling
and rate counters still apply. Responses use `Cache-Control: no-store` and
never return the current token or executable input.

| Observation | Response |
| --- | --- |
| Exact claimant and token, task still dispatched | `200`, `active: true`. Pause, needs-attention and graceful canceling do not invalidate existing work. |
| Exact claimant and token, task settled | `200`, `active: false`. Stop this local execution, including when its force-stop notification was lost. |
| Different claimant, wrong token, or an old token after retry under the same task key | `409 not_claimant`. Stop the old execution. |
| Missing task, missing or tombstoned run, or a run outside the executor's Account | `404 not_found`. The bound claim is no longer available. |
| Missing or blank `Claim-Token` header | `400 parameter_missing`, naming the header without echoing it. |

This proof does not depend on current inbox membership, tool announcements,
the host's current default Runner, or eligibility for new work. An already
claimed task survives a default Runner change or its Human manager's pending shutdown
until its own lifecycle settles; ordinary transport authentication still
applies. A read observes persisted status and does not project an elapsed
deadline itself. Existing deadline settlement remains authoritative.

Poll while the local execution remains active, even when Cable is connected.
Read errors, `429`, malformed responses and transport failures are not proof
of cancellation: retain the original execution context, resources and deadline,
honor `Retry-After`, and let existing terminal credential-loss handling act
on its own authority. A failed read does not release local admission capacity;
the handler's actual yield or exit owns that release. Cancellation must target the original execution, not a
new claim later issued under the same task key. The reference Runner normally
checks every five seconds; larger custom pools increase that interval to
bound request load. Network time, backoff and handler cleanup add latency.
The best-effort local deadline rule under "Expiry" also applies to these reads.

Claim reads have a separate caller budget of **600/minute**; claim POSTs
inherit **6,000/minute**. Both retain the ordinary broad source-IP backstop.
A `429` carries the existing integer-seconds `Retry-After` response.

### Extend

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/extend
```

```json
{ "claim_token": "…", "timeout_ms": 300000 }
```

Only the row's CURRENT CLAIMANT may extend its deadline — the executor that
took the row AND the token its claim minted (409 `not_claimant` for any other
address or token, including a token from an older execution) — on a row that is a claimed
`dispatched` park on a live run with an uncut execution source (409 `not_extendable`
for an unclaimed row, a settled one, a queued one, an ask, or a stopped execution).
Pause and a repair hold preserve an existing claim's ability to renew. A claim at or past its current deadline also returns
`409 not_extendable`, even when the expiry sweep has not yet settled its row.
That refusal changes neither the task nor its clock and emits no extension event;
ordinary commit or sweep processing still owns expiry settlement.
During Pause, the persisted deadline uses the frozen Run clock. The returned
`task.deadline_at` and `claim.deadline_at` map that remaining window to wall time,
so a live executor can keep its existing timer and renewal path. Resume shifts
the stored park clock once by the accumulated pause duration.
`timeout_ms` is the NEW BUDGET FROM NOW: the
deadline becomes now plus it, bounded by the tool's announced `timeout_ms`
when the tool announced one and by the kernel's hour (3,600,000 ms) either
way (409 `extension_too_long`); a value that is not a positive integer is 422
`invalid_timeout_ms`. There is no count limit or overall run deadline: a live
claimant may keep extending, while task cancellation or a run force-stop can
settle the park. Once the claimant stops extending, the park's current deadline
applies. The write moves THE ONE CLOCK the claim owns, so
the sweep's frontier follows it with no second derivation; nothing rotates —
the answer is the same `{task, claim: {claim_token, deadline_at}}` a grant
gives, `deadline_at` moved. The row's `timeout_ms` is unchanged: the budget
does not move, the clock under it does. It is narrated on the run's stream as
`task_deadline_extended {task_key, deadline_at, by, timeout_ms}` (`by` the
claimant's public id), so a watcher sees the runner ask for more time. A
commit that arrives after a deadline the claimant did not move stays an
expiry: the extension is the way to prevent one, never a way past it.

### Commit

```http
POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/commit
```

The parked call's answer, settled against the token its claim minted. The
envelope is flat:

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

Only `claim_token` is required; `outcome` defaults to `completed`. THE TWO
AXES: `is_error: true` on a completed outcome is a tool that RAN and errored
— data the continuation reads, marked so an error never reads as an answer;
`outcome: "failed"` is a tool that could not run at all (`tool_failed`) and
takes the task's own `on_failure` policy.

A claimed task may still report its result while its executor's controlling
Human is shutting down. The current executor transport and the task's own
claim token prove that result; the new-admission eligibility check must not
reject it just because shutdown is pending. New claims remain closed, and an
unclaimed ask still requires current eligibility. Explicit executor revocation
and the run creator's current workspace write-standing check still apply.
Agent removal advances its application's credential epoch immediately;
an old transport credential cannot use this exact-claimant rule to bypass the
fence. A late result cannot replace a task's force-stop terminal state.

THE THREE CHANNELS, one meaning each. `content` is MCP's
`CallToolResult.content` — a String, or a list of blocks of two kinds:
`{type: "text", text}` and `{type: "resource_link", uri:
"nexus://uploads/<public_id>", name, mimeType?, size?, title?, description?}`
(MCP's own `ResourceLink`; `name` is required; the `uri` names THIS
executor's own capture ("Captures", above), or a capture retained by this task's
sealed operation observation, else `422 unknown_result_upload`
with the park standing; any other scheme is `invalid_content`) — and the
ONLY channel a model reads: a text block as its text; a result with no text
as `""` (the kernel never serializes anything into the text position); the
round's links to bound image and PDF uploads (identified by the upload's detected
type, not the link's optional `mimeType`) as ONE attachment-only message
after the round's last result when the current model accepts that media
type, else as the ruled index line. Later conversation turns retain those
attachments with the round, subject to their model selection, history budget,
pruning and compaction. A non-media link is the client's alone — the tool's own
sentence already names the path. `structured_content` is MCP's
`structuredContent` — any JSON value, including explicit null and false. An omitted
field is absent; an explicit null is a stored structured value. It is stored whole, served on the task
read, never rendered to a model; a runner that wants the model to read its
structure puts the words in `content` beside it. A kernel-created lifecycle
hook task additionally interprets the closed decision object described
[below](#lifecycle-hook-tasks); an ordinary tool's structured output remains
opaque, even if it uses the same keys. `metadata` is the
model-invisible carrier — a JSON object bounded by `envelope_bound`, served
on the task read as `metadata`, with ONE reserved key, `checkpoint`
([Runs](runs.md)). The value under `checkpoint` is the
ANNOUNCING RUNNER's own record of its environment before this call ran, stored
and served VERBATIM — any JSON object rides. rho-runner writes `{hash,
store}` (a tree hash in the runner's shadow store, the store's id;
`outside: [paths]` when the call's own target lay outside the root,
`ignored: [paths]` when it was gitignored) or `{skipped, bytes, files}`
when it declined to capture. The kernel reads whether a `hash` is present
and interprets nothing else; the claimant of the row
(`claimed_by_executor_public_id`) is the runner that wrote it. A runner
that captures also announces `checkpoint_restore` (a write-kind tool taking
`{checkpoint, store?}`) and `checkpoints` (a read: `{}`, `{run}`, `{from, to}`,
`{checkpoint}`, each accepting an optional `store`) — described to nobody,
so no model declares them; a member reaches them through a request run.
The store identifier selects the original work root; an unknown store
refuses instead of falling back to the runner's default root. Without a
selector, restore and diff use the current root, while a record list can
find a run across the runner's stores. Restore first captures undo and
refuses before changing files if a displaced path was not captured there
(for example, an ignored or oversized file).
`title` is the UI's one-line header
for a collapsed row, served beside them. The grammar is
[Runs](runs.md)'s.

For ordinary tools, the commit is WRITE-ONCE, and the answer is the settle's own: `{task}` with
the task settled; a second commit under the same token after the settle is
`200` with the task unchanged (`idle` — a retry after a lost response is
never a second answer); a wrong, rotated or lapsed token is 409
`stale_claim`; a task not yet dispatched is 409 `task_not_running`. THE
DEADLINE WINS: an answer arriving after the park expired settles the task by
the same expiry rule (`timed_out`, or `uncertain` for a claimed
non-replayable call — "Expiry" below) and its content is discarded — it
never quietly succeeds late. The address proves the door before the token
proves the claim: a commit from an executor the row does not name — or, on a
pool row, from any member but its claimant — is 409
`not_addressed_here` whatever token it carries. Payload refusals leave the
park standing: 422 `invalid_outcome`, `result_too_large` (1 MB),
`invalid_result_type`, `invalid_title`, `invalid_metadata`,
`metadata_too_large`, the grammar's `invalid_content` /
`unsupported_content_kind` / `too_many_content_blocks`, and
`unknown_result_upload` — a `resource_link` naming an id that is not this
executor's own capture or a capture retained by this task's sealed operation
observation (a merely known id grants no access), whole or nothing. One does not:
422 `result_unstorable` (bytes storage
can never hold — a NUL, invalid UTF-8) refuses the report AND closes the
park, the task settling `failed` with `error.key: result_unstorable` and
the guard's word in `error.detail` — a typed refusal is final, and the
bytes are the runner's to clean BEFORE it submits. A commit
refused by TRANSPORT — a dropped connection, a 429 — is safe to retry
under the same token while the deadline stands.

A tool with accepted operations additionally requires all attached work to have
settled and been observed or explicitly released. An exact retry by its final
claimant returns the stored result even after the claim deadline; changed
content refuses `final_result_conflict`. Previous-generation tokens remain stale.
See [finalization](executor-operations.md#commit-the-final-result) for result
identity, failure cleanup and capture ownership.

AN ASK'S COMMIT carries no `claim_token`: the row was never claimed, and the
addressee's credential is the whole authorization — the row names this
executor, the executor is still eligible for the run's frozen principal,
and that principal still holds write standing. `content` is the answer the
model reads as `<answer task="…">` on its next round; `outcome: "failed"`
escalates through the ask's own policy (a kernel ask halts). The member
`resolution` door ([Runs](runs.md)) answers the SAME row for
a person with write standing — two doors, one settle: the second answer is
`200` with the task as it stands (`idle`). A tool row on this door without a
token is `stale_claim`, never an ask.

### Expiry

For ordinary tools, the expiry sweep and a commit arriving at or after a park's
deadline use the same settlement rule:

- never claimed → `timed_out` (`error.key: tool_timeout`): nothing started,
  whatever the profile;
- claimed, and the tool's frozen effect profile is replayable (a `read_only`
  or `pure` kind, or `intrinsic` idempotency) → `timed_out`: a re-run is
  harmless, so the model may re-issue the call from its envelope or a person
  may `retry` it;
- claimed, any other profile → `uncertain` (`error.key: tool_uncertain`,
  `error.detail` says the effect may have happened): nothing re-runs it blind.
  The run's containment reads it as a failure — absorbed into the model's
  envelope, or holding the run for a person's `retry` (a new generation
  retaining the accepted Runner target) or `abandon`.

A tool never re-queues itself at expiry. Its accepted child operations and
observations remain durable; expiry settles the parent and cancels attached
work. A live handler can renew its ordinary claim while waiting. Each child
keeps its own deadline and effects. No claim renewal or operation trace
reconstructs a lost handler, VM, or external handle.

The runner derives its handler deadline from the current granted claim,
reserving time to submit the result. At that local deadline it requests
cancellation and attempts to commit `completed` with `is_error: true`:
"The tool timed out: its granted execution deadline passed before it returned
a result. Cancellation was requested; external effects may be incomplete.
Check its effect before calling it again." This stable text does not depend
on measured elapsed time or claim extensions. Process tools own their process
cleanup; the shared deadline path does not promise that every handler or
external process has stopped, or that an effect was undone. A handler that
ignores cancellation retains its execution context and resources until its
actual exit; a late result cannot replace the settled outcome. Local
deadline handling is best effort during an in-flight control HTTP request
or credential refresh: the request must have a finite timeout, but that
timeout may exceed the task's remaining time.
After the control call returns or times out, the existing deadline and
cancellation path resumes. This does not extend the park or let a late
result overwrite settled state. No aggregate probe deadline or extra
concurrency is required solely to align the HTTP and task budgets.

The kernel may settle an unanswered claim before a live runner completes
this path, just as when the runner died or lost its network; the frozen
effect profile determines `timed_out` versus `uncertain` above.
A handler with no clamp of its own
(a tool provider's, the delegated compaction) is the case the extension is
for: the runner extends at half the park and again at each half while the
handler runs; a tool that clamps itself (bash) never extends.

### Push

`AgentAPI::V1::ExecutorInboxChannel`, subscribed with NO params over the
cable whose bearer is the transport credential (the credential names the
address; a member bearer holds no executor identity and is rejected). It
carries two frames and nothing executable:

- `work_available` — `{type, kind, run_public_id, task_key, tool_name?}`
  when a row is addressed to this executor: which and where, never what. A
  runner claims that one row directly instead of paging its inbox; a wide
  fan publishes one frame per member. A pool row's frame reaches every
  member's stream — the same members the addressing computed — and the
  first claim takes it.
- `work_canceled` — `{type, run_public_id, task_key}` to the CLAIMANT
  when the kernel cancels a row it holds (a stop, a branch cancel): the
  runner stops the handler; its commit afterwards is `idle`.

The socket closes when the credential stops being usable — a re-pair, a
revoke, a family loss — within the connection's authority check interval; the
stream name carries no epoch. HTTP remains authoritative: the inbox recovers
work discovery, and the exact-claim GET recovers cancellation for work already
executing. Cable is a latency aid; a missed frame is detected by the relevant
read rather than inferred from inbox absence.

An ask's frame is `{type: work_available, kind: "ask", run_public_id,
task_key}` — the agent application's notice that a model is waiting on a
person; nothing claims it.

### Progress — the ephemeral frames this executor posts

```http
POST /agent_api/v1/executor/progress
```

`{frame}` in the body uses a source claim as its fence. Tool progress carries
`{run_public_id, task_key, claim_token}` and requires the current claimant;
a settled task drops further tool frames. Process progress carries
`{conversation_public_id | run_public_id, process_id, source:
{run_public_id, task_key, claim_token}, lines[], exit?}`. The nested source
identifies the task that started the process; its target, claimant, token and
host must match. Its original claim remains proof after settlement. A host
default change neither revokes that proof nor authorizes another Runner.
Retry rotates the claim and detail collection removes the evidence; stale
process frames then refuse without terminating the process. An explicitly
targeted `read_process` call remains available. Tokens stay private and are
never broadcast.
The kernel stamps `type`, `executor_public_id`, `at`
(milliseconds) and, inside a claim, `tool_name`; the payload is `text_tail` /
`structured` on `executor_progress`, `lines[]` / `exit` on `process_output`.
`202` always for a well-formed frame; the body is bounded by `envelope_bound`
(`422 frame_too_large`), a key of neither kind or a payload member of the
wrong type is `422 invalid_frame`; ONE FRAME PER KEY PER `min_interval_ms`
per kernel process (`size_bounds`, `progress_min_interval_ms`) — a faster
poster is answered `202` and the frame dropped, never a refusal to handle.
Frames go out on the host's `progress` feed (`items: progress` on the host's
events channel); the envelope is `{frame}`, never `{event}`; nothing is
stored in the primary database and nothing replays — a late subscriber sees
what follows. (The cable adapter keeps its own rows for its retention; they
are the adapter's.) The kernel's own frames on the same feed are
runs.md's ("The event stream"); the pack lists the feed's vocabulary
once, under conversations.

### Requests — what is addressed to this executor as a task

An executor surface is either a CAPTURE the executor publishes ("Captures",
above) or a REQUEST addressed to it as a task. A request for something only
this executor can answer — a file's bytes, a process's log — is a TOOL CALL
like any other: a ONE-TASK STANDALONE RUN a member creates AND STARTS on the
task-grained surface ([Runs](runs.md): `POST …/runs`
with `steps: [{tool: {name, input, route: {kind: "runner",
runner_executor_public_id: UUID}, timeout_ms?}}]`, `prompt_mechanism: raw`,
`approval_mode: bypass`, then
`POST …/start`), whose deliverable is that step. The row is granted by its
origin unless the run's `approval_rules` deny it or name `author` with
`ask`. It lists on this inbox as a `tool_call` row with
`conversation_public_id: null`, is claimed, extended and committed by the
doors above, expires by the sweep at its own deadline (the step's
`timeout_ms`, else the announced park, else the kernel default), and its
answer is read on the member task read — `content` (a `resource_link` when
the answer is a capture), `title` and `metadata`. There is no second door
and no second kind: a runner announces a capability as a tool (a `READ_ONLY`
profile for a read; announced without `description` or `input_schema` so
no model is handed it) and serves it; a name it did not announce refuses
`tool_not_served` at acceptance. Withdrawal before delivery fails the task with
the same code. Presence is never consulted — an offline
runner's request waits out its deadline and settles `timed_out`. A tool
deliverable that does not complete holds the run `needs_attention
deliverable_unresolved` like any other; the SDK's composition
(`runs.start_tool_call` / `wait_for_tool_result`) reads the terminal task and
`stop`s the run behind a failed one.

### Lifecycle hook tasks

A profile's optional [lifecycle hooks](../../lifecycle-hooks.md) run as
ordinary `tool_call` inbox entries. The configured executor tool must be
announced normally; it does not have to appear in the profile's model-facing
`tool_definitions`. Claim, approval, extension, timeout, cancellation, and
commit use the same protocol as other tools. No separate hook inbox exists.

The kernel supplies `tool_input` containing `event` (`turn_start`,
`pre_compact`, `post_compact`, or `stop`), `task_key` of the triggering task,
`run_public_id`, `conversation_public_id` (`null` for standalone
execution), `output_preview`, and `output_size_bytes`. Preview and size may be
`null` before output exists. A mid-turn `pre_compact` additionally supplies
`compaction_trigger` (`manual`, `usage`, `wall`, or `overflow`) and nullable
`overshoot_bytes` and `overshoot_tokens`. The token count is present only for
a token limit; its byte estimate does not prove the tokens a prune can free.
The inbox entry's own `task_key` still identifies the hook
task to claim and commit; the key inside `tool_input` identifies its source.

Commit an acknowledgement as:

```json
{
  "claim_token": "…",
  "content": "Review complete.",
  "structured_content": { "continue": false }
}
```

Only a `stop` hook can request another model round:

```json
{
  "claim_token": "…",
  "content": "A follow-up is needed.",
  "structured_content": {
    "continue": true,
    "feedback": "Run the focused regression check before finishing."
  }
}
```

The decision object requires boolean `continue` and permits only one other
key, `feedback`: optional text without NUL, at most 16 KiB, and required to be
nonblank when requesting continuation. Other hook events require
`continue: false`. Only the server-owned hook marker grants this result its
control meaning; a matching event field or tool name on an ordinary call does
not. Stop feedback becomes the next model round's prompt. The declaration's
`max_continuations` bounds how many times a Stop hook can do this.

A malformed decision settles the hook `failed` with `invalid_hook_result`;
`is_error: true` yields `hook_error`, exceeding the continuation bound
yields `stop_hook_limit`, and requesting continuation without an existing
model round to inherit yields `hook_requires_model`. These are accepted terminal task results, not a
request to retry the same commit. Ordinary `outcome: failed` and deadline
expiry retain the usual tool failure rules. Hook failures hold for explicit
repair; retry re-executes the hook, and abandon releases its hold. Force-stop
cancels pending hook tasks immediately without a hook veto.

### The delegated compaction

A FAT KERNEL COMPACTS: the kernel's
own summarizer is the shipped default, and an agent whose declared
`compaction_policy` is `{"mode": "delegate", "tool_name": "…"}` receives
each compaction as an inbox row instead — a `tool_call` naming the policy's
`tool_name`, addressed to the DECLARING profile's address as the agent
application's own tool (an Agent address is never a Runner target),
with `tool_input` `{history, retained_tail,
conversation, turn, task}` on a run-backed turn, `{history, retained_tail,
run_public_id, task}` on a standalone run, `{history, retained_tail,
conversation, turn}` between turns — the history rendered as pointers, the
tail verbatim. The agent claims and commits it like any tool row: the
summary text as `content`, which the round then reads in place of the
history it replaced; `outcome: "failed"` when it could not summarize, which
is the agent's failure in the agent's log — the round then fails on size. A
`completed` answer marked `is_error` is never read as a summary. The address
must ANNOUNCE the name, or the row fails at start `tool_not_served`.

A delegate NOBODY answered — the agent died holding the claim, or never
claimed it — settles at the deadline by the expiry rule above (never
claimed: `timed_out`; claimed: `timed_out` for its replayable profile,
`uncertain` otherwise), and the kernel appends its own
summarizer ONCE in its place, narrated `context_compacted{mode: kernel,
trigger: fallback, fallback_from: <the delegate's key>, fallback_reason:
tool_timeout | tool_uncertain}` ([Conversations](conversations.md)); a second
failure is the honest size failure. A delegate on a run with no declaring
agent — a person's own standalone run — is refused at the append
door, `invalid_steps` with `delegate_requires_agent`
([Runs](runs.md)).

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The address returned; an inbox page; a claim granted; a commit applied or idle. |
| `201 Created` | — | A capture staged on the uploads door: the descriptor. |
| `202 Accepted` | — | A well-formed progress frame, broadcast or dropped for cadence. |
| `400 Bad Request` | `parameter_missing` `parameter_invalid` | The announcement carried no `tools`; an inbox cursor that does not parse; a capture upload with no `upload[file]` part, or one that is not a file. |
| `413 Content Too Large` | `content_too_large` | A capture over `upload_bound` on the uploads door; nothing is staged. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not an executor-transport credential — a member bearer on any door here, a fenced epoch, a revoked runner. |
| `422 Unprocessable Content` | `reserved_namespace` | An announcement entry names a kernel tool under a reserved namespace (`nexus.graph`, `nexus.human`, `nexus.conversation`, `nexus.tools`; canonical or wire spelling) — the message names the namespace; nothing is written. |
| `422 Unprocessable Content` | `invalid_announcement` | An announcement entry is malformed — the message names `tools[i].field` — or `environment` is not an object; nothing is written. |
| `422 Unprocessable Content` | `validation_failed` | The announced list is over the envelope bound, or the environment document over its bound. |
| `404 Not Found` | `not_found` | An inbox door named a run or key this credential's account does not hold. |
| `409 Conflict` | `not_addressed_here` `already_claimed` `task_not_claimable` `not_claimable_kind` `stale_claim` `task_not_running` `not_eligible` | The inbox doors' refusals — a caller branches on the code alone: the row names another addressee or a pool this executor is not a member of (or, at commit, a pool row this executor did not claim), was ever claimed, is no longer a claimable park, is an ask or an approval, the token is dead, the task is not yet dispatched, or the executor lost eligibility. |
| `409 Conflict` | `not_authorized` | The run's principal lost write standing — a fact about the row's run, not this credential. |
| `409 Conflict` | `claim_inactive` | The input attachment read names an elapsed or settled execution. |
| `409 Conflict` | `not_claimant` | The source task, claimant and private token do not match the posting executor. |
| `409 Conflict` | `not_extendable` `extension_too_long` | The extend door's refusals (beside `not_claimant`, shared with the frame fence): the row is not a claimed `dispatched` park on a run that can still be answered, or the new budget exceeds the tool's announced `timeout_ms` or the kernel's hour. |
| `422 Unprocessable Content` | `invalid_timeout_ms` | The extend door's `timeout_ms` is not a positive integer. |
| `422 Unprocessable Content` | `frame_too_large` `invalid_frame` | A progress frame over `envelope_bound`; a frame keyed by neither a task nor a process, or a payload member of the wrong type. |
| `422 Unprocessable Content` | `invalid_outcome` `result_too_large` `invalid_result_type` `invalid_title` `invalid_metadata` `metadata_too_large` `invalid_content` `unsupported_content_kind` `too_many_content_blocks` `unknown_result_upload` | An outcome outside `completed`/`failed`, a commit payload refusal, or a `resource_link` naming a capture that is not this executor's own; the park stands. |
| `422 Unprocessable Content` | `result_unstorable` | The result's bytes can never be stored (a NUL, invalid UTF-8): the report is refused AND the park closes, the task settling `failed` with `error.key: result_unstorable`. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. `Retry-After` is a whole number of seconds. |
