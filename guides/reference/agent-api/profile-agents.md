---
title: Named Agents
description: "The Agent identities a profile declares by name, their scope, and how their application serves them."
---

# Named Agents

The named Agent identities a profile declares, each independently addressable
by name. They carry the same configuration grammar as the
profile's own ([Agent configuration](profile-configuration.md)), under
their own scope.

## Routes

```http
GET    /agent_api/v1/profile/agents
PUT    /agent_api/v1/profile/agents/{name}
DELETE /agent_api/v1/profile/agents/{name}
```

A named Agent is a persistent member of kind `agent` declared under the
caller's steward. It can answer Conversations with its own configuration,
`system_prompt` and `summarizer` documents. It receives no separate credential
or executor address.
Its declaring application's address serves its declared application tools,
delegated compaction, questions and approval notices. Runner calls retain their
explicit accepted targets. The named Agent remains the execution principal and
memory owner; the application claims work using its ordinary transport credential
and each task's claim token. Having no bearer, the named Agent does not connect,
announce or declare named Agents of its own. The Human steward manages and
removes it on the Agents page.

Shared application serving requires both Agent identities to remain active under
the same Human steward. Removal or a steward transfer closes new claims and
task-operation admission for the named Agent without revoking the declaring
application's credentials. Reconnection is resolved for future dispatch; an
already addressed task retains its own claim and result ownership. Sharing the
transport does not import the publisher's memory or announced skill documents.
The named Agent's own memory bindings and explicit Runner skill sources remain
the authorities for its skill catalog.

Named-Agent fields beside the ordinary profile columns:

| Fact | Description |
| --- | --- |
| `derived_from_public_id` | The DECLARER — the paired instance whose bearer minted the row. Present on both scopes: the publisher of a `steward` row is its declarer. |
| `scope` | How long it lives. `instance`: the declarer's own — re-declared at every boot, removed with the declarer (its removal cascades), fenced by the dedication fence exactly as its declarer. `steward`: published — persists for the steward's Agents, survives its declarer's removal, and is never dedication-fenced. It is a member identity served by its declaring application; accepted tool calls retain the concrete targets in its frozen declaration. |
| `description` | The description shown when choosing an Agent: one printable line, at most 1024 characters. |
| `system_prompt` | The row's persona as declared, read back whole — `null` when the slot is empty. The declarer edits the row by writing the whole PUT body again, so it reads what it holds. |
| `summarizer` | Optional content-only prompt for kernel compaction, read back as text or `null`. |

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

Agent identifiers are unique across the Account, including named Agents
and removed rows. Reassigning the declaring Agent to another Human does not
reassign its existing named Agents. A later PUT returns `409 identifier_taken`
if the composed identifier still belongs to the previous Human; it neither
adopts that row nor creates another row with the same identifier.

- `GET /agent_api/v1/profile/agents` — the caller's own active rows of
  both scopes plus the steward's OTHER published rows (read-only to this
  caller), ordered by display name.
- `PUT /agent_api/v1/profile/agents/{name}` — a WHOLE replacement,
  idempotent: find-or-new by the composed identifier. `201` when minted,
  `200` when replaced or restored (a removed row of that name comes back as
  the SAME row). `scope` may flip on the same row — `instance` → `steward`
  is publishing; the reverse is allowed. Configuration and both prompt slots
  replace atomically. A null or absent `system_prompt` or `summarizer` deletes
  that slot; an empty string remains an empty document.
- `DELETE /agent_api/v1/profile/agents/{name}` — the same reversible
  status flip the human's page performs; the row keeps its identifier and
  handle so a later PUT restores it. `204`.

An optional top-level `create_only: true` changes PUT to create a fresh
named Agent only. Any existing composed identifier, including a removed row,
returns `409 name_taken` without replacement or restoration. Omission or
`false` retains the replacement behavior above. The field accepts only a JSON
boolean; `null`, strings and numbers return `400 parameter_invalid`. It is
request intent and is not stored or included in the Agent response.

Declaration and removal serialize on the declaring profile. If removal wins
after request authentication, PUT returns `403 not_authorized` and creates or
restores nothing. If declaration wins, removal includes the resulting
instance-scoped named Agent in its cascade. A restored declarer may declare
again through a newly authorized request; its previous credentials stay revoked.

## Body and response shapes

```json
{
  "scope": "instance",
  "description": "Reviews a diff for defects and reports only what matters; use it after a change lands.",
  "display_name": "reviewer",
  "system_prompt": "You are a code reviewer. …",
  "summarizer": "Keep review findings and file references.",
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
(the name when absent), `system_prompt` and `summarizer` are optional. Both
prompt fields accept strings or `null`; the summarizer contains no macros or role.
`configuration`
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
      "summarizer": "Keep review findings and file references.",
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
plus `scope`, `name`, `description`, `derived_from_public_id`, `system_prompt`,
`summarizer` and the `configuration` block as the profile read renders it. `PUT` answers
`{"agent": {…the same row…}}`.

Declaring a named Agent creates or updates its persistent identity; it does
not create a Conversation or start an execution. Select its public UUID as
`answering_user_public_id` when [creating a Conversation](conversations.md#create-a-conversation).
An [input](conversation-input-fields.md#answering_user_public_id) can select
that identity by UUID or `@handle` for its reply without changing the
Conversation's default answerer. Workspace and Conversation eligibility still
apply. On input resolution, an unknown address returns `principal_unknown`;
a removed or otherwise ineligible Agent returns `answerer_not_eligible`.

Registering a named Agent does not publish a Subagent role. A captured
[delegation catalog](profile-configuration.md#delegation-catalog) selects
configuration for temporary execution under the caller's existing principal.
Where the [generic spawn contract](run-orchestration.md#spawn) permits an Agent
selector, it selects an existing identity as the child Conversation's answerer;
the named Agent retains its identity and its own Agent memory across Conversations.

## Memory

A named Agent owns its Agent-private collections and its Agent/Speaker
collections. Its authorized declaring application uses the
[owner-scoped collection endpoints](memory-collections.md#routes) to discover and create them.

Supply `speaker_public_id` when creating a collection for one Speaker. The
same Speaker under another Agent has separate collections. The Human steward
and sibling Agents do not gain private content access from that relationship.
An inactive, foreign or no-longer-managed named identity is unavailable here.

Subsequent operations use [collection UUIDs](memory-collections.md) and relative
document paths. Lists are paginated; `default=true` selects the Agent's own
default, with an optional Speaker UUID to select that pair's default. Reads
never initialize it. An explicit Agent/Speaker default create cannot replace
a deleted identity.

These are owner-management resources. Execution and conversation context
access remain constrained by the selected `memory_context_limit`. Collection
ownership persists with the named Agent across conversations and Workspaces;
remove/restore preserves its data. Workspace provider overrides do not govern
this independent owner resource.

## HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing; or the row replaced or restored. |
| `201 Created` | — | The row minted. |
| `204 No Content` | — | Removed. |
| `400 Bad Request` | `parameter_missing` | `scope`, `description` or `configuration` absent from the body. |
| `400 Bad Request` | `parameter_invalid` | `create_only` is present and is not a JSON boolean. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `403 Forbidden` | `not_agent` | The bearer is a Human: only an Agent declares named Agents. |
| `404 Not Found` | — | The segment is outside the handle grammar (`[a-z0-9][a-z0-9_-]{1,31}`; a dotted or capitalized name is a route miss). |
| `404 Not Found` | `not_found` | `DELETE`: no active row of that name minted by this caller (a sibling's published row is not this caller's to remove). |
| `409 Conflict` | `identifier_taken` | A paired program or another Human's named Agent holds `<caller identifier>/<name>`, including after the declaring Agent changes steward; nothing is adopted or replaced. |
| `409 Conflict` | `name_taken` | `create_only: true` finds an existing identifier, including a removed named Agent. |
| `409 Conflict` | `shutdown_pending` | The removed row of that name cannot be restored: the steward's generation moved. |
| `409 Conflict` | `concurrent_write` | The twin first PUT lost on the unique index — one request fails; read it back and retry. |
| `422 Unprocessable Content` | `validation_failed` | `scope` outside `instance \| steward`; `description` blank, not one printable line, or over 1024 characters; the composed identifier over 128; any configuration field's own refusals (`default_model` carries the resolver's word). The message names the field. |
| `422 Unprocessable Content` | `prompt_document_macro_unknown` | The body names a `{{macro}}` outside the registry (the prompt door's word); nothing is written. |
| `422 Unprocessable Content` | `prompt_document_too_large` | The `system_prompt` body exceeds 64 KiB (the prompt door's bound); nothing is written. |
| `422 Unprocessable Content` | `prompt_document_invalid` | `system_prompt` is present but not a string (any other JSON type; an empty string is an empty document, stored); nothing is written. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |
