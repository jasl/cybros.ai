---
title: Agent configuration
description: "The one writer of an Agent's standing configuration: tools, kernel imports, Runner candidates, models, aliases, approval and lifecycle hooks."
---

# Agent configuration

An Agent's standing declaration: the tools its model may call, where
they run, which models answer and how a turn crosses the approval
stage. A reply without an inline agent configuration reads it at materialization,
then freezes it onto that execution. An input can instead capture an
identity-free declaration at admission, as described below. The application owns
its standing declaration and prompt documents. Nexus validates and snapshots
these generic values for execution; the Human Platform provides a read projection.

```http
PUT /agent_api/v1/profile/configuration
```

The Agent replaces its `configuration` block and its own
`system_prompt` and `summarizer` documents in one transaction. Nexus assembles
the accepted tool set from these explicit declarations, selected plain kernel
tools, the selected Runner's announced model schemas and explicitly selected MCP tools.

## Body

```json
{
  "configuration": {
    "tool_definitions": [
      { "type": "function", "function": { "name": "bash", "description": "…", "parameters": { "type": "object", "properties": { "command": { "type": "string" } }, "required": ["command"] } } }
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
    "fallback_models": ["openrouter/moonshotai/kimi-k3"]
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
### Shapes the door refuses

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

The existing [prompt-document doors](profile-prompt-documents.md)
still read and independently edit individual documents. The complete Agent
response carries its configuration; document text remains on those existing
read doors. Named Agents retain their independent
`PUT /profile/agents/{name}` commands and are not included in this transaction.

`tool_definitions` and `compaction_policy` use their declared JSON grammars,
validated by the model: the tool list is a list of declaration objects (empty
declares none) under the 1 MiB canonical-JSON `tool_definitions_bound` and obeys the kernel-name rule a task's
`tools` obeys — a live kernel tool must be declared in the exact bytes
[the catalog](run-tools.md) serves or through the existing compact alias grammar.
The list is stored canonical by
name. This bound covers an aggregate of tools from several authorities or Runners;
the 1 MiB bounds on a whole step payload and frozen execution context still apply.
`compaction_policy` takes exactly the shape a task's `compaction`
takes and remains under the 64 KiB envelope bound.

`default_model` names one complete `provider/model` reference, never a routing
policy. A changed reference passes through the model resolver for
`text_generation`. A reported refusal other than the temporary conditions below
returns `422 validation_failed` with the reason on that field, including an
unknown provider or model or an unsupported workload. A selector
(`model_selector:…`) or bare word is `unknown_model`. An unchanged reference is
retained without repeating this resolution. `image_model` follows the same rule
for `image_generation`.

A declaration can retain or introduce a temporarily unavailable reference:
`provider_disabled`, `model_hidden`, `missing_credential`,
`reauthorization_required` and `credential_unusable` do not reject the save.
Execution checks live availability and uses its captured recovery candidates;
saving a configuration does not establish that its model can run now. Resolution
can stop at a temporary condition before checking the remaining model details.

### Function declarations

They accept nested `{type: "function", function: {...}}` and
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

### Runner routes

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
ordinary model announcements from that selected Runner are imported. Announcements
with `mcp` source metadata require an explicit Runner route instead. Unavailable
names and operator-only announcements contribute no tool, and no other candidate's
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

### MCP imports and routes

`mcp_tools` is an explicit list of `{connection_public_id, tool_name, name}` objects.
The connection UUID identifies one external account; `tool_name` is the exact remote
name, and `name` is the callable exposed to the model. All three are required.
Names are nonempty, at most 128 characters and contain no NUL. Callable names
cannot use reserved kernel names or collide with another declaration. Omission,
`null` and `[]` import no MCP tools; there is no wildcard or future-tools selection.

```json
{
  "mcp_tools": [
    { "connection_public_id": "01900000-0000-7000-8000-000000000091", "tool_name": "search", "name": "work_search" }
  ]
}
```

At the ordinary assembly boundary, Nexus reads the saved connection catalog and
freezes the description, input schema, optional `output_schema`, conservative
`effect_profile`, and `route: {kind: "mcp", connection_public_id, tool_name}` beside
the callable function. No remote IO happens during assembly. These metadata fields
are removed from provider serialization. Imported MCP schemas use `defer_loading`;
the ordinary search/call rule determines visibility.

An explicit function declaration may carry that same MCP route. It requires a
concrete connection UUID and remote name, independent of the callable. Explicit
routes and imports use the same current connection/steward/catalog checks. Changing
a connection name or catalog never redirects an accepted execution. Credentials
are never part of a declaration. A retry keeps the captured schema and route;
changed stewards, disabled connections and withdrawn tools still block new calls.
See [MCP connections](mcp-connections.md) for authorization and execution limits.

### What acceptance freezes

The accepted definitions, selected environment and ordered eligible candidate
facts are frozen together. Later profile changes, announcements and default
preferences affect future work. The optional `nexus.runners.list` tool reads that
frozen candidate list and current Runner; it neither imports tools nor changes
accepted work. A model chooses another environment by passing its UUID to `spawn`;
omission inherits the spawning execution's frozen selection and null chooses no
Runner. Delegate tasks and child operations inherit their accepted tool surface.

### Memory limits and conversation reach

`memory_context_limit` is an optional ceiling over the memory bindings a
conversation selects. `null` adds no ceiling; `{"bindings": []}` admits no
memory. A nonempty limit uses the [memory binding grammar](conversation-memory.md#named-bindings),
with natural root names only: each `name` equals its `scope`, and neither
`conversation_public_id` nor `speaker_public_id` is allowed. It includes
the required `conversation` root. For example:

```json
{
  "memory_context_limit": {
    "bindings": [
      { "name": "conversation", "scope": "conversation", "access": "read_write" },
      { "name": "workspace", "scope": "workspace", "access": "read" },
      { "name": "speaker", "scope": "speaker", "access": "read_write" }
    ]
  },
  "conversation_reach": "subtree"
}
```

The effective context is the intersection of the selected bindings and this
limit. A limit never adds a missing root, and `read` wins over `read_write`.
A limited profile cannot retain a conversation alias pointing outside the
current conversation. Injection, skills, memory tools, preview and memory
management use this effective context. The Agent's profile-memory door also
applies its limit. Prompt slots follow the authored template independently
of memory bindings.

`conversation_reach` accepts `workspace`, `subtree` or `null`; omission and
`null` use the ordinary workspace reach. `subtree` restricts the execution's
conversation addressing and history tools to its current conversation and
descendants, intersected with ordinary visibility. It grants no access.
Spawned children, forks and scheduled conversations retain an inherited
`subtree` restriction; selecting a broader answering profile cannot widen it.
A standalone execution with `subtree` has no conversation to address.

Each execution freezes its effective memory bindings, Speaker subject and
conversation reach. Profile changes affect new ordinary executions. Child
work, retries, regeneration and completion mail retain the captured limits;
a receiving profile may narrow inherited memory further. The
[conversation memory reference](conversation-memory.md#named-bindings)
defines Speaker selection and delegation in detail.

### fallback_models

An ordered array of complete `provider/model` references, each at most 193
characters, under the 64 KiB JSON envelope bound. `[]` declares no automatic fallback. Omission or null
on the standing profile declaration clears the list. The initial
`default_model` and this list are independent: the initial model is not
appended implicitly. Duplicate routes are visited only once.

Each execution captures its effective list. Later profile edits cannot
change accepted work, retry a spent route, or add another candidate to its
chain. Candidate availability remains live: disabled providers or models
and missing credentials are skipped without provider IO or a failed
attempt. The caller's captured model and provider constraints also apply.

A classifier refusal or an exhausted retryable transport/server failure
can advance to the next eligible candidate. A content block, an arbitrary
request error, or Stop cannot. Recovery replaces the affected model step;
completed tool results remain. The [model selection and recovery
contract](models.md#model-selection-and-recovery) defines intent, constraints,
route budgets and switch reporting for Runs, direct replies and
InferenceRequests.

### image_model

An optional complete `provider/model` reference, at most 193 characters, for
[`image_generate`](../kernel-tools.md#images). Omission or null clears the
standing value. A changed reference is checked against the catalog for the
`image_generation` workload; availability is checked again when work starts.
Each execution captures its chosen image model. The tool's arguments cannot
replace that model, and it does not inherit the text model's fallback list.

### Inline agent configuration

Conversation input create and update, context estimate, and turn
regeneration accept an optional `agent_configuration` object. It carries
these configuration fields directly, without a `configuration` wrapper:
`tool_definitions`, `kernel_tools`, `runner_executor_public_ids`,
`runner_tool_names`, `mcp_tools`, `approval_mode`, `approval_rules`, `prompt_mechanism`,
`prompt_template`, `compaction_policy`, `lifecycle_hooks`,
`memory_context_limit`, `conversation_reach`, `default_model`, `image_model`,
`fallback_models` and `delegation_catalog`. It can also carry `system_prompt` and `summarizer`, each
as `{content, role?}`. There is no User, credential, role name or executor
identity inside the declaration.

```json
{
  "agent_configuration": {
    "prompt_mechanism": "default",
    "system_prompt": { "content": "Check the supplied change.", "role": "developer" },
    "kernel_tools": ["nexus.memory.read"],
    "approval_mode": "ask",
    "default_model": "openai_api/gpt-6.1-sol",
    "fallback_models": ["anthropic/claude-sonnet-4-5"]
  }
}
```

The object replaces the agent configuration whole; it does not merge
with the standing profile. Omitted fields use the declaration's defaults,
including an empty fallback list. Its tool, approval, template, memory
and conversation-reach fields use the same grammars as a profile
declaration. Prompt content is bounded and its macros must be declared.
The acting and answering principals, Workspace access, Runner eligibility
and other live admission gates still have their existing owners.

Input admission stores the authored object. Materialization resolves the
selected tools, prompts, memory and environment for that execution and
freezes the result. A queued inline input therefore does not pick up a
later Preset or profile edit. With the object omitted, an ordinary input
resolves the answering User's standing declaration at materialization,
then freezes it. A context estimate performs the same compilation without
writing or reserving that future result. Regeneration without a new
object reuses the originating candidate's captured declaration; a supplied
object replaces it for the new candidate. A child created from a delegation
declaration, and a fork of that child, instead resolves omitted declarations
from the Conversation's owned defaults. Those defaults survive reclamation of
the first input and spawning Run.

### Delegation catalog

The Profile and inline agent configuration accept nullable
`delegation_catalog`. Each entry has a unique `name`, a parent-facing
`description`, `model_mode` (`caller` or `default`), optional `inherited_tool_names`,
and a leaf `declaration` using the execution grammar above. A leaf cannot contain another catalog.
The captured parent catalog is carried into selected children for nested
delegation, without recursively repeating it in the authored JSON.

`inherited_tool_names` is a bounded array of unique nonempty callable names, each
at most 128 characters without NUL. Omitted, null or `[]` inherits no tools.
Spawn copies matching definitions from the direct parent's captured tool context
into the child's independent declarations, preserving exact schemas and routes.
A missing name contributes nothing. Nested delegation uses its immediate parent,
so the original catalog cannot restore an absent tool. A nonempty list requires
the leaf's `approval_mode`; its own approval policy governs inherited calls.
Applications can use this mechanism for MCP selection inheritance without changing
the role's independent non-MCP tool configuration.

`null` retains generic identity-based spawn. Any array, including `[]`, requires
`spawn.declaration` to name one captured entry and rejects the `agent` selector
or a missing declaration. An empty array therefore publishes no spawn target.
The selected child keeps the caller's answering principal; a catalog entry
does not create a User, credential or standing Agent configuration.

An explicit spawn `model`/`model_selection` wins. Otherwise `caller` uses the
calling task's current actual model, including a prior fallback, and inherits
its selection constraints. `default` uses the selected leaf's default model.
The leaf owns its fallback list unless the spawn explicitly replaces it.
Later edits to a live catalog affect future accepted parents, not the captured
directory of existing work. Later sends to a child use that child's own
current model and captured defaults rather than following the parent again.

### Aliases

The alias is the one other way to declare a kernel tool: an entry carrying
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

### Lifecycle hooks

A hook tool must be served by an eligible executor through the ordinary
announcement and inbox protocol. It need not appear in `tool_definitions`:
declaring a hook does not expose it for the model to call. An `approval_mode`
is required even when hooks are the profile's only tools. Hook tasks are
kernel-authored and follow the approval rules for that origin. Failed hooks
use the existing attention and repair flow; user force-stop bypasses them.
The [lifecycle hook manual](../../build/lifecycle-hooks.md) describes event ordering
and the bounded Stop continuation protocol. These settings are also available
on named Agents below.

## Response

`200` with the profile, exactly as `GET /agent_api/v1/profile` now reads it.

## HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | Declared; the profile is returned. |
| `400 Bad Request` | `parameter_missing` | The `configuration` root is absent or not an object, or a non-null `prompt_documents` root or owned slot is not an object. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, unusable, or not a member-plane credential. |
| `403 Forbidden` | `not_agent` | A Human member has no declaration to write. |
| `403 Forbidden` | `not_authorized` | The Agent is no longer eligible when its declaration lock is acquired. |
| `422 Unprocessable Content` | `validation_failed` | A word outside a vocabulary, a missing approval mode on a profile declaring tools or hooks, a malformed rule (a seventh key, a missing tool, a verdict or origin outside its three words, a `match` without a `path`, a glob that does not compile), a malformed or over-bound tool list, fallback list, rule list, policy, lifecycle hook declaration or template, `assembly` without a `prompt_template`, a template outside the grammar (the message names its path), or a changed `default_model` or `image_model` with invalid catalog identity or workload (the message carries the resolver's reason). The message names the field. Temporary unavailability does not reject a declaration; execution checks live availability. |
| `422 Unprocessable Content` | `prompt_document_invalid`, `prompt_document_too_large`, `prompt_document_macro_unknown` | Either replacement document fails the existing slot validation; configuration and both slots remain unchanged. |
| `429 Too Many Requests` | `rate_limited` | The ordinary caller budget or broad source-IP backstop is spent. |
