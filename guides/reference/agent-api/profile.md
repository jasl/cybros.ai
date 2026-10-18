# Agent API Profile

Status: live Agent API resource.

## Own balance or allowance

```http
GET /agent_api/v1/profile/budgets
GET /agent_api/v1/profile/budgets/{public_id}
GET /agent_api/v1/profile/budgets/{budget_public_id}/entries
```

These member-plane reads return the acting Human's balance or acting Agent's
allowance. An Agent never reads its steward's balance. There are no member-plane
budget mutations. The [shared financial read contract](../platform-api/budgets.md#read-windows)
defines current and historical windows, exact headroom, amount-only entries and
keyset pagination. Financial authority never grants activity access.

## Identity and configuration

The profile is the member plane's bootstrap read: a program asks who it is
acting as and what its credential is. It deliberately answers nothing about a
delivery address or client. It exposes no email address, no internal database
id, and no credential material.

For an Agent it also carries the Agent's **standing configuration**
— the tools its model may call and how a turn is assembled — which its
application declares through the writer below and which the kernel reads at
each turn's materialization and freezes per turn onto that turn's rows. The
ordered `fallback_models` list is frozen with the execution; live availability
gates still apply before a candidate sends. An input may instead capture an
[inline declaration](profile-configuration.md#inline-agent-configuration)
at admission without changing the standing profile.

## Get the current profile

### Endpoint

```http
GET /agent_api/v1/profile
```

### Authentication

This endpoint accepts a **member-plane** credential and nothing else. A
transport credential is refused with `401` — an executor learns its own
identity from [Executor](executor.md), never from here. A revoked, expired, or
authority-fenced credential returns `401` on its next request, and the family
never explains which of those it was. For an Agent, the authority check
requires the Agent to be active and `steward_live?` to pass: its same-Account
steward must be active, and its `applied_steward_shutdown_generation` must equal
that steward's current `managed_resource_shutdown_generation`. Human removal therefore fences this
resource even for an Agent that has no executor. Agent convergence removes
the Agent and acknowledges that snapshot. Whenever an Agent becomes removed,
its member access and Agent-application credentials are fenced, and its related
work is force-stopped asynchronously; an independent Runner is unaffected.
Restore keeps the same Agent and does not wait for cleanup, but old credentials
stay invalid. Reconnect supplies fresh credentials for the retained address.
Agents currently have remove/restore, not a separate suspension command.

There are no query or body parameters.

### Response

```json
{
  "member": {
    "public_id": "01900000-0000-7000-8000-000000000001",
    "handle": "lark",
    "kind": "agent",
    "role": "member",
    "display_name": "Notes assistant",
    "agent_identifier": "01900000-0000-7000-8000-000000000010"
  },
  "credential": {
    "plane": "member",
    "expires_at": "2026-08-08T00:00:00Z"
  },
  "configuration": {
    "tool_definitions": [
      { "type": "function", "function": { "name": "bash", "description": "…", "parameters": { "type": "object", "properties": { "command": { "type": "string" } }, "required": ["command"] } } }
    ],
    "approval_mode": "bypass",
    "approval_rules": [
      { "tool": "bash|start_process", "path": "command", "match": "*rm -rf /*", "verdict": "deny" },
      { "tool": "memory_*|ask|delegate_task|skill", "verdict": "allow" }
    ],
    "prompt_mechanism": "default",
    "prompt_template": null,
    "compaction_policy": { "mode": "kernel" },
    "lifecycle_hooks": null,
    "memory_context_limit": null,
    "conversation_reach": null,
    "default_model": "openrouter/z-ai/glm-5.3",
    "fallback_models": ["openrouter/moonshotai/kimi-k3"]
  },
  "measured_at": "2026-07-25T00:00:00Z"
}
```

| Field | Type | Description |
| --- | --- | --- |
| `member.public_id` | UUIDv7 string | Public identifier of the acting member. |
| `member.handle` | string | The member's name beside its identity: 2–32 lowercase ASCII letters, digits, `_` or `-`, starting with a letter or digit, unique per account. A peer writes it as `@handle` on a conversation's access carrier or as `agent:` on `spawn` or `send`. The kernel assigns an agent's from its name table at creation (a numeric suffix past a collision) and its steward may rename it; a Human's defaults from its display name and is the Human's own to change. Never absent, never null; `agent_identifier` stays the program's registration identity. |
| `member.kind` | string | `agent` or `human`. |
| `member.role` | string | Current role. An agent member is always `member`. |
| `member.display_name` | string | Current member name. For an Agent it is program-owned and written by the winning connection; for a Human it is ordinary member data. |
| `member.agent_identifier` | string | The Agent's opaque, non-secret registration identifier; absent for a Human. An API-key client retains this value for later application OAuth login. |
| `credential.plane` | string | Always `member` here — the plane this bearer resolved on. |
| `credential.expires_at` | string or `null` | When this credential expires; `null` for a credential with no expiry. |
| `configuration` | object | The Agent's standing declaration, present only when `member.kind` is `agent`; a Human declares nothing and the block is absent. Every field is `null` (the tool list `[]`) until the profile declares. |
| `configuration.tool_definitions` | array | Explicit tool declarations, canonical by name, in the wire families' own `{type: "function", function: {name, description, parameters}}` shape. Optional top-level `defer_loading` defers schema exposure without changing authority (see below). Kernel tools use [the catalog](runs.md)'s exact schema bytes or an alias declaration, `{name, canonical, params?, omit?, description?, defer_loading?}`. Read-back renders aliases as full function blocks with their resolution facts. Explicit Runner and MCP routes remain valid. `[]` when none are declared. This field retains the authored declaration; it does not read back automatically imported tools. |
| `configuration.kernel_tools` | array | Exact canonical kernel names whose plain definitions Nexus imports, such as `nexus.conversation.spawn` or `nexus.runners.list`. Omitted, null or `[]` imports no plain tools. Explicit kernel declarations and aliases in `tool_definitions` independently enable their tools; this field is not a deny list over those declarations. Duplicate and unknown names, wire aliases and wildcards are invalid. |
| `configuration.runner_executor_public_ids` | array | Ordered, unique Runner UUID candidates declared by this Agent. Only the selected Runner contributes automatic tools. Omitted, null or `[]` declares no candidates. Candidate knowledge survives when no Runner is selected; it is independent of the current tool list. |
| `configuration.runner_tool_names` | array or `null` | Exact served-name allowlist intersected with the selected Runner's ordinary model announcements. Omitted or null imports all ordinary announcements carrying both a model description and input schema; `[]` imports none. Announcements carrying `mcp` source metadata require explicit routes. Names unavailable on the selected Runner contribute no tool. A named Agent uses this field to limit its Runner tool subset. |
| `configuration.mcp_tools` | array | Exact `{connection_public_id, tool_name, name}` selections from the current steward's MCP connections. `name` is the unique callable name; `tool_name` is the remote name. Omitted, null or `[]` imports none. |
| `configuration.approval_mode` | string or `null` | `bypass`, `ask` or `rules` — how the agent's tool calls cross the approval stage ([Run approval](run-approval.md)). Required for explicit tools, nonempty `kernel_tools` or `mcp_tools`, lifecycle hooks, or Runner candidates whose `runner_tool_names` is not `[]`. Candidate knowledge alone need not enable any tools. |
| `configuration.approval_rules` | array or `null` | The rule list — `[{tool, path?, match?, verdict, reason?, origin?}]`, the exact grammar in [Run approval](run-approval.md#the-rule-grammar) — frozen with the mode onto every turn the profile declares for. `null` when none. |
| `configuration.prompt_mechanism` | string or `null` | `raw`, `assembly` or `default`. `default` (the kernel's word when none is declared) is the built-in order — the three prompt-document slots, memory, the skills catalog, history, the inline lead, the inline tail, the input ([Prompt assembly](prompt-assembly.md#the-default-order)); `raw` sends the input's own entries; `assembly` compiles the same blocks in the ORDER `prompt_template` states ([Prompt assembly](prompt-assembly.md#the-assembly-template)). |
| `configuration.prompt_template` | object or `null` | The assembly template — REQUIRED when `prompt_mechanism` is `assembly`, stored unread under any other word: `{ "blocks": [ … ], "variables"?: { name: default } }`, the block grammar in [Prompt assembly](prompt-assembly.md#the-assembly-template), at most 64 KiB. A template outside the grammar is 422 `validation_failed` naming the JSON-pointer path of the fault (`/blocks/3/role`). |
| `configuration.compaction_policy` | object or `null` | `{mode: kernel \| delegate \| off, tool_name?, model?, reasoning_enabled?, reasoning_effort?}` — the shape a round's compaction takes; `delegate` names its `tool_name`. The independent reasoning controls follow [Models](models.md#reasoning-selection). The mid-turn arm prunes while the results outside the keep-recent tail cover the overshoot net of the placeholders each cleared call leaves, and summarizes once they cannot — nothing to configure. |
| `configuration.lifecycle_hooks` | object or `null` | Optional event-to-tool declarations for `turn_start`, `pre_compact`, `post_compact`, and `stop`, frozen onto each execution. See [Lifecycle hooks](../../build/lifecycle-hooks.md) and the declaration grammar below. `null` or `{}` enables none. |
| `configuration.memory_context_limit` | object or `null` | Optional ceiling over selected memory roots and access; [configuration limits](profile-configuration.md#memory-limits-and-conversation-reach) owns its grammar. |
| `configuration.conversation_reach` | string or `null` | `workspace` or `subtree`; null uses ordinary workspace reach. See [configuration limits](profile-configuration.md#memory-limits-and-conversation-reach). |
| `configuration.default_model` | string or `null` | The Agent's declared `provider/model` reference ([Models](models.md)). It is first in the model-selection order for a turn addressed away from the Conversation's default answerer or sent by a peer (`spawn`, `send`), using the selected model's default reasoning setting. When null, Nexus uses the addressee's last reply model in this Conversation, then the Conversation's last reply model, then the submitted initiator model. The default answerer's own ordinary inputs keep their submitted model. Recovery uses the execution’s captured ordered candidates and selection intent. |
| `configuration.fallback_models` | array or `null` | Ordered complete `provider/model` recovery candidates. Null or `[]` declares none. The initial model is independent. Captured with the execution; later declarations do not rewrite accepted work. See [Agent configuration](profile-configuration.md#fallback-models). |
| `configuration.image_model` | string or `null` | Complete `provider/model` reference used by the kernel image tool; captured with the execution and checked for the `image_generation` workload. |
| `measured_at` | string | When the blocks were measured. |

### Renames and the cooldown

A handle is a NAME beside the identity: every persisted
reference is by row, so a rename — the Human's own in settings, the steward's
for an agent — breaks nothing and the rendered history follows the row. The
name a rename leaves enters a **14-day cooldown** in which no other member of
the account may take it (a refusal names the cooldown; the releaser may take
its own name back at once; only the latest released name is reserved, so a
second rename frees the first); a swap of two handles therefore waits out the
cooldown by design. The kernel never redirects an old handle: an unknown `@old`
on an access carrier is `principal_not_eligible`; an input's `to:` returns
`principal_unknown`, like any other unknown address —
a name meaning two people over time is worse for a model than a loud
refusal — and no surface carries the previous handle or a hint toward the
new one (`member` keeps the five fields above). Every rename narrates
`handle_changed {user_public_id, old, new}` on the member's own event rows;
no Agent API route reads a member's rows yet.

### This resource reports no delivery address

An Agent has at most one current logical delivery address. A successful
connection with a non-revoked address has one; a never-connected or terminally
revoked Agent validly has none and is un-askable. Its member credential is
unbound and does not name an address even when one exists. Asking the member
plane for it would be asking one plane to answer another's question, so this
resource simply does not carry it. An Agent connection returns a sibling
executor-transport credential; present that sibling token to
[Executor](executor.md) to read the address. The member token presented here
cannot call Executor, and a Human member token may likewise have no delivery
address at all.

That is also why there is nothing here to poll for a *different* address: a
profile cannot have a second current one. This is a logical-address guarantee,
not physical-device attestation; several processes holding a copied current
credential are indistinguishable and unsupported. To reach this same Agent
from several client locations, expose that access through your application.
Separate installations may instead pair under distinct installation identifiers,
creating distinct Agents and addresses; reconnecting the same identifier
re-pairs its existing logical address.

An Agent also need not receive Tasks at all. A pure conversation or
role-play product may use its member/data authority while leaving the delivery
queue empty; neither this resource nor the existence of an executor address
implies pending Task work.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | Agent returned. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. `Retry-After` is a whole number of seconds. |

## The rest of this resource

| Page | What it owns |
| --- | --- |
| [Agent configuration](profile-configuration.md) | The standing declaration: tools, imports, Runner candidates, models, aliases, approval, lifecycle hooks, memory limits and conversation reach |
| [Named Agents](profile-agents.md) | The persistent Agent identities the caller declares by name |
| [Profile memory](profile-memory.md) | The Human's own `user/` or Agent's own `agent/` scope and the shared conditional-write contract |
| [Profile prompt documents](profile-prompt-documents.md) | The `system_prompt`, `summarizer` and `persona` slots |

## Store entries

### Endpoints

```http
GET    /agent_api/v1/profile/store_entries
POST   /agent_api/v1/profile/store_entries
GET    /agent_api/v1/profile/store_entries/{store_entry_id}
PATCH  /agent_api/v1/profile/store_entries/{store_entry_id}
DELETE /agent_api/v1/profile/store_entries/{store_entry_id}?lock_version=...
```

The principal's own door to the bounded namespaced JSON current-value
store — client state that no prompt ever reads. **Whose:** the ACTING
user's own row. An agent's entries here are the agent's, not its
steward's, and the steward's are the steward's: a store is client-owned
state per principal. Profile memory likewise selects only the caller's own
Human or Agent anchor. There is no workspace fence on a person's own row and another
principal's store is unreachable.

No receipt is kept for the profile store — `Idempotency-Key` is still
required, but a repeat with the same key is `409 key_taken`, never a
replay: the unique index and `lock_version` are the whole convergence
contract. The body, projections, pagination and the full status table are
[Store entries](store-entries.md); the bounds are the store's: 64 entries
per principal, 1 MiB per value.
