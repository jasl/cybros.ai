---
title: Conversation memory
description: The member-plane door to the memory documents a conversation assembles from, their scopes, bindings and skills.
---

# Conversation memory

Memory is the durable text a conversation's next reply is assembled from.
It reaches the model as a leading block in the prompt, and on this plane
these routes are its only writer: a `direct_reply` is one model call with
no tools when the declaring profile carries none, so nothing on that path
can call `memory_read`. A run-backed turn's rounds carry the profile's
tools, so a run declaring the memory tools reaches this conversation's
scope through them — `conversation/…` paths resolve to this conversation,
and each write bumps `context_revision` exactly as these routes do.

This door reads and writes the conversation's effective memory bindings.
Writes bump this conversation's `context_revision`. Some scopes also have doors of their own: the
room's `workspace/` rows at [`workspaces/{id}/memory`](workspaces.md#memory),
which picks no conversation and bumps no revision, the person's `user/`
rows at [`profile/memory`](profile-memory.md), and the answering agent's
`agent/` rows at the same door for a paired program's own, or at
[`profile/agents/{name}/memory`](profile-agents.md#memory) for a named
definition's. `speaker/` is managed here through an explicit stored binding
or a subject selected for the current request.

Client state that no prompt reads is not memory. It belongs in the
conversation's own [store entries](store-entries.md), which fork with the
conversation and bump nothing.

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/show
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/grep
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/edit
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/delete
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory_context
```

## Paths and scopes

A memory path carries its scope as its first segment
(`workspace/notes.md`), which no routing convention survives, so **the
path rides the body on every verb that names one**, the reads included.
Percent-encoding it would turn a model-facing string into a
transport-facing one for nothing.

**`workspace/…`** is shared with everyone who can open the workspace —
other agents and every human member.

**`conversation/…`** belongs to this conversation alone.

**`user/…`** belongs to the Human acting as the principal and follows that
Human across workspaces. It requires an explicit binding and is absent from
the default roots. An Agent never resolves it through its steward. The
Human's own door is [`profile/memory`](profile-memory.md).

**`agent/…`** belongs to the agent that answers the turn — a paired
program or a named Agent — and follows that row across every
workspace and conversation it answers in, as `user/` follows a person. It
is the answerer's, not the poster's. A Human-answered
conversation has no `agent/` rung. No sibling under the same steward reads
it, and the steward's own `user/` never carries it, which is what lets an
agent that faces people outside the account keep notes of its own while
binding no `user/` at all.

**`speaker/…`** belongs to the answering Agent and one Speaker together.
It follows that pair across workspaces and conversations. Two Agents
speaking with the same person have separate documents, as do two people
speaking with the same Agent. The Speaker is a member or external ingress
identity; it changes neither the authenticated member's authority nor the
answering Agent. No Speaker memory falls back to `agent/` or `user/`.

A bare name is refused `memory_path_invalid` rather than defaulted: a
default would decide where notes live by accident, and the five scopes
differ in who can read them.

## List documents

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory
```

### Response

`200` with every document in this conversation's selected bindings — by
default its own, its workspace's and the answering Agent's `agent/`
scope, plus `speaker/` when its subject is explicitly bound — as `{memory: [{path, public_id, lock_version, bytesize,
description, written_at}]}`. No content: `show` is what loads text.

`description` is the skill row's line and `null` on a plain document.
`written_at` is the content's age, not the row's, so a forked conversation
does not report every inherited document as written at the moment of the
fork.

## Show a document

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory/show
```

### Request

```json
{ "memory": { "path": "conversation/plan.md" } }
```

### Response

`200` with the document and its `content`:

```json
{ "memory": { "path": "conversation/plan.md", "public_id": "01995000-0000-7000-8000-000000000001", "lock_version": 0, "bytesize": 18, "description": null, "content": "the whole document", "written_at": "2026-09-08T00:00:00Z" } }
```

## Write a document

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory
```

### Request

The whole document, under its condition:

```json
{ "memory": { "path": "conversation/plan.md", "content": "the whole document", "expected_public_id": null, "expected_lock_version": null } }
```

`description` is a skill row's and is refused on any other path.

### Response

`201` with the written document, in the `show` shape.

## Edit a document

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory/edit
```

### Request

```json
{ "memory": { "path": "conversation/plan.md", "old_text": "one exact passage", "new_text": "its replacement", "expected_public_id": "01995000-0000-7000-8000-000000000001", "expected_lock_version": 0 } }
```

The exact passage must occur once. Stale versions refuse before matching;
no match is `memory_edit_not_found` and several matches
`memory_edit_ambiguous`, and the document is unchanged either way.

### Response

`200` with the edited document, in the `show` shape.

## Search documents

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory/grep
```

### Request

```json
{ "memory": { "pattern": "deadline", "path": "workspace/", "ignore_case": true, "limit": 100 } }
```

A bounded regular expression over lines, ordered by logical path then
line. `limit` defaults to 100 and accepts 1–500; malformed, nonpositive
and larger scalar values return `400 parameter_invalid`.

### Response

`200 {matches: [{path, line_number, text}], truncated}`. Lines are capped
at 500 characters.

## Delete a document

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory/delete
```

### Request

```json
{ "memory": { "path": "conversation/plan.md", "expected_public_id": "01995000-0000-7000-8000-000000000001", "expected_lock_version": 0 } }
```

### Response

`204`, and it is gone: no history, no recycle bin.

## Replace the bindings

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory_context
```

### Request

The configuration is replaced whole. A missing `memory_context` field is
`400`; an explicit `null` restores the default roots; `{"bindings": []}`
disables all memory roots.

```json
{"memory_context":{"bindings":[
  {"name":"conversation","scope":"conversation","access":"read_write"},
  {"name":"group","scope":"conversation","access":"read","conversation_public_id":"01900000-0000-7000-8000-000000000072"}
]}}
```

### Response

`200 {conversation: …}`, the conversation's full representation. It also
carries `memory_context` on every read, and the field may be supplied at
creation. The full representation also carries `effective_memory_context`,
the currently available bindings after the answering profile's limit. Each
binding includes its resolved anchor UUID; a Speaker binding includes both
`agent_public_id` and `speaker_public_id`.

## Conditional writes

Both expected fields are required on every write, edit and delete.
`null`/`null` creates only an absent path; a UUID and version pair from a
read or a listing replaces or deletes only the observed row. Missing or
malformed conditions return `400 parameter_missing` or
`parameter_invalid`; stale, missing and recreated rows return `409
stale_object` without changes.

Never automatically retry an old calculation with a newly fetched pair.
[Conditional writes](profile-memory.md#conditional-writes) owns the shared
create, delete, fork and conflict contract.

## Named bindings

Memory content lives in database rows and immutable text versions. Paths
are a file-style interface; they refer to no files and synchronize with no
runner.

Each binding has a unique root `name` (`[a-z][a-z0-9_-]{0,31}`), an
existing `scope` (`conversation`, `workspace`, `user`, `agent` or `speaker`), and
`access` (`read` or `read_write`). At most 16 bindings are allowed. Every
nonempty configuration includes `conversation` with scope `conversation`
and no explicit UUID, so the current conversation remains addressable. The
reserved root names `conversation`, `workspace`, `user`, `agent` and `speaker` keep
those meanings. An `agent` binding on a Human-answered conversation names
no row and is refused `memory_scope_unavailable` when configured; an
Agent never resolves `user` through its steward. A differently named conversation binding may select a visible
existing conversation in the same workspace with `conversation_public_id`;
otherwise it uses the current host. `user` and `workspace` select
the current Human principal and current workspace, and
`agent` the answering agent's own row. Binding an arbitrary Human or
Agent is unsupported.

A `speaker` binding may include `speaker_public_id`, an existing same-Account
Speaker UUID. It selects the subject while the answerer supplies the Agent
owner. Without this explicit subject, a new ordinary execution captures its
input's actual Speaker. The management door never guesses a subject from the
latest turn: an unbound Speaker root is unavailable unless the request selects
one. A conversation
may be created with an unbound root before its first input arrives.

Every memory verb accepts optional `memory.speaker_public_id`. On the GET
listing, send it as the `memory[speaker_public_id]` query parameter; on
show, write, edit, delete and grep, include it in the existing `memory`
request object. It must name an existing ingress Speaker controlled by the
acting Agent in the same Account, or the request refuses `403 not_authorized`.
The selector binds only relative Speaker roots for this request. It preserves
explicit Speaker bindings and the selected execution's memory limits, changes
no Conversation configuration, and creates no Speaker. Omission leaves the
stored bindings unchanged. For example:

```json
{"memory":{"path":"speaker/preferences.md","speaker_public_id":"019a3333-4444-7555-8666-777788889999"}}
```

The default roots are `conversation`, `workspace`, `agent` and `speaker`.
The answering profile's `memory_context_limit` intersects selected bindings;
it never adds a root, and read-only access wins. See
[Agent configuration](profile-configuration.md#memory-limits-and-conversation-reach).

Configuration requires host write standing and source read standing; a
`read_write` conversation binding also requires write standing on that
source. Names such as `group/` and `person/` are aliases, never new
storage scopes: `group/notes.md` reads the selected conversation's row,
and list, grep, show, edit and write responses keep that same logical
path. Write, edit and delete through a `read` binding return `403
memory_read_only`. A missing, tombstoned or inaccessible source is omitted
from unqualified reads and from injection; an explicit path returns
`memory_scope_unavailable`. No source falls back to another root. An
explicit nonempty configuration exposes its available roots and access
modes to the model even before documents exist.

Injection, preview, the memory tools and this management door use the same
resolver. An execution freezes its configuration on the reply variant, and
its run, tasks, child operations, retries, regenerated variants and
completion mail continue with its captured subject and limits. A current
receiver profile can narrow inherited bindings further. Ordinary peer mail
uses the receiver's selected bindings intersected with the sender's anchors
and access ceiling. Explicit conversation aliases must name a shared source
available to both. Speaker aliases retain the sender's corresponding subject
and that subject's access ceiling; the ordinary `speaker/` root follows the
sender's captured subject. A spawn inherits the initiating
execution's bindings: a relative conversation root follows the child,
while an explicit shared UUID stays shared unless a profile limit excludes
it. Delegating from Agent A to B keeps the Speaker subject but selects B's
own `speaker/` documents for that person. A fork copies the
conversation's configuration and retains the selected variant's
configuration when adopting it. A configuration change affects new
ordinary executions and bumps `context_revision`; it does not rewrite a
running execution. The agent and workspace memory doors remain management
of those resources' own anchors.

## Skills

A document under the reserved prefix `workspace/skills/<name>` is a skill,
the room's, and one under `agent/skills/<name>` is the answering agent's
own. A skill callable resolves a name through its sources in order — the
Agent's announced documents, the Agent's `agent/skills/`, the
room's `workspace/skills/`, the Agent-and-Speaker pair's `speaker/skills/`,
then an explicitly selected Human `user/skills/` — and the first source that
has it wins. Database skill sources must be present in the effective memory
bindings; excluding a root excludes its catalog entries and skill loads:

**`name`** follows the skill grammar — `[a-z0-9]` with single hyphens, at
most 64 characters. It is stricter than a memory name because a model
types it back from the catalog and it must match a directory on a runner
byte for byte.

**`description`** is required and at most 1024 bytes: the line the model
reads in its turn's skills block to choose. It is refused outside
`skills/`.

**`content`** is the markdown body the model reads when it loads the skill
with the `skill` tool.

`conversation/skills/…` is refused `skill_scope_unavailable`: a skill is
never per conversation, because a fork copies the conversation rung and a
skill copied per fork would be a second authority for one instruction. A
model's `memory_write`, `memory_edit` and `memory_delete` never author a
`skills/` row (`memory_reserved_prefix`); a person or their program does,
through this door. The assembly's memory block never renders a `skills/`
row, while `memory_ls` and `memory_read` see it as any document. The
workspace's row is written through any conversation of the room, or
through the workspace's own memory door.

## While a provider overrides memory

When `tool_provider_overrides` names a provider for `nexus.memory`
([Workspaces](workspaces.md)), these routes refuse `409 memory_overridden`
naming the provider for reads and writes — all five scopes, the `user/`,
`agent/` and `speaker/` roots included. The assembly block renders nothing and the kernel's rows
wait untouched for the override to clear. The person's own door
(`profile/memory`) is not a workspace's and keeps serving `user/`.

Read this beside the scopes above: the two are one product line, and
an overridden workspace's memory is the provider's, reachable only through
the tools.

A `skills/` path is the exception. A skill is the kernel's instruction row
and never the provider's, so a verb naming one — `show`, the write,
`delete` — is served here even while the workspace overrides
`nexus.memory`. The model's memory verbs under an override still go to the
provider, and the listing, which names no path, stays refused.

## Context revision and archived conversations

A write bumps `context_revision`, exactly as an edit or an activation
does, because it changes what the next reply will be assembled from — so
`expected_context_revision` keeps meaning what it says. A refusal bumps
nothing. This management door refuses writes to archived conversations with
`409 conversation_archived`. Already accepted execution keeps its frozen
memory bindings and may finish memory writes after Conversation archive;
ordinary ACL, Workspace lifecycle and explicit Stop rules still apply.

## Forks

Forking is copy-on-write: a fork copies the pointer rows and nothing else,
at most 64 rows and zero content bytes. From that instant parent and child
are independent — a parent rewriting or deleting its own document never
reaches the child, and the child's own writes never reach the parent.

## What the model sees

A leading block, ahead of history, capped at a byte budget and spent
newest-first. The block is always a prefix of the newest documents: the
walk stops at the first one that does not fit, and everything past it is
named in the block rather than dropped in silence, so a model can always
tell that a document exists even when it cannot read it here. The bounds
are 64 documents per anchor and 64 KiB each. An Agent's private documents
and each of its Agent-and-Speaker pairs have independent 64-document caps.

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing, the document, the matches, or the conversation after a binding change. |
| `201 Created` | — | The written document; a replace answers `201` too, a write being a conditional replacement of the whole document. |
| `204 No Content` | — | Deleted. |
| `400 Bad Request` | `parameter_missing`, `parameter_invalid` | A required condition or the `memory_context` field is missing, or a condition or `limit` is malformed. |
| `403 Forbidden` | `not_authorized` | A write without write standing on the conversation. |
| `403 Forbidden` | `memory_read_only` | A write, edit or delete through a `read` binding. |
| `404 Not Found` | `not_found` | The workspace or conversation is not visible to the caller. |
| `404 Not Found` | `memory_not_found` | A read found no document at that path in the selected bindings. |
| `409 Conflict` | `stale_object` | The selected row or version no longer matches, or an absent path was created. |
| `409 Conflict` | `conversation_archived` | A write to an archived conversation. |
| `409 Conflict` | `memory_overridden` | The workspace's memory is a provider's; the message names it. |
| `422 Unprocessable Content` | `memory_path_invalid` | A bare name, or a scope word outside `conversation \| workspace \| user \| agent \| speaker`. |
| `422 Unprocessable Content` | `memory_scope_unavailable` | A binding's source is missing, tombstoned or inaccessible. |
| `422 Unprocessable Content` | `memory_edit_not_found`, `memory_edit_ambiguous` | The passage to replace occurs no times, or more than once. |
| `422 Unprocessable Content` | `memory_full` | The 65th document under one anchor. |
| `422 Unprocessable Content` | `memory_document_too_large` | The content exceeds the per-document bound. |
| `422 Unprocessable Content` | `memory_content_invalid` | The content is not a string. |
| `422 Unprocessable Content` | `skill_description_required` | A `skills/` write with no description, or a blank one. |
| `422 Unprocessable Content` | `memory_description_invalid` | A description that is not a string, exceeds 1024 bytes, or is given on a path outside `skills/`. |
| `422 Unprocessable Content` | `skill_name_invalid` | A `skills/` path whose remainder is not a skill name (`skills/`, `skills/a/b`, `skills/PDF`). |
| `422 Unprocessable Content` | `skill_scope_unavailable` | A `conversation/skills/…` path. |
| `422 Unprocessable Content` | `validation_failed` | A binding outside the grammar: an unknown root name, a scope or access word outside the lists, more than 16 bindings, or a nonempty configuration without the `conversation` root. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |
