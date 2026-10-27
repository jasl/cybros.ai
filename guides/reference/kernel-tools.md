# Kernel tools

Tools the kernel serves itself. A kernel tool has a canonical `source.category.name` and a short wire alias; a model sees the alias. An agent declares a kernel tool byte-identically to the catalog Nexus serves (`GET /agent_api/v1/tools`), or through the compact alias grammar; it may declare its own alias and parameter map, and the call then arrives under the alias and runs under the canonical name.

| Canonical | Wire name | Purpose |
| --- | --- | --- |
| `nexus.graph.delegate_task` | `delegate_task` | A delegated model branch in the current run with an empty context, optional model and narrowed tools; `wait` and `lifetime` as described in [Orchestration](../build/orchestration.md) |
| `nexus.graph.wait` | `wait` | Observe an existing task by run and task key with a finite timeout, without owning it |
| `nexus.human.ask` | `ask` | Park a question for a person with a prompt and optional options; holds its branch until answered or expired |
| `nexus.conversation.spawn` | `spawn` | Create a child conversation from a captured `declaration`, or use the generic identity path when no catalog is declared, and send its first request |
| `nexus.conversation.send` | `send` | Deliver a recipient-owned ordinary message by address or Conversation link; exact-run steering is explicit |
| `nexus.conversation.links` | `links` | Discover links for the calling Conversation and answering Agent |
| `nexus.conversation.request` | `request` | Request work in an existing Conversation and observe its exact completion |
| `nexus.conversation.status` | `status` | Read the status of a conversation or its work |
| `nexus.conversation.cancel` | `cancel` | Request cancellation of work this run started |
| `nexus.conversation.read` | `session_read` | Visible context, including unfinished turns; `include_execution` adds persisted execution progress |
| `nexus.conversation.search` | `session_search` | Keyword search over visible history |
| `nexus.memory.ls` | `memory_ls` | List memory documents in the bound scopes |
| `nexus.memory.read` | `memory_read` | Read a memory document |
| `nexus.memory.grep` | `memory_grep` | Search memory text |
| `nexus.memory.write` | `memory_write` | Create or replace a memory document |
| `nexus.memory.edit` | `memory_edit` | Edit a memory document conditionally |
| `nexus.memory.delete` | `memory_delete` | Delete a memory document |
| `nexus.image.generate` | `image_generate` | Generate or edit images with the execution's captured image model |
| `nexus.schedules.read` | `read_schedules` | List, inspect and read execution history of this conversation's schedules |
| `nexus.schedules.manage` | `manage_schedule` | Create, edit, pause, resume or cancel this conversation's schedules |
| `nexus.tools.search` | `tool_search` | Search this execution's available tools and skills by name, task words, or runner and tool name |
| `nexus.tools.call` | `tool_call` | Invoke an exact callable discovered by search, including deferred schemas |
| `nexus.runners.list` | `runners_list` | The runners this execution may address, with their environment facts |
| `nexus.models.list` | `models_list` | Currently available model references, identities, capabilities and pricing; optional case-insensitive `query`, `limit` (default 20, maximum 100) and `offset` (default 0) return `models`, `total`, `offset` and nullable `next_offset` |
| `nexus.skill.load` | `skill` | Load one skill's instructions from its accepted source |

New directly addressed `send`, `request` and `spawn` calls obey the recipient Agent's Public/Private setting in the Workspace's [Agent messaging policy](agent-api/workspaces.md#read-messaging), using the calling Run's answering Agent as the sender. Accepted work and kernel result replies retain their existing delivery rules; `status`, `cancel` and history reads keep their existing authorization.

The memory family is the one overridable family: a tool provider may take it over under the workspace's explicit opt-in, and must take the whole family.

Every kernel tool crosses the approval stage like any other; `ask`, the memory tools and `delegate_task` are commonly allowed by rule. Model-authored branches do not receive the graph-building `task` capability, so delegation from a model has one level; `spawn` remains available and its children can delegate further.

Each tool's exact schema, the alias grammar and the import rules are in [Run tools](agent-api/run-tools.md#the-kernel-tool-catalog); the orchestration tools' semantics are in [Run orchestration](agent-api/run-orchestration.md#the-seven-tools).

`session_search` combines archive, auxiliary-conversation and default-answerer
filters within one Workspace. Its results carry the exact candidate UUID, field
and an opaque excerpt `location` (null for title hits). Applications can open
that saved text through the [bounded field reader](agent-api/conversation-history.md#read-an-exact-field),
including accepted follow-up messages. `session_read` keeps its existing
active-variant context semantics.

## Images

`image_generate` requires `prompt`. Optional `configuration` carries the image
model's generation options. Optional `reference_upload_public_ids` lists image
upload UUIDs bound to the calling Run or its visible conversation history,
preserving their order. Upload a local reference through the Runner's file tools
before calling; a local path is not an image reference for this tool.

The model comes from the captured `image_model` configuration field. The caller
cannot select a different route in the tool arguments. Nexus creates one waited
`image_generation` ModelTask under the tool's `expansion_parent` relationship.
It uses the ordinary invocation, Stop, pause and retry lifecycle, without text
history, tools, reasoning controls or text-model fallback candidates.

The image task's output contains durable `nexus://uploads/<public_id>` resource
links. These uploads share the provider result's validated stored blobs; an
application reads or downloads them through the existing attachment doors.
No application executor is needed to generate or publish the result.

## Schedules

`read_schedules` accepts `action: list`, `show` or `history`; the latter two
require `job_id`. Lists accept `limit` from 1 through 50 (default 30) and a UUID
`after` returned as `next_after`. These tool cursors are distinct from the
HTTP API's opaque pagination tokens.

If a read exceeds the tool-result bound, it completes with `result_too_large`.
Reduce the list limit or read the full saved record through the Schedules API.

`manage_schedule` accepts `create`, `update`, `pause`, `resume` or `cancel`.
Creation requires `prompt` and `rule`; `name` is optional. Update requires
`job_id` and `expected_lock_version` and changes the name, prompt or rule.
Lifecycle actions require `job_id`.

A management result normally includes the saved record. If its full prompt would
exceed the tool-result bound, the result contains `public_id`, `status`,
`lock_version` and `next_run_at`; the full instruction remains on the Schedule
API resource.

Creation captures the calling round's answering Agent, declaration, model,
tools and approval policy. The model supplies the future instruction and clock,
not an identity or a new execution policy. The source Run is provenance; its
completion or Stop does not cancel the schedule. Rules, dispatch and child
results use the ordinary [Schedules](agent-api/schedules.md) resource.

Linked messages use the fixed endpoints of a [Conversation link](agent-api/conversation-links.md); a link grants no peer history or execution control.
