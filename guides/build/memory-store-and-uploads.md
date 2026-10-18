# Memory, store and uploads

Three kinds of durable state, each with one owner in Nexus:

| State | Use it for | Who reads it |
| --- | --- | --- |
| Memory | Model-readable text the agent remembers: notes, decisions, skills | The model, through kernel memory tools and prompt assembly |
| Store entries | Opaque JSON an application keeps: routing, recovery and delivery state | The application only |
| Uploads | File bytes: attachments to inputs and captures published by executors | Models (when the media type is supported), applications, people |

Agent business data persists through Nexus wherever possible. Local working files belong to the runner; an application's own source and installed packages stay local to its installation.

## Memory

Memory is a set of logical documents addressed by path. `conversation/` belongs to one dialogue, `workspace/` contains shared knowledge, and `agent/` belongs to the answering Agent. `speaker/` contains that Agent's notes about the current Speaker, separate for every Agent/Speaker pair across conversations and workspaces. A private Agent's owner uses the same Speaker mechanism as an outside visitor. The default prompt mechanism injects relevant memory; the kernel's `memory_*` tools (`memory_ls`, `memory_read`, `memory_grep`, `memory_write`, `memory_edit`, `memory_delete`) read and write it during a run with conditional writes against a document's version.

- `GET …/conversations/{id}/memory`, `POST …/memory`, `…/memory/show`, `…/memory/delete` address a conversation's bound scopes.
- `/agent_api/v1/profile/memory` is the person's own door to the same store and a paired agent's door to its own `agent/` scope; `/agent_api/v1/profile/agents/{name}/memory` is the declarer's door to a named Agent's; the workspace has its own scope.
- Scopes follow access: a read-only binding refuses writes with a named refusal, and an unavailable binding reports `memory_scope_unavailable`. A profile's `memory_context_limit` caps inherited bindings. rho's external Bots permit writable conversation and Speaker memory plus read-only workspace memory, and exclude Agent-private and Human-owned notes.
- Bind `speaker_public_id` explicitly for management before a first input. Inputs otherwise capture their Speaker when they materialize. Delegation preserves the Speaker; a different answering Agent reads its own notes about that person. Human-owned `user/` documents remain an explicit Human scope and are not an Agent's default personal memory.
- Skills are documents too. The effective memory context limits their database sources; a declared runner can separately serve documents the `skill` tool loads.

The kernel owns the mechanism and the application owns extraction and ranking. Nexus does not automatically extract memory from conversations; rho offers an optional [background memory review](../use/files-images-memory.md#background-memory-review). A model saying it remembered something should be backed by a successful memory operation.

## Store entries

A bounded, namespaced JSON current-value store on three hosts: a workspace, a conversation and the acting principal's own profile.

```http
GET/POST  /agent_api/v1/workspaces/{id}/store_entries
GET/POST  /agent_api/v1/workspaces/{id}/conversations/{id}/store_entries
GET/POST  /agent_api/v1/profile/store_entries
```

Entries are keyed by `namespace` and `key`, hold any JSON value including `null`, and commit before external effects so an application can resume from them. Creation requires an `Idempotency-Key` and replays its receipt. Reads and writes share the resource's rate-limit budget.

## Uploads

Stage bytes first, then name them on an input or an InferenceRequest; a steer cannot carry attachments.

```http
POST /agent_api/v1/uploads                       # stage bytes (member plane)
GET  /agent_api/v1/uploads/{id}/bytes            # read, with HTTP Range
GET  /agent_api/v1/uploads/{id}/thumbnail        # 256 px on the longest edge
GET  /agent_api/v1/uploads/{id}/preview          # 1600 px
POST /agent_api/v1/executor/uploads              # an executor publishes a capture
```

- Images and PDFs use native placement when the selected model supports them; other files reach the model through attachment-tool references.
- Reading follows one rule: the creator, or anyone with access to a readable referring row — an input's attachment, a tool result's capture. Anything unreadable is `404`.
- Uploads are immutable and carry a strong `ETag`; a matching `If-None-Match` answers `304`.
- Thumbnail and preview generation is limited to 30 per minute and answers `representation_unavailable` for a file with no such representation.
- An executor publishes a capture through its own upload door and names it as a `resource_link` in a committed result; the result binds it. See [Captures and files](../runners/captures-and-files.md).

The complete contracts are the [Conversation memory reference](../reference/agent-api/conversation-memory.md) and [Profile memory](../reference/agent-api/profile-memory.md) for memory, [Store entries](../reference/agent-api/store-entries.md) and [Uploads](../reference/agent-api/uploads.md).
