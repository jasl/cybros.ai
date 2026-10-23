---
title: Memory collections
description: Own, discover and manage durable memory collections and conditional document writes.
---

# Memory collections

The member API exposes collections that own memory documents. Its UUID is stable; its name and description
are optional labels. One User, Workspace or Conversation may own several collections.
An Agent's Speaker collection additionally names one Speaker. Ownership and the
Speaker cannot change after creation.

Collections are independent of conversations that use them. Removing a binding
does not delete its collection. Collections still follow their own owner's
lifecycle and access rules. Bindings grant no additional authority.

## Routes

```http
GET /agent_api/v1/memory_collections
GET /agent_api/v1/profile/memory_collections
POST /agent_api/v1/profile/memory_collections
GET /agent_api/v1/profile/agents/{name}/memory_collections
POST /agent_api/v1/profile/agents/{name}/memory_collections
GET /agent_api/v1/workspaces/{workspace_public_id}/memory_collections
POST /agent_api/v1/workspaces/{workspace_public_id}/memory_collections
GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory_collections
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory_collections
GET /agent_api/v1/memory_collections/{public_id}
PATCH /agent_api/v1/memory_collections/{public_id}
POST /agent_api/v1/memory_collections/{public_id}/archive
POST /agent_api/v1/memory_collections/{public_id}/restore
DELETE /agent_api/v1/memory_collections/{public_id}
GET /agent_api/v1/memory_collections/{public_id}/documents
POST /agent_api/v1/memory_collections/{public_id}/documents
POST /agent_api/v1/memory_collections/{public_id}/documents/show
POST /agent_api/v1/memory_collections/{public_id}/documents/edit
POST /agent_api/v1/memory_collections/{public_id}/documents/delete
POST /agent_api/v1/memory_collections/{public_id}/documents/grep
```

## List collections

### Endpoint

`GET …/memory_collections`, globally or under one of the owners in Routes.

### Request

Lists use ordinary `after` and `limit` pagination. Owner lists can select
`default=true`; add `speaker_public_id` to select that Agent/Speaker default,
or omit it for the owner's own default. This query never allocates a collection.

### Response

`200 {memory_collections: […], pagination: {next_after}}` using the
[collection representation](#collection-metadata). The global list and details
use the same authorized scope. Deleted collections are absent.

### Status codes

An unavailable owner returns `404 not_found`. See [status codes](#common-status-codes).

## Create a collection

### Endpoint

`POST …/memory_collections` under the intended owner in Routes.

### Request

```json
{"memory_collection":{"name":"Project knowledge","description":"Maintained release notes"}}
```

Ordinary creates are non-default collections. For an Agent/Speaker collection,
supply `speaker_public_id` under the Agent's owner endpoint. An explicit
`default: true` may initialize that pair's missing default; it cannot replace
a deleted default. User, Workspace and Conversation defaults are established
when their owners are created. Reads and previews never allocate defaults.

### Response

`201 {memory_collection: …}`. Repeating explicit Agent/Speaker default
initialization returns its existing live default with `200`.

### Status codes

Insufficient management authority is `403 not_authorized`; a deleted default
or unavailable Speaker/default operation is `422 memory_scope_unavailable`.
See [status codes](#common-status-codes).

## Show a collection

### Endpoint

`GET …/memory_collections/{public_id}`.

### Request

The collection UUID is in the URL. No body is required.

### Response

`200 {memory_collection: …}` using the [collection representation](#collection-metadata).

### Status codes

An absent or unauthorized collection is `404 not_found`.
See [status codes](#common-status-codes).

## Update collection metadata

### Endpoint

`PATCH …/memory_collections/{public_id}`.

### Request

```json
{"memory_collection":{"name":"Release knowledge","lock_version":2}}
```

Include the original collection version and the `name` or `description` fields
to change. Ownership and the Speaker cannot change.

### Response

`200 {memory_collection: …}` with the current metadata and version.

### Status codes

A stale version is `409 stale_object`; invalid labels are `422 validation_failed`.
See [status codes](#common-status-codes).

## Archive a collection

### Endpoint

`POST …/memory_collections/{public_id}/archive`.

### Request

`{memory_collection: {lock_version: …}}` using the original collection version.

### Response

`200 {memory_collection: …}`. All content paths become read-only.

### Status codes

A stale version is `409 stale_object`. See [status codes](#common-status-codes).

## Restore a collection

### Endpoint

`POST …/memory_collections/{public_id}/restore`.

### Request

`{memory_collection: {lock_version: …}}` using the original collection version.

### Response

`200 {memory_collection: …}`. The same UUID becomes active again.

### Status codes

A stale version is `409 stale_object`. See [status codes](#common-status-codes).

## Delete a collection

### Endpoint

`DELETE …/memory_collections/{public_id}`.

### Request

`{memory_collection: {lock_version: …}}` using the original collection version.

### Response

`204`. Kernel content becomes unavailable immediately; cleanup is bounded.

### Status codes

A stale version is `409 stale_object`. See [status codes](#common-status-codes).

## List documents

### Endpoint

`GET …/memory_collections/{public_id}/documents`.

### Request

The URL fixes the collection. No body is required.

### Response

`200 {memory: [{path, collection_public_id, public_id, lock_version, bytesize,
description, written_at}]}`. `written_at` is the text's age; `description` is
`null` for an ordinary document.

### Status codes

An active Workspace memory provider override returns `409 memory_overridden`.
See [status codes](#common-status-codes).

## Show a document

### Endpoint

`POST …/memory_collections/{public_id}/documents/show`.

### Request

`{memory: {path: "notes.md"}}` with a collection-relative path.

### Response

`200 {memory: …}` with `content` added to the listing shape.

### Status codes

An absent document returns `404 memory_not_found`. See [status codes](#common-status-codes).

## Write a document

### Endpoint

`POST …/memory_collections/{public_id}/documents`.

### Request

```json
{"memory":{"path":"notes.md","content":"The release uses a blue marker.","expected_public_id":null,"expected_lock_version":null}}
```

The full text replaces the document. Use the original document
[conditions](#conditional-writes); a skill also requires `description`.

### Response

`201 {memory: …}` with the full current document.

### Status codes

An occupied absent-path create or changed document returns `409 stale_object`.
See [status codes](#common-status-codes).

## Edit a document

### Endpoint

`POST …/memory_collections/{public_id}/documents/edit`.

### Request

`memory` contains `path`, `old_text`, `new_text` and the two non-null document
conditions. The old passage must occur exactly once.

### Response

`200 {memory: …}` with the full current document.

### Status codes

An empty old passage is `422 memory_edit_invalid`; zero or multiple matches
return `422 memory_edit_not_found` or `memory_edit_ambiguous`.
See [status codes](#common-status-codes).

## Delete a document

### Endpoint

`POST …/memory_collections/{public_id}/documents/delete`.

### Request

`memory` contains `path` and the two non-null document conditions.

### Response

`204`.

### Status codes

A removed, recreated or changed document returns `409 stale_object`.
See [status codes](#common-status-codes).

## Search documents

### Endpoint

`POST …/memory_collections/{public_id}/documents/grep`.

### Request

`{memory: {pattern, path?, ignore_case?, limit?}}`. The optional `path` is a
prefix. Search uses a bounded regular expression; `limit` defaults to 100 and
permits 1–500.

### Response

`200 {matches: [{path, line_number, text}], truncated}`. Returned lines are
capped at 500 characters.

### Status codes

An invalid or over-budget expression returns `422 memory_pattern_invalid` or
`memory_pattern_too_costly`. See [status codes](#common-status-codes).

## Collection metadata

The representation includes `public_id`, `name`, `description`, `scope`,
`owner_public_id`, nullable `speaker_public_id`, `is_default`, `archived_at`,
`lock_version`, `created_at`, `updated_at`, `writable` and `manageable`.
`scope` is derived from the owner. All external identities are UUIDs.

Names need not be unique. `name` accepts up to 128 characters and `description`
up to 1024; either may be `null`.

## Collection lifecycle

| State or command | Effect |
| --- | --- |
| Active | Reads and writes remain subject to owner authority. |
| Archive | Every content path becomes read-only, including already captured executions. It does not cancel work. |
| Restore | The same UUID becomes active. A read-only binding remains read-only. |
| Delete | Subsequent kernel content access closes immediately; document cleanup follows in bounded batches. It does not stop executions using the collection. |

Deletion is terminal. A deleted default retains its identity and cannot be
silently recreated; explicitly create and bind a new non-default collection if
needed. Deletion does not retract already read bytes, sealed requests, retained
answers or independent copies.

## Authorization

| Owner | Read and content write | Metadata and lifecycle management |
| --- | --- | --- |
| Workspace | Existing data access, write standing and dedication rules | Active Human owner |
| Conversation | Existing Conversation and Workspace access; writes require full standing and a writable Workspace | Same full standing and writable Workspace |
| Human | That Human | That Human |
| Agent, including its Speaker collections | The Agent or its authorized named-definition declarer | Same Agent or declarer |

A steward or administrator gains no Agent/Speaker private-content access from
that role. A conversation's permitted context view does not grant global
collection management. Agent execution limits continue to constrain execution
and conversation context access; the collection resource is owner management.

A Conversation collection can be managed while its owner is archived, if its
Workspace and access still permit it. The separate conversation path door
refuses management writes to an archived Conversation. Tombstoned owners are
unavailable; Workspace lifecycle restrictions apply to both doors.

## Collection documents

The URL fixes the collection; paths are relative, such as `notes.md` or
`skills/review-checklist`. They are logical database names, never runner files.
Names are at most 128 characters, start with a lowercase letter or digit, and
then contain only lowercase letters, digits, `_`, `-`, `.`, or `/`.
Each collection permits 64 documents, including skills, and each document
permits 64 KiB of UTF-8 content. A second collection has its own document quota.

## Conditional writes

Every HTTP write, edit and delete requires `expected_public_id` and
`expected_lock_version`. `null`/`null` creates only an absent path. An observed
document UUID and nonnegative version replace or delete only that document.
Edits and deletes require a non-null pair. Missing or malformed conditions
return `400 parameter_missing` or `parameter_invalid`.

The conditions are checked inside the existing owner/collection mutation
transaction. A changed, removed or recreated document, or a create at an
occupied path, returns `409 stale_object` without changing content. Replacements
retain the document UUID and advance its version. Recreation uses a new UUID.

The collection document URL already pins the collection. A
[conversation binding write](conversation-memory.md#conditional-writes) also
requires `expected_collection_public_id`, including creation at an absent path.
Changing the binding cannot redirect an old proposal into its new target.
Never fetch newer conditions and automatically replay an old calculation.

Model-facing memory tools retain their ordinary full-document/exact-edit
semantics and do not take these HTTP version conditions. They do not promise
protection against stale model-generated replacements. Automated proposals
derived from a snapshot should use the snapshot's original conditions here.

## Skills and provider overrides

`skills/<name>` is reserved for skills in User, Agent, Speaker and Workspace
collections. The name uses lowercase letters/digits and single hyphens, up to
64 characters; a nonblank description of at most 1024 bytes is required.
Conversation-owned skills are refused. Ordinary memory cannot carry a skill
description. Model memory mutation tools cannot author reserved skill rows.

A Workspace's `nexus.memory` override blocks ordinary content through both
its own collections and its Conversation collections with `409
memory_overridden`. A collection UUID does not bypass it. Metadata and
lifecycle still manage the kernel collection, while a specifically named
skill path retains kernel handling. User/Agent/Speaker owner resources are
independent of Workspace overrides.

## Common status codes

| Status | Code | Meaning |
| --- | --- | --- |
| `400` | `parameter_missing`, `parameter_invalid` | A required condition or scalar parameter is missing or malformed. |
| `403` | `not_authorized` | The caller can see the resource but cannot perform this mutation. |
| `403` | `memory_read_only` | The collection is archived or the selected binding is read-only. |
| `404` | `not_found`, `memory_not_found` | The collection is unavailable to this caller, or the document is absent. |
| `409` | `stale_object` | The observed collection or document condition no longer matches. |
| `409` | `memory_overridden` | Ordinary content belongs to the Workspace's selected provider. |
| `422` | `memory_full`, `memory_document_too_large`, `memory_content_invalid`, `memory_path_invalid` | Document quota, content or logical-name validation failed. |
| `422` | `skill_scope_unavailable`, `skill_name_invalid`, `skill_description_required`, `memory_description_invalid` | Skill location, name or description validation failed. |
| `422` | `memory_edit_invalid`, `memory_edit_not_found`, `memory_edit_ambiguous` | The old text is empty, absent or occurs more than once. |
| `422` | `memory_pattern_invalid`, `memory_pattern_too_costly` | The regular expression is invalid or exceeds its execution budget. |
| `422` | `memory_scope_unavailable` | The requested Speaker/default operation is unavailable, including a deleted default. |
| `422` | `validation_failed` | Collection name or description validation failed. |

The usual member authentication and rate-limit responses also apply.
