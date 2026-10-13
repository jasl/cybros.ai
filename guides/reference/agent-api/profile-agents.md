---
title: Named agent definitions
description: "The Agent identities a profile declares by name, their scope, and how their application serves them."
---

# Named agent definitions

The named Agent identities a profile declares, each independently addressable
by name. They carry the same configuration grammar as the
profile's own ([Agent configuration](profile-configuration.md)), under
their own scope.

## Routes

```http
GET    /agent_api/v1/profile/agents
PUT    /agent_api/v1/profile/agents/{name}
DELETE /agent_api/v1/profile/agents/{name}
GET    /agent_api/v1/profile/agents/{name}/memory
POST   /agent_api/v1/profile/agents/{name}/memory
POST   /agent_api/v1/profile/agents/{name}/memory/show
POST   /agent_api/v1/profile/agents/{name}/memory/grep
POST   /agent_api/v1/profile/agents/{name}/memory/edit
POST   /agent_api/v1/profile/agents/{name}/memory/delete
```

A named definition is an Agent the caller declares: a member row of kind `agent`
under the caller's steward, addressed like any peer by its `@handle` in
`spawn {agent:}` and `send {agent:}`, carrying its own configuration block
and `system_prompt` slot. It receives no separate credential or executor address.
Its declaring application's address serves its declared application tools,
delegated compaction, questions and approval notices. Runner calls retain their
explicit accepted targets. The named Agent remains the execution principal and
memory owner; the application claims work using its ordinary transport credential
and each task's claim token. Having no bearer, the definition does not connect,
announce or declare definitions of its own.
Pairing stays the human's: a named definition is the paired program's
configuration, answered for by the human who paired that program, listed
and removable on that human's agents page like any stewarded profile.

Shared application serving requires both Agent identities to remain active under
the same Human steward. Removal or a steward transfer closes new claims and
task-operation admission for the definition without revoking the declaring
application's credentials. Reconnection is resolved for future dispatch; an
already addressed task retains its own claim and result ownership. Sharing the
transport does not import the publisher's memory or announced skill documents.
The definition's own memory bindings and explicit Runner skill sources remain
the authorities for its skill catalog.

Four facts beside the ordinary profile columns:

| Fact | Description |
| --- | --- |
| `derived_from_public_id` | The DECLARER — the paired instance whose bearer minted the row. Present on both scopes: the publisher of a `steward` row is its declarer. |
| `scope` | How long it lives. `instance`: the declarer's own — re-declared at every boot, removed with the declarer (its removal cascades), fenced by the dedication fence exactly as its declarer. `steward`: published — persists for the steward's Agents, survives its declarer's removal, and is never dedication-fenced. It is configuration, not a running program; accepted tool calls retain the concrete targets in its frozen declaration. |
| `description` | The one line a spawner chooses it by: one printable line, at most 1024 characters. |
| `system_prompt` | The row's persona as declared, read back whole — `null` when the slot is empty. The declarer edits the row by writing the whole PUT body again, so it reads what it holds. |

The identifier is COMPOSED by the door, for both scopes: `<caller's
agent_identifier>/<name>` (`rho.7f3a9c1e/reviewer`). Because the caller's
own identifier is the prefix, a row is reachable through this door ONLY by
the instance that minted it — a sibling reads it in the listing and never
writes it. The `name` is the row's handle when the word is free in the
account, else `<name>-2`, `-3` … (the kernel's one rule); the answer
carries the handle assigned, and the steward may rename it on the agents
page. `publish` (a scope flip), removal and restore never change the
handle, the public id or the identifier. The kernel never reads the
composition back: the door lists by column, never by prefix.

Agent identifiers are unique across the Account, including named definitions
and removed rows. Reassigning the declaring Agent to another Human does not
reassign its existing definitions. A later PUT returns `409 identifier_taken`
if the composed identifier still belongs to the previous Human; it neither
adopts that row nor creates another row with the same identifier.

- `GET /agent_api/v1/profile/agents` — the caller's own active rows of
  both scopes plus the steward's OTHER published rows (read-only to this
  caller), ordered by display name.
- `PUT /agent_api/v1/profile/agents/{name}` — a WHOLE replacement,
  idempotent: find-or-new by the composed identifier. `201` when minted,
  `200` when replaced or restored (a removed row of that name comes back as
  the SAME row). `scope` may flip on the same row — `instance` → `steward`
  is publishing; the reverse is allowed. A nil or absent `system_prompt`
  deletes the slot.
- `DELETE /agent_api/v1/profile/agents/{name}` — the same reversible
  status flip the human's page performs; the row keeps its identifier and
  handle so a later PUT restores it. `204`.

An optional top-level `create_only: true` changes PUT to create a fresh
definition only. Any existing composed identifier, including a removed row,
returns `409 name_taken` without replacement or restoration. Omission or
`false` retains the replacement behavior above. The field accepts only a JSON
boolean; `null`, strings and numbers return `400 parameter_invalid`. It is
request intent and is not stored or included in the Agent response.

Declaration and removal serialize on the declaring profile. If removal wins
after request authentication, PUT returns `403 not_authorized` and creates or
restores nothing. If declaration wins, removal includes the resulting
instance-scoped definition in its cascade. A restored declarer may declare
again through a newly authorized request; its previous credentials stay revoked.

## Body and response shapes

```json
{
  "scope": "instance",
  "description": "Reviews a diff for defects and reports only what matters; use it after a change lands.",
  "display_name": "reviewer",
  "system_prompt": "You are a code reviewer. …",
  "configuration": {
    "tool_definitions": [ { "type": "function", "function": { "name": "read", "…": "…" } } ],
    "approval_mode": "bypass",
    "approval_rules": null,
    "prompt_mechanism": "default",
    "prompt_template": null,
    "compaction_policy": { "mode": "kernel" },
    "default_model": "openrouter/z-ai/glm-5.3",
    "fallback_models": ["openrouter/moonshotai/kimi-k3"]
  }
}
```

`scope`, `description` and `configuration` are required; `display_name`
(the name when absent) and `system_prompt` are optional. `configuration`
has the same fields as [Agent configuration](profile-configuration.md)
including `lifecycle_hooks`, `memory_context_limit`, `conversation_reach`
and ordered `fallback_models`. `default_model` is judged at declaration;
its selected model precedes the initiator's when the named row answers.
Each execution captures the effective fallback list and selection intent,
then uses the shared [recovery rules](models.md#model-selection-and-recovery).

```json
{
  "agents": [
    {
      "public_id": "01900000-0000-7000-8000-000000000030",
      "handle": "reviewer",
      "kind": "agent",
      "display_name": "reviewer",
      "agent_identifier": "rho.7f3a9c1e/reviewer",
      "steward_public_id": "01900000-0000-7000-8000-000000000003",
      "scope": "instance",
      "name": "reviewer",
      "description": "Reviews a diff for defects and reports only what matters; use it after a change lands.",
      "derived_from_public_id": "01900000-0000-7000-8000-000000000020",
      "system_prompt": "You review diffs. Report defects, nothing else.",
      "configuration": { "tool_definitions": [ "…" ], "approval_mode": "bypass", "approval_rules": null,
                         "prompt_mechanism": "default", "prompt_template": null,
                         "compaction_policy": { "mode": "kernel" }, "lifecycle_hooks": null,
                         "default_model": "openrouter/z-ai/glm-5.3", "fallback_models": [] }
    }
  ]
}
```

A row is the [principals listing](workspaces.md)'s row (`public_id`,
`handle`, `kind`, `display_name`, `agent_identifier`, `steward_public_id`)
plus `scope`, `name`, `description`, `derived_from_public_id`, `system_prompt`
and the `configuration` block as the profile read renders it. `PUT` answers
`{"agent": {…the same row…}}`.

The kernel's model-facing texts are UNCHANGED by this door: `spawn`'s
description, `principal_unknown` (the agents it could have named) and
`answerer_not_eligible` say what they said. A REMOVED named row is still
FOUND by its handle (the resolver is not filtered on status — the cooldown
rule) and answers `answerer_not_eligible`'s sentence; a misspelled one is
`principal_unknown`. What a spawner's model reads about the definitions
is its own program's business (rho renders its roster in the per-turn inline
lead after history).

## Memory

### Endpoints

```http
GET  /agent_api/v1/profile/agents/{name}/memory
POST /agent_api/v1/profile/agents/{name}/memory/show
POST /agent_api/v1/profile/agents/{name}/memory
POST /agent_api/v1/profile/agents/{name}/memory/grep
POST /agent_api/v1/profile/agents/{name}/memory/edit
POST /agent_api/v1/profile/agents/{name}/memory/delete
```

A named definition carries memory of its own: the `agent/` rung, the
documents it reads and writes in every conversation it answers, in every
workspace, which no sibling under the same steward reads and which never
land in the steward's `user/` ([Conversation memory](conversation-memory.md)).
This door is the declarer's management of that rung — the paired program
that minted the row under `<its identifier>/<name>` — with the verbs,
bodies, conditional writes and refusals of every memory door
([Profile memory](profile-memory.md)). The one scope here is `agent/`; a
path of another scope is `422 memory_scope_unavailable`. The named row's
own turns reach the same rows through the memory tools.

The rung lives and goes with the row: a `steward`-scope definition's
documents persist with it, an `instance` definition's go with its
declarer's removal, and a remove-and-restore of the name keeps the same
row and its documents. It is no workspace's, so no provider override
reaches it and no conversation's `context_revision` moves; the next turn
the row answers reads the documents live. `agent/skills/<name>` is a
lawful skill row, resolved after the Agent application's announced
documents and before the room's.

The named definition's `memory_context_limit` applies to this door too.
Excluding `agent` makes its paths unavailable; a read-only `agent` limit
permits reads and refuses writes with `memory_read_only`. This door has no
Speaker subject and does not manage `speaker/` documents.

```json
{ "memory": { "path": "agent/notes.md", "content": "customers prefer short answers", "expected_public_id": null, "expected_lock_version": null } }
```

| Status | Code | Description |
| --- | --- | --- |
| `200 OK`, `201 Created`, `204 No Content` | — | The listing or document, the written document, the deletion — as at every memory door. |
| `403 Forbidden` | `not_agent` | The bearer is a Human: only the declarer manages a definition's rung. |
| `404 Not Found` | `not_found` | No active row of that name minted by this caller; a sibling's published row is not this caller's. |
| `422 Unprocessable Content` | `memory_scope_unavailable` | A path outside `agent/`, or an Agent root excluded by the definition's limit. |
| everything else | | [Profile memory](profile-memory.md#http-response-status-codes)'s table, the conditions and bounds included. |

## HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing; or the row replaced or restored. |
| `201 Created` | — | The row minted. |
| `204 No Content` | — | Removed. |
| `400 Bad Request` | `parameter_missing` | `scope`, `description` or `configuration` absent from the body. |
| `400 Bad Request` | `parameter_invalid` | `create_only` is present and is not a JSON boolean. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `403 Forbidden` | `not_agent` | The bearer is a Human: only an Agent declares definitions. |
| `404 Not Found` | — | The segment is outside the handle grammar (`[a-z0-9][a-z0-9_-]{1,31}`; a dotted or capitalized name is a route miss). |
| `404 Not Found` | `not_found` | `DELETE`: no active row of that name minted by this caller (a sibling's published row is not this caller's to remove). |
| `409 Conflict` | `identifier_taken` | A paired program or another Human's definition holds `<caller identifier>/<name>`, including after the declaring Agent changes steward; nothing is adopted or replaced. |
| `409 Conflict` | `name_taken` | `create_only: true` finds an existing identifier, including a removed definition. |
| `409 Conflict` | `shutdown_pending` | The removed row of that name cannot be restored: the steward's generation moved. |
| `409 Conflict` | `concurrent_write` | The twin first PUT lost on the unique index — one request fails; read it back and retry. |
| `422 Unprocessable Content` | `validation_failed` | `scope` outside `instance \| steward`; `description` blank, not one printable line, or over 1024 characters; the composed identifier over 128; any configuration field's own refusals (`default_model` carries the resolver's word). The message names the field. |
| `422 Unprocessable Content` | `prompt_document_macro_unknown` | The body names a `{{macro}}` outside the registry (the prompt door's word); nothing is written. |
| `422 Unprocessable Content` | `prompt_document_too_large` | The `system_prompt` body exceeds 64 KiB (the prompt door's bound); nothing is written. |
| `422 Unprocessable Content` | `prompt_document_invalid` | `system_prompt` is present but not a string (any other JSON type; an empty string is an empty document, stored); nothing is written. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |
