---
title: Run tools
description: The kernel tool catalog, importing tools into a run, Runner environment discovery, deferred tool search, the result envelope, the skill tool and the kernel's naming registry.
---

# Run tools

What a model can call inside a run: the kernel's own tools, the tools a
Runner or provider announces, and the grammar their results come back
in. Which tools a given turn actually offers is resolved by
[Tool assembly](tool-assembly.md); the catalog and its rules are here.

## Routes

```http
GET /agent_api/v1/tools
```

## The kernel tool catalog

`GET /agent_api/v1/tools` publishes every kernel tool this deployment
runs, as `{canonical_name, name, effect_profile, definition, template}`.

An author may select exact canonical names through `kernel_tools` and let
Nexus import their plain definitions, or splice an entry's `definition`
into an explicit `tools` array. The same import grammar is available on
Agent profiles. The read-only
[tool assembly projection](tool-assembly.md) resolves a proposed
declaration and Runner selection before authoring work.

An explicit plain kernel declaration must use the catalog's exact schema:
the registry stores wire names rather than computing them, and the tools
block is the front of every cached prefix. A paraphrase is refused
`kernel_tool_redefined`. Compact aliases remain the supported way to
choose another spelling or parameter presentation.

The store retains the full authorized declaration. Provider projection
omits schemas marked `defer_loading: true` when eager search and call
tools are declared ([Profile](profile.md)), and omits a skill callable
with an empty frozen catalog. The annotation does not alter kernel schema
equality. Eager skill catalogs appear in the turn's `skills` block, while
deferred ones remain available through tool search. The sealed request
records the schemas actually offered to the provider.

### The un-aliased render

The catalog publishes every description with its tool-name macros spelled
as the kernel's own wire names. A profile that declares an alias of a
kernel tool ([Profile](profile.md), the `tool_definitions` row) — its own
spelling, with a parameter map — is the sanctioned way to declare a
kernel tool in other bytes: the kernel renders the texts with the
profile's names at declaration, and a call under the alias runs under the
canonical.

`template` is the description's macro-bearing source: the text with its
`{{delegate_task}}`-style tool-name macros unrendered, which the plain
`definition` renders as the kernel's own wire names. It exists for one
reader, an adaptation pack (the SDK's `CybrosAgent::ModelAdaptations`)
whose alias entry carries a `recut: {anchor, replacement}` — one anchored
edit rendered against this text at declaration, so no kernel prose is
ever copied into a pack, and a paragraph the kernel re-cuts fails the
pack's anchor loudly instead of drifting. A client that only declares the
plain tool never reads it. The contract pack
(`contracts/nexus/v1/tools.json`) carries one entry as the route serves it
— `nexus.graph.delegate_task`, the template the gem's `claude` recut
anchors on — so a re-cut of any other description regenerates nothing.

### effect_profile

`effect_profile` is trusted metadata for the host — kind, destructive,
effect_scope, idempotency, reconciliation — and never rides the model's
wire. It is what the approval gate reads: the effect profile frozen on
the held row, rendered on the agent's inbox row for the
approver.

### Declaring is enabling

Declaring a kernel tool is the whole gesture by which an agent turns it
on, and doing it from a conversation's first round matters: adding an
eager schema midway rewrites the front of the cached prefix and
invalidates everything after it.

`kernel_tools` selects additional plain definitions by exact canonical
name; null or `[]` adds none. It does not override explicit kernel
definitions or aliases. To omit a capability, omit it from both sources.
Nexus composes and renders the final declaration once when accepting the
work.

## Importing tools onto a model step

Member-authored model steps and standalone tool `model_defaults` may use
`kernel_tools`, `runner_executor_public_ids`, `runner_tool_names` and
`mcp_tools` with the [Profile configuration](profile-configuration.md) grammar.

`kernel_tools` adds selected plain canonical definitions, and explicit
`tools` remain independent declarations. The ordered Runner UUID list
declares candidates: the run's selected default must be among them when
importing from that Runner, and with no selected Runner the candidates
remain available through `runners_list` but contribute no tools.
`runner_tool_names: null` imports all model schemas from the selected
Runner and `[]` imports none.

`mcp_tools` selects exact saved tools as
`{connection_public_id, tool_name, name}` entries: the connection UUID,
remote tool name and unique callable name. Null or `[]` imports none.
The acting Agent needs its own connection grant and the owner's allowed
tool selection. Imports capture the saved schema and connection route;
they perform no remote discovery. See [MCP imports and routes](profile-configuration.md#mcp-imports-and-routes).

Only acceptance reads current announcements and saved MCP catalogs. The task stores the
resulting definitions, selected environment, candidate facts and skill
catalog. Import intent is consumed there; it is not a second persisted
source that later rounds resolve again. The original explicit-tools form,
without import fields, retains its explicit Runner or MCP routes and does
not automatically import announcements or catalogs.

A tool's own explicit execution route is independent of these model
defaults: the executor running that tool does not become the target of
its child tools. Children inherit the frozen context. A child model
operation may narrow `tools` by callable name, but any import field is
refused as `context_not_authorable`.

## Runner environment discovery

`nexus.runners.list` (wire `runners_list`) is an optional reserved kernel
tool. It accepts `{}` and returns `{current_runner_executor_public_id,
runners}`. Each Runner entry contains `runner_executor_public_id`,
`display_name` and its announced `environment`. The list follows the
Agent's declared candidate order and freezes eligible candidates at
acceptance, independently of imported tools. The current UUID can be null
even when candidates exist.

This is the accepted environment context, not a live connection probe. It
reads no later profile or announcement and never derives candidates from
tool routes. Use a candidate UUID as
`spawn.default_runner_executor_public_id` to create work in that
environment. Omission inherits the spawning execution's frozen default,
and explicit null chooses no Runner. Delegate tasks and child operations
keep their frozen inherited environment. No model-facing Runner change
tool is provided.

## Tool search and deferred calls

`nexus.tools.search` (wire `tool_search`) and `nexus.tools.call` (wire
`tool_call`) are reserved kernel tools. Declare their catalog definitions
from the first round to provide stable entry points for deferred schemas.
They work across providers without a provider-specific loaded-tool state.

`tool_search` accepts `{query: string, limit?: integer}` — a nonempty
query, limit 1–20, default 5. It searches the calling execution's frozen
callable names, descriptions and route values, including Runner UUIDs and served
names or MCP connection UUIDs and remote tool names, plus skill names and
descriptions. An exact callable query returns that entry;
otherwise matches contain all query terms.

The result is `{tools: [{name, definition, route?, skills}], truncated:
boolean}`. `definition` is the complete function schema, including the
same `strict` default as provider projection; `route`, when present,
contains the declared Runner target or MCP connection route
(`kind`, `connection_public_id`, `tool_name`); `skills` contains
source-qualified frozen catalog entries. Results keep whole schemas
within the output bound, and `truncated` reports omitted matches. Search
never adds a tool or reads a later executor announcement.

`tool_call` accepts `{name: string, input: object}`. `name` must be an
exact callable in that frozen declaration, not a served name guessed from
another Runner. It expands one ordinary child tool through the existing
task-operation lowering and task append path. Alias mapping, concrete
target acceptance, approval and deadlines apply normally to the child:
the wrapper is not an approval bypass. Its paired result preserves the
child's error and capture semantics. An application's code bridge may
call the same discovered name directly. An empty or narrowed declaration
never gains authority through search or call.

## The result envelope

One wire field, one engine, one meaning, shared by the await resolution
and the executor's commit ([Executor inbox](executor-inbox.md)).

### content

`content` is MCP's `CallToolResult.content`: either a plain string or a
list of content blocks of two kinds — `{"type": "text", "text": "…"}` and
`{"type": "resource_link", "uri": "nexus://uploads/<public_id>", "name":
"…", "mimeType"?, "size"?, "title"?, "description"?}`.

A bare string is the identity case and stays valid forever: it and a
single text block write the same bytes, which matters because the
tool-result entry is the prompt-cache breakpoint. A blank result — empty,
or only whitespace — writes no body at all and the model reads nothing,
which is what it has always done.

A `resource_link` names a capture the committing executor staged as its
own ([Executor](executor.md#publish-a-capture)): `uri` is the one scheme
the kernel resolves, `name` is required (MCP `BaseMetadata`), and the
rest are typed and stored verbatim. The body binds the upload so the
capture lives as long as the result, and its bytes are read on `GET
/agent_api/v1/uploads/{public_id}/bytes` ([Uploads](uploads.md)) by the
result's reader.

What the model reads of it: a link to a bound image or PDF upload — the
upload's detected type, not the link's optional `mimeType` — rides as one
attachment-only message after the round's last result when the current
model accepts that media type, else as an attachment index line. Later
conversation turns carry these attachments with the retained round,
applying their own model selection and history budget. A non-media link
appears as its standard MCP `resource_link` JSON in the tool result's text,
in block order alongside any text blocks. Its URI and metadata remain
available to the model even when the tool returns no text block.

An id that is not the committer's own capture refuses `422
unknown_result_upload`, whole or nothing, with the park standing. An
operation-owning tool final may additionally retain captures already
bound to that parent's sealed operation observations.

### The closed vocabulary

| Refusal | Cause |
| --- | --- |
| `422 unsupported_content_kind` | A well-formed block of any other kind |
| `422 invalid_content` | A shape outside the grammar: a link of another scheme, a missing `name`, a mistyped field |
| `422 too_many_content_blocks` | More blocks than a body can hold |
| `422 result_unstorable` | Bytes that cannot be stored at all |

The grammar refusals leave the park standing. `result_unstorable` on a
tool call does not: the runner's report is refused with the `422`, and
the park is closed at once — the task settles `failed` with `error.key:
result_unstorable` and `error.detail` naming the storage guard's word
(`unsupported_text: the result's bytes cannot be stored`), so the next
round reads the failure instead of waiting out the claim deadline. An
outcome that cannot be stored is a failed outcome, not an open park, and
a typed refusal is final for the runner, which never resubmits it. On an
await the same refusal leaves the park standing: its resolver is a person
at an interactive door.

### structured_content

`structured_content` is MCP's `structuredContent`: any JSON value.
Explicit null and false are retained, and omission means no structured
value. It rides beside the text and never inside it.

Who sees it is worth stating exactly. It is always served back on the
task read, where a client or a UI picks it up, and it never reaches the
model: this wire's tool result is a string, the same division MCP itself
draws, where `content` is what the LLM reads and `structuredContent` is
result data for the client.

The kernel never serializes `structured_content` into the text position:
a structure-only result hands the model `""`, and its `output` reads `""`,
never the storage envelope's JSON. MCP's "a tool that returns structured
content SHOULD also return the serialized JSON in a TextContent block" is
the runner's to honour — a tool that wants the model to read its
structure puts the words in `content` beside it, and the model reads the
prose while the client reads the structure.

### result_type

`result_type` is accepted, validated and not stored. Absent reads as
`"complete"`, the spec's own rule, and anything else refuses `422
invalid_result_type`: its only other value belongs to MRTR, which this
system does not implement, so accepting it would be a lie.

### What a settled task reads back

`GET …/tasks/{task_key}` carries `output` — the text projection,
unchanged — alongside `content` (the blocks) and `structured_content`.

Two more fields are UI-only. `title` is the one-line header a collapsed
transcript row shows: the file it read, the command it ran. `metadata` is
the model-invisible carrier: structured material for a per-tool renderer,
with one reserved key `checkpoint`, the runner's own record of its
environment before the call, verbatim
([Executor inbox](executor-inbox.md)). Both are served on that same read,
only when the executor sent them. Neither is ever spliced into a model
request; the model sees the output and nothing else. Without them every
tool renders as "Called X" over a raw blob.

Where a runner finds this work, claims it and commits its answer is the
executor plane's inbox ([Executor inbox](executor-inbox.md)): per
executor, across every live run of its account, with `work_available`
pushed on the executor's own channel. Nothing of it is reachable with a
member bearer.

## The skill tool

One more kernel tool an agent declares from the first round, published as
`Nexus::Tools::SKILL` (`nexus.skill.load`, wire name `skill`; a profile
may alias it — Claude Code's `Skill({skill})` maps `skill` onto `name`).

`skill({name})` loads a document from the turn's frozen skill catalog,
exposed through the `skills` block or `tool_search` according to schema
visibility. Runner documents use declared callables such as `mac_skill`
and `build_skill`, each carrying a concrete Runner route to the served
`skill` tool. Equal document names remain separate because each entry
names its callable and source UUID. The assembly renders `- callable /
name [executor UUID]: description`, and kernel memory entries omit the
UUID. The result is the document body as ordinary tool result content,
with no additional task kind or graph edge.

For a non-Runner skill callable, the [skills block](prompt-assembly.md#the-skills-block)
defines source precedence. Database documents come only from the execution's
effective memory bindings. Acceptance freezes the selected source as well. A call reads
its selected source, never the host's current default or another
same-named document. A source no longer serving the selected skill fails
delivery with `tool_not_served`; a document missing at load returns
`skill_unknown` as ordinary tool-result data. Later catalog changes apply
only to later acceptance. `nexus.skill` cannot be a Workspace provider
override.

## The kernel's naming registry

Every tool the kernel executes has a three-segment canonical name,
`source.category.name`, where the source is the authority that executes
it: `nexus.*` runs in the server, `rho.*` in the agent's own process.

Providers receive a short wire name instead (`nexus.graph.delegate_task`
→ `delegate_task`), because short names protect tool-call success. The
wire name is stored, never derived, so a name already sitting on a cached
prefix can never be moved by a rule change; a call resolves back to its
canonical intent through the alias index.

The descriptions name a kernel tool through a macro (`{{delegate_task}}`,
`{{ask}}`, `{{memory_write}}`), rendered plain in the catalog and with a
profile's own spellings when that profile aliases the tool. A runner's
tool name the texts quote (`read`, `grep`, `start_process`) is literal,
pinned to what rho declares.

Every live entry declares one complete effect profile — `{kind,
destructive, effect_scope, idempotency, reconciliation}` — trusted
registry metadata that drives recovery classification and, later,
approval routing. It is never a security boundary, and it never rides the
provider wire: the schema a provider sees is exactly name, description
and parameters.

### The three declaration shapes

Declaring a kernel tool is the gesture that enables it: an agent puts
`delegate_task` in a model task's `tools` and the model can call it. One
declaration is refused, because it could not work — a live kernel name
declared with anything but the published bytes, `kernel_tool_redefined`.
The model would be told one thing while the kernel's executor did
another, and the paraphrase would buy a second cached prefix describing a
tool that does not behave that way.

An alias entry (`{name, canonical, params?, omit?, description?}`,
[Profile](profile.md)) is the third shape: the agent's own spelling of a
live kernel tool, rendered by the kernel with the profile's names. It
adds its own refusals — `alias_canonical_unknown`, `alias_name_reserved`,
`duplicate_tool_name`, `alias_param_unknown`,
`alias_invert_needs_boolean`, `alias_param_description_required`. A
round's `tools` admits the same three shapes and stores the same render;
a call the model makes under an alias becomes a row under the kernel's
wire name (`tool_name`), its input mapped, with the alias beside it
(`tool_alias`).

### Live names and reserved namespaces

Every registered kernel name is live and executable: the registry holds
no name ahead of its executor, so no client tool — a runner's included —
can take a kernel word, and no transitional spelling ever ships. The
`nexus.conversation.*` family (`spawn`, `send`, `status`, `cancel`) is
reserved under these wire names, and all four tools are live. The memory
family is live and executable under `memory_ls` and `memory_delete`, and
what it lacks is a client that declares it.

A reserved namespace is a different fact: `nexus.graph`, `nexus.human`,
`nexus.conversation`, `nexus.tools` and `nexus.runners` are the families
no executor may serve in the kernel's place. That governs the
announcement door ([Executor](executor.md)), never this one.

Two consequences a client sees:

The append door refuses a `tool_task` whose `tool_name` is any registered
kernel name, in either spelling: `reserved_tool_name`. The model reaches
these through its own tool calls, and a client has the whole task grammar
for everything else.

A model call the round never declared fails at birth with `unknown_tool`
instead of parking until its deadline, a kernel tool included. The
round's declaration is the only gate, so a turn whose tools withhold
`delegate_task` — a conversation input's `tool_names`, a branch's
inherited set — refuses a guessed `delegate_task` exactly as it refuses a
name nobody serves. The task is still authored, since the pairing law
owes every call a result, and the continuation hears why. One bad name
among good calls never fails the round.

### Kernel tools have no addressee

`delegate_task`, `wait` and `ask` are kernel tools: Nexus is their
runner. None appears in any executor's inbox — a kernel tool carries no
addressee, and the executor claim answers `not_addressed_here`, because a
runner that could claim it could forge a graph mutation nobody authored.
It parks like every other tool task, on the same clock and the same
deadline, so a lost evaluation returns through the timeout sweep exactly
as a crashed runner's task does.
