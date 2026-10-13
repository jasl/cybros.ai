# Kernel tools

Tools the kernel serves itself. A kernel tool has a canonical `source.category.name` and a short wire alias; a model sees the alias. An agent declares a kernel tool byte-identically to the catalog Nexus serves (`GET /agent_api/v1/tools`), or through the compact alias grammar; it may declare its own alias and parameter map, and the call then arrives under the alias and runs under the canonical name.

| Canonical | Wire name | Purpose |
| --- | --- | --- |
| `nexus.graph.delegate_task` | `delegate_task` | A delegated model branch in the current run with an empty context, optional model and narrowed tools; `wait` and `lifetime` as described in [Orchestration](../build/orchestration.md) |
| `nexus.graph.wait` | `wait` | Observe an existing task by run and task key with a finite timeout, without owning it |
| `nexus.human.ask` | `ask` | Park a question for a person with a prompt and optional options; holds its branch until answered or expired |
| `nexus.conversation.spawn` | `spawn` | Create a child conversation from a captured `declaration`, or use the generic identity path when no catalog is declared, and send its first request |
| `nexus.conversation.send` | `send` | Address an input to another conversation, optionally selecting its answerer; no task dependency |
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
| `nexus.tools.search` | `tool_search` | Search this execution's available tools and skills by name, task words, or runner and tool name |
| `nexus.tools.call` | `tool_call` | Invoke an exact callable discovered by search, including deferred schemas |
| `nexus.runners.list` | `runners_list` | The runners this execution may address, with their environment facts |
| `nexus.models.list` | `models_list` | Currently available model references, identities, capabilities and pricing; optional case-insensitive `query`, `limit` (default 20, maximum 100) and `offset` (default 0) return `models`, `total`, `offset` and nullable `next_offset` |
| `nexus.skill.load` | `skill` | Load one skill's instructions from its accepted source |

New `send` and `spawn` requests obey the recipient Agent's Public/Private setting in the Workspace's [Agent messaging policy](agent-api/workspaces.md#read-messaging), using the calling Run's answering Agent as the sender. Accepted work and kernel result replies retain their existing delivery rules; `status`, `cancel` and history reads keep their existing authorization.

The memory family is the one overridable family: a tool provider may take it over under the workspace's explicit opt-in, and must take the whole family.

Every kernel tool crosses the approval stage like any other; `ask`, the memory tools and `delegate_task` are commonly allowed by rule. Model-authored branches do not receive the graph-building `task` capability, so delegation from a model has one level; `spawn` remains available and its children can delegate further.

Each tool's exact schema, the alias grammar and the import rules are in [Run tools](agent-api/run-tools.md#the-kernel-tool-catalog); the orchestration tools' semantics are in [Run orchestration](agent-api/run-orchestration.md#the-seven-tools).
