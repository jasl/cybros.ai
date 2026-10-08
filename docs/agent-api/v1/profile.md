# Agent API Profile

Status: live Agent API resource.

The profile is the member plane's bootstrap read: a program asks who it is
acting as and what its credential is. It deliberately answers nothing about a
delivery address or client. It exposes no email address, no internal database
id, and no credential material.

For an Agent it also carries the profile's **standing configuration**
— the tools its model may call and how a turn is assembled — which the profile
itself declares through the one writer below and which the kernel reads at
each turn's materialization and freezes per turn onto that turn's rows. The
`fallback_model` is the exception: the kernel reads it live when considering
an eligible fallback, as described below.

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
resource even for a Agent that has no executor. Agent convergence removes
the Agent and acknowledges that snapshot. Whenever a Agent becomes removed,
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
    "display_name": "Notes assistant"
  },
  "credential": {
    "plane": "member",
    "expires_at": "2026-08-08T00:00:00Z"
  },
  "configuration": {
    "tool_definitions": [
      { "type": "function", "function": { "name": "bash", "description": "…", "parameters": { … } } }
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
    "default_model": "openrouter/z-ai/glm-5.3",
    "fallback_model": "openrouter/moonshotai/kimi-k3"
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
| `credential.plane` | string | Always `member` here — the plane this bearer resolved on. |
| `credential.expires_at` | string or `null` | When this credential expires; `null` for a credential with no expiry. |
| `configuration` | object | The Agent's standing declaration, present only when `member.kind` is `agent`; a Human declares nothing and the block is absent. Every field is `null` (the tool list `[]`) until the profile declares. |
| `configuration.tool_definitions` | array | Explicit tool declarations, canonical by name, in the wire families' own `{type: "function", function: {name, description, parameters}}` shape. Optional top-level `defer_loading` defers schema exposure without changing authority (see below). Kernel tools use [the catalog](runs.md)'s exact schema bytes or an alias declaration, `{name, canonical, params?, omit?, description?, defer_loading?}`. Read-back renders aliases as full function blocks with their resolution facts. Explicit Runner routes remain valid. `[]` when none are declared. This field retains the authored declaration; it does not read back automatically imported tools. |
| `configuration.kernel_tools` | array | Exact canonical kernel names whose plain definitions Nexus imports, such as `nexus.conversation.spawn` or `nexus.runners.list`. Omitted, null or `[]` imports no plain tools. Explicit kernel declarations and aliases in `tool_definitions` independently enable their tools; this field is not a deny list over those declarations. Duplicate and unknown names, wire aliases and wildcards are invalid. |
| `configuration.runner_executor_public_ids` | array | Ordered, unique Runner UUID candidates declared by this Agent. Only the selected Runner contributes automatic tools. Omitted, null or `[]` declares no candidates. Candidate knowledge survives when no Runner is selected; it is independent of the current tool list. |
| `configuration.runner_tool_names` | array or `null` | Exact served-name allowlist intersected with the selected Runner's model announcements. Omitted or null imports all announcements carrying both a model description and input schema; `[]` imports none. Names unavailable on the selected Runner contribute no tool. A named definition uses this field to limit its Runner tool subset. |
| `configuration.approval_mode` | string or `null` | `bypass`, `ask` or `rules` — how the agent's tool calls cross the approval stage ([Runs](runs.md) "Approval"). Required for explicit tools, nonempty `kernel_tools`, lifecycle hooks, or Runner candidates whose `runner_tool_names` is not `[]`. Candidate knowledge alone need not enable any tools. |
| `configuration.approval_rules` | array or `null` | The rule list — `[{tool, path?, match?, verdict, reason?, origin?}]`, the exact grammar in [Runs](runs.md) "Approval" — frozen with the mode onto every turn the profile declares for. `null` when none. |
| `configuration.prompt_mechanism` | string or `null` | `raw`, `assembly` or `default`. `default` (the kernel's word when none is declared) is the built-in order — the three prompt-document slots, memory, the skills catalog, history, the inline lead, the inline tail, the input ([Conversations](conversations.md#the-default-template--the-slots-memory-your-text-history)); `raw` sends the input's own entries; `assembly` compiles the same blocks in the ORDER `prompt_template` states ([Conversations](conversations.md#the-assembly-template--your-own-order)). |
| `configuration.prompt_template` | object or `null` | The assembly template — REQUIRED when `prompt_mechanism` is `assembly`, stored unread under any other word: `{ "blocks": [ … ], "variables"?: { name: default } }`, the block grammar in [Conversations](conversations.md#the-assembly-template--your-own-order), at most 64 KiB. A template outside the grammar is 422 `validation_failed` naming the JSON-pointer path of the fault (`/blocks/3/role`). |
| `configuration.compaction_policy` | object or `null` | `{mode: kernel \| delegate \| off, tool_name?, model?, reasoning_enabled?, reasoning_effort?}` — the shape a round's compaction takes; `delegate` names its `tool_name`. The independent reasoning controls follow [Models](models.md#reasoning-selection). The mid-turn arm prunes while the results outside the keep-recent tail cover the overshoot net of the placeholders each cleared call leaves, and summarizes once they cannot — nothing to configure. |
| `configuration.lifecycle_hooks` | object or `null` | Optional event-to-tool declarations for `turn_start`, `pre_compact`, `post_compact`, and `stop`, frozen onto each execution. See [Lifecycle hooks](../../lifecycle-hooks.md) and the declaration grammar below. `null` or `{}` enables none. |
| `configuration.default_model` | string or `null` | The Agent's declared `provider/model` reference ([Models](models.md)). It is first in the model-selection order for a turn addressed away from the Conversation's default answerer or sent by a peer (`spawn`, `send`), using the selected model's default reasoning setting. When null, Nexus uses the addressee's last reply model in this Conversation, then the Conversation's last reply model, then the submitted initiator model. The default answerer's own ordinary inputs keep their submitted model. Result-mail recovery has the separate bounded fallback described in [Conversations](conversations.md). |
| `configuration.fallback_model` | string or `null` | The model a step this profile answers — or a inference request it creates — re-runs on ONCE when a provider's classifier declined it, or the provider was overloaded on every attempt of its budget — a catalog ref `provider/model` judged as `default_model` is and allowed to equal it. `null` declares none, and a declined step then fails `model_refused`, an overloaded one `provider_overloaded`. Read live from the answering profile at the moment of the switch. See [Declare the configuration](#declare-the-configuration). |
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

## Declare the configuration

### Endpoint

```http
PUT /agent_api/v1/profile/configuration
```

The Agent replaces its `configuration` block and its own
`system_prompt` and `summarizer` documents in one transaction. Nexus assembles
the accepted tool set from these explicit declarations, selected plain kernel
tools and the selected Runner's announced model schemas.

### Body

```json
{
  "configuration": {
    "tool_definitions": [
      { "type": "function", "function": { "name": "bash", "description": "…", "parameters": { … } } }
    ],
    "approval_mode": "bypass",
    "approval_rules": [
      { "tool": "bash|start_process", "path": "command", "match": "*rm -rf /*", "verdict": "deny" }
    ],
    "prompt_mechanism": "default",
    "prompt_template": null,
    "compaction_policy": { "mode": "kernel" },
    "lifecycle_hooks": {
      "stop": { "tool": "review_completion", "timeout_ms": 30000, "max_continuations": 2 }
    },
    "default_model": "openrouter/z-ai/glm-5.3",
    "fallback_model": "openrouter/moonshotai/kimi-k3"
  },
  "prompt_documents": {
    "system_prompt": { "content": "You are {{agent}}.", "role": "developer" },
    "summarizer": { "content": "Preserve decisions and pointers to results." }
  }
}
```

`PUT` is a **whole replacement**, not a merge: the tool list is a set at the
front of every cached prefix, and a merged set is a different prefix. A field
omitted from the body clears. An empty `tool_definitions` list declares no
explicit tools; the import fields remain independent. The `configuration` root is required; the fields inside it are each
optional. The sibling `prompt_documents` root replaces the Agent's two
owned slots. An omitted, null or empty-object root clears both; an omitted or null slot
clears that slot. An object uses the existing prompt-document shape
`{content, role?}`. Empty `content` stores an empty document. Role omission
uses `system`; `summarizer` remains content-only and permits only that role.
The `configuration` root must be an object; non-null `prompt_documents`
roots and slot values must also be objects. Other shapes return
`400 parameter_missing` without changing the declaration.
An empty slot object reaches the ordinary missing-content validation refusal.
Unknown slots and fields are ignored under the ordinary parameter contract.

Configuration, both documents and their validation form one atomic write.
The template's variable names and the replacement `system_prompt` are
validated together, so a variable can be renamed without an intermediate
invalid declaration. A refused configuration or either document changes
nothing, including document versions. Successful replacements retain the
document and advance its version through the same writer as individual
slot edits. This complete PUT and individual slot writes serialize on the
Agent; a later individual edit uses the then-current template. Repeating
the complete declaration converges on the same contents, but a document
rewrite still advances its version; this is not a stored-response replay.

The existing [prompt-document doors](#prompt-documents--the-acting-users-own-slots)
still read and independently edit individual documents. The complete Agent
response carries its configuration; document text remains on those existing
read doors. Named definitions retain their independent
`PUT /profile/agents/{name}` commands and are not included in this transaction.

`tool_definitions` and `compaction_policy` use their declared JSON grammars,
validated by the model: the tool list is a list of declaration objects (empty
declares none) under the 1 MiB canonical-JSON `tool_definitions_bound` and obeys the kernel-name rule a task's
`tools` obeys — a live kernel tool must be declared in the exact bytes
[the catalog](runs.md) serves or through the existing compact alias grammar.
The list is stored canonical by
name. This bound covers an aggregate of tools from several authorities or Runners;
the 1 MiB bounds on a whole step payload and frozen execution context still apply.
`compaction_policy` takes exactly the shape a task's `compaction`
takes and remains under the 64 KiB envelope bound. `default_model` is judged at declaration by the one check
the drain makes of a reply head — a complete `provider/model` this account may
run under its policies and credentials — and a ref that fails is 422
`validation_failed` naming the field with the resolver's word (`unknown_model`,
`unknown_provider`, `provider_disabled`, `model_hidden`, `missing_credential`, …), never stored
to park every addressed turn; a selector (`model_selector:…`) or a bare word is
`unknown_model` — the fact names one model, never a policy.

Function declarations accept nested `{type: "function", function: {...}}` and
flat `{type: "function", name, description, parameters}` forms with the same
semantics. An omitted `strict` defaults to `false` on the provider request, so
fields absent from the schema's `required` list remain optional. Explicit
`strict: true` or `false` is preserved; a strict declaration must satisfy the
chosen provider's schema requirements. This wire default does not rewrite the
stored declaration or its parameter schema. Alias resolution metadata is removed
from the provider request, and non-function tools keep their own wire fields.

A declaration may add top-level `defer_loading: true` or `false`; omission means
eager exposure. This annotation is stored with the full schema and stripped from
provider serialization. When the selected frozen declaration includes eager
`nexus.tools.search` and `nexus.tools.call` (plain names or aliases), deferred
schemas are omitted from the provider's tool list. The model discovers their
exact schemas using `tool_search`, then invokes the exact callable through
`tool_call` or an application's code bridge. This is a provider-independent
Nexus mechanism, not a provider-native `defer_loading` wire field. The frozen
authorized set, parameter schemas and target routes remain unchanged.

If narrowing leaves either search or call absent or deferred, all selected
schemas are exposed directly. Thus `tool_names: ["read"]` still offers `read`,
and `tool_names: []` still authorizes nothing. No wrapper is implicitly added to
the declaration. A guessed callable already in the frozen authorized set can
still execute; deferral is not a permission boundary. A non-boolean annotation
is invalid. Kernel schema equality ignores this presentation annotation only.

Runner function declarations add a top-level `route: {kind: "runner",
runner_executor_public_id: UUID, tool_name: "served name"}` beside `function`.
The callable name is authored and unique across this declaration, even when two
Runners serve the same execution name. Each keeps its own exact description and
parameter schema. Model declarations require a concrete UUID; omitted targets
are only allowed on member-authored Runner tool steps. Routing metadata is
removed before provider serialization. `invalid_tool_route` refuses malformed
routes, and `runner_target_required` refuses a routed declaration without a UUID.
The configuration can be declared before the target is currently usable; target
eligibility and the served capability are checked when an execution accepts it.

At acceptance, Nexus combines the explicit declarations, `kernel_tools` plain
definitions and the selected Runner's model tool announcements. A selected Runner
must be in `runner_executor_public_ids` and currently eligible for the answerer;
connection presence is not an eligibility condition. A missing selection imports
no Runner tools. `runner_tool_names` is an exact-name allowlist: only matching
model announcements from that selected Runner are imported. Unavailable names
and operator-only announcements contribute no tool, and no other candidate's
tools are imported to fill them. An explicit concrete route to an unserved tool
still refuses with `tool_not_served`; an input's `tool_names` requesting a callable
absent from the assembled declaration refuses with `tool_not_declared`. Imported
descriptions and parameter schemas are copied exactly and carry an explicit UUID
route.

Imported Runner tools normally retain their served names. A name colliding with
an explicit callable or kernel name receives a stable target-qualified callable:
the first 49 characters, `__`, and 12 SHA-256 hex characters derived from the full
Runner UUID, a NUL separator, and served name. The route retains the original
served name. A remaining duplicate is refused, never overwritten. Imported Runner
schemas are deferred; the ordinary missing-search/call rule exposes them directly
when discovery is unavailable. Plain kernel imports and explicit aliases can
coexist, and the existing alias renderer resolves macros against the final set.

The accepted definitions, selected environment and ordered eligible candidate
facts are frozen together. Later profile changes, announcements and default
preferences affect future work. The optional `nexus.runners.list` tool reads that
frozen candidate list and current Runner; it neither imports tools nor changes
accepted work. A model chooses another environment by passing its UUID to `spawn`;
omission inherits the spawning execution's frozen selection and null chooses no
Runner. Delegate tasks and child operations inherit their accepted tool surface.

`fallback_model` is judged the same way, and may equal `default_model` (a run
on another model then falls back to the profile's own). It is the model the
kernel re-runs a run's model step on — a mainline round, a composed member, a
`delegate_task` branch, whatever model its author named — ONCE when a provider's
classifier DECLINED it (`finish_quality: refused`) or the provider was
OVERLOADED on every attempt the step's budget spent (HTTP 503 or 529, or
Anthropic's streamed `overloaded_error`, each time — the step fails
`provider_overloaded`; a budget spent on anything else among those answers
stays `attempt_budget_spent`). Never for an unavailable model, a rate limit
(which waits out the lane's floor and retries within the budget), a
transport or request error (an unavailable model on an ordinary turn still
fails; a result-mail run keeps its `default_model` switch, which also
takes an overload no fallback answered), and never for a content block
(`finish_quality: blocked`), which is not re-sent to any model. The kernel
reads it live from the step's ANSWERING profile at the moment of the
refusal or overload — the turn's answerer, or a standalone run's creator
— resolves it against the step's own request, and requeues the step on it,
narrating `model_change {from, to, reason: model_refused | provider_overloaded, category?}`; a
fallback the account cannot run at that moment, one equal to the model
that failed, or one that needs the tool run's reasoning back
(DeepSeek with tools, Kimi K3) when a tool round after the step's last user
message is one it did not produce, leaves the step standing, named in its error. The
switched round keeps the fallback for the rest of its turn, but work it
STARTS — a composed member, a `delegate_task` delegate, the model a spawn or send
names by default — begins on the model its lineage was configured with. A
TOOL-LESS reply the profile answers has no step to requeue: the kernel
re-asks it instead as its own regeneration, a `source: "fallback"`
candidate beside the declined one, the Turn running throughout
([Conversations](conversations.md), "Tail content verbs"). An InferenceRequest the
profile creates runs once more on it the same way, as the run's second
execution ([InferenceRequests](inference-requests.md), "The creator's declared fallback"). A
step re-runs on a fallback once: a refusal or overload of the fallback stands, and
neither a person's retry nor a later declaration re-arms it. A re-declaration
that omits the field removes the fallback from every run in flight.
Anthropic's recommended fallback for an Anthropic refusal is another Claude
model — its safeguards are calibrated per model and per category, so the
same request usually gets an answer there ([Refusals and
fallback](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback)).
A model of another vendor is the declarer's choice: it moves the request
outside that calibration and carries the refused request's WHOLE context —
tool results included — to the other vendor, under its enforcement and
retention rules. Recurring `bio` or `cyber` refusals on legitimate work
belong to the vendor's verification programs; a `reasoning_extraction`
refusal is fixed in the prompt (do not ask the model to reproduce its
reasoning), and the round's `refusal_category` is where to see which.

THE ALIAS is the one other way to declare a kernel tool: an entry carrying
`canonical` — `{"name": "Agent", "canonical": "nexus.graph.delegate_task", "params":
{"run_in_background": {"maps_to": "wait", "invert": true, "description": "…"}}}`
— is the agent's own SPELLING of it (`name` flat or under `function`, the
compact input). `params` maps each of the alias's parameter names onto a kernel
parameter (`maps_to`), negating a boolean when `invert` is set (an inverted
parameter needs its own `description`: the kernel's sentence is wrong under
inversion); `omit` names kernel parameters the alias never exposes; `description`
replaces the kernel's text. Descriptions carry tool-name MACROS — `{{delegate_task}}`,
`{{ask}}`, `{{memory_write}}` — that the kernel renders with the
profile's own spellings at declaration: the stored bytes are the profile's
RENDER (the alias as a full function block with its facts beside it; every plain
kernel entry re-spelled with the same declared names), and a profile that
declares no alias holds the catalog's bytes exactly.
The compact shape may retain the same kernel name and canonical, for example
`{"type":"function","function":{"name":"skill"},"canonical":"nexus.skill.load","defer_loading":true}`.
This explicitly selects presentation without copying the kernel schema. A
reserved name may never point to another canonical. An identity declaration
takes precedence over an automatic plain import with the same callable name.
The canonical stays the kernel's: routing, the reserved namespaces and the
override rules never see an alias; a call the model makes under the alias runs
under the kernel's wire name, its parameters mapped, and the record keeps the
alias beside it (the transcript's `calls[].name` / `tool`, the inbox row's
`tool_alias`). Several spellings of one canonical, the plain name among them, are
lawful; the refusals, each a `validation_failed` naming the word:
`alias_canonical_unknown` (not a live kernel tool), `alias_name_reserved` (a
reserved kernel spelling points to a different canonical — a kernel name is never re-pointed),
`duplicate_tool_name` (two entries, any kind, on one name), `alias_param_unknown`
(`maps_to` or `omit` names no kernel parameter, or an alias parameter shadows one
the alias keeps), `alias_invert_needs_boolean`, `alias_param_description_required`.
A declaration under other spellings moves the prefix, as any re-declaration
does: the bytes are per profile, and a provider's cache is keyed on bytes.

A running turn keeps the bytes it froze; the new declaration reaches the next
turn's materialization.

`lifecycle_hooks` is an object under the same 64 KiB envelope bound. Its only
event names are `turn_start`, `pre_compact`, `post_compact`, and `stop`. Each
entry requires `tool` and `timeout_ms`; `stop` also requires
`max_continuations`. The tool is a nonempty executor tool name of at most 128
bytes, without NUL, and cannot be a reserved kernel tool name. The timeout is
an integer from 1 through 300000 milliseconds. `max_continuations` is an
integer from 0 through 20; zero allows the Stop hook to accept completion but
never request another model round. Unknown events or entry fields are invalid.

A hook tool must be served by an eligible executor through the ordinary
announcement and inbox protocol. It need not appear in `tool_definitions`:
declaring a hook does not expose it for the model to call. An `approval_mode`
is required even when hooks are the profile's only tools. Hook tasks are
kernel-authored and follow the approval rules for that origin. Failed hooks
use the existing attention and repair flow; user force-stop bypasses them.
The [lifecycle hook manual](../../lifecycle-hooks.md) describes event ordering
and the bounded Stop continuation protocol. These settings are also available
on named definitions below.

### Response

`200` with the profile, exactly as `GET /agent_api/v1/profile` now reads it.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | Declared; the profile is returned. |
| `400 Bad Request` | `parameter_missing` | The `configuration` root is absent or not an object, or a non-null `prompt_documents` root or owned slot is not an object. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `403 Forbidden` | `not_agent` | A Human member has no declaration to write. |
| `403 Forbidden` | `not_authorized` | The Agent is no longer eligible when its declaration lock is acquired. |
| `422 Unprocessable Content` | `validation_failed` | A word outside a vocabulary, a missing approval mode on a profile declaring tools or hooks, a malformed rule (a seventh key, a missing tool, a verdict or origin outside its three words, a `match` without a `path`, a glob that does not compile), a malformed or over-bound tool list, rule list, policy, lifecycle hook declaration or template, `assembly` without a `prompt_template`, a template outside the grammar (the message names its path), or a `default_model` or `fallback_model` this account may not run (the message carries the resolver's word). The message names the field. |
| `422 Unprocessable Content` | `prompt_document_invalid`, `prompt_document_too_large`, `prompt_document_macro_unknown` | Either replacement document fails the existing slot validation; configuration and both slots remain unchanged. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |

## Named definitions — the profile's own sub-agents

### Endpoints

```http
GET    /agent_api/v1/profile/agents
PUT    /agent_api/v1/profile/agents/{name}
DELETE /agent_api/v1/profile/agents/{name}
```

A NAMED DEFINITION is an Agent the caller MINTS as its own
sub-agent: a member row of kind `agent`
under the caller's steward, addressed like any peer by its `@handle` in
`spawn {agent:}` and `send {agent:}`, carrying its own configuration block
and `system_prompt` slot — and NOTHING a pairing mints: no credential, no
executor address. It ANSWERS conversations (its runner calls are served
by the runner the spawned child inherits) and never claims, announces or
connects; having no bearer, it never declares definitions of its own.
Pairing stays the human's: a named definition is the paired program's
configuration, answered for by the human who paired that program, listed
and removable on that human's agents page like any stewarded profile.

Three facts beside the ordinary profile columns:

| Fact | Description |
| --- | --- |
| `derived_from_public_id` | The DECLARER — the paired instance whose bearer minted the row. Present on both scopes: the publisher of a `steward` row is its declarer. |
| `scope` | How long it lives. `instance`: the declarer's own — re-declared at every boot, removed with the declarer (its removal cascades), fenced by the dedication fence exactly as its declarer. `steward`: published — persists for the steward's Agents, survives its declarer's removal, and is never dedication-fenced. It is configuration, not a running program; accepted tool calls retain the concrete targets in its frozen declaration. |
| `description` | The one line a spawner chooses it by: one printable line, at most 1024 characters. |

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

Declaration and removal serialize on the declaring profile. If removal wins
after request authentication, PUT returns `403 not_authorized` and creates or
restores nothing. If declaration wins, removal includes the resulting
instance-scoped definition in its cascade. A restored declarer may declare
again through a newly authorized request; its previous credentials stay revoked.

### Body and response shapes

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
    "fallback_model": "openrouter/moonshotai/kimi-k3"
  }
}
```

`scope`, `description` and `configuration` are required; `display_name`
(the name when absent) and `system_prompt` are optional. `configuration`
has the same fields as [Declare the configuration](#declare-the-configuration)
including `lifecycle_hooks` — the same writer and refusals; `default_model` is
judged at declaration (the named row answers on it before the
initiator's model), and so is `fallback_model` (a step the named row answers
re-runs on it once when declined or overloaded).

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
      "configuration": { "tool_definitions": [ "…" ], "approval_mode": "bypass", "approval_rules": null,
                         "prompt_mechanism": "default", "prompt_template": null,
                         "compaction_policy": { "mode": "kernel" }, "lifecycle_hooks": null,
                         "default_model": "openrouter/z-ai/glm-5.3", "fallback_model": null }
    }
  ]
}
```

A row is the [principals listing](workspaces.md)'s row (`public_id`,
`handle`, `kind`, `display_name`, `agent_identifier`, `steward_public_id`)
plus `scope`, `name`, `description`, `derived_from_public_id` and the
`configuration` block as the profile read renders it. `PUT` answers
`{"agent": {…the same row…}}`.

The kernel's model-facing texts are UNCHANGED by this door: `spawn`'s
description, `principal_unknown` (the agents it could have named) and
`answerer_not_eligible` say what they said. A REMOVED named row is still
FOUND by its handle (the resolver is not filtered on status — the cooldown
rule) and answers `answerer_not_eligible`'s sentence; a misspelled one is
`principal_unknown`. What a spawner's model reads about the definitions
is its own program's business (rho renders its roster in the per-turn inline
lead after history).

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing; or the row replaced or restored. |
| `201 Created` | — | The row minted. |
| `204 No Content` | — | Removed. |
| `400 Bad Request` | `parameter_missing` | `scope`, `description` or `configuration` absent from the body. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `403 Forbidden` | `not_agent` | The bearer is a Human: only an Agent declares definitions. |
| `404 Not Found` | — | The segment is outside the handle grammar (`[a-z0-9][a-z0-9_-]{1,31}`; a dotted or capitalized name is a route miss). |
| `404 Not Found` | `not_found` | `DELETE`: no active row of that name minted by this caller (a sibling's published row is not this caller's to remove). |
| `409 Conflict` | `identifier_taken` | A paired program or another Human's definition holds `<caller identifier>/<name>`, including after the declaring Agent changes steward; nothing is adopted or replaced. |
| `409 Conflict` | `shutdown_pending` | The removed row of that name cannot be restored: the steward's generation moved. |
| `409 Conflict` | `concurrent_write` | The twin first PUT lost on the unique index — one request fails; read it back and retry. |
| `422 Unprocessable Content` | `validation_failed` | `scope` outside `instance \| steward`; `description` blank, not one printable line, or over 1024 characters; the composed identifier over 128; any configuration field's own refusals (`default_model` carries the resolver's word). The message names the field. |
| `422 Unprocessable Content` | `prompt_document_macro_unknown` | The body names a `{{macro}}` outside the registry (the prompt door's word); nothing is written. |
| `422 Unprocessable Content` | `prompt_document_too_large` | The `system_prompt` body exceeds 64 KiB (the prompt door's bound); nothing is written. |
| `422 Unprocessable Content` | `prompt_document_invalid` | `system_prompt` is present but not a string (any other JSON type; an empty string is an empty document, stored); nothing is written. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |

## Memory — the person's own scope

### Endpoints

```http
GET /agent_api/v1/profile/memory
POST /agent_api/v1/profile/memory/show
POST /agent_api/v1/profile/memory
POST /agent_api/v1/profile/memory/delete
```

The person's own door to memory's `user/` scope. The scope follows the
acting user's **controlling Human** — an agent's steward, a Human itself —
so an agent writes its steward's notes here and reads them back from any
workspace, and the person reads what every agent they steward wrote. A
member of another Human's circle finds nothing under the same path: the
scope is theirs, not this one's. `workspace/` and `conversation/` have
their own doors ([Workspaces](workspaces.md#memory--the-rooms-own-rows),
[Conversations](conversations.md#memory--durable-scoped-and-on-this-plane-injected-rather-than-fetched))
and are refused here with `memory_scope_unavailable`.

```http
POST /agent_api/v1/profile/memory/grep
POST /agent_api/v1/profile/memory/edit
```

Only `user/…` paths resolve at this door, and **the path rides the body**
on every verb that names one, including the reads — a memory path carries
its scope as its first segment, which no routing convention survives.

- `GET /agent_api/v1/profile/memory` — every document under the caller's
  `user/` scope, as `{path, public_id, lock_version, bytesize, description, written_at}`
  (`description` is the skill row's, `null` on a plain document).
  `written_at` is the CONTENT's age.
- `POST /agent_api/v1/profile/memory/show` — `{memory: {path}}` answers
  one document with its `content`.
- `POST /agent_api/v1/profile/memory` — `{memory: {path, content, description?, expected_public_id, expected_lock_version}}`
  writes one document whole. 201.
- `POST /agent_api/v1/profile/memory/grep` — `{memory: {pattern, path?, ignore_case?, limit?}}`;
  200 `{matches: [{path, line_number, text}], truncated}`. It searches only
  this person's `user/` documents, with the bounded regex semantics described
  in [conversation memory](conversations.md#memory--durable-scoped-and-on-this-plane-injected-rather-than-fetched).
- `POST /agent_api/v1/profile/memory/edit` — `{memory: {path, old_text, new_text,
  expected_public_id, expected_lock_version}}`; 200 `{memory: ...}`. Replaces
  exactly one occurrence under the observed version; stale or ambiguous edits
  leave the document unchanged.
- `POST /agent_api/v1/profile/memory/delete` — `{memory: {path, expected_public_id, expected_lock_version}}`. 204,
  and it is gone: no history, no recycle bin.

A write here bumps no conversation's `context_revision`: the row belongs
to no conversation, and the next turn of ANY conversation the person or
their agents post into reads it live through the assembly block.

**Skills.** A document under the reserved prefix `user/skills/<name>` IS A
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

### Body and response shapes

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

### Conditional writes

Every write and delete at all three memory doors requires both
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

### Who may write

The Human and every agent they steward — any member-plane credential
whose controlling Human the scope belongs to. There is no workspace fence
and no writability check: the scope is the caller's own. The bounds are
memory's: 64 documents per person, 64 KiB per document.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing, or the document. |
| `201 Created` | — | Written (a replace answers 201 too: a write conditionally replaces the whole document). |
| `204 No Content` | — | Deleted. |
| `400 Bad Request` | `parameter_missing`, `parameter_invalid` | A required condition is missing or malformed. |
| `409 Conflict` | `stale_object` | The selected row/version no longer matches, or an absent path was created. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `404 Not Found` | `memory_not_found` | A read found no document at that path under the caller's scope. |
| `422 Unprocessable Content` | `memory_path_invalid` | A bare name, or a scope word outside `conversation \| workspace \| user`. |
| `422 Unprocessable Content` | `memory_scope_unavailable` | A `workspace/` or `conversation/` path — those scopes have their own doors. |
| `422 Unprocessable Content` | `memory_full` | The 65th document under this person. |
| `422 Unprocessable Content` | `memory_document_too_large` | The content exceeds the per-document bound. |
| `422 Unprocessable Content` | `memory_content_invalid` | The content is not a string. |
| `422 Unprocessable Content` | `skill_description_required` | A `skills/` write with no description, or a blank one. |
| `422 Unprocessable Content` | `memory_description_invalid` | A description that is not a string, exceeds 1024 bytes, or is given on a path outside `skills/`. |
| `422 Unprocessable Content` | `skill_name_invalid` | A `skills/` path whose remainder is not a skill name (`skills/`, `skills/a/b`, `skills/PDF`). |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |

## Prompt documents — the acting user's own slots

### Endpoints

```http
GET /agent_api/v1/profile/prompt_documents
GET /agent_api/v1/profile/prompt_documents/{slot}
PUT /agent_api/v1/profile/prompt_documents/{slot}
DELETE /agent_api/v1/profile/prompt_documents/{slot}
```

The acting user's OWN slots. Of the default template
([Conversations](conversations.md#the-default-template--the-slots-memory-your-text-history)):
an Agent holds `system_prompt` — its identity, compiled first
into every assembled turn it is the declaring profile of (its own row,
never its steward's); a Human holds `persona` — who the person is,
compiled into every turn that person posts, in every workspace, behind
the room's `character`. The workspace's `character` has its own door
([Workspaces](workspaces.md#prompt-documents--the-rooms-character)). An
Agent holds one more slot the template never places:
`summarizer` — the text of the kernel-mode compaction summarizer for
every conversation it answers ([Conversations](conversations.md#compaction--a-context-that-will-not-fit-is-repaired-not-reported)),
read as that step's raw `instructions` in place of the kernel's default;
absent, the default. It is CONTENT-ONLY: no macro (its request has no
sources, so a `{{…}}` is refused by name as everywhere) and no role — a
`role` other than `system` on it is `prompt_document_invalid`. Under a
`delegate` policy nothing reads it. The slot the caller's kind cannot
hold is refused here by name (`prompt_slot_unavailable`) before any row
is touched. The slot is the URL's member segment and the write is a
`PUT`: a whole replacement, first or later write alike, `version`
counting the writes.

- `GET /agent_api/v1/profile/prompt_documents` — the caller's slots, as
  `{slot, role, bytesize, version, written_at}`.
- `GET /agent_api/v1/profile/prompt_documents/{slot}` — the document with
  its `content`, as written (macros unrendered).
- `PUT /agent_api/v1/profile/prompt_documents/{slot}` —
  `{prompt_document: {content, role?}}`; 200 with the document. `role` is
  `system` (default), `developer` or `user`. Omitting `role` uses `system`
  on every write, including replacement of a document with another role.
  The macros `{{agent}}
  {{user}} {{workspace}} {{date}} {{conversation_kind}}` are substituted at compile;
  [conversation assembly](conversations.md#the-default-template--the-slots-memory-your-text-history) defines their sources. A word
  outside the registry is refused, naming it.
- `DELETE /agent_api/v1/profile/prompt_documents/{slot}` — 204, gone.

No fence and no workspace: the users row is the caller's own and the
lock. A write bumps no conversation's `context_revision` — the next turn
of ANY conversation reads it live. Bound: 64 KiB. rho resolves its own
`work_preset` (`standard` or `compact`), optional `base_prompt` replacement and
appended `custom_instructions` into `system_prompt` at each settings/declaration
edge in the atomic configuration declaration above. `base_prompt: null` uses
the selected preset; `base_prompt: ""` supplies an empty base. rho owns these
application settings; they introduce no additional Nexus profile mechanism.
Named-agent prompt bodies, Human persona and Workspace character remain
independent. Already materialized turns keep their captured document.
For rho's assembled turns, Nexus renders the
frozen selected environment as a `user`-role lead, and rho supplies its application
context as a `developer`-role inline lead after history; later turns replay both
through the sealed preface. rho's `summarizer` slot carries the
`summarizer_prompt` of the SDK pack row its summary model resolves to,
replaced in that same PUT and cleared when the row carries none, the
knob is `off`, or the policy is `delegate`. `rho prompt show [SLOT]` (rho-dev) reads
this door from a terminal. Use rho's **Working style** settings to persist a
custom base or additional instructions; rho ships no direct slot `write`/`delete`
verb, because its own slots are rewritten from configuration at declaration.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The listing, the document, or the written document. |
| `204 No Content` | — | Deleted. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `404 Not Found` | `prompt_document_not_found` | The slot holds no document. |
| `422 Unprocessable Content` | `prompt_slot_unavailable` | The slot is not the caller's to hold: `character` at this door, `persona` for an agent, `system_prompt` for a Human. |
| `422 Unprocessable Content` | `prompt_document_too_large` | The content exceeds 64 KiB. |
| `422 Unprocessable Content` | `prompt_document_macro_unknown` | A `{{word}}` outside the registry, named in the message. |
| `422 Unprocessable Content` | `prompt_document_invalid` | No `content`, a non-string, a role outside `system \| developer \| user`. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |

## Store entries — the principal's own

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
state per principal, where memory's `user/` above is the person's. There is no fence on a person's own row and another
principal's store is unreachable.

No receipt is kept for the profile store — `Idempotency-Key` is still
required, but a repeat with the same key is `409 key_taken`, never a
replay: the unique index and `lock_version` are the whole convergence
contract. The body, projections, pagination and the full status table are
[Store entries](store-entries.md); the bounds are the store's: 64 entries
per principal, 1 MiB per value.
