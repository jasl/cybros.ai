---
title: Conversation memory
description: Bind collections into a conversation, inspect effective identities and perform conditional document operations.
---

# Conversation memory

A conversation selects documents from [memory collections](memory-collections.md)
through named bindings. A path is `binding-name/document-name`; it refers to
database text, never a runner file. The kernel assembles readable ordinary
documents into the memory block and exposes the same sources to its memory tools.

Bindings are references. Changing or deleting a conversation's binding does
not delete an external collection, and a binding grants no additional source
authority. Collection metadata and lifecycle are managed through the
[collection resource](memory-collections.md), independently of the consuming
conversation.

## Routes

```http
GET  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/show
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/grep
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/edit
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/delete
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory_context
```

## Replace bindings

### Endpoint

`POST …/memory_context`.

### Request

Send `{memory_context: null}` for defaults, `{memory_context: {bindings: []}}`
to disable memory, or a complete [named binding selection](#named-bindings).
Replacement is whole; omitting the field does not reset it.

### Response

`200 {conversation: …}`. Successful replacement advances `context_revision`.

### Status codes

Missing `memory_context` is `400 parameter_missing`; invalid bindings are
`422 validation_failed`. See [bounds and status codes](#bounds-and-status-codes).

## List documents and inspect bindings

### Endpoint

`GET …/memory`.

### Request

An optional `memory[speaker_public_id]` selects a relative Speaker source.
No document path is required.

### Response

`200` with two fields:

- `memory`: documents without content, each with `path`, `collection_public_id`,
  `public_id`, `lock_version`, `bytesize`, `description` and `written_at`.
- `memory_context`: effective bindings including `name`, original `source`,
  effective `access`, derived `scope`, `collection_public_id`, `owner_public_id`,
  `speaker_public_id` and `state` (`active`, `archived`, `deleted` or `unallocated`).

`collection_public_id` may be null for an unallocated source. The same management
projection appears as `effective_memory_context` on a conversation. It allows
an empty document path to select its collection before a conditional create.
`written_at` is the text's age, including when a fork shares the text.

### Status codes

An active memory provider override returns `409 memory_overridden`.
See [bounds and status codes](#bounds-and-status-codes).

## Show a document

### Endpoint

`POST …/memory/show`.

### Request

```json
{"memory":{"path":"conversation/plan.md"}}
```

An optional `memory.speaker_public_id` selects a relative Speaker source.
Paths ride the body for every operation that names one.

### Response

`200 {memory: …}` with `content` added to the listing shape.

### Status codes

An absent path is `404 memory_not_found`. See
[bounds and status codes](#bounds-and-status-codes).

## Write a document

### Endpoint

`POST …/memory`.

### Request

```json
{"memory":{"path":"conversation/plan.md","content":"The whole document","expected_collection_public_id":"01900000-0000-7000-8000-000000000073","expected_public_id":null,"expected_lock_version":null}}
```

Use the three original [conditions](#conditional-writes). An optional
`speaker_public_id` selects a relative Speaker source; a skill also requires
`description`.

### Response

`201 {memory: …}` with the full current document.

### Status codes

A changed collection or document returns `409 stale_object`. See
[bounds and status codes](#bounds-and-status-codes).

## Edit a document

### Endpoint

`POST …/memory/edit`.

### Request

`memory` contains `path`, `old_text`, `new_text`, the three non-null conditions
and an optional `speaker_public_id`. The old passage must occur exactly once.
A stale document refuses before matching.

### Response

`200 {memory: …}` with the full current document.

### Status codes

An empty old passage is `422 memory_edit_invalid`; zero or multiple matches
return `422 memory_edit_not_found` or `memory_edit_ambiguous`. See
[bounds and status codes](#bounds-and-status-codes).

## Delete a document

### Endpoint

`POST …/memory/delete`.

### Request

`memory` contains `path`, the three non-null conditions and an optional
`speaker_public_id`.

### Response

`204`. There is no document recycle bin or version browser.

### Status codes

A changed collection or document returns `409 stale_object`. See
[bounds and status codes](#bounds-and-status-codes).

## Search documents

### Endpoint

`POST …/memory/grep`.

### Request

```json
{"memory":{"pattern":"deadline","path":"knowledge/","ignore_case":true,"limit":100}}
```

An optional `speaker_public_id` selects a relative Speaker source. `path` is an
optional prefix. Search uses a bounded regular expression; `limit` defaults
to 100 and permits 1–500.

### Response

`200 {matches: [{path, line_number, text}], truncated}` ordered by logical path
and line. Lines are capped at 500 characters.

### Status codes

An invalid or over-budget expression returns `422 memory_pattern_invalid` or
`memory_pattern_too_costly`. See [bounds and status codes](#bounds-and-status-codes).

## Named bindings

`memory_context: null` selects the applicable defaults. `{"bindings": []}`
disables memory. Each explicit binding contains a unique `name`, `access`
(`read` or `read_write`) and exactly one `source` form:

```json
{"memory_context":{"bindings":[
  {"name":"conversation","source":{"scope":"conversation"},"access":"read_write"},
  {"name":"group","source":{"scope":"conversation","conversation_public_id":"01900000-0000-7000-8000-000000000072"},"access":"read"},
  {"name":"knowledge","source":{"collection_public_id":"01900000-0000-7000-8000-000000000073"},"access":"read"}
]}}
```

Use this selection in the replacement operation or at conversation creation.

Relative scope sources select a default collection. Exact sources select a
specific collection UUID. Names match `[a-z][a-z0-9_-]{0,31}`; at most 16
bindings are allowed. A nonempty configuration need not include a conversation
root. Reserved names retain their ownership meanings: `conversation` must
refer to the current Conversation's collection, `agent` to its answerer, and
the other natural roots to their corresponding owners. Aliases never change
the source's scope or authority.

| Relative source | Default owner |
| --- | --- |
| `conversation` | This Conversation; a differently named alias may specify a visible Conversation in the same Workspace. |
| `workspace` | The current Workspace. |
| `agent` | The answering Agent, across its conversations and Workspaces. |
| `speaker` | The answering Agent plus the selected Speaker. |
| `user` | The acting Human, explicitly selected. An Agent never resolves this through its steward. |

The usual defaults are `conversation`, `workspace`, `agent` and `speaker`,
where applicable. Two Agents speaking with one Speaker own separate Speaker
collections; two Speakers speaking with one Agent also remain separate.

An explicit source must be available and authorized when configured and when
new work selects its sources. Workspace/Conversation sources remain in the
current Workspace. An Agent collection must belong to the answerer; a Speaker
collection must also match the selected subject. The profile's
[`memory_context_limit`](profile-configuration.md#memory-limits-and-conversation-reach)
narrows sources and access. Conversation-only limits use actual ownership,
so neither an alias nor a collection UUID bypasses them.

### Speaker selection

A relative Speaker source may contain `speaker_public_id`. Otherwise a new
ordinary execution uses its input's Speaker. Management never guesses a
subject from the latest turn.

Every memory verb accepts optional `memory.speaker_public_id`; GET uses the
`memory[speaker_public_id]` query parameter. This selects an existing ingress
Speaker controlled by the acting Agent in the same Account for this request's
relative Speaker roots. Explicit subjects remain explicit, limits remain in
force, and the selector changes no conversation configuration or Speaker.

```json
{"memory":{"path":"speaker/preferences.md","speaker_public_id":"019a3333-4444-7555-8666-777788889999"}}
```

A missing Speaker default can be explicitly prepared through its authorized
[Agent collection endpoint](memory-collections.md#create-a-collection). Reads,
listings and previews never create it. A deleted default cannot be recreated.

## Conditional writes

Every write, edit and delete requires `expected_collection_public_id`,
`expected_public_id` and `expected_lock_version`. For an absent path, take
the collection UUID from the bindings projection and send `null` for both
document conditions. For an existing document, use the original collection,
document UUID and version from read or list.

The server rechecks the binding inside the mutation boundary. If it now points
at another collection, `409 stale_object` changes neither target. Document
deletion/recreation or version changes also refuse. Missing and malformed
conditions return `400 parameter_missing` or `parameter_invalid`.

Do not read newer conditions and automatically replay an old proposal. The
[collection document contract](memory-collections.md#conditional-writes)
defines the shared version and fork behavior. Model-facing memory tools do
not acquire these HTTP CAS guarantees.

## Captures and lifecycle

New source selection captures the collection UUID, owner/subject, access
ceiling and authored source in the Run and reply Variant. A captured binding
contains the authored `name`, `source` and `access`, plus `capture` with
`collection_public_id`, `owner_public_id`, `scope` and `speaker_public_id`.
This identity is not a permanent authorization or a content snapshot.

Changing bindings affects new selections. Existing execution, ordinary
regeneration, retries and kernel completion mail retain captured identities,
even when continuation creates a new Run. Explicit new declarations select
again. Sealed model requests reuse their bytes; subsequent memory reads use
the captured collection's current content and current authority/state.

For new send/spawn work, relative Conversation and Agent sources follow the
receiver; Speaker sources retain the subject with the receiving answerer.
Exact collection sources retain their UUID and require recipient authority.
Both sides' limits apply. Schedule dispatch copies the parent's current
selection into its child; first materialization captures it.

Archive makes a collection read-only for new and old execution. Restore uses
the same UUID and cannot widen an original read-only selection. Delete closes
later content access without canceling execution or completion delivery.
Unavailable captured sources disappear from aggregate reads/injection; an
explicit path returns `memory_scope_unavailable`. No default or same-named
replacement is substituted. Deleted automatic defaults do not block ordinary
conversation; invalid explicit new selections refuse.

Conversation archive is separate: this management door refuses writes with
`409 conversation_archived`, while accepted execution may finish under its
existing lifecycle rules. It cannot bypass collection Archive/Delete.
Successful conversation-path writes advance only this host's
`context_revision`; shared collection changes do not broadcast revisions.

## Forks

Fork copies the source Conversation's owned collections and document pointers
within existing copy budgets, giving them new UUIDs and independent later
writes while sharing immutable text. Archived state is retained. Deleted
defaults copy only their tombstone; other deleted collections are omitted.
Self-owned selectors are remapped; external collection bindings remain external.
Deleting a parent does not erase a child's independent content pointer.

## Skills

`skills/<name>` inside a User, Agent, Speaker or Workspace collection is a
skill; Conversation-owned skills are refused. Skills require a description,
are excluded from ordinary memory injection and remain readable by memory
lookup. Model memory mutation tools cannot author them.

Skill precedence is announced Agent documents, Agent collections, Workspace
collections, Speaker collections, then explicitly selected Human collections.
Within a scope, binding order wins; duplicate document identities are included
once. Database sources obey effective bindings and execution limits.
The selected catalog fixes collection/document identity, so deleting a skill
cannot make its load adopt another same-named document.

## Provider overrides

A Workspace `nexus.memory` override blocks ordinary conversation memory HTTP
reads/writes with `409 memory_overridden` and suppresses kernel injection.
The six model verbs use the provider's existing scope protocol for relative
sources. Exact collection sources cannot be translated to provider scopes:
new selection refuses `memory_collection_provider_unsupported`, and captured
explicit operations refuse without provider dispatch. Continuation and mail
still retain the original capture. Clearing the override resumes the captured
kernel identity if it remains available; it never allocates a replacement.

A specifically named skill path retains its kernel exception; unqualified
listing still refuses. Collection UUID content doors do not bypass a Workspace
override. User/Agent/Speaker owner management remains independent of it.

## Bounds and status codes

Memory injection uses its existing byte budget, newest-first, and reports
omitted documents. Each collection permits 64 documents of 64 KiB each; this
is not a combined quota across an owner's collections.

The [collection status codes](memory-collections.md#common-status-codes) apply, plus
`409 conversation_archived` for archived-host writes and `422
memory_scope_unavailable` for an unavailable selected source. Invalid binding
configuration returns `422 validation_failed`. Read-only bindings refuse with
`403 memory_read_only`. Refused operations change no document or revision.
