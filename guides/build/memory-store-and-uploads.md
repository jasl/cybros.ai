# Memory, store and uploads

Three kinds of durable state, each with one owner in Nexus:

| State | Use it for | Who reads it |
| --- | --- | --- |
| Memory | Model-readable text the agent remembers: notes, decisions, skills | The model, through kernel memory tools and prompt assembly |
| Store entries | Opaque JSON an application keeps: routing, recovery and delivery state | The application only |
| Uploads | File bytes: attachments to inputs and captures published by executors | Models (when the media type is supported), applications, people |

Agent business data persists through Nexus wherever possible. Local working files belong to the runner; an application's own source and installed packages stay local to its installation.

## Memory

Memory documents belong to collections, each with a stable UUID and one owner.
A conversation binds selected collections under logical names such as
`conversation/`, `workspace/`, `agent/` and `speaker/`. A path is not a runner
file. Agent/Speaker notes remain separate for every answerer and person across
conversations and Workspaces.

- Use the [collection API](../reference/agent-api/memory-collections.md) for
  owner-scoped discovery/creation, UUID-addressed lifecycle and relative document
  paths. A User, Workspace or Conversation can own multiple collections.
- Use the [conversation memory API](../reference/agent-api/conversation-memory.md)
  for selected binding paths. HTTP mutations pin the collection UUID and the
  document UUID/version; model-facing memory tools do not take those CAS conditions.
- Bindings grant no authority. Profile limits narrow execution sources and
  access. rho external Bots permit writable Conversation and Speaker memory
  and read-only Workspace memory, excluding Agent-private and Human-owned notes.
- Relative Speaker sources use the input's subject at materialization.
  Management may select a subject explicitly; reads do not allocate defaults.
  Delegation retains that subject but uses the receiving Agent's own notes.
- Archive makes a collection read-only; Delete makes it unavailable without
  stopping consumers. Old captures cannot adopt a replacement collection.
- Skills are documents too. Effective bindings constrain their database
  sources; declared Runners can separately serve skill documents.

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
