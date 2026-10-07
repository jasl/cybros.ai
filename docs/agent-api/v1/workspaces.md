# Agent API Workspaces

Status: live Agent API resource.

Workspaces are the mandatory containers for execution and content resources. This member-plane resource exposes the collection, owner
management, and the strict serial lifecycle. There is no default Workspace:
the empty list is a normal first answer, and an Agent program creates its own
dedicated private Workspace when none fits.

Management commands exist so a **Human owner credential** can manage the
aggregate over the member plane. An Agent principal that can browse a row but
invokes an owner-only command receives an honest `403 not_workspace_owner`.

## Routes

```http
GET    /agent_api/v1/workspaces
GET    /agent_api/v1/workspaces?state=archived
GET    /agent_api/v1/workspaces/{workspace_id}
POST   /agent_api/v1/workspaces
PATCH  /agent_api/v1/workspaces/{workspace_id}
PUT    /agent_api/v1/workspaces/{workspace_id}/access_mode
PUT    /agent_api/v1/workspaces/{workspace_id}/tool_provider_overrides
GET    /agent_api/v1/workspaces/{workspace_id}/principals
GET    /agent_api/v1/workspaces/{workspace_id}/prompt_documents
GET    /agent_api/v1/workspaces/{workspace_id}/prompt_documents/{slot}
PUT    /agent_api/v1/workspaces/{workspace_id}/prompt_documents/{slot}
DELETE /agent_api/v1/workspaces/{workspace_id}/prompt_documents/{slot}
GET    /agent_api/v1/workspaces/{workspace_id}/memory
POST   /agent_api/v1/workspaces/{workspace_id}/memory/show
POST   /agent_api/v1/workspaces/{workspace_id}/memory
POST   /agent_api/v1/workspaces/{workspace_id}/memory/grep
POST   /agent_api/v1/workspaces/{workspace_id}/memory/edit
POST   /agent_api/v1/workspaces/{workspace_id}/memory/delete
POST   /agent_api/v1/workspaces/{workspace_id}/ownership_transfer
POST   /agent_api/v1/workspaces/{workspace_id}/archival
POST   /agent_api/v1/workspaces/{workspace_id}/restoration
DELETE /agent_api/v1/workspaces/{workspace_id}?lock_version=...
```

- The default state scope is `live` (`active | restoring`); `state=archived`
  is the recycle bin (`archiving | archived`); any other value is
  `400 parameter_invalid`. Tombstones are absent from every surface.
- Dedication visibility is applied after ordinary owner/access-mode/steward
  access. For an Agent, omitting `dedicated_to_current_agent` or passing
  `false` returns only undedicated (`agent_identifier IS NULL`) Workspaces;
  `true` returns only Workspaces matching that Agent's Agent identifier.
  For a Human, omission or `false` retains every accessible Workspace, while
  `true` returns an empty collection. Multiple matches are legal.
- Dedication grants no access. The exact identifier is resolved server-side
  and never crosses the wire; direct reads keep their ordinary access
  semantics, while a dedicated row remains the final mismatched-Agent write
  fence.
- `GET …/workspaces/{id}/principals` — THE PRINCIPALS LISTING: who may be named on a conversation's access carrier — every member
  User of the account with access to this workspace (the one access
  relation, answered per row: a Human by owner-or-account-wide coverage,
  an agent through its live steward's), of either kind, ordered by display
  name, as `{ principals: [{ public_id, handle, kind, display_name,
  agent_identifier, steward_public_id }] }`. Every key is present on every
  row — a Human's `agent_identifier` and `steward_public_id` are null,
  never absent. `handle` is the member's NAME — unique per
  account, `[a-z0-9][a-z0-9_-]{1,31}` — accepted by the access carrier and by
  agent selection (`agent` on `spawn`/`send`, or a turn's
  `answering_user_public_id`), written `@handle` or bare. The tools' `to`
  parameter instead names a conversation by public id or child label.
  The kernel assigns an agent's handle, and its steward may rename it.
  The system user is never a member and never listed. No
  pagination: the set is an account's members with access, small by
  construction (the executors listing's shape). This is the member plane's
  ONE user listing: an agent learns its peers' ids here and its own
  steward's off its own row; `rho conversation participants` (rho-dev) and the
  agent-selection clients read it. Absence of access is absence: a workspace
  the caller cannot browse is 404.
- Lists paginate by keyset: ordering is over the list's own key columns,
  ASCENDING by default and `order=desc` for the other direction — over
  those key columns, so on a name-keyed list `desc` is reverse
  alphabetical rather than newest. The cursor CARRIES its direction: a page
  taken one way and continued the other would walk back over rows the
  caller already has, so that combination is refused `parameter_invalid`
  rather than served. `after` is an
  opaque cursor, `limit` defaults to 25; values above the maximum clamp to
  100, while non-integer values and values below 1 return
  `400 parameter_invalid`.
- `lock_version` is required on every mutating command except create: in the
  JSON body for PATCH/PUT/POST commands, as a required query parameter on
  DELETE. Missing is `400 parameter_missing`; malformed, negative, or beyond
  the PostgreSQL integer range is `400 parameter_invalid`.

## Create and idempotency

`POST /agent_api/v1/workspaces` requires a client-minted `Idempotency-Key`
header (1–255 bytes; missing or empty is `400 idempotency_key_required`).
The accepted request is digested after allowlisting; for 24 hours the same
key with the same digest replays the stored `201` verbatim, while a different
digest is `409 idempotency_envelope_mismatch`. `Idempotency-Replayed` is
`false` for a new creation and `true` for a replay. Replay re-resolves the created
Workspace through the caller's current scope — access loss or a tombstone is
`404`, never a leaked stored response.

Body (`workspace`): `name` (required), `access_mode` (optional; Human
principals only), and `metadata` (optional JSON object, 2 KiB canonical-JSON
bound). An Agent create always forces `private` and derives the dedication tag
from the authenticated Agent; a Human create stores a null tag. `dedicated`
and raw `agent_identifier` are outside every create allowlist and ignored like
any unknown field. Dedication is creator-derived and frozen at creation; there
is no input, mutation field, or command.

## Update

`PATCH /agent_api/v1/workspaces/{workspace_id}` requires `lock_version` and at
least one of `name` or `metadata`. When present, `metadata` must be a non-null
JSON object under the same 2 KiB canonical-JSON bound as create. A non-object
value returns `422 validation_failed`; an oversized object returns
`413 content_too_large`.

## Owner management

Changing access mode uses this exact envelope:

```http
PUT /agent_api/v1/workspaces/{workspace_id}/access_mode
Content-Type: application/json

{"access_mode":{"access_mode":"account_wide","lock_version":0}}
```

Ownership transfer names an active Human in the same Account:

```http
POST /agent_api/v1/workspaces/{workspace_id}/ownership_transfer
Content-Type: application/json

{"ownership_transfer":{"target_user_public_id":"019f0000-0000-7000-8000-000000000401","lock_version":0}}
```

Archival and restoration use the same command envelope:

```http
POST /agent_api/v1/workspaces/{workspace_id}/archival
POST /agent_api/v1/workspaces/{workspace_id}/restoration
Content-Type: application/json

{"command":{"lock_version":0}}
```

Lifecycle acceptance may answer with `archiving` or `restoring`. Wait for the
stable `archived` or `active` state and refetch its current `lock_version`
before issuing the next lifecycle command.

## Tool provider overrides

A workspace may opt a kernel tool FAMILY into a tool provider: the
provider then serves that family's verbs in the kernel's place, for this
workspace alone.

```http
PUT /agent_api/v1/workspaces/{workspace_id}/tool_provider_overrides
Content-Type: application/json

{"tool_provider_overrides":{"overrides":{"nexus.memory":"<provider public_id>"},"lock_version":0}}
```

`overrides` is a WHOLE REPLACEMENT of the map — namespace → the public id of
a tool provider — and is required: `{}` clears every override (an absent
key is `400 parameter_missing`, never "clear"); a value that is not a string
is `400 parameter_invalid`. `lock_version` is the workspace's, CASed exactly
as the metadata PATCH CASes it, so a concurrent PATCH answers
`409 stale_object`. The overridable namespaces are the live kernel
namespaces outside the reserved set — today exactly `nexus.memory`
(`memory_read`, `memory_write`, `memory_edit`, `memory_ls`, `memory_grep`,
`memory_delete`); the pack lists them as `overridable_namespaces`.
`nexus.skill` is live and announceable but never overridable — a skill load
is routed per call by its name's source ([Executor](executor.md), "Where a
tool call goes"), so `{"nexus.skill": …}` is `422 validation_failed` (the
model's `namespace_not_overridable` error under it, as check 1 below says).

WHO may set it: a caller with WRITE standing under the dedication fence —
any member with data access, an agent whose dedication the workspace is;
never a fenced agent (`403 workspace_agent_identifier_mismatch`), never
outside `active` (`409 workspace_not_active`). Ownership is not required:
an agent with write standing may opt its own workspace in.

Three checks run before any lock, in this order:

1. `422 reserved_namespace` — the key names a reserved kernel namespace
   (`nexus.graph`, `nexus.human`, `nexus.conversation`, `nexus.tools`): no provider may serve one.
   The same code the announcement door answers. A key that is neither
   reserved nor overridable is `422 validation_failed`, naming it.
2. `422 provider_not_eligible` — the value is not a live tool provider of
   this account, or its scope would darken other members: addressing
   requires the provider to be eligible for the run's principal, so the
   PUT admits a provider only when it is `account_wide`, or the workspace
   is `private` and its owner is the provider's manager. A workspace later
   widened to `account_wide` keeps a `user_private` override; the new
   members' calls then fail `tool_not_served`, honest on the transcript and
   visible on the read below.
3. `422 provider_incomplete` — the provider does not announce EVERY live
   wire name of the namespace (names only). A provider taking `memory_read`
   while the kernel kept `memory_write` would be two memories under one family.

**The kernel's description bytes are the contract.** `memory_read`'s text
promises scope semantics ("shared with everyone who can open this
workspace"), and opting in makes that text the PROVIDER's to honour: the
kernel stamps every routed row with `scope: {bindings: [...]}` beside
`tool_input`, which passes through untouched. Each binding names its logical
root, database scope, public anchor UUID, and `read` or `read_write` access.
The provider must honor that resolved binding set, including aliases and
unavailable roots; it must not infer three default roots from the host IDs.
See [Executor](executor.md#read-this-executors-inbox) for the wire shape.

**Drift is level-triggered.** A provider that later drops a verb fails THAT
verb's calls `tool_not_served`; a provider that is revoked fails them all;
the read still names it. There is no kernel fallback: a tool name resolves
to exactly one providing authority.

**What is silenced while a namespace is overridden** (`nexus.memory`): the
six verbs ride the inbox to the provider; the assembly block renders NO
memory for this workspace's conversations; the conversation memory routes
(`…/conversations/{id}/memory`, [Conversations](conversations.md)) refuse
`409 memory_overridden` naming the provider for reads and writes; the
kernel's rows persist untouched, so clearing the override restores them.
The person's own door (`profile/memory`) is not a workspace's and keeps
serving `user/`. In an overridden Workspace, a turn with no memory tools
cannot read that provider's memory: the kernel's injected block is absent,
and the provider's memory is reachable only through its tool verbs. A
`direct_reply` input may have tools when its answering Agent declares them;
the input kind does not determine tool availability.

The Full projection renders the map with the provider's `display_name` and
`assignment_scope` so a person can see why; a reaped provider renders `null`
for both beside its id (the id is a snapshot, not a reference). Setting it
is not narrated: the read, `lock_version` and `updated_at` are the record.
No `rho` verb sets it — the SDK's `workspace.set_tool_provider_overrides` is
its client.

## Prompt documents — the room's character

A workspace holds ONE prompt-document slot, `character` — the room's
identity and scenario — compiled by the default template into every
assembled turn of every conversation in it, behind the agent's
`system_prompt` and ahead of the person's `persona` and memory
([Conversations](conversations.md#the-default-template--the-slots-memory-your-text-history)).
The slot is the URL's member segment — one word, never a slash — so
unlike memory every verb addresses it in the path, and the write is a
`PUT`: a whole replacement, first or later write alike.

```http
GET    /agent_api/v1/workspaces/{workspace_id}/prompt_documents
GET    /agent_api/v1/workspaces/{workspace_id}/prompt_documents/{slot}
PUT    /agent_api/v1/workspaces/{workspace_id}/prompt_documents/{slot}
DELETE /agent_api/v1/workspaces/{workspace_id}/prompt_documents/{slot}
```

```json
{ "prompt_document": { "content": "You are the narrator of {{workspace}}, speaking with {{user}}.", "role": "system" } }
```

```json
{ "prompt_document": { "slot": "character", "role": "system", "bytesize": 63, "version": 2, "content": "…", "written_at": "2026-09-08T00:00:00Z" } }
```

- `GET …/prompt_documents` — every slot this workspace holds, as
  `{slot, role, bytesize, version, written_at}` (no content: `GET
  …/{slot}` is what loads text).
- `PUT …/prompt_documents/{slot}` — `{prompt_document: {content, role?}}`
  writes the document whole; 200 with the document whether first or later
  write, `version` counting the writes. `role` is the block's role in the
  sealed list — `system` (the default), `developer` or `user`. Omitting
  `role` uses `system` on every write, including replacement of a document
  with another role. A role
  other than `system` breaks the leading system run and stands as its own
  item, the author's choice. The content rides as written: the macros
  `{{agent}} {{user}} {{workspace}} {{date}} {{conversation_kind}}` are substituted at compile,
  and a word outside that registry is refused here, naming it.
- `DELETE …/prompt_documents/{slot}` — 204, and it is gone: no history.
  The sealed requests that compiled it keep the bytes they were sent.

WHO may write: WRITE standing under the dedication fence — any member
with data access, an agent whose dedication the workspace is — never a
fenced agent, which reads it and never writes it; never outside `active`.
Reads take browse standing; an archived room still reads. The workspaces
row is the lock. A write bumps no conversation's `context_revision`: the
next turn of every conversation reads the slot live. Bound: 64 KiB.

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing, the document, or the written document. |
| `204 No Content` | — | Deleted. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `403 Forbidden` | `not_authorized` | A write without write standing — a fenced agent, a member without data access. |
| `404 Not Found` | `not_found` | The workspace is not visible to the caller. |
| `404 Not Found` | `prompt_document_not_found` | The slot holds no document. |
| `409 Conflict` | `workspace_not_active` | A write outside `active`. |
| `422 Unprocessable Content` | `prompt_slot_unavailable` | The slot is not this door's: a workspace anchors `character` alone (`system_prompt` and `persona` live on [`profile/prompt_documents`](profile.md#prompt-documents--the-acting-users-own-slots)). |
| `422 Unprocessable Content` | `prompt_document_too_large` | The content exceeds 64 KiB. |
| `422 Unprocessable Content` | `prompt_document_macro_unknown` | A `{{word}}` outside the registry, named in the message. |
| `422 Unprocessable Content` | `prompt_document_invalid` | No `content`, a non-string, a role outside `system \| developer \| user`. |

## Memory — the room's own rows

The room's own door to memory's `workspace/` scope: the rows every
conversation of this workspace assembles from, written and read here
without picking a conversation of the room (audit alt-silent-losses-5 —
before this door a `workspace/…` row could only be written through some
conversation's memory door). The profile door's shape on the workspace's
anchor: `user/` and `conversation/` have their own doors
([Profile](profile.md#memory--the-persons-own-scope),
[Conversations](conversations.md#memory--durable-scoped-and-on-this-plane-injected-rather-than-fetched))
and are refused here with `memory_scope_unavailable`. **The path rides the
body on every verb that names one**, the reads included.

```http
GET    /agent_api/v1/workspaces/{workspace_id}/memory
POST   /agent_api/v1/workspaces/{workspace_id}/memory/show
POST   /agent_api/v1/workspaces/{workspace_id}/memory
POST   /agent_api/v1/workspaces/{workspace_id}/memory/delete
```

- `GET …/memory` — every `workspace/` document of this room, as
  `{path, public_id, lock_version, bytesize, description, written_at}` (no content: `show` is what
  loads text). This door's rows alone — never a conversation's, never a
  `user/` rung.
- `POST …/memory/show` — `{memory: {path}}` answers one document with its
  `content`.
- `POST …/memory` — `{memory: {path, content, description?, expected_public_id, expected_lock_version}}` writes one
  document whole. 201. `description` is a skill row's
  (`workspace/skills/<name>`, [Profile](profile.md#memory--the-persons-own-scope)).
- `POST …/memory/grep` — `{memory: {pattern, path?, ignore_case?, limit?}}`;
  200 `{matches: [{path, line_number, text}], truncated}`. Only this workspace's
  documents are searched, with the bounded regex semantics described in
  [conversation memory](conversations.md#memory--durable-scoped-and-on-this-plane-injected-rather-than-fetched).
- `POST …/memory/edit` — `{memory: {path, old_text, new_text, expected_public_id,
  expected_lock_version}}`; 200 `{memory: ...}`. The expected version must
  match and the exact passage must occur once; a refusal changes nothing.
- `POST …/memory/delete` — `{memory: {path, expected_public_id, expected_lock_version}}`. 204, and it is gone.

Both expected fields are required: `null`/`null` creates only an absent path;
a UUID/version pair from read or list replaces or deletes only the observed row.
Missing or malformed conditions return `400 parameter_missing` /
`parameter_invalid`; stale, missing, or recreated rows return `409 stale_object`
without changes. See [conditional writes](profile.md#conditional-writes) for the
shared create, delete, fork, and conflict contract. Never automatically retry an
old calculation with a newly fetched pair.

WHO may write: WRITE standing on the workspace — data access under the
dedication fence, in `active`; a browsable-but-not-writable caller (an
archived room's reader, a fenced agent) reads and never writes (`403
not_authorized`). The workspaces row is the lock. A write bumps no
conversation's `context_revision`: the next turn of every conversation in
the room reads the rows live. Bounds and the 64-document cap are memory's.

WHILE THE WORKSPACE IS OVERRIDDEN (`tool_provider_overrides` above) every
plain verb here is `409 memory_overridden` naming the provider — the ONE
guard the conversation door runs (`MemoryOverrideGuard`); a `skills/` path
passes it, a skill being the kernel's row and never the provider's. The
person's own door keeps serving `user/` meanwhile.

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing or the document. |
| `201 Created` | — | The written document. |
| `204 No Content` | — | Deleted. |
| `400 Bad Request` | `parameter_missing`, `parameter_invalid` | A required condition is missing or malformed. |
| `409 Conflict` | `stale_object` | The selected row/version no longer matches, or an absent path was created. |
| `403 Forbidden` | `not_authorized` | A write without write standing on the workspace. |
| `404 Not Found` | `not_found` | The workspace is not visible to the caller. |
| `404 Not Found` | `memory_not_found` | A read found no document at that path in this room. |
| `409 Conflict` | `memory_overridden` | The workspace's memory is a provider's; the message names it. |
| `422 Unprocessable Content` | `memory_scope_unavailable` | A `user/` or `conversation/` path — those scopes have their own doors. |
| `422 Unprocessable Content` | `memory_path_invalid` | A bare name, or a scope word outside the three. |
| `422 Unprocessable Content` | `memory_full`, `memory_document_too_large`, `memory_content_invalid`, `memory_description_invalid`, `skill_description_required`, `skill_name_invalid` | Memory's own refusals, as on every door. |

## Projections

Workspace Basic (lists):
`public_id, name, access_mode, state, dedicated, lock_version, archived_at,
created_at, updated_at`.

Workspace Full (singular responses) adds `metadata`,
`tool_provider_overrides {namespace → {provider_public_id, display_name,
assignment_scope}}` (`{}` when none), `owner {public_id, display_name}`, and
`creator {public_id, display_name, kind}`.

`dedicated` is the only public dedication marker; it is boolean and the exact
identifier never renders anywhere.

## Status mapping

| Outcome | HTTP |
| --- | --- |
| created | `201`, Full projection |
| updated / transferred / lifecycle accepted | `200`, Full projection |
| repeat of an already-current state | `200`, Full projection (state-based no-op) |
| transition in progress | `409 transition_in_progress` |
| no effective access, tombstoned, unknown id | `404 not_found` |
| reader without management authority | `403 not_workspace_owner` |
| mismatched Agent write on a dedicated Workspace | `403 workspace_agent_identifier_mismatch` |
| management outside `active` | `409 workspace_not_active` |
| stale `lock_version` | `409 stale_object` |
| ineligible or self transfer target | `422 target_not_eligible` |
| unsupported access mode | `422 invalid_access_mode` |
| override of a reserved kernel namespace | `422 reserved_namespace` |
| override provider not live, not a tool provider, or out of the members' scope | `422 provider_not_eligible` |
| override provider not announcing the whole namespace | `422 provider_incomplete` |
| metadata over its bound | `413 content_too_large` |
| other validation failures | `422 validation_failed` |
