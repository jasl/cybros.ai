---
title: Profile memory
description: "The person's own door to memory's user scope and a paired agent's to its own agent scope, the conditional-write contract every memory door shares, and who may write."
---

# Profile memory

The room's `workspace/` rows are at
[`workspaces/{id}/memory`](workspaces.md#memory) and a conversation's own
at [Conversation memory](conversation-memory.md). The conditional-write
contract below is shared by all three doors.

## Routes

```http
GET /agent_api/v1/profile/memory
POST /agent_api/v1/profile/memory/show
POST /agent_api/v1/profile/memory
POST /agent_api/v1/profile/memory/delete
```

The Human caller's own door to memory's `user/` scope, and an Agent's door
to its own `agent/` scope. `user/` resolves only for the Human acting as
the caller. An Agent never resolves it through its steward and cannot
read or write the steward's documents through this door.

`agent/` is the caller's own row when the caller is a paired agent: the
notes this program carries into every conversation it answers, which its
steward's other agents do not read and which never land in the steward's
`user/`. A Human has no `agent/` rung here, and a named definition's is
its declarer's at [`profile/agents/{name}/memory`](profile-agents.md#memory).
`workspace/` and `conversation/` have their own doors
([Workspaces](workspaces.md#memory),
[Conversations](conversation-memory.md)) and are refused here with
`memory_scope_unavailable`. `speaker/` needs a conversation's explicit
Speaker binding or an execution's captured subject and is unavailable here.

```http
POST /agent_api/v1/profile/memory/grep
POST /agent_api/v1/profile/memory/edit
```

Only `user/…` for a Human or `agent/…` for an Agent resolves at this
door, and **the path rides the body** on every verb that names one,
including the reads — a memory path carries its scope as its first
segment, which no routing convention survives.

- `GET /agent_api/v1/profile/memory` — every document under the caller's
  available profile scope, as `{path, public_id, lock_version, bytesize, description, written_at}`
  (`description` is the skill row's, `null` on a plain document).
  `written_at` is the CONTENT's age.
- `POST /agent_api/v1/profile/memory/show` — `{memory: {path}}` answers
  one document with its `content`.
- `POST /agent_api/v1/profile/memory` — `{memory: {path, content, description?, expected_public_id, expected_lock_version}}`
  writes one document whole. 201.
- `POST /agent_api/v1/profile/memory/grep` — `{memory: {pattern, path?, ignore_case?, limit?}}`;
  200 `{matches: [{path, line_number, text}], truncated}`. It searches only
  the caller's available profile documents, with the bounded regex semantics described
  in [conversation memory](conversation-memory.md#search-documents).
- `POST /agent_api/v1/profile/memory/edit` — `{memory: {path, old_text, new_text,
  expected_public_id, expected_lock_version}}`; 200 `{memory: ...}`. Replaces
  exactly one occurrence under the observed version; stale or ambiguous edits
  leave the document unchanged.
- `POST /agent_api/v1/profile/memory/delete` — `{memory: {path, expected_public_id, expected_lock_version}}`. 204,
  and it is gone: no history, no recycle bin.

A write here bumps no conversation's `context_revision`: the row belongs
to no conversation. A later turn reads it only when its effective bindings
include that anchor.

**Skills.** A document under `user/skills/<name>` or `agent/skills/<name>` is a
SKILL: `name` under the skill grammar (`[a-z0-9]`, single hyphens, ≤ 64 —
stricter than a memory name's, because a model types it back from the
catalog and it must match a directory on a runner byte for byte),
`description` REQUIRED (≤ 1024 bytes — the line the model reads in its
turn's skills block to choose), `content` the markdown body the model reads
when it loads it with the `skill` tool. `description` is refused outside
`skills/`. A model's `memory_write`, `memory_edit` and `memory_delete` never
author a `skills/` row (`memory_reserved_prefix`) — a person or their
program does, through this door. The assembly's memory block never renders
a `skills/` row; `memory_ls` and `memory_read` see it as any document. The
64-document cap per person is shared with plain memory.

## Body and response shapes

```json
{ "memory": { "path": "user/notes.md", "content": "the whole document", "expected_public_id": null, "expected_lock_version": null } }
```

```json
{ "memory": { "path": "user/skills/review-checklist", "content": "# Review\n…", "description": "How I review a change. Use before approving a pull request.", "expected_public_id": null, "expected_lock_version": null } }
```

```json
{ "memory": { "path": "user/notes.md", "public_id": "01995000-0000-7000-8000-000000000001", "lock_version": 0, "bytesize": 18, "description": null, "content": "the whole document", "written_at": "2026-09-08T00:00:00Z" } }
```

The listing entry is the same shape without `content`; `description` is
`null` on a plain document and the skill's line on a `skills/` row.

## Conditional writes

Every write and delete at every memory door requires both
`expected_public_id` and `expected_lock_version` in the `memory` object.
To create an absent path, explicitly send `null` for both. To replace or delete,
copy the UUID and non-negative integer from the document you read or listed.
Deletes require a non-null pair. Missing fields return `400 parameter_missing`;
malformed or half-null pairs return `400 parameter_invalid`.

The scoped path still selects the row; the UUID never selects another scope.
The condition is checked under the existing anchor lock. A changed version,
a deleted row, a recreated row at that path, or an already occupied path with
an absent condition returns `409 stale_object`. Nothing changes: no content
version is allocated or reclaimed, and no conversation context revision advances.
Read again and reconsider the change; do not automatically fetch a newer pair and
replay an old calculation. This is concurrency control, not a replay receipt.

Successful replacements retain `public_id` and advance `lock_version`.
Deletion and recreation produces a new UUID. A conversation fork gives each copied
pointer a new UUID and version zero while sharing its existing immutable content.
The parent's condition cannot mutate the child's independent document.

The kernel's model-facing tools use ordinary document operations without version
arguments: `memory_write(path, content)` creates or replaces the current whole
document, `memory_edit(path, old_text, new_text)` replaces exactly one matching
passage in its current content, and `memory_delete(path)` deletes the current
document. Reads, listings, skill loads, and mutation results omit version metadata.
These tools do not protect a stale model-generated replacement from a newer edit.

Automated work derived from an earlier snapshot must apply its proposal through
this HTTP API using the snapshot's original pair. A conflict requires reconsidering
the proposal, rather than reading a newer pair and blindly replaying the old text.

## Who may write

`user/`: the Human itself. `agent/`: the Agent itself, subject to its
`memory_context_limit`. A limit excluding `agent` makes that root unavailable;
a read-only limit refuses writes with `memory_read_only`. There is no
workspace fence at this door. The bounds are memory's: 64 documents
per anchor row — per person, per agent — and 64 KiB per document.

## HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing, or the document. |
| `201 Created` | — | Written (a replace answers 201 too: a write conditionally replaces the whole document). |
| `204 No Content` | — | Deleted. |
| `400 Bad Request` | `parameter_missing`, `parameter_invalid` | A required condition is missing or malformed. |
| `409 Conflict` | `stale_object` | The selected row/version no longer matches, or an absent path was created. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `404 Not Found` | `memory_not_found` | A read found no document at that path under the caller's scope. |
| `403 Forbidden` | `memory_read_only` | A write through a read-only profile limit. |
| `422 Unprocessable Content` | `memory_path_invalid` | A bare name, or a scope word outside `conversation \| workspace \| user \| agent \| speaker`. |
| `422 Unprocessable Content` | `memory_scope_unavailable` | A path outside the caller's profile scope, or an Agent root excluded by its limit. |
| `422 Unprocessable Content` | `memory_full` | The 65th document under this person. |
| `422 Unprocessable Content` | `memory_document_too_large` | The content exceeds the per-document bound. |
| `422 Unprocessable Content` | `memory_content_invalid` | The content is not a string. |
| `422 Unprocessable Content` | `skill_description_required` | A `skills/` write with no description, or a blank one. |
| `422 Unprocessable Content` | `memory_description_invalid` | A description that is not a string, exceeds 1024 bytes, or is given on a path outside `skills/`. |
| `422 Unprocessable Content` | `skill_name_invalid` | A `skills/` path whose remainder is not a skill name (`skills/`, `skills/a/b`, `skills/PDF`). |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |
