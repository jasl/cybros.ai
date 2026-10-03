# Agent API Conversations

Completed conversation executions follow [execution retention](execution-retention.md): text stays readable after execution detail expires.

Status: live Agent API resource.

A Conversation is the timeline aggregate: a position-ordered sequence of
turns (each with its variant candidates and settled content), a durable
input queue that IS the message envelope, fork-without-copy lineage, and a
per-conversation replay event stream. The kernel COMPILES the reply prompt
by default from the knowledge it holds; `context_mode: "raw"` is the
advanced escape hatch where the caller owns the whole prompt verbatim.

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/archived
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}/children
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}/archive
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}/unarchive
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/reorder
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/forks
PUT    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/runner
PUT    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/access
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/cancellation
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/edit
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/regeneration
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{variant_public_id}/activation
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{public_id}
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{public_id}/request
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/context_estimate
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/compaction
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/events
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/show
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/delete
WS     /agent_api/v1/cable
```

## Lifecycle: the working list, the bin, the condemned phase

- `POST …/conversations` — create under the caller's `Idempotency-Key`
  with `{ conversation: { title?, metadata?, billing_subject?,
  runner_executor_public_id?, answering_user_public_id?,
  access?: { default?, entries?: [{ user_public_id | handle, level }] } } }`.
  Creation and exact receipt replay both return `201` with the original
  response body. `Idempotency-Replayed` is `false` for a new creation and
  `true` for a replay.
  `answering_user_public_id` names the Agent Profile that ANSWERS this
  conversation: whose declaration chooses the engine of every
  reply head, whose `system_prompt` slot leads every assembled turn, whose
  standing the runner is judged for; omitted, the creator answers its own
  conversation (an agent creator brings its engine; a Human creator has a
  plain chat until a profile is named); refused 422 `answerer_not_eligible`
  unless it names an agent profile of the account that may write in this
  workspace (absence, a Human, the system user, a removed or
  dedication-fenced profile conceal as ineligibility); it never changes
  after create and a fork copies it.
  `runner_executor_public_id` names the runner-kind executor the
  conversation's runner-tool calls are addressed to from birth — refused
  422 `runner_not_eligible` unless it names a live runner eligible for the
  conversation's ANSWERER; omitted, the conversation is UNBOUND — the
  kernel infers no runner, however many are eligible (a
  runner-tool call on an unbound host fails `tool_not_served` at start).
  Both names ride the idempotency envelope, so a replay naming another is
  409 `idempotency_envelope_mismatch`. The conversation document carries
  the binding as `runner: {executor_public_id, display_name, presence,
  last_seen_at?} | null` — where the next round's runner-kind calls land,
  null before any binding and after a reap; presence is display, never a
  reason to choose. Not on the listing shape — and `answering_user_public_id`
  on both shapes. The document also carries THE ACCESS CARRIER:
  `access: {default, entries: [{user_public_id, handle, kind,
  display_name, level}]}` — the level (`full | read | none`) of every principal the
  entries do not name, and one entry per named principal. The creator and
  the answerer are `full` by derivation and never appear as entries; `none`
  conceals. Every conversation is born `full` (every member, not
  create-frozen). THE CARRIER AT BIRTH: `access` on the
  create body names the default and the entries — each `{user_public_id,
  level}` OR `{handle, level}` (the member's handle, written
  `@lark` or `lark`, resolved at the door; one spelling per entry), the
  ids and handles from `GET …/workspaces/{id}/principals`; omitted, `full`
  with no entries. A principal that may not be named — the creator, the
  named answerer (both full by derivation: a row would lie), the system
  user, an unknown id or handle, a principal named twice by either
  spelling, an entry spelling both — is refused 422
  `principal_not_eligible`, ONE code with no detail (every id named is the
  caller's own account's; the listing says which); an unknown level or
  default is 422 `validation_failed`. `access` rides the idempotency
  envelope in the request's own entry order — array order is request
  identity on this surface, so a replay that lists the same entries in
  another order, or omits them, is 409 `idempotency_envelope_mismatch`; a
  refused create writes no receipt, so its key is free. Not on the listing
  shape; never null. An entry is
  self-describing: it includes the principal's `display_name` so a client
  can render the access list without another lookup. THE LEVEL IS THE DOOR: `none` conceals — every member-plane door over the
  conversation (the lists, show, turns, events and the events channel,
  inputs, store, memory, fork, the replay of a create or fork receipt,
  and every route of a loop one of its turns hosts) answers 404 for a
  `none` principal, exactly as a tombstone does, never a 403 that admits
  the row exists. `read` is read: every read answers, and every write —
  an input, a rename, archive, unarchive, delete, fork, a turn's edit,
  regenerate, cancel, delete and view-state, a compaction request, the
  store, the memory door, the runner handoff, and every verb on a hosted loop — is 403
  `not_authorized`; `full` is what write standing has always meant,
  still conjoined with the workspace's. The kernel's own acts never
  consult the level: the answerer's engine writes its turns, and a
  task's receipt lands as kernel mail whatever the loop's creator holds.
- `PUT …/conversations/{id}/runner` — THE HANDOFF: body
  `{ runner: { executor_public_id } }`, a whole replacement of the binding.
  The caller is the conversation's answering profile on its own member
  bearer or a Human with write standing ON THE CONVERSATION — `full` on
  the row with workspace write standing (a Human the row
  lists at `read` has none, whatever the workspace says); any other agent
  is 403 `not_authorized`; a transport credential never reaches the member
  plane. The target must be a runner-kind executor of the account
  eligible for the conversation's ANSWERER: 404 `runner_not_found` (an
  unknown id, a tools provider, an agent address), 409
  `runner_not_eligible` with the message naming why (`revoked`, `no ready
  credential`, `shutdown pending`, `not in scope for this host's
  principal`); the same id is a plain 200 (idempotent by value, no
  receipt). 200 answers the conversation document. The kernel records
  `runner_bound` on the feed, then — per live loop of the conversation,
  under that loop's own lock — the unclaimed runner-kind rows are
  re-addressed through the one addressing site with their park clock
  re-armed at `now + the new runner's timeout_ms`, narrated
  `task_readdressed`; claimed rows finish where they started; a name the
  new runner does not serve fails `tool_not_served` at once, honouring
  `on_failure`. The host filesystem is implicit state — the person moves
  the checkout; the switch is never implicit.
- `PUT …/conversations/{id}/access` — THE ACCESS CARRIER'S LATER CHANGE: body `{ access: { default, entries?: [{ user_public_id |
  handle, level }] } }`, a WHOLE replacement of the default and the named entries
  (entries omitted is the empty set) — the handoff's shape: PUT, never a
  PATCH twin, idempotent by value, no receipt. Full control includes changing permissions:
  `full` on this row — the creator, the answerer, or a `full` entry — with
  write standing on the workspace; a principal the row lists at `read` is
  403 `not_authorized` (it cannot escalate itself), one it conceals finds
  the door 404 before any standing is judged. The creator and the
  answerer can never be locked out (full by derivation); a `full` peer may
  narrow the default — a product that wants less narrows. 422
  `principal_not_eligible` and 422 `validation_failed` as on create; a
  tombstone is 404; the archived bin accepts it (who may read the bin is
  not content). 200 answers the conversation document; the same set is a
  plain 200 with nothing written. The kernel narrates ONE `access_changed`
  item on the feed per change — `{default, entries: [{user_public_id,
  level}], by, kind}`, the actor's kind recorded (`human | agent`) — and never bumps `context_revision`: assembly does not read the
  carrier. An agent learns its own id from `GET /agent_api/v1/profile`
  (`member.public_id`) and its peers' — and its own steward's — from
  `GET …/workspaces/{id}/principals`.

The DEFAULT list is the working surface — unarchived, top-level, and
never a SIDE conversation (`side: true`, below); `?side=1` lists the
workspace's sides only, any parent — a side is a child row a UI may
hide, and the flag is the one way to see them (any other value is the
default). `/archived` is the recycle bin's own view. A subagent conversation
(`parent` present) is a lifecycle FOLLOWER: readable by id, listed only
through its parent's `/children` (the nested resource — the Rails-native
shape a follower has always been listed by, through the one read funnel,
keyset-paged; there is no `?parent=` filter on the working list), never a
direct archive/delete target — the parent's verbs stamp the whole tree,
and the parent's `POST …/cancellation` stops work derived from its execution
owners, including their subagent requests (below). It is born by the kernel's `spawn` tool alone
(see [Agent loops](agent_loops.md)): off the spawning loop's
conversation, never a branch. THE PARENT FACTS ride both shapes as ONE
block, `parent: {public_id, spawn_node_key, label} | null` — the
parent's id (a public-id snapshot that survives the parent's reap, as
every child's does), the key of the `spawn` call that minted it (the id
the spawning model read back; null once the spawning loop is reaped —
`spawn_node_id` is unique, one child per call, and nullifies with the
loop) and the label `spawn` gave it (null when none; `[a-z0-9][a-z0-9_-]*`,
≤ 64, unique among one parent's children). The child is created by
the spawner's profile and answered by the chosen one — the creator's own
(a subagent) or a named peer — through the same answerer door as
`POST …/conversations`; it copies the parent's access carrier (the
parent's entries plus its derived-full pair materialized, minus the
child's own derived pair), billing pair, and bound runner when that
runner is eligible for the child's answerer; its `user/` memory rung is
the answerer's controlling Human's whoever posts into it. A SIDE never
spawns and is never a child's answerer. Spawn's `lifetime` controls the
initial request's completion obligation, not the child Conversation's lifetime:
`turn` requires the original execution's report before its caller's final reply;
`conversation` permits later mail. The child remains reusable in both modes.
Later sends, human inputs, and regenerated executions are separate work.
`PATCH {public_id}` updates `title`/`metadata` (the bin refuses:
unarchive to rename).

- `POST {public_id}/archive` — reversible, read-only bin (a subagent
  target refuses `subagent_follows_parent`, 409 — the parent's verb stamps
  it): new caller
  inputs refuse with `conversation_archived` (409); a running generation
  completes into the archived row, and kernel-stamped mail (a subagent's
  completion notice) still passes. The end is narrated: one
  `conversation_ended` (`reason: archived`) on every member stamped, in
  the verb's transaction ("Events" below). Fork of an archived source is permitted
  — a pure read-derivation. A side conversation is never archived
  (`side_conversation`, 422); the parent's archive reaps its live sides
  FIRST, a running one cancelled by the kernel's own act, never refused.
- `POST {public_id}/unarchive` — blanket-restores the tree (a side refuses
  `side_conversation`, a subagent `subagent_follows_parent` (409); the
  reaped ones do not return).
- `DELETE {public_id}` — delete intent: the tombstone command. Refuses
  `subagent_follows_parent` (409) on a subagent target and
  `conversation_busy` (409) while live work runs anywhere in the tree;
  narrates `conversation_ended` (`reason: tombstoned`) on every member
  stamped as the last item its feed carries — on the cable at once, and
  the next poll is the 404;
  repeated delete answers 404 (the condemned phase conceals like absence);
  physical reclamation follows after the frozen 30-day window, deferred
  further while any fork child's closure still pins the row. On a SIDE
  conversation DELETE is tombstone AND reap at once: its running turn, if
  any, is cancelled first, the row is stamped and reaped in the same call
  (204, then 404) — exact when idle, and bounded by the reap sweep's
  cadence only while a cancelled attempt's settlement is still pending. A
  side has no children, so leaves-first holds; the parent's tombstone
  reaps its sides first, and a side never pins its parent's reap.
  Reclaiming a conversation also marks its hosted loops for deletion:
  their execution history follows the existing settlement and retention
  rules, and they never reappear as independent workspace-visible loops.

### Agent removal

Removing an Agent Profile synchronously revokes its member access and its
Agent-application credentials, then asynchronously force-stops related work.
This is a consequence of the existing remove operation, not a new Conversation
endpoint or an Agent suspension API. The independent Runner registration is
unchanged; its work in a stopped loop receives the ordinary cancellation.

Related work includes a Conversation whose creator, default answerer, current
turn's initiator or answerer is the removed Profile, its related spawned
descendants, and still-live historical or background loops using that Profile.
Historical participation alone does not stop another Profile's unrelated
current turn; a fork's shared prefix does not create a stop relationship.
The stop uses the existing
force-stop behavior; it does not delete transcript or previously accepted
results, and late results cannot overwrite canceled terminal tasks.

The response guarantees the access cut, not an already-terminal Conversation
or task. Status can lag, and tasks may instead reach their ordinary deadlines.
An after-commit wake starts cleanup; a bounded recurring scan recovers lost
wakes, including for paused work whose ordinary clock is frozen. Cleanup
checks that the Profile is currently removed. After restore it skips that
Profile, so an old cleanup wake does not stop new work admitted after restore.
Restore does not wait for cleanup or revive old credentials or stopped work.
There is no durable removal episode or promise to withdraw every old delivery
across an intervening restore. A fresh DeviceFlow connection reuses the retained
Agent-application address with new credentials.

## Inputs — the one front door

Every caller-authored message rides `POST .../inputs` with an
`Idempotency-Key`. The accepted row is the durable waiting room; a drain
materializes it into a turn (messages immediately when the lane is idle;
`direct_reply` heads become a running assistant turn). Within the 24-hour
replay window, the same key and request return the original complete `202`
acceptance, including text, raw instructions and assembly intent, even after
the queued input has been edited or consumed. `Idempotency-Replayed` is
`false` for a new acceptance and `true` for a replay. A changed request with that key
returns `409 idempotency_envelope_mismatch`. The receipt adds no separate
prompt-size ceiling: submitted content and the compiled request retain their
own storage and model-window limits. Long inline text, declared variable
values and raw instructions are accepted under the same rules on CREATE and
PATCH; an assembled prompt that exceeds its storage wall when materialized
remains a blocked input that can be edited or deleted.

The answering Profile determines the reply's engine: the input's
`answering_user_public_id` when supplied, otherwise the Conversation's stored
answerer. A peer's post uses that addressee's configuration, not the poster's.
For an ordinary reply, a Profile with tool declarations or lifecycle hooks
produces a kernel AgentLoop. A Profile with neither, or a Human answerer,
produces a direct `conversation_reply` model invocation. Kernel result-mail
replies use a loop even when the receiving Profile has neither tools nor hooks,
so their failed model tasks remain repairable.

A backing loop starts `running`; its first round seals the assembled request
with the Profile's tools, narrowed by the input's `tool_names`, and freezes its
compaction, hook, approval, and memory policy. An explicit `tool_names: []`
removes tools for that turn while retaining the declaring Profile's loop engine.
The variant reports `source: "agent_loop"`, and turn events carry
`agent_loop_public_id`. A client submits the input, not a separate
`POST .../agent_loops`. Both engines use the same timeline assembly;
`context_mode: "raw"` or a Profile declaring `prompt_mechanism: "raw"` instead
uses the input's own entries.

FILES BESIDE THE WORDS. An input may carry `attachments:
[upload_public_id, …]` beside its `text` — ids of the caller's own staged
uploads (`POST /agent_api/v1/uploads`, creator-scoped: an unknown, another
creator's or a fileless id refuses `422 unknown_input_upload`, whole or
nothing; a malformed id is `400 parameter_invalid` at the boundary). The
door composes ONE message entry — the words, then the attachments in the
order given — and binds the uploads for liveness (a bound upload is never
reaped); a file with no words is a message (`text` reads `""`). Images may
be carried natively; ordinary files (PDF, Office, text, code and archives)
are indexed with filename, detected type, size and a `nexus://uploads/<public_id>`
reference. Executors can import those bytes through their active claim's
[attachment resources](executor.md#read-bound-input-attachments), then parse
or inspect them with their workspace tools. Nexus does not execute or parse
arbitrary documents and does not broaden native model media allowlists.
A steer takes none — `attachments` beside
`delivery_mode: steer` refuses `422 attachments_not_steerable`; `rho`'s
`--attach` implies `--mode queue`. `attachments` never ride beside raw
`entries` (`400 parameter_invalid`): the raw grammar places its own
`{"type": "upload"}` parts, and the door binds what those placed. The
set is in the idempotency envelope, so a replay naming another set is
a mismatch. The row shows its pictures as `attachments: [{public_id,
filename, content_type, byte_size}]` in part order — the row's fact,
whatever the answerer reads. WHAT THE MODEL READS is decided per part,
per turn, at assembly against the turn's resolved engine: a row whose
`capabilities.input_modalities` includes `image` (and whose wire takes
the type) receives the picture natively — the sealed request carries
the `upload` part and binds the row; any other engine reads, in the
picture's position, one text part
`[Attachment: diagram.png (image/png, 184,213 bytes) — image content
omitted: this model does not support image input]` (or `— this model
does not take image/heic` when the row takes images but the wire
refuses the type), and the sealed request binds nothing. The picture
survives on the reply turn's kept prompt either way, so a later turn
under a vision engine reads it natively and under a text engine reads
the line: a later turn sees the attachment in history. A native
picture is funded in the history budget at the wire's declared per-image
cost (0 where the wire declares none); the byte wall counts words only.
A compaction summary reads a picture as a POINTER in
its position — `[Attachment: diagram.png (image/png, 184,213 bytes) —
not carried past the summary; ask for it again if needed]`, the index
line's grammar with the summary's reason — and the summarizer is told to
name it, never describe what it showed; after the cut the picture leaves
the wire with the turns the summary replaced. An attachment's bytes are
read back by `GET /agent_api/v1/uploads/{public_id}/bytes` by any reader of
the conversation (uploads.md, one rule for every upload a row names — a
tool result's capture reads the same way), and a picture of it for a UI by
the two named reads beside it, `…/thumbnail` and `…/preview` (presets named
in code; an upload with no representation of that kind is
`404 representation_unavailable`); every one of the three carries a strong
`ETag` and answers `If-None-Match` with `304`; a narrowing to `none` closes
those reads with the rest. The
SDK spells the field `inputs.create(attachments: [...])` (ids or the
`Upload` values `uploads.create` answered; `update` the same, `[]` to
unbind) and reads the row's pictures back as `UploadRef`s; `rho run --attach
PATH` (and rho-dev's `rho do/say --attach`) posts the path to the daemon, which stages the bytes on its
member plane as rho's own user and binds the ids.

WHERE A `direct_reply`'S WORDS LIVE. A `direct_reply` whose `text` is the
person's words (the shape rho's `do`/`say` post — one row, one
materialization) creates NO user turn: the text rides as the final user
message of that turn's sealed request, and is kept on the reply turn as
its prompt. A later turn's assembled history renders each earlier reply
turn as its preface — the per-turn text its request placed between
history and the words, replayed for the answering agent's own turns
("The default template" below) — then the words that opened it, in the
user role, then what it produced — a tool-less reply's text, a
loop-backed turn's rounds (text, calls, results) from rows — so the
timeline records the assistant's turn alone and the model still reads
the question before the answer. The
kernel's own receipt is such a turn: its words are the `<task_result>`
envelope, delivered to a later turn exactly once — there, never again at
the call that started the task. A turn whose in-turn summary arrived
renders the summary in place of everything before its repaired round,
its preface and opening words included. Each such turn is one more history entry,
funded by the history budget like any other: under a tight budget a
turn's rounds outlive its opening words, and older turns leave the
window sooner. A client that wants the person's words as a turn of the
timeline's own still posts a `message` first.

WHOSE WORDS (the speaker envelope). The unlabelled user
voice a model reads is its PERSON's: a row posted directly into the
conversation by one of its own voices — its creator, the ANSWERER of the
turn the row is read for, or the Human that answerer answers to (an
answering profile's steward; the human themself on a human-answered
turn) — renders bare. The answerer is the TURN's: the
input's addressee on the wire, the turn's own `answering_user_public_id`
in history — the conversation's default everywhere but a group turn, so
a 1:1 conversation keeps its bytes and B's turn bares B's person, not
A's. Every
other user-side row is rendered, wherever the model reads it, in the
line-structured speaker envelope, naming its author by handle, kind and
id and the conversation it was sent from when the row carries a sender
stamp (a turn's author is its SPEAKER — `speaker_actor`'s User, which a
fork's adopted boundary turn keeps while control passes to the forker,
so a colleague's word stays the colleague's in the fork):

```
<message from="@lark" kind="agent" user="<public_id>" conversation="<sender conversation id>">
…the row's words…
</message>
```

That is another human's word, another agent's, and every row sent FROM
another conversation whoever sent it (a peer's `send`, a spawn brief —
the spawner's row on a copy of itself). The kernel's own rows (`origin:
task_result | child`) are never wrapped: their text IS the
`<task_result>` envelope. ONE renderer serves the five sites the model
reads a row at — the trailing user message of the turn it opens, that
turn's seed in later history, a user-role `message` turn's content, the
steer tail of a running round, and the summarizer's transcript — so the
sealed request and the next turn's prefix carry the same bytes. The
envelope is rendered at assembly and never stored: the row and the
turn's prompt keep the bare words, a renamed handle re-renders from the
row. Inside any envelope, a body may not forge or close one: exactly
four forms — `</task_result`, `</message`, `<task_result ` and
`<message ` — are spelled with `&lt;` for their `<`; `&`, every other
`<` and code stay as written, and the spelling is reversible. A child
whose reply echoes its brief's tag lines therefore reaches its parent
with those lines spelled inside one `<task_result>`, never as a second
envelope. Adjacent user-role segments still merge into one user entry on
the wire (the envelope, then the person's next word, each its own part) —
the merge is the wire's, and no envelope goes around the kernel's.

ANOTHER AGENT'S TURN (the group's history). History is
assembled FOR the turn's answerer. A reply turn that answerer wrote is
its own work and renders as today — its seed, then its rounds or its
text. A reply turn ANOTHER agent answered is not the model's work: it
renders as ONE user-side segment — its seed under the seed's own voice
(the question that agent answered), then that agent's FINAL TEXT (the
turn's `content`, the same text the timeline shows) in the speaker
envelope of the agent that answered — never that agent's rounds (a wire
pairs calls with results of one loop). Two seeds are skipped: one the
assembling answerer itself posted (its own addressed row is already the
call in its own rounds), and a kernel-origin one (that receipt was the
other agent's). A turn that produced no text renders only its seed. So
A reads B's answer as `<message from="@b" kind="agent" user=…>`, and B
reads A's turns the same way while seeing its own as assistant history
— each agent sees itself as the model and every other agent as a
correspondent. The summarizer's transcript and the estimate render every
turn as spoken. The prefix property (a side's first request equals
the parent's above the boundary) holds for a side taken from a 1:1
conversation or during a turn its default answerer runs; a side taken
during another agent's turn answers as that agent and renders the
parent's turns under that agent's reading — a different prefix by
design.

```json
{
  "input": {
    "kind": "direct_reply",
    "text": "optional prompt riding as the final user message",
    "model": { "model": "openai_api/gpt-6.1-sol", "reasoning_effort": "medium" },
    "configuration": {},
    "tool_names": ["read_file", "write_file"],
    "approval_mode": "ask",
    "delivery_mode": "queue",
    "deliver_in": "20m",
    "context_mode": "assembled",
    "history": { "max_entries": 20, "token_budget_share": 0.5 },
    "expected_context_revision": 4,
    "expected_tail_turn_public_id": "0198…",
    "answering_user_public_id": "@lark"
  }
}
```

- `kind` — `message` (content; born completed at materialization) or
  `direct_reply` (asks the kernel for an assistant reply).
- `answering_user_public_id` — WHO ANSWERS THIS TURN (group
  chat): the create door's word, an ADDRESS — `@handle` or a public id,
  resolved at the door within the account (the SDK spells it `to:`,
  rho `--to`; the `send` tool spells it `agent` — on every model-facing
  tool `to` is a conversation and `agent` a principal). Absent is the
  conversation's stored answerer (the default;
  a Human's plain chat is answered by the Human). The named profile must
  be a member that may answer here: an agent of the account that may
  write in the workspace (the create door's rule) holding `full` on this
  conversation (`read` cannot post, so it cannot answer) — a name
  that is nobody's is 422 `principal_unknown`; a Human, the system user,
  a `read`-level or fenced profile is 422 `answerer_not_eligible`, the
  create door's word. The kernel's own mail carries its mailing loop's
  answerer on the same field and is never judged. Frozen on the row and
  on the reply turn it opens (`answering_user_public_id` on both, in
  `input_accepted` and `turn_created`): the addressee's engine, tools,
  `approval_mode` word and `system_prompt` answer that turn; its
  `tool_names` and `approval_mode` are judged against the ADDRESSEE's
  declaration. Create-only — the edit surface drops it — and in the
  idempotency envelope (a replay naming another addressee is
  `idempotency_envelope_mismatch`). Refused by name on the loop door.
  THE ADDRESSEE'S ENGINE (the agent's own
  preset first, else the initiator's): a reply row addressed AWAY from
  the conversation's stored answerer, and every row a peer SENT (an
  agent's `send`, the spawn brief), runs on the engine that answers for
  that addressee, in ONE order — the addressee's own `default_model`
  ([Profile](profile.md), the seventh column, at the model's own
  reasoning default), else the addressee's last reply turn's model trio
  in this conversation, else the conversation's last reply turn's, else
  the row's own `model` — THE INITIATOR'S on a `send` or a brief: the
  call's `model` when it named one, else the round it ran in
  ([Agent loops](agent_loops.md), `spawn`/`send`). The kernel stores the
  fact and carries the initiator's model; it chooses nothing. The
  conversation's own rows posted as itself (the person's `model` on a
  1:1 lane — the user's own choice) and the kernel's mail keep the model
  they name. A `send`'s `agent`, when named, is the addressee, else the
  conversation's answerer: the addressee's conversation, the addressee's
  engine. The model an addressed turn runs on is readable on its loop's
  `turn.model` ([Agent loops](agent_loops.md), the turn shape) and on
  the turn's `active_variant.model`.
  THE WAKE RULE OF A GROUP falls out of this one column: the idle unit is
  the CONVERSATION (one active turn per conversation, the queue read in
  order), an agent is ADDRESSED and never woken — a `to: B` while A's
  turn runs queues and opens B's turn at A's boundary; an unaddressed
  word wakes the default answerer alone; the kernel never fans out (a
  product that wants N answers posts N addressed rows). The conversation's
  runner binding, its `handoff`, its `memory_principal` and the inbox's
  scope stamp stay the HOST's — the default answerer's and the poster's
  Human — a group's environment is the conversation's, not each agent's.
- `delivery_mode` — `queue` (default: an idle recipient begins
  immediately, a busy one at the next turn boundary — and what the
  kernel's own mail always is) or `steer` (bind to the in-flight reply;
  a principal's input steers — a person's, or an agent's `send` with
  `steer` — never the kernel's mail). A steer is a redirect, so it needs
  something to redirect: with a reply in flight the row is held
  `steering` against that turn; with the lane IDLE there is nothing to
  redirect and the row simply queues (`pending`) — the words are still
  worth delivering, and the state tells the sender which it got. Only a
  `direct_reply` turn binds a steer (a message or a summary turn has no
  request to land in), and only one answered by the row's addressee: an
  UNNAMED steer addresses the RUNNING reply's answerer (the correction
  reaches the agent actually running, never the default past it), a
  NAMED `to` that differs from the running answerer queues for its own
  turn (`pending`, no binding — nothing corrupts, so no refusal).
  An optional `expected_steering_loop_public_id` pins a conversation steer to
  one loop execution. The door compares it with the reply's running candidate
  under the conversation and loop locks. An idle room, another addressee, a
  different candidate, a tool-less reply or a loop that has already delivered,
  stopped or begun canceling refuses `409 steering_target_changed`; it never
  queues instead. The selector is a canonicalized UUID (`400 parameter_invalid`
  when malformed), requires `delivery_mode: steer` (`422 steering_guard_requires_steer`),
  and is not admitted on the standalone loop door. It is fixed on the accepted
  input and included in its idempotency envelope; exact receipt replay still
  returns the original acceptance after the execution ends. If the target ends
  before consuming the correction, that input is canceled with the existing
  `input_deleted{steer_canceled: true}` event. It never reaches a replacement
  execution or a later turn. This selector grants no authority to the caller.
  Without that selector, when the bound turn settles — completed, failed or canceled alike —
  the binding is over and the row falls back to the queue (narrated
  `input_edited{state: pending, reason: steer_target_settled}`),
  releasing the caller's bound; a steer no longer sits `steering`
  forever waiting on a reply that already ended. This also covers inputs
  accepted after the loop finishes but before its turn status converges,
  and replies delivered while their background work continues. A previous
  candidate's background completion does not release steers for a running
  regeneration. ONE EXCEPTION, on a
  loop-backed turn: a HOLD — the turn `failed` because its
  loop is `needs_attention` — keeps steers bound, since a retry or an
  answer reopens that same turn and the steer lands with it. The same
  hold gates the queue: a queued row that predates it waits, narrated
  once as `input_blocked{blocked_reason: loop_held}` with no state
  written; only a caller-authored input typed AFTER the hold AND
  addressed to the held answerer materializes behind it (it is the
  person's answer, and it opens the next turn; a post-hold row addressed
  to ANOTHER agent waits like a pre-hold one — opening that agent's turn
  would replace, and so kill, the repairable loop) — the gate is judged
  per row in read order, so a held kernel receipt at the head never
  keeps that answer from reaching it (the one `loop_held` item names the
  first row in read order, whichever it is); the receipt drains once
  the repaired turn stands.
- `deliver_at` / `deliver_in` — NOT BEFORE this time. Exactly one: `deliver_at` an ISO 8601 time WITH an offset
  or `Z` (a wall-clock time with no offset is `400 parameter_invalid`), or `deliver_in` a delay from now (`90s`,
  `20m`, `2h`, `1d`). The row is accepted now, sits in the queue at its arrival position, and is invisible to the
  drain until the time passes — it neither heads nor blocks the queue before then; when due it drains in read
  order and wakes an idle conversation (the receipt's own path). More than two minutes past: `422
  deliver_at_in_past`; more than ten years ahead: `422 deliver_at_too_far`; both fields: `422 deliver_at_ambiguous`.
  `queue` only: beside `delivery_mode: steer` it refuses `422 deliver_at_not_steerable`. The kernel's own mail never
  carries one. A scheduled row counts toward `input_queue_limit` while it waits. Conversation door only: the loop
  door refuses it by name. The listing shows `deliver_at` on the row.
- `context_mode` — `assembled` (default: the kernel compiles history +
  prompt, adjacent same-role messages merged for the wire) or `raw`
  (reply lane only: `entries` is the verbatim message array; no history,
  no merging; bounds and the window gate still apply). A raw assistant
  entry may carry `phase` beside the `native_origin` that licenses it,
  exactly as a sealed entry does (the preview's `entries`, below), and
  the compiler resends it under the same rule.
- `instructions` — the system field under `context_mode: raw`, the `raw`
  grammar's one field outside `entries`: sealed as sent in the wire's own
  slot (`request_options.instructions` on a tool-less reply; the round's
  system field on a loop-backed one, inherited by every continuation) —
  one copy per round, never a list item. Refused 422 on an assembled
  input, whose system text is the slot blocks the kernel compiles into
  the list, and by name on the loop door. Rendered on the row when
  present; editable while queued.
- `tool_names` — THE TURN'S TOOL SUBSET: the flat wire names, out of the
  declaring profile's `tool_definitions`, that this reply runs with.
  Absent means the whole declaration; an EMPTY list means no tools at
  all — a reply from context alone, still under the declaring profile's
  engine (a side conversation's `btw`); a list narrows it by name and
  never adds — a name the profile does not declare is 422
  `validation_failed` naming it (a subset, never an addition), a list
  that names a tool twice or names a blank is 422, and a scalar is 400
  `parameter_invalid`. The input already carries the turn's model, so
  the turn's tools ride beside it (the `context_mode`-overrides-
  `prompt_mechanism` precedent): frozen onto round `r1` at
  materialization — the declaration's own bytes, fewer of them, in the
  declaration's order — through the same narrowing a `task({tools})`
  branch uses, and inherited by every continuation of that turn. A
  reply-lane field: on a `message`, which compiles no request, it is
  422; on the loop door it is refused by name like the model trio (the
  loop's one turn carries its seed's tools). A tool absent from a turn's
  bytes is REFUSED IF GUESSED: the declaration is the round's only gate,
  kernel tools included, so a model calling a withheld `compose` gets
  `unknown_tool` and the round goes on. Rendered on the row (`tool_names`)
  when present; editable while queued, where `[]` is no tools as on the
  create and "back to the whole declaration" is the whole declaration by
  name (the `approval_mode` rule: no clear gesture).
- `approval_mode` — THE TURN'S TIGHTENING of the declaring profile's
  approval mode: `ask` or
  `rules` on a `bypass` profile, `rules` on an `ask` one — only ever
  stricter than the declared word (bypass → ask → rules; each step
  removes a grant path), never looser: a loosening, a word outside the
  vocabulary, or a word on a profile that declared no mode is 422
  `validation_failed` naming `approval_mode`. Absent means the profile's
  own word. Frozen onto the loop row at materialization beside the
  profile's `approval_rules` ([Agent loops](agent_loops.md) "Approval"),
  so the turn's every tool call crosses the stage under it. A reply-lane
  field: 422 on a `message`; refused by name on the loop door (the loop's
  one turn carries its shell's word). Rendered on the row when present;
  editable while queued — there is no clear gesture, send the profile's
  own word (a rank-equal word is lawful).
- Assembled replies also carry the earlier turns' REASONING back to the
  model (default: every turn), in the target wire's own field — signed
  thinking blocks, encrypted reasoning items, Gemini's thought parts, the
  chat message's `reasoning_details` / `reasoning_content`, DeepSeek's
  plain-text reasoning item — when the target can read its origin:
  Anthropic's and Gemini's across their own models (the API drops what a
  model cannot read, unbilled), every other format on the exact model that
  produced it. Reasoning the target cannot read carries nothing — no text
  stands in for it, and signatures and encrypted material never cross.
  Replayed reasoning is history: it is priced with its turn in the one fit
  and leaves the window only with its turn.
- `inline` — the client's OWN text placed into the assembly (the block
  primitive, usable directly — no template needed): a list of up to 16
  entries, each `{ "role": developer|user, "text": …,
  "position"?: "lead"|"tail" }` or `{ "slot": system_prompt|character|
  persona, "text": …, "role"?: system|developer|user|assistant }`. An
  entry naming a SLOT replaces that
  slot's registered prompt document for this turn — the agent's system
  prompt, the room's character, the person's persona ("The default
  template" below) — in slot order, whether or not anything is registered
  there; its role is the registered document's when it names none, else
  `system`. `slot` and `position` never ride together (400
  `parameter_invalid`). A `system_prompt` override may name the
  addressee's declared template variables beside the built-in macros (its
  document may too); the other slots see the built-ins alone. A slot-less
  entry is placed by `position`, where the addressee's template puts its
  `lead` or `tail` block — a template without that block has nowhere
  for it, and the entry is refused 422 `validation_failed` naming
  `inline_position_unplaced` (the built-in order places both): `lead`
  (the default) then `tail` ride behind history and ahead of the prompt.
  Funded like the prompt in the self-fit budget: the client's text never
  yields, only history does. What a turn places between history and its
  prompt is its PREFACE ("The default template" below): sealed with the
  turn and replayed by every later turn of the same answering agent
  where it was sent. A lead equal, role and text, to the lead of the
  newest preface of this answering agent's own turns still in the window
  is laid ONCE — the window already carries it, so an unchanged lead
  re-sent every turn (rho's environment block rides that way) costs one
  copy per window, not one per turn; a changed one is laid with its own
  turn and never edits an earlier one; a lead the window no longer holds
  (a summary or a stated bound removed its turn) is laid again; and
  another agent's history never carries it. A turn that relied on the
  window for its lead records the lead it relied on (never laid, never
  replayed), so a regeneration whose own window no longer carries it lays
  it. A `tail` and a template's own
  post-history inline text are per-turn text and ride every turn that
  renders them. A positioned
  entry is therefore `developer` or `user`: a `system` entry there would
  be a mid-conversation system message the Anthropic and Gemini wires
  hoist into the top system block, an `assistant` one words the model
  never said, and both are refused 422 `validation_failed` naming
  `inline_role_unplaced`; a slot override keeps every role. An
  `assembly` template that places `lead` ahead of `history` makes the
  lead a per-turn block of the prefix instead — an identical lead keeps
  the cached prefix, a changed one moves it, the template's own policy;
  nothing ahead of history is sealed or replayed. `developer` is
  accepted on every lane — the Anthropic and Gemini wires lower it to
  `user` in place, the OpenAI-shaped wires carry it — and a role the
  target lane's wire refuses is the lane's typed refusal, exactly as in
  raw mode.
- `reasoning_replay` — the policy knob beside `history`:
  `{ "mode": "none" | "last_turn" | "all" }` (`all` replays every traced
  turn). The kernel default is `all` on every model — reasoning is
  history: every trace the target can read rides on every later request
  exactly as the request that first carried it did, so each request
  extends the previous one; person turns, kernel mail, regeneration and
  the estimate share it. A trace is priced with its turn in the one fit —
  the provider's reported reasoning count, and its bytes against the
  sealed request's storage bound — and leaves only with its turn: when
  history and its traces outgrow the fit with no bound the caller stated,
  the timeline compaction runs (the head waits behind the summary), never
  a cut of traces alone and never a request re-sent without them; under a
  compaction policy of `off` the request slides, dropping the oldest turns
  with their traces to both the window and the bytes. The fit leaves the
  turn's own answer room on a hard or shared window, `min(32k, 12.5 %)` of
  it; a model planned to an advisory bound below its window has that room
  already. What puts a trace back on a later turn is the caller's own
  word for one turn — a narrower mode named for it, a `history` bound
  stated for it, or the effort set to `none` on a native lane (reasoning
  off replays none) — the next turn at the default carries again what
  that turn left out. After a model switch the earlier traces the new
  model cannot read carry nothing, one change at the switch, and later
  turns on that model extend each other. A provider's non-transient HTTP
  refusal (4xx) of a request carrying native reasoning disables default
  replay for later assembled requests in that conversation; a
  context-window refusal is the compaction's instead (the between-turn
  summary on a direct reply, the in-turn repair on a loop), never a
  reason to drop reasoning. The switch is read where each turn's request
  is compiled: a loop keeps replaying its own turn's reasoning (a tool
  turn must pass it back). One `reasoning_replay_downgraded` event
  identifies the failed task's turn. An explicit caller mode still wins. Already sealed requests, including
  retries, keep their content; raw messages are also explicit content and
  are not rewritten by this default change. The mode governs reasoning
  material only: an assistant message's wire label (`phase`; see the
  preview's `entries`) is the round's own fact, not replay material, and
  rides whatever the mode — to its producing wire and lane only.
- `history` — per-request assembly intent, the estimate surface's exact
  vocabulary (assembled replies only: a message has nothing to compile
  and `raw` skips the compile, so both refuse a stored intent that would
  silently do nothing): at most `max_entries` (≤ 200) newest turns,
  and/or `token_budget_share` (0 < x ≤ 1, six-decimal precision) of the
  model's own window. Stored on the row as `context_options`, honored at
  materialization, and editable while queued — `history: null` (or `{}`)
  clears the intent. The closed vocabulary refuses at the boundary: an
  unknown key or a malformed shape is a 400, never a silent drop. A
  share against a model that declares no window parks the head blocked
  as `history_budget_unavailable` (the estimate returns the same
  refusal). The prompt itself never yields to the bound — only history
  does.
- `variables` — the turn's values for the names the addressee's
  `prompt_template` declares (`{ name: "value" }`, strings), over the
  template's defaults ("The assembly template" below). Body-read like its
  siblings: a non-object is a 400. Admitted only when the addressee's
  standing word is `assembly` — anywhere else nothing would read them and
  the intent is 422 `validation_failed`; a name the template does not
  declare is refused by name (`variable_undeclared`).
  Judged against the addressee's row of the day it is written; if the
  profile re-declares its template before the drain, a name the CURRENT
  template lacks parks the head blocked as `prompt_template_invalid` —
  never rendered as literal braces, never silently dropped.
- **The default fits, and the fit is the wall**: whenever no
  `token_budget_share` is stated (a `max_entries`-only intent composes
  with it), history fits itself to the model's own window (advisory bound
  first, else the hard bound) minus the prompt's own cost — newest-first.
  Once the timeline overflows that fit the head does not send a trimmed
  request: it arms the timeline compaction (a `compaction_summary` turn,
  the same repair the size walls arm) and waits behind it, so the prefix
  after the summary is stable instead of sliding by one turn per reply.
  Only when no summary can be armed (the author's compaction policy is
  `off`; the summary itself overflows the fit) does the trimmed request
  go, narrated as a `context_trimmed` event (regenerate's reassembly
  fallback narrates its trims the same way). A stated share is the
  caller's own bound and trims to it as asked. Only a prompt the model
  itself cannot take still blocks
  (`estimated_input_exceeds_model_limit`; the gate fires only on an
  exact tokenizer count — inexact upper bounds never refuse). At most
  the newest 200 turns are considered per assembly; older
  content-bearing turns count in the skipped evidence as
  `candidate_limit` — with no stated bound, reaching that end is the
  wall as well and arms the same compaction.
- Freshness fences: `expected_context_revision` refuses `stale_context`,
  `expected_tail_turn_public_id` refuses `stale_timeline` — both
  synchronous at accept.
- The caller-authored queue bound refuses `input_queue_full` (409)
  synchronously; peer mail counts. The kernel's own `task_result` mail
  (below) is not counted against the bound but can meet it — a refused
  mail is retried, never dropped.
- KERNEL MAIL: an unconsumed conversation-lifetime background result
  answers in a supplementary turn, even when it finishes before the original
  reply. After that reply is final, the kernel writes an input through this
  same door — a kernel-stamped user-role `direct_reply`, `delivery_mode:
  queue` ALWAYS (never a steer: a running turn finishes first), on the
  mailing loop's model and its seed's tools intersected with the answering
  profile's current declaration. The receipt stores an explicit list, including
  an empty one, so later additions cannot expand it. Kernel aliases match by
  canonical identity; executor tools match by name. Approval keeps the loop's
  mode while it still tightens the profile's current mode, else the profile's,
  and uses the current profile's rules — with the kernel's own
  word `origin: "task_result"` (no caller can supply it) and the sender
  stamp `sender_conversation_public_id` (the conversation whose loop
  produced it), ADDRESSED to the mailing loop's own answerer
  (`answering_user_public_id` — a task A started answers to A's turn,
  never to the conversation's default and never to everyone; the door
  never judges the kernel's mail for eligibility). An IDLE conversation
  is WOKEN by it: a new loop-backed turn under that answering profile
  whose trailing user message is the receipt, exactly as a person's
  queued input wakes an idle recipient, bounded by what bounds a turn.
  It drains FIRST — the queue's READ ORDER is the kernel's own rows
  (`origin: task_result | child`), then arrival (`GET …/inputs` lists in
  that order; `queue_position` stays the arrival number) — so a person's
  word posted earlier reads after it, by design:
  the model finishes absorbing what it asked for before it takes new
  instructions. At a turn boundary, up to 16 already-arrived, contiguous
  compatible callback inputs can share one
  supplementary reply. Earlier receipts become individual message turns;
  the last receipt opens the reply whose history includes them. Every
  receipt retains its own content and source stamps. Compatibility requires
  identical principals, model, tool and approval policy, and ordinary
  visible assembled input without custom context or freshness fences; the
  total content is bounded by the snapshot size limit. Ordinary task/tool/compose
  receipts require the same source loop. Independent worker finals may cross
  source loops only when their frozen original requester and execution memory
  context also match. Each such receipt carries `callback_result`, the exact
  worker result pointer described below. Unknown result provenance cannot qualify.
  There is no batching delay or reordering across an incompatible receipt.
  The batch commits only when the actual assembled
  request includes uncut history and opens a reply. A history cap, raw
  profile, unavailable model or degraded reply instead leaves the remaining
  receipts queued and processes the original head individually. All sources are
  locked in stable order and checked before consumption. After multiple independent
  worker finals are consumed, the receiving conversation owns their combined
  reply: stopping one source does not retract read material or cancel that reply.
  Its singular sender fields are empty and `callback_sources` retains all sources.
  Single-worker replies and ordinary receipts keep their existing source Stop fence.
  Result mail uses a loop even if the receiving profile has
  no tools. An unavailable original model permits one switch to that same
  recipient's current different `default_model`, never back to a model that
  already declined the step; no other candidate is selected. If model selection or execution still fails, the mail turn retains its prompt,
  recipient and execution configuration in a loop held at `needs_attention`.
  A task retry can name a replacement model without repeating completed
  tools or the child request. It does not renew the automatic allowance.
  Separate input or assembly refusals still degrade to a completed message
  containing the received text; that message has no retryable model task.
  If an already-created mail loop first prepares its request on retry,
  implicit history overflow instead holds with `history_exceeds_fit`,
  preserving the prompt for a larger-window model or explicit history
  budget. It does not initiate a separate conversation summary. The
  200-turn candidate window's end is no overflow there — no retry changes
  a turn count — so that request sends the newest window, narrated as a
  `context_trimmed` event.
  A tool-less profile retains the originating loop's approval mode without
  acquiring tools. An archived conversation admits the receipt and it wakes
  at unarchive; a woken turn with nothing to do simply ends. `origin` is
  on EVERY input and on the turn it becomes — the row's SOURCE KIND, one
  of four words: `person` (a human's word), `agent` (a peer's `send`),
  `task_result` (this receipt), `child` (a spawned conversation's reply).
  The kernel's two are the SET every kernel rule reads — the read order,
  the bound, the edit surface, the archive pass, the fallback — never
  origin presence and never the sender stamp, which a peer's `send`
  carries too and which rides only the stamped rows, read by presence.
  Input `origin: "person"` corresponds to an author whose User kind is
  `human`; these fields have distinct vocabularies. Settled, unmailed
  task results are rediscovered by the periodic recovery sweep even if
  the immediate job wake is lost or the input queue is full. Accepting
  the input and marking the result mailed commit together. Pausing or
  holding the originating loop preserves already completed results;
  stopping it permanently suppresses further task mail, removes its queued
  supplementary inputs and cancels its started but undelivered supplementary
  replies, except a combined worker report whose results were already consumed
  under the rule above. A completed source can still be stopped; its published answer
  remains. The
  `input_accepted` item carries `origin` and `authored_by: {kind: "human"
  | "agent", handle, display_name}` on every row (the author, kind
  recorded), `sender_conversation_public_id` when a stamp
  rides the row (a peer's `send`, the kernel's mail), plus
  `agent_loop_public_id` and `task_key` (the key the model saw) on the
  kernel's mail and on an agent's `send`, and the
  wake is narrated by the ordinary pair — `input_materialized` naming the
  receipt, `turn_status{agent_loop_public_id}` naming the woken loop.
  A turn-owned spawn's initial report instead settles a `delegation_task` in
  its originating loop and is consumed before that reply becomes final. An
  immediate spawn wait is independent: expiration or cancellation does not
  release the completion obligation, and an open wait receives that same report
  exactly once. This result does not also become a kernel input. A held child
  remains repairable and outstanding; its own questions and effect deadlines
  still apply. Later independent child requests keep their ordinary mail path.
  THE CROSS-TURN CHILD-REPLY RELAY is the `child` row's writer: a
  spawned child's settled reply turn (`direct_reply`, either engine —
  a loop-backed turn or one model call) reaches its parent exactly once,
  LEVEL-TRIGGERED over the turn's own `relayed_at` marker (a recurring
  sweep every minute walks the spawned children's unrelayed terminal
  replies; the converger's kick at both terminals is a latency hint).
  Only a reply the PARENT opened is owed — the turn's
  `sender_conversation_public_id` is the parent's: the brief, and every
  parent `send`, including a send to a scheduled execution child — a person's
  or a third agent's exchange in the child is theirs alone, stamped as nothing
  owed and never relayed; and a CASCADE
  CANCEL OWES NOTHING below the canceller: a reply owed to a parent
  execution owner that was stopped is stamped too, even if its original
  reply had already completed. This is the turn
  that sent the particular request, which can differ from the original
  spawning turn. A later `send` can therefore receive a reply after the
  spawning turn was canceled, while canceling that later request suppresses
  its reply even if the spawning turn completed. Thus a
  grandchild's canceled reply never wakes the canceled child as a new
  turn, while the canceller — its own turn running — is still told what
  it canceled. The relay addresses the originating REQUEST's answerer
  (`answering_user_public_id` on the mail): the execution that issued the
  initial `spawn` or the later `send` opening this child turn. This can be
  a different agent or a different model configuration from the original
  spawner. It does not follow the parent's active turn at delivery time.
  A steer joining an existing child turn retains its original reply owner.
  Only the initial request's reply settles the spawning call's kernel-held
  await when one is parked
  (`wait: true`; the settle's `task_status` item on the parent's feed
  carries `resolved_by: {kind: "conversation", public_id}`). Other owed
  replies become kernel mail on the parent — `origin: child`, the child's
  `public_id` as the sender stamp, `agent_loop_public_id` and `task_key`
  identifying the `spawn` or `send` call that opened this child turn,
  the text `<task_result task="…" status="…" conversation="…">…`,
  AUTHORED AS TASK MAIL IS: by the originating request loop's creator, on
  that loop's surface (its model trio, its approval tightening while still
  valid, and its seed's tools intersected with the current declaration,
  including an explicit empty set); the kernel relays its own receipt and
  impersonates nobody.
  A parent that is gone (tombstoned) owes nothing; a full queue is
  retried on the sweep's clock.
  A conversation-lifetime background tip that settles while the spine
  still runs waits for final delivery, then follows the same mail path as
  a late result. Launch-time `wait: true` and explicit graph result reads
  consume it in the original reply, preventing duplicate mail. The separate
  `wait` tool remains an observer and does not consume queued mail. Turn-lifetime
  obligations instead drain into a synthesis
  round before the reply is final. Such an in-loop acceptance still carries
  `input_accepted{origin: task_result, agent_loop_public_id, task_key}`
  without an `input_public_id`; consumers must not treat it as a new Turn.
  Once per tip, on whichever path read it: a consumed tip is never mailed.
- A head the drain cannot serve parks as `state: "blocked"` with its
  reason (`unknown_model`, `estimated_input_exceeds_model_limit`,
  `author_not_authorized` — the author may no longer write here; the
  repairs are the delete or the author's write standing restored, since an
  edit changes the words, never the author — …) — durable, narrated on the
  event stream, FIFO holding behind it.

### The waiting room's edit surface

`GET .../inputs` reads the queue in READ order — the kernel's own rows
first, then arrival (with each row's text and `lock_version`). While a
row is `pending` or `blocked` it stays a principal's to change — a
person's word and a peer's `send` (`origin: agent`) alike, since the
recipient's queue is theirs to manage — unless it is the kernel's: a row
with `origin: task_result | child` is immutable to the person, and every
verb below refuses it `409 kernel_input_immutable`. Stopping its source
execution withdraws pending result mail and cancels undelivered derived replies.
An already-consumed combined worker report belongs to its receiving conversation
and survives an individual source Stop.
Canceling an individual task changes that task's result; an owed canceled result
can still be delivered. The queue editing verbs are:

- `PATCH .../inputs/{public_id}` edits content (`text` or raw `entries`)
  and its pictures (`attachments` — ABSENT keeps the binding: an edit
  that carries new `text` re-composes the message from that text plus
  the pictures the row already binds, so the fix for a blocked head never
  loses one; `text: ""` clears the words while keeping those pictures;
  `[]` unbinds; a list rebinds in that order, beside the row's
  words when the edit carries none; never beside raw `entries`),
  the model trio, `configuration`, `tool_names` (`[]` is no tools; the
  whole declaration by name restores it),
  `visible_in_context`, `context_mode`,
  `history`, and `reasoning_replay` — a PATCH naming either intent key
  REPLACES the whole stored intent with exactly what it sent (an intent
  you want kept must ride along), `deliver_at` or `deliver_in` (absent
  keeps the time; a time reschedules; `deliver_in: "0s"` makes the row
  due now — the same two bounds as on create) — with an optional `expected_lock_version` CAS
  (`stale_object` on a miss). **Editing a blocked head is the unblock
  path**: the edit is the fix, the row returns to `pending`, and the
  drain re-judges it. Rescheduling it into the future immediately lets
  other due rows drain; the edited row still wakes at its new time.
  `kind`, `role`, `delivery_mode`, and the sender
  stamp are create-frozen; a held steer refuses `steering_held` — cancel
  it instead.
- `DELETE .../inputs/{public_id}` gives a row up before it materializes;
  deleting a `steering` row IS the steer-cancel verb — a scheduled row
  included: the delete is its cancel.
- `POST .../inputs/reorder` with `inputs: [public_id, …]` renumbers the
  PERSON'S rows among their own positions — the list must name every one
  of them exactly (else `queue_changed`), so nothing reorders behind the
  caller's back; a kernel id in the list is `kernel_input_immutable`, and
  a kernel row's position is never rewritten.

## The default template — the slots, memory, your text, history

An assembled `direct_reply` (`prompt_mechanism: default`, the kernel's
word when the profile declares none) compiles ONE fixed order, and the
sealed request records exactly what it compiled:

```
[system_prompt] [character] [persona] [memory] [skills] [history] [inline lead] [inline tail] [input]
```

THE SLOTS are prompt documents — durable rows, each on the anchor that
owns it, read live at every materialization (a write bumps no
`context_revision`; the next turn of every conversation sees it):

| Slot | Whose | Door |
| --- | --- | --- |
| `system_prompt` | the agent's identity — the ANSWERING profile's row (the conversation's stored answerer, whoever posted; a Human-answered conversation compiles none) | the agent's own [`profile/prompt_documents`](profile.md#prompt-documents--the-acting-users-own-slots) |
| `character` | the room's identity and scenario — the workspace's row | [`workspaces/{id}/prompt_documents`](workspaces.md#prompt-documents--the-rooms-character) (write standing under the dedication fence) |
| `persona` | the person this turn answers to — the poster's controlling Human's row, resolved exactly as memory's `user/` rung is | the person's own [`profile/prompt_documents`](profile.md#prompt-documents--the-acting-users-own-slots) |

An absent slot renders nothing. Each present slot is one block of its
document's `role` (`system` unless the author said otherwise), and
adjacent same-role blocks JOIN for the wire — so with every slot at its
default the sealed list opens with ONE system item whose parts are the
three documents in that order, each its own text; a `developer`- or
`user`-role slot breaks the run and stands as its own item, the author's
choice. Anthropic's wire lifts the leading system items into its system
field; a chat-shaped wire sends them as the first messages. Either way
the system text rides the sealed list and never the wire's `instructions`
field, so a loop-backed turn's round `r1` is byte for byte the tool-less
reply's request plus the tool block, and every continuation round
carries it once.

MACROS inside a slot's text are a closed registry substituted at
compile: `{{agent}}` — the declaring profile's display name; `{{user}}`
— the poster's controlling Human's display name; `{{workspace}}` — the
workspace's name; `{{date}}` — today, ISO 8601 (a slot naming the date
moves the cached prefix once a day — the author's choice);
`{{conversation_kind}}` — `standalone`, `conversation`, `child`, `scheduled`,
or `side`. A scheduled execution is `scheduled` even though it also has a parent;
a side fork is `side`, and an ordinary fork is `conversation`. The kind follows
the host's durable identity and remains stable when a parent or schedule is
collected. It describes the host, not a turn's input origin or execution lifetime.
The same value is available in registered slots, inline slot overrides and
template inline blocks at compilation, including the first scheduled request.
A source
that is absent renders empty, never the braces. A word outside the
registry is refused at the door when the document is written — and at
this door when an inline `slot` override carries one — as 422
`prompt_document_macro_unknown`, naming it, so a typo never reaches a
model as literal braces; `{{history}}` is a block, not a macro.

THE SKILLS BLOCK follows memory: the turn's skill catalog, rendered only
when the turn declares the `skill` tool ([Agent loops](agent_loops.md)
"`skill`") — one line per skill, `- name: description`, under the header
the tool's own text points at ("Skills available now."): the bound
runner's and the agent address's announced documents, then the
workspace's `skills/` rows, then the controlling Human's, a name clash
resolved in that order, bounded by `skill_catalog_bound` (16 KiB) with
one names-only tail. Rendered ONCE per turn into the sealed seed and
frozen for the loop, exactly as memory is: a skill written or announced
mid-loop is the next turn's fact. A turn without the tool has no
catalog; a `direct_reply` never carries one; a `raw` turn is not
assembled and shows none. The memory block never renders a `skills/`
row: the catalog is its pointer, the body is loaded on demand.

THE ORDER IS THE CACHE'S. The slots, memory and the skills catalog change
only when someone writes them; history changes every reply — so they
lead, the stable cache marker lands after them ([Agent loops](agent_loops.md)
"Prompt caching"), history rides behind them, and the per-turn text —
the `inline` lead and tail, then the input — rides behind history. What a
turn laid between history and its input is its PREFACE, sealed with the
turn as it was sent: every later turn of the same answering agent
replays it in place, so a turn's request is the earlier request whole
plus its own tail — the prefix a provider cache and a signed thinking
block are bound to. `[history]` holds each earlier turn by its kind: a
`message` turn as its content in its role; a reply turn as its preface
(the assembling agent's own turns only; another agent's reply never
carries its preface), the words that opened it (its prompt, user role),
then what it produced — a tool-less reply's text, a loop-backed turn's
rounds — or its in-turn summary in place of all three; a summary turn as
its summary under the kernel's header. Adjacent same-role items merge
into one message whose parts are each item's own, never folded into one
text — except the user messages a loop round's request carried on their
own (each delivered result, the abort marker, each steer it read), which
stay their own messages in history as that request sent them, so a wire
that sends one item per message (the Responses and chat wires) and one
that merges same-role neighbours (Anthropic, Gemini) both see the earlier
request whole. A regenerated or edited answer keeps its turn's preface. The
slots, memory and the inline entries are FUNDED
ahead of history in the self-fit budget: they never yield, history does,
down to none (`history.selected: 0`, `skipped_reason: budget_exceeded`
on the estimate) — only a prompt the model itself cannot take refuses,
at the window gate.

THE PER-TURN OVERRIDE is an `inline` entry naming a `slot` (above): it
replaces that slot's registered document for this turn alone, in slot
order, and the row stands untouched — `version` does not move. The
effective word is written onto the turn's loop row (`prompt_mechanism:
default | assembly | raw` on a loop-backed turn's full read).

## The assembly template — your own order

`assembly` is the SAME compiler as `default` with the block order read
from the answering profile's `prompt_template`
([Profile](profile.md#declare-the-configuration)) — the same blocks, the
same merge rule, the same funding; `default` is this grammar's built-in
template, so a profile under `default` compiles the fixed order above
whatever template it stores. The template is a JSON object:

```json
{
  "blocks": [
    { "type": "slot", "slot": "system_prompt" },
    { "type": "inline", "role": "system", "text": "Today's scene is {{scene}}." },
    { "type": "slot", "slot": "persona" },
    { "type": "memory" },
    { "type": "skills" },
    { "type": "lead" },
    { "type": "history", "max_entries": 40, "budget": { "share": 0.6, "min_tokens": 512 } },
    { "type": "tail" },
    { "type": "input" }
  ],
  "variables": { "scene": "an ordinary day" }
}
```

| Block | Fields | Count | What it renders |
| --- | --- | --- | --- |
| `slot` | `slot`: `system_prompt`, `character` or `persona` | at most once per slot, ahead of `history` | the registered document (or the turn's inline override), in its role, macros substituted; a slot the template does not name is neither rendered nor read. A slot after `history` is refused at its path: it would ride the turn's preface into every later turn's history, a `system`-role one hoisted into the top system block by the Anthropic and Gemini wires |
| `inline` | `role`: `system`, `developer`, `user` or `assistant`; `text` | any | the template's own text, macros and variables substituted. A `system` inline is admitted only in the LEADING RUN — before the first block that is neither a slot nor a system inline — because the Anthropic and Gemini wires lift every system entry wherever it sits; elsewhere it is refused at its path. Between `history` and `input` it rides the turn's preface as the macros rendered it, replayed by later turns rather than rendered again |
| `memory` | — | at most once | the memory block; absent, no memory is rendered |
| `skills` | — | at most once | the turn's skill catalog, rendered only when the turn declares the `skill` tool: one line per skill, `- name: description`, the bound runner's and the agent address's announced documents, then the workspace's `skills/` rows, then the controlling Human's, a name clash resolved in that order, bounded by `skill_catalog_bound` with one names-only tail; absent from a `raw` turn; absent, no catalog is rendered |
| `lead`, `tail` | — | at most once each | where the turn's slot-less `inline` entries land; absent, such an entry is refused at the door. Placed between `history` and `input` (as `default` places both) they are the turn's PREFACE, sealed with it and replayed by later turns; placed ahead of `history` they re-render every turn — an identical text keeps the cached prefix, a changed one moves it, the template's own policy |
| `history` | `max_entries`? (1–200), `budget`? `{ share?, min_tokens?, max_tokens? }` | exactly once | the timeline. `share` is the default of the turn's `token_budget_share` (the same flat mapping onto the window — and the same `history_budget_unavailable` park on a windowless model); `min_tokens` is a floor funded only when room remains after every other block; `max_tokens` caps it. The turn's `history` intent overrides these numbers |
| `input` | — | exactly once, LAST | the turn's prompt; any block after it is refused |

`blocks` holds 1–64 entries; `variables` up to 32, named `[a-z][a-z0-9_]*`,
never one of the built-in macro names, each defaulting to a string. Every
`{{name}}` in an inline text must be a macro or a declared variable. The
whole template is bounded like a prompt document (64 KiB). A refusal
names its JSON-pointer path (`/blocks/2/role`, `/variables/Scene`).

THE BUDGET is one allocation over the model's window (advisory bound
first, else the hard bound; less an eighth under reasoning replay): every
slot, inline, memory, skills, lead, tail and input block is a REQUIRED floor at
its own cost and history the one optional child, so history trims first,
newest-first, down to nothing. A floor the window cannot fund is
EVIDENCE — the block reports `floor_unmet` on the estimate — never a
byte change: the request compiles whole and only the window gate
refuses, on an exact count against that same window — the advisory
bound first, else the hard bound (`estimated_input_exceeds_model_limit`);
the hard bound alone is the provider's own refusal. A model that declares no window
sizes nothing: history is unbounded, as under `default`.

## Forks

`POST .../forks` with `fork: { turn_public_id, variant_public_id?, title? }`
creates the child: closure by reference, the boundary turn adopted as the
child's own editable latest message (content entry-copied onto the same
fragments — zero content bytes), the source's view-state frozen at the
fork. Creation and exact receipt replay both return `201` with the original
body; `Idempotency-Replayed` distinguishes a new child (`false`) from a
replay (`true`). The child answers as its source does: `answering_user_public_id` is
copied, never re-derived — the forker is never the answerer.
The access carrier forks with it: every principal's level on the
child equals its level on the source, except the forker, who becomes the
creator — `access.default` and the entries are copied at the fork
instant, the source's derived-full principals (its creator, its answerer)
materialize as `full` entries unless they are the child's own creator or
answerer, and the forker's own entry is dropped. A Human who opened a
`none` conversation reads its answerer's side of it.
A concealed target or variant answers 404; an unsettled variant
refuses `variant_not_forkable`; oversized lineage refuses `fork_too_large`.

The answer is `{conversation, world}`: `world` is the fact for the fork
point — the FIRST runner-addressed write-kind call claimed strictly above
the turn in the source's reach, every candidate and every concealed turn
counted (the world is physical), so `checkpoint` names the tree before the
successors' work. Claim order decides this, including when an older turn's
background write starts after a newer turn's write. `untouched` means
nothing above it wrote; a replay answers the same `world`. Rewind is NOT a
kernel verb: a rewind to turn N is the
SDK's composition — fork at N, read the answer's `world`, ask the child's
bound runner to restore it through a request loop (`world_restore
{checkpoint, store}`), poll. The SDK retains the runner's store identifier
alongside the tree hash, including when it recovers the record through
`checkpoints {loop}`. The kernel keeps the correlation and the timeline
move; the files are the runner's.

THE SIDE CONVERSATION: `fork: { side: true,
title? }` names NO turn — the fork point is the parent's newest SETTLED
turn, live head or not: the position below the active turn, or below an
undelivered tail whose loop can still recover from a hold; otherwise the
head's last position. A delivered reply remains eligible while its
background tasks finish. (A `turn_public_id` or `variant_public_id`
sent beside `side` is not read, though the envelope digests it;
`variant_not_forkable` does not apply — nothing running is forked; a side
of a conversation whose first turn still runs inherits nothing and is
allowed). Vacant slots left by undo remain vacant: the fork point names
the newest remaining turn within that boundary. The side answers as the
running or recoverable tail does, otherwise as that remaining turn does;
only an empty history falls back to the conversation's default answerer.
The child carries `side: true` on both projections, bounds its
closure at that boundary INCLUSIVE and adopts nothing: the inherited turns
render from the parent's rows through the closure — a loop-backed turn
from its rounds, never from a clone's `content` — so the bytes are the
parent's. Assembly renders that inherited history behind ONE boundary
item, the kernel's fact that the turns above are inherited reference: a
USER-role message reading `[The turns above are inherited from the
parent conversation as reference. Only the turns after this point belong
to this conversation.]`, emitted after the last inherited turn in the
window (no inherited turn in the window — a compaction cut past the
boundary — renders none) and merged by the wire rule with the side's next
user text. User role, not system: the Anthropic protocol hoists every
system-role entry into the top system block, which would move the first
bytes of the request; in user role the parent's prefix ABOVE the boundary
is untouched. THE PINNED PROPERTY: the side's first sealed request equals
the parent's running request's entries above the boundary, byte for byte
(the provider's prefix cache is shared), and the side's own history stays
byte-stable turn over turn. The shared bytes are the kernel's; a provider
cache HIT also needs the same TOOL BLOCK — OpenAI-shaped wires render the
tool declarations ahead of the messages, so a side turn that narrows
`tool_names` (a tool-less `btw`) shares the parent's entries and still
misses its cache at token one. Measured on deepseek-v4-flash: a side turn
carrying the parent's 20 declarations read 5632 of the parent's 6144
cached tokens; a tool-less one read 0. The instruction text a product wants ("you are
in a side conversation, answer briefly") is the caller's own inline
`tail` entry, never kernel bytes; the tool posture is the caller's
per-turn `tool_names` narrowing as on any turn. The copy list is the
fork's: the answerer, the runner binding, the billing pair, memory
pointers, store rows; `fork_created` is narrated into the parent's stream
as for any fork; the parent's transcript is never written. A side is never
forked again — plain or side — `side_of_side` (422). A side cannot spawn a
child, and `send`, `status`, and `cancel` refuse a side addressee with
`side_conversation`. Its lifecycle is described under Lifecycle above (no archive,
DELETE reaps at once, the parent's cascade). One open side per parent and
an idle TTL are an agent application's bookkeeping (rho's), not kernel
rules.

## Turns — the timeline window

`GET .../turns?limit=&after_position=&before_position=&include_hidden=` reads the merged
timeline (inherited prefix entries included, `inherited: true`), each entry
carrying its active variant's model identity, preview, and rendered
content — and on a reply turn `prompt_text`, the person's words that
opened it (the seed's readable text, the same words the sealed request
carries; absent on a `message` turn, whose `content` IS the person's
words, and on a seed carrying no text, a picture alone), so a history
reader can say what was said without a second read. Every turn names WHO
ANSWERED — `answering_user_public_id`, the
addressee of a reply, the conversation's answerer on a message or the
kernel's summary — and WHO SPOKE, `speaker: {user_public_id, handle,
kind, display_name}`: a message turn's speaker, a reply turn's ANSWERER
(the agent whose engine wrote it), absent on the kernel's summary, which
names no principal. Every input carries the same two — its addressee and
its author — so a follower can read which agent's turn is running and
which agent each earlier turn was. A LOOP-BACKED variant (`source: "agent_loop"`) also carries
`agent_loop_public_id` — the feed's correlation key — and `rounds`: the
loop's newest SPINE rounds as the loop transcript's rows without their
calls (`task_key`, `status`, `text_preview`, `usage`, and by presence the
compaction cut — `compacted_before` / `pruned_before` — …; never an
edge, a join or a spine mark — a turn shows rounds, not a graph). Both are
ADDITIVE, absent on every other source, read by presence; the loop's own
transcript route is the paginated window when a page's rounds are not
enough. A loop-backed variant also carries `world`, a DERIVED fact off the
loop's own rows: `{status: "untouched"}` when no runner-addressed
write-kind call was claimed, else `{status: "touched", loop, runner,
checkpoint}` — the writing loop, the executor that CLAIMED its first such
call, and that call's `metadata.checkpoint` verbatim (absent when the
runner answered none). The kernel compares nothing: whether this
conversation's bound `runner` can restore `checkpoint` is the reader's
comparison. The default window excludes hidden turns;
`excluded_from_context` rows appear here and never in assembly.
`include_hidden=true` explicitly includes hidden turns for management and
execution recovery, with their original `visibility` and the same position
pagination. This discovers a hidden held execution even after its
`active_turn_public_id` clears. The option uses the same Conversation access
rules and inherited view overrides; concealed turns remain absent. It does
not change context assembly or transcript streaming, and clients must still
respect each turn's visibility when displaying content. The Ruby SDK exposes
the option as `conversation.turns.list(include_hidden: true)`.

Source stamps are durable turn fields: `sender_conversation_public_id`,
`sender_agent_loop_public_id`, and `sender_task_key` appear when recorded
on the input. They identify the sending conversation, source execution, and
source task independently of the receiving turn's `agent_loop_public_id`.
They remain available after input consumption and event retention, so a
follower can correlate a callback with the original execution without
reconstructing it from retained feed events.

`input_public_id` retains the accepted input's UUID after consumption. A worker
final receipt exposes nullable `callback_result` with these UUID fields:
`conversation_public_id`, `input_public_id`, `turn_public_id`, `variant_public_id`
and `requester_actor_public_id`. They name the independent worker's exact formal
result and original requester; later manual regeneration does not retarget this
pointer. An unknown requester is `null` and prevents cross-source batching while
preserving the exact worker result. These are kernel-written read projections,
not input creation fields.

Materialized worker callbacks retain `callback_sources`, an immutable array of
objects with the callback receipt's `input_public_id`, `origin`,
`sender_conversation_public_id`, `sender_agent_loop_public_id`, `sender_task_key`
and `result` (the `callback_result` object above). A single worker receipt retains
one element. The combined reply retains all consumed sources and has no singular
sender ownership; earlier receipt message turns keep their own source. Ordinary
turns expose an empty array. This records provenance without creating a result
resource, batch group or new task identity. Consumers read the fixed variant
through the existing worker conversation's variant API under its current access
rules; they must not substitute that turn's current active variant.
An adopted fork boundary is a new turn without input consumption: it keeps its
existing fork/source references, without `input_public_id` and with empty
`callback_sources`. It must not masquerade as another materialization of the
original input. Inherited prefix turns retain their original projections.

Every variant carries `memory_context`, the bindings frozen for that execution,
including on the timeline, variant deck, and content-verb responses. This is
independent of the conversation's current `memory_context`. The key is always
present: `null` selects the default roots, while `{"bindings": []}` explicitly
disables memory. Regeneration retains the source variant's value.

### Tail content verbs

Every content verb aims at the TAIL — the frozen prefix answers
`branch_required`; a turn still referenced by a descendant's closure is
also frozen even if it has no local successor. Rewrite history by forking
and editing. Every verb below
answers the variant block in ONE shape, the deck's and the turns page's:
`prompt_text` (a reply turn's seed words) and `attachments` ride it by
presence, as on the turns page.

- `POST .../turns/{id}/edit` with `edit: { text }` (or raw `entries`) —
  the content becomes a NEW activated candidate (`source: "edit"`),
  never a patch. Works on both kinds: fix your message, or hand-override
  the assistant's answer. On a reply turn the candidate carries the turn's
  seed, so its answer names `prompt_text`; on a message turn there is none.
- `POST .../turns/{id}/regeneration` (optional
  `regeneration: { model, configuration }`) — re-asks a compatible sealed request
  for a new sample (`202`), which lands as a sibling beside the original;
  a caller-supplied model re-asks elsewhere. Changing the model, disabling
  reasoning, or a default-replay downgrade on native-bearing content requires
  rebuilding, as does an active candidate without a sealed request (a
  fork-adopted or edited turn). An assembled prompt uses the CURRENT context
  strictly below the turn, then the turn's sealed preface — the per-turn
  text its request carried behind history, laid verbatim and never
  re-rendered, a lead the turn relied on the window for laid when this
  window no longer carries it — then appends the turn's original prompt
  with its speaker and attachments; the new candidate keeps the preface
  its request laid, as an entry-copied request already carries it. A raw prompt instead restores its original
  messages, roles, order and upload
  occurrences, without adding history, templates or speaker envelopes. The
  input mode stays with the prompt across regeneration, edits and forks,
  independently of later profile changes. A target unable to accept a raw
  attachment refuses regeneration; raw content is never replaced with an
  attachment placeholder. Native reasoning tagged with its producing model
  keeps the usual wire compatibility rules: portable text may cross models,
  but foreign signatures and encrypted material do not. Untagged native
  payloads supplied by a raw caller remain that caller's responsibility.
  Omitted or `null` `configuration` reuses the original candidate's generation
  configuration when it has one. An inference candidate inherits its original
  request's resolved parameters on the same model; on another model it
  inherits only what its caller chose — every sealed value that differs from
  the old model's catalog default — and the new model's defaults for the
  rest, the same reading the kernel's own `fallback` candidate takes (the old
  model's defaults would refuse every model whose parameter vocabulary
  differs). A loop-backed candidate inherits its seed's
  submitted configuration, with unspecified parameters taking current catalog
  defaults. A supplied object replaces the entire configuration; `{}` selects
  the chosen model's current defaults. On another model the original's
  reasoning effort is not carried — it is the old model's vocabulary — so the
  new model resolves at its own default unless `model` names an effort. The
  chosen model validates the configuration before accepting regeneration,
  including inherited parameters when switching models. Original raw `instructions` remain separate from
  those generation parameters and are
  retained when the candidate has its own execution record. Edited and
  fork-adopted candidates do not recover configuration from older executions.
  The turn's own answer never rides its regeneration. The turn reopens to
  `running`; the old candidate keeps rendering until the new one
  completes — a completed sample becomes the rendered one, a canceled or
  terminally failed sample sits in the deck while the turn returns to
  `completed`. A loop held at `needs_attention` instead activates its failed
  candidate and leaves the turn `failed`, retaining its adjudication and
  same-turn retry/reopen behavior. `direct_reply`
  turns only (`unsupported_turn_type`). A LOOP-BACKED turn regenerates as
  a NEW candidate with its OWN loop (`source: "agent_loop"`, the answer
  carrying its `agent_loop_public_id`): the origin loop's seed round
  re-asked — its sealed input entry-copied when compatible,
  else rebuilt using the prompt's original raw or assembled mode — under
  the origin loop's own approval freeze; the old candidate keeps its loop,
  rounds and picture. Successful regeneration permanently stops that old
  execution and its undelivered derived work; a refused regeneration leaves
  the source unchanged.
  Reassembly uses the original seed's tool set for its skill catalog, even
  when the profile's declaration has since changed. An edited or fork-adopted
  candidate regenerates without tools or their skill catalog, retaining the
  original prompt, its preface and its mode but not the old execution's
  parameters or instructions.
  The new running candidate's approvals remain decidable while the old
  completed answer is displayed.
  While the origin's loop is `needs_attention` the door refuses
  `loop_needs_attention` (adjudicate it first). The kernel judges NOTHING
  about the world the origin's loop changed: the variant's `world` says
  what happened, and whether to restore it first is the caller's (the
  SDK's `rewind`, rho's `regenerate`). The `202` carries no `content`
  yet, but the turn's seed is cloned onto the newborn candidate, so
  `prompt_text` rides it by presence.
  An edit on a hold-settled loop-backed tail is the person answering for
  the loop: the loop's adjudication verbs (`retry`, `abandon`, the
  repairing append) then refuse `not_adjudicable`, and no later loop
  status flips the turn behind the edit.
- `POST .../variants/{id}/activation` — the swipe switch: point the tail
  turn at another settled candidate (`variant_not_active` for an
  unsettled target; re-activating the active one is an event-free no-op).
  The answer is the candidate's own block, `prompt_text` included on a
  reply turn. Selecting a completed candidate also leaves the Turn
  `completed`, including when the previously selected candidate was failed.

An edit or a changed activation emits `turn_variant` followed by `turn_status`
in the same transaction, and publishes the selected sealed Turn on the
transcript stream after commit. Both durable events identify the Turn and
candidate; a loop-backed selection also names its `agent_loop_public_id`.
The status item describes the Turn, without replacing the loop's own status.
A reader can recover the selected body from the variants list and that loop's
current tasks and attention from its trace. Changed activation permanently
stops the replaced candidate's unfinished work and undelivered derived
requests/results. Selecting an old candidate never revives canceled work.
Reading a candidate or re-activating the active one has no stop effect.

THE KERNEL'S OWN CANDIDATE (`source: "fallback"`). A tool-less reply — the
first answer or any regenerated sample — whose answer a provider's
classifier DECLINED (`finish_quality: refused`), or whose provider was
OVERLOADED on every attempt of its budget (`failure_reason_key:
provider_overloaded` — 503, 529 or the streamed `overloaded_error` each
time; a rate limit is never overload and waits out the lane's floor), is
re-asked once by the kernel on its answering profile's declared `fallback_model`
([Profile](profile.md)), read at that moment: a new candidate beside the
declined one (`origin_variant_id` names it), asked as the declined
sample's poster, under that sample's own generation parameters where they
differ from the declining model's defaults and the fallback's defaults
elsewhere, at the fallback's own reasoning default. The Turn never leaves
`running` in between — it keeps its steers and its place in the lane, and
no settled Turn is published; the feed says the switch once (`turn_variant
{regenerating: true}`, then the declined sample's `turn_status` below).
The declined sample stays in the deck as `failed`; a completed fallback
candidate becomes the rendered one as any completed sample does. A
declined sample has no text, so later history renders the turn's seed
alone: a turn whose refusal stood carries no sign of it into the next
turn's request. No
declaration, a fallback equal to the model that declined or one that
declined this Turn or was overloaded for it before (whoever asked), a
content block (`finish_quality: blocked`), a `fallback` candidate declined
or overloaded in turn, a fallback the account cannot run for this request
at that moment, or one that needs the tool loop's reasoning back
(DeepSeek with tools, Kimi K3) when a tool round after the last user
message is one it did not produce (an earlier turn's rounds go back without
their reasoning): the sample stands, and the Turn settles as a failed sample does.
Result mail is loop-backed and switches as a loop step does
([Agent loops](agent_loops.md)).

### The undo verb and the stop verb

`DELETE .../turns/{public_id}` undoes the tail turn: the APEX — and
only the apex — physically removes (mid-history conceals instead:
`apex_only`). Live work ends first (`not_terminal`), a fork still reading
the row refuses naming the pinning conversation (`descendant_pinned`),
and held steering mail refuses rather than dying silently
(`steering_holds` — cancel the steer, then delete). An original child Turn
still owing a turn-owned delegation report refuses `delegation_pending` until
relay preserves the report on its parent's completion task. Concealment does
not discard that original execution or retarget its report. The vacated slot
never refills.

`POST .../cancellation` stops all existing execution owners in the addressed
conversation (`202` when a source cut or active cancellation is accepted;
`not_running` when nothing remains to cut). This includes earlier turns'
background work, completed sources with unconsumed results, and the current
reply or regeneration. The source cut is permanent; a later user input starts
new work normally. Ordinary queued user inputs are retained.

The running invocation terminalizes as canceled and convergence settles the
timeline. A regeneration's completed original keeps the pointer. A declined or
overloaded sample that has not yet settled settles as failed without a fallback:
Stop wins over the switch. A loop-backed running reply drains to canceled; a
hold-settled tail's loop is stoppable while its settled variant stays readable.
Stopping a completed source does not rewrite its delivered body or status.

Derived cancellation follows the immutable sender loop/task of each child request
and supplementary reply, recursively. It removes pending derived inputs and stops
already-started undelivered replies, including their background work. The same
rule excludes an already-consumed combined worker report: that reply belongs to
the receiving conversation, whose own Stop still cancels it. The same
reusable child conversation may contain a later independent request; that request
is not canceled just because its room was originally spawned by a stopped loop.
A child Stop does not stop its parent. Full access on the addressed conversation
is required; cancellation of its derived work neither rechecks the caller against
child access settings nor grants access to child content. Cancel also works in
the bin. Already published replies and external tool effects are not undone.
`DELETE .../turns/{public_id}` on a turn whose loop is
still live refuses `loop_live` (409) — stop it first; a deletable turn
tombstones its loops before the row goes.

### View state

`PATCH .../turns/{public_id}` with `turn: { visibility?, concealed? }` is
the one view-state writer over both sides of the fork boundary: a LOCAL
turn's own columns, or — for an inherited prefix row — the child's
override row (the shared row is never touched; every other descendant is
unaffected). The tail-only constraint has specific error codes: the apex
never conceals unless a descendant's pin already refuses its hard delete
(`apex_never_conceals`), only terminal rows conceal (`not_terminal`), and
restore lands only where the row would again be the tail
(`branch_required`; chains restore bottom-up).

`GET .../turns/{turn_public_id}/variants` lists a reachable turn's live
deck (`active` flagged), each row the variant block as the turns page
renders it — `prompt_text` (a reply turn's seed words) and `attachments`
by presence. `PATCH .../variants/{public_id}` with
`variant: { concealed: }` conceals or restores a LOCAL turn's candidate:
the ACTIVE candidate refuses (`variant_active` — activate another first),
and a restore whose freed slot was retaken refuses honestly
(`slot_occupied`).

## Compaction

`POST .../compaction` compacts on demand. THE KERNEL STILL PICKS NO
THRESHOLD — automatic compaction repairs what the kernel can prove will
not fit. The manual endpoint lets a caller compact earlier to reduce
context cost before reaching that limit.

```json
{ "compaction": { "model": "openai_api/gpt-6.1-sol" } }
```

Both fields are optional. Unnamed, the model is the conversation's own —
the newest variant's — and the reason to name one is to run a summary
somewhere cheaper than the conversation itself.

IT REACHES WHICHEVER HOST IS LIVE, under the conversation's
lock and then the loop's:

- IDLE — the between-turn repair: a `compaction_summary` turn is
  appended, backed by a one-task kernel loop whose only task is the
  summarizer, and it settles through the converger like every
  loop-backed turn. Answers `202 {turn}` with the turn `running`; a
  caller waits for it the way it waits for any turn, and its
  `turn_status` items say `turn_kind: compaction_summary`, so a word
  queued behind it tells the summary's loop from its own turn's.
- A LOOP-BACKED REPLY RUNNING — the mid-turn repair, on the spine's
  newest QUEUED round (a round on the wire has a sealed request):
  the loop's own `compact` (agent_loops.md), answering `202 {turn, task:
  {key, status}, summary_task_key}` — the running turn, the round made
  to fit, and the summarizer it waits on. A `model` named on the
  request applies between turns only — mid-turn the round's own
  `compaction` policy decides — and a manual repair always summarizes,
  never prunes.

A REGENERATE IS NOT REPAIRABLE THIS WAY, and the reason is structural.
A summary is a TURN and turn positions only ever append, so it lands
ABOVE the turn being regenerated — while the re-ask reads strictly BELOW
it, or it becomes a continuation of its own answer. A regenerate also
re-asks material the origin already sent and fitted, so it does not
newly overflow.

THE SUMMARY IS ALSO WHERE READING STARTS. History begins at the newest
settled summary, and the cut is derived per read — never a stored cursor
— so it survives a fork (the child inherits the summary through the
closure and starts compacted at the same place) and the regenerate
corridor (a window landing before a summary correctly finds an older
one, or none). The assembly reads the turns from the summary onward and
never touches the ones it replaced.

IT IS THE SAME REPAIR, not a second one: same summarizer, same
rendering, same instructions, same cut, same narration. The
`context_compacted` event carries `trigger: "manual"` where the wall's
carries `"wall"` and the provider's count's `"usage"`, which is the only
difference a client can see.

Refusals: `409 conversation_busy` (a DIRECT reply is in flight, or the
conversation's own summary is still running — nothing else is busy: a
running loop-backed reply is compacted, not refused), `409
already_compacted` (the newest turn is already a summary, or the round
already carries a repair; compacting a compaction is a loop, not a
repair), `422 nothing_to_compact`, and mid-turn the loop's own words:
`409 task_not_queued` (the running turn has no round left to repair
before it is sent), `409 compaction_disabled` (the turn's policy is
`off`), `422 compaction_unavailable_under_raw` (a raw turn assembles no
history; only a delegate can compact it); and `500 arm_failed` (the
summary row could not be created — the one 5xx on this door that carries
a code, listed in the pack's `conversations.json`).

## Context estimate

`POST .../context_estimate` sizes the ASSEMBLED context the way the reply
lane will build it — advisory, write-free, never a provider call:

```json
{
  "context_estimate": {
    "prompt": "and this question",
    "model": { "model": "openai_api/gpt-6.1-sol" },
    "history": { "max_entries": 20, "token_budget_share": 0.5 }
  }
}
```

The estimate also takes `reasoning_replay: {mode}` and `inline: […]`,
modeling the same replay and the same client text the send will carry
(the caller's mode, the kill-switch, the model row's default — the same
rule in the same order); an entry naming a `slot` is priced in the
estimate exactly as the send prices it, in place of the registered
document. The registered slots and memory are always in the count.
`history` states INTENT — at most N entries, or a share of the model's
own window — and the kernel's history block owns the mechanics:
newest-first selection within the bound, chronological render, and the
evidence (`history.selected` / `skipped` / `skipped_reason` /
`compacted`) a trim-planning client reads. Positions never appear on this wire.

Answers `input_tokens`, `tokenizer_exact`, `catalog_input_token_limit`,
`advisory_input_token_limit`, `message_count`, and the `history` block. The `context` block on a
conversation read is the complementary fact: occupancy from the newest
succeeded usage record's provider-reported tokens — never a local
re-count — with `cache_read_tokens` beside `input_tokens` when the
provider reported how much of that prefix it served from cache (absent
otherwise; the side conversation's paid confirmation reads this number).

The estimate models the SEND the caller would make, under the same rule
the input door applies: the caller is the author (its persona and its
`user/` memory rung render), and `answering_user_public_id` — the input
door's own word, resolved through the same resolver — names the
ADDRESSEE whose declaration, template and `system_prompt` the compile
runs under and against whom history's speakers are enveloped; unnamed,
the conversation's stored answerer. When addressing another agent, model
selection follows the same order as sending: the addressee's declared
default model, its most recent direct reply, the conversation's most
recent direct reply, then the submitted model. That selection supplies
the preview's context budget, reasoning default and attachment capabilities.
An unknown name is 422
`principal_unknown`; a Human, a `read`-level or a fenced profile is 422
`answerer_not_eligible`. An addressee whose standing word is `raw` has
nothing here to compile: 422 `estimate_unavailable_under_raw`. Two more
fields ride the body: `variables` (the turn's values for the addressee's
declared template names, as on an input) and `template` — an
ESTIMATE-ONLY trial template under the grammar below, compiled in place
of the addressee's so an author can compare an order before declaring
it; never stored, never on an input. A trial outside the grammar is 422
`prompt_template_invalid` naming its JSON-pointer path; a variable the
effective template does not declare is 422 `prompt_template_invalid`; a
positioned inline entry the template does not place is 422
`inline_position_unplaced`, and one of role `system` or `assistant` is
422 `inline_role_unplaced`, as on an input.

### The preview — `render: true`

With `render: true` (a JSON boolean) the same answer carries what the
send would seal — nothing is written:

```json
{
  "context_estimate": {
    "input_tokens": 812, "tokenizer_exact": true,
    "catalog_input_token_limit": 128000, "advisory_input_token_limit": 100000,
    "message_count": 2,
    "history": { "selected": 4, "skipped": 12, "skipped_reason": "budget_exceeded" },
    "mechanism": "assembly",
    "entries": [
      { "role": "system", "parts": [{ "type": "text", "text": "You are the room's narrator." }] },
      { "role": "user", "parts": [{ "type": "text", "text": "first\n\nand this question" }] }
    ],
    "storage": { "bytes": 18342, "bound": 1048576, "within_bound": true },
    "blocks": [
      { "block": "slot:system_prompt", "index": 0, "type": "slot", "role": "system", "state": "selected", "tokens": 6, "allocated_tokens": 6 },
      { "block": "memory", "index": 1, "type": "memory", "role": null, "state": "empty", "tokens": 0, "allocated_tokens": 0 },
      { "block": "history", "index": 2, "type": "history", "role": "user", "state": "selected", "tokens": 3, "allocated_tokens": 99991 },
      { "block": "input", "index": 3, "type": "input", "role": "user", "state": "selected", "tokens": 4, "allocated_tokens": 4 }
    ],
    "memory": { "included": 0, "omitted": 0 },
    "slots": { "system_prompt": 4 }
  }
}
```

- `mechanism` — the word the compile ran under: `assembly` under the
  addressee's template or a trial one, else `default`.
- `entries` — THE SAME BYTES: the payloads the seal writes, read back
  exactly as the sealed-request door reads them. A preview and the send
  that follows on the same conversation state — same caller, same words,
  same addressee — produce byte-identical entries, under `default` and
  under `assembly`, in a 1:1 conversation and in a group addressed away
  from the stored answerer. An assistant entry rendered from a round whose
  wire labelled its messages carries that label as `phase` (the Responses
  grammar's `commentary` | `final_answer`) beside the `native_origin`
  (`provider_id`, `model_id`, `api_format`) that licenses it; the compiler
  resends `phase` only to a target whose `api_format` and `provider_id`
  both equal the origin's, and drops it silently on every other wire. An
  unlabelled message carries neither key.
- `storage` — the seal's ONE measure (the canonical bytes of each entry,
  summed) against the seal's bound. Over it the preview still answers
  200 with `within_bound: false` and `refusal: content_too_large` — the
  word the seal refuses with — because showing the overflow is the point.
- `blocks` — one row per block of the template, in its order: `block`
  (the key: `slot:<name>`, `inline:<index>`, `memory`, `lead`, `history`,
  `tail`, `input`), `type`, `role` (the first segment's, null when the
  block rendered nothing), `state` ∈ `selected` | `empty` | `floor_unmet` |
  `carried` (a `lead` equal to the one the window already carries, laid
  once — its tokens 0), `tokens` (its fill cost — exact when `tokenizer_exact`, else bytes/4)
  and `allocated_tokens` (the allocator's grant; null on a model with no
  declared window, where nothing is sized and history is unbounded).
  Exclusion is EVIDENCE, never a byte change: `floor_unmet` marks a
  required block the window could not fund on bytes that still send
  whole (history is trimmed to nothing first); the count says what the
  drain's window gate will refuse, the preview itself refuses nothing on
  size. No per-block bytes — no wire carries a pre-merge number.
- `memory` — `included` / `omitted` document counts of the memory block;
  `slots` — the registered documents compiled, `slot → version` (an
  override carries none, an unfilled slot is absent).

Without `render` the answer is the count alone, as above. `rho prompt
preview CONVERSATION --to @handle [--var name=value…] [--template FILE]` (rho-dev)
prints the rendered answer from a terminal; the SDK's
`estimate_input(render: true, to:, variables:, template:)` reads it typed.

## The sealed request — the debug door

`GET .../turns/{turn_public_id}/variants/{variant_public_id}/request`
answers the bytes ONE candidate's request was sealed with:

```json
{
  "request": {
    "entries": [
      { "role": "system", "parts": [{ "type": "text", "text": "You are the room's narrator in Kitchen.\n\nThe person is Ada." }] },
      { "role": "user", "parts": [{ "type": "text", "text": "Durable memory for this conversation…\n\n## workspace/notes.md\ngate code 4471\n\nfirst" }] }
    ],
    "request_options": { "temperature": 0.2 }
  }
}
```

Exactly two keys: the sealed entries in position order, verbatim — the
slot blocks, memory, history, the inline lead, the tail, the input, as
the assembler placed them and the wire rule merged them — and the
invocation's `request_options` (the generation bag plus the wire facts a
round carries: `tools`, `instructions` under `raw`, and `prompt_cache` —
the request's cache kind `{kind, tier?, tail?}` its markers are placed by). Derived from the
sealed body, never re-assembled: nothing here is computed at read time,
and no evidence block rides it. A loop-backed variant answers its FIRST
round's request (every later round is the loop's, read through
[`…/tasks/{key}/request`](agent_loops.md)); a variant with no sealed
request — a reply that never minted, a round never scheduled — is 404
`request_not_sealed`. Browse standing reads it: these are the
workspace's own bytes. `rho request CONVERSATION TURN` (rho-dev) prints the active
candidate's. A side conversation's first sealed request is its parent's
running request above the boundary item — entry for entry, byte for
byte — which is how the shared-prefix property is read, and pinned.

## Events — the replay window and the cable

`GET .../events?after=&limit=` mirrors the OneShot replay contract: opaque
`cvei`-prefixed cursor, ascending host-local sequences, `next_after`, and
the committed allocation `watermark` a follower freezes to bound its drain.
The watermark survives item expiry: an empty page with a watermark beyond
the follower's consumed sequence means committed progress is no longer
replayable. Refresh the projection from the host's durable state in that
case; do not invent events or derive an opaque cursor from the watermark.
`next_after` still names the last returned item and is null on an empty page.
The cable channel (`AgentAPI::V1::ConversationEventsChannel`,
`items: "events" | "lifecycle"`) carries the same projected items;
`lifecycle` narrows to `turn_status`, `attention_required` and
`conversation_ended`; `items: "progress"` subscribes the conversation's
ephemeral progress feed ("The progress feed", below) — the frames its bound
runner posts while a call runs or a process prints (executor.md,
"Progress") and the kernel's own timings (agent_loops.md, "The event
stream") — under the envelope `{frame}`, never `{event}`, nothing durable,
nothing replayed. ONE HOSTED
PLANE: a standalone agent loop hosts this same stream at
its own address (agent_loops.md, "The event stream"), so every item names
its host as `resource: {type: "conversation" | "agent_loop", public_id}`,
and the vocabulary is ONE closed list of twenty-five on both hosts — not
every type appears on every host: `input_accepted` (with `origin`,
`authored_by: {kind, handle, display_name}` and `answering_user_public_id`
— the addressee — on every row,
`sender_conversation_public_id` on a stamped row, plus
`agent_loop_public_id` and `task_key` on kernel mail and an agent's
`send` — and on a receipt drained in-loop, where no `input_public_id`
rides),
`input_edited`
(`reason`: an edit, `follow_up_bound` — a queued word bound as the head a
kernel-planted round will drain — or `steer_target_settled` — a steer
released to the queue when its loop ended without landing it),
`input_deleted`, `input_materialized` (`input_public_id`,
`queue_position`, and `turn_public_id` when conversation-backed; a steer
landing in a model round additionally carries `task_key` and
`agent_loop_public_id`. For an input opening a new turn, correlate its
`turn_public_id` with `turn_status` to obtain that turn's loop),
`input_blocked` (`blocked_reason`: a drain refusal, or `loop_held` —
the tail is a hold and this row predates it or addresses another
answerer), `turn_created` (with `answering_user_public_id` on every
kind — who answered a reply turn; the conversation's answerer at
creation on a message or summary turn),
`turn_status`, `turn_variant`, `task_status`, `round_result`, `usage`,
`attention_required` (the loop-backed turn's own items, keyed by
`task_key` — agent_loops.md), `context_trimmed` (narrated only when
assembly left history out: `history_selected`, `history_skipped`,
`history_skipped_reason` — an untrimmed assembly's evidence is the sealed
request itself), `context_compacted` (a repair was armed for a context
that would not fit — `mode: prune|kernel|delegate`, `trigger:
usage|wall|overflow|manual|fallback`, `agent_loop_public_id`, the `turn_public_id`;
between turns `summary_turn_public_id`, the summary turn appended; on a
loop-backed turn's own round `task_key` and, when it summarizes,
`summary_task_key` — one item, one builder, on either host; a `fallback`
item is the kernel's summarizer appended once in place of a delegate
nobody answered, and carries `fallback_from` — the expired delegate's key
— and `fallback_reason`, `tool_timeout` or `tool_uncertain`), `fork_created`, `visibility`, `soft_delete`,
`turn_deleted`, `reasoning_replay_downgraded` (the replay kill-switch
tripped for this conversation), `runner_bound` (a HOST item — the handoff
landed: `{executor_public_id, previous_executor_public_id?, by}`, the
previous absent before any binding or after a reap, `by` the caller's
public id) and `task_readdressed` (a loop item on the host feed — an
unclaimed runner-kind row moved with the handoff: `{task_key, role,
executor_public_id?, deadline_at}`, the executor absent on a pool row, the
deadline the re-armed park's) and `task_deadline_extended` (a loop item on
the host feed — a claimant extended its own park: `{task_key, deadline_at,
by, timeout_ms}`, `by` the claimant's public id; [Executor](executor.md)
"Extend") and `access_changed` (a host item — the carrier
was replaced: `{default, entries: [{user_public_id, level}], by, kind}`,
`by` the caller's public id and `kind` its KIND, `human | agent`; never
narrated for an unchanged set) and `conversation_ended` (a HOST item — THE
END IS A PERSISTED EVENT (the row and its event are committed together,
so followers can recover the lifecycle transition through replay):
`{reason: archived | tombstoned, conversation_public_id}`, narrated by
archive and by DELETE in the verb's own transaction on every member of the
tree they stamp, naming the member itself; a tombstone's item is the LAST
item its feed ever carries — the cable delivers it, the next poll is the
family 404, and the reap destroys the row later. An archived feed remains
readable; accepted work can still settle into the archived row. A follower
may end its local following on archive, without issuing kernel Stop or
claiming that all work has stopped. Unarchive narrates nothing and retains
the historical archive item. A new following must reconcile that item with
the conversation's current `archived_at`: if restored, continue replay;
otherwise end the local following).
One type in the vocabulary is a MEMBER item
and never appears on either host's feed: `handle_changed` (a
member was renamed: `{user_public_id, old, new}`, narrated on the member's own
rows; [Profile](profile.md) "Renames and the cooldown").

THE CABLE AND THE LEVEL: subscription checks the same visibility as REST:
`none` rejects like absence. Changing the conversation's access list does
not disconnect an already subscribed socket; subsequent REST reads use the
new access immediately. A client requiring immediate removal of that live
subscription must close it. Workspace authority withdrawal is different:
the kernel requests disconnection of member sockets, allowing them to
reconnect and resubscribe under current authority. That notification is
best effort; durable replay and REST enforce current access independently.

On a conversation host, `turn_status` carries either Turn state or loop
state, and `status` is OPTIONAL. The converger narrates the TURN's row after
each settle —
`{turn_public_id, turn_kind, variant_public_id, agent_loop_public_id,
status, variant_status, failure_reason_key?}` and, on a hold,
`error_key` (the newest failure) and `blocked_task_keys` (what an
adjudicator can act on) — where `status` is the TURN's settled state and
`variant_status` the sample's own terminal (a failed regeneration
narrates `completed`/`failed`). A reply whose answer the provider DECLINED
is a failed sample though its call completed: `variant_status` is
`failed`, `failure_reason_key` is `model_refused`, and `finish_quality`
(`refused | blocked`) and the provider's `refusal_category` (absent when it
named none) ride beside them; it never replaces a completed sample and
never moves the context revision. When the answering profile's fallback
re-asks it, that same item says `status: "running"` and carries
`model_change {from, to, reason: "model_refused" | "provider_overloaded", category?}` — the one
`turn_status` of the switch, beside the fallback candidate's `turn_variant`. Edit and activation also publish the Turn's
current `status` and selected `variant_status`, even when selecting another
completed candidate leaves the status unchanged. The loop, under its own
lock, narrates where IT is at every
status write — `{turn_public_id, turn_kind, variant_public_id, agent_loop_public_id,
loop_status, failure_reason?, attention_reason?}` with NO `status` — and
a follower treats a missing `status` as no turn transition. A reply with no
backing loop carries no loop keys. `turn_kind` — the turn
row's own `kind` — rides EVERY `turn_status` a conversation host
narrates (the materializer's `running`, the loop's notes, the
converger's settle, a regeneration's, a cancel's, an edit's or activation's):
`direct_reply` on an answer, `compaction_summary` on the kernel's between-turn summary, so a
follower that posted a word behind a summary tells the summarizer's loop
from its own turn's without reading the turn. Every item narrated by a
loop carries `agent_loop_public_id`; on a conversation host it also
carries `turn_public_id` and `variant_public_id` from that loop's own
variant, even when another turn or regenerated candidate is running.
These identify the event's source, not the currently displayed answer.
Task-grained items also carry `task_key`, which is local to the source
loop. A standalone loop has no turn or variant identity; a direct reply
has no loop identity. Items age out after 30 days while the conversation
lives, even if a turn is still running. Sequence allocation never rewinds
when items expire, so replay may have a gap after a follower's last seen
sequence. Expired items cannot be recovered by replay; refresh from the
durable timeline and loop tasks instead of treating the stream as an archive.

## The transcript feed — what a turn SAID

The `events` feed carries where a turn GOT TO; `items: "transcript"` on
the same channel carries what it is saying. ONE stream over the host: a direct reply and a loop-backed turn publish here, a standalone
loop on its own channel (agent_loops.md, "The event stream"), in one
vocabulary. Three kinds of item ride it:

**Deltas, while a reply runs.** `text_delta` (`text`), `reasoning_delta`
(`kind`, `text`), `tool_call_started` (`call_id`, `name` — published on a
call's FIRST fragment, so a row can be drawn before its arguments
finish), `tool_call_arguments_delta` (`call_id`, `delta`), and
`stream_reset` (`reason: "retry"` — a transient retry threw this
attempt's streamed output away; DISCARD what you accumulated rather than
splicing two attempts together; `reason: "refused"` — the attempt ended in
an answer the provider declined, which the kernel stores none of, so
discard the same way; `reason: "failed"` — the attempt failed and nothing
retries it, a budget spent mid-stream included, so the reply holds none
of it). Every item names its `turn_public_id`
and `variant_public_id`.

**The settled task, when a loop-backed round or call terminalizes.**
`{"type": "round", "task_key": …, "round": {…}}` and `{"type": "call",
"task_key": …, "call": {…}}` carrying the SAME row the loop's paginated
transcript serves, under the task key the deltas carried.

**The settled turn, after execution settles or a completed candidate is selected.**
`{"type": "turn",
"turn": {…}}` carrying the SAME projection a `GET .../turns` page serves,
under its `turn_public_id` — so the sealed body replaces the accumulator,
as an event rather than a rule every client re-implements against a
separate read. A loop-backed
turn's snapshot carries the loop's `rounds`. The top-level
`variant_public_id` identifies the candidate whose execution settled, or
the candidate selected by edit or activation; `agent_loop_public_id` is
also present when that source candidate is loop-backed. Selection does not
imply a new loop completion, and a manual edit has no backing loop.
These keys identify the frame's source, while `turn.active_variant` is
the displayed answer: a canceled or terminally failed regeneration can
carry the new candidate's keys around the retained original answer.
Consumers must match the source before replacing an execution's accumulator,
so a delayed snapshot from an earlier candidate cannot settle a new one.

**A settled `round` carries a PREVIEW, a settled `turn` carries the body.**
`round.text_preview` is truncated by construction (`text_bytes` beside it
says how much there was), so what replaces an accumulator is the TURN's
`active_variant.content` and never a round's preview — a follower that
replaced on `round` would silently truncate what a person is reading. On a
standalone loop there is no `turn` item at all: the deltas are everything
that was said, and no remainder follows them.

The three questions every consumer of this feed answers — what to do with a
delta, with a `stream_reset`, and with the settled body — are implemented
ONCE in the Ruby SDK as `CybrosAgent::Api::TranscriptAccumulator`
(`accumulate` / `reset` / `replace_on_settle`). A client that writes its own
must answer the same three, and must count what it accumulated rather than
compare against a bounded buffer: a preview held to N bytes is a TAIL of a
longer answer, and `settled.start_with?(preview)` is false for every reply
past N.

NOTHING ON THIS FEED IS DURABLE. It is a TAIL, not a log: a subscriber
joining a running reply gets what happens from then on, nothing is
backfilled, and a delta that never arrives costs a frame of latency,
never a fact — the variant and its content are the record, and
`GET .../turns` is the recovery path rather than the steady state. A
`hidden` or concealed turn is off this feed as it is off the timeline,
its loop's rounds included; a `hidden` task is off it on both hosts.
This suppresses conversation content, not execution: background results
still persist, and durable task events and the loop's own trace remain.

The contract: a loop-backed turn's rounds stream HERE, on the
conversation the turn belongs to — its deltas and its settled `round` and
`call` items carry `agent_loop_public_id` and `task_key` beside
`turn_public_id` and `variant_public_id`. Those two keys are ADDITIVE and
absent for a direct reply; on a loop host (a standalone loop's own
channel) `turn_public_id` and `variant_public_id` are the absent ones.

## The progress feed — what is happening RIGHT NOW

`items: "progress"` on the same channel carries what is happening while it
happens — ONE feed over the host, a standalone loop's on its own channel
(agent_loops.md, "The event stream"), under the envelope `{frame}` and
never `{event}`. Five words ride it, listed ONCE in the contract pack
(`conversations.json#/progress_frame_types`): the kernel's own three —
`round_started` (`task_key`, `spine`, `attempt`, `model`, `request_bytes`:
a model attempt was dialled), `step_started` (`task_key`, `tool_name`,
`status`: a tool row was dispatched, run or held — an approval-gated call
says so twice, held then released, and a reader upserts the call's live
status), `step_claimed` (`task_key`, `tool_name`, `executor_public_id`: an
executor took it) — and the executor's two, `executor_progress` and
`process_output` (executor.md, "Progress"). Every frame carries the host's
keys — `agent_loop_public_id` and `task_key`, and on a conversation host
`turn_public_id` and `variant_public_id` beside them — and `at` in
milliseconds. A frame is minted only for a fact NO row and NO settled item
carries at that instant: a round's or a call's END is never a frame — it is
the settled `round` / `call` on the transcript feed, whose `started_at` /
`completed_at` are the timing; a compaction's arming is the durable
`context_compacted`; a direct reply narrates `turn_status`, its deltas and
its settled `turn`, and mints no frame.

The transcript feed's laws hold here, inherited: NOTHING is durable — a
frame is stored nowhere and replays never; a frame never CREATES a row (it
narrates one the window already serves, or a claimant a task read already
names); COMPLETION WINS — the settled snapshot replaces a live mark; the
feed is a TAIL, not a log — a subscriber sees what follows its
subscription. A `hidden` task reaches this feed exactly as it reaches the
transcript: not at all; on a conversation host a `hidden` or concealed TURN
silences its loop's frames the same way.

## Memory — durable, scoped, and on this plane injected rather than fetched

A `direct_reply` is one model call with **no tools** when the declaring
profile carries none, so nothing on that path can call `memory_read`.
Memory reaches a conversation's model through an **assembly block**, and
it gets there through these routes — on a tool-less turn memory's only
writer. A LOOP-BACKED turn's rounds carry the profile's tools, so a loop
declaring the memory tools reaches this conversation's scope through
them (`conversation/…` paths resolve to this conversation); each write
bumps `context_revision` exactly as these routes do. Client state that no
prompt reads is NOT memory: it lives in the conversation's own
`…/store_entries` ([Store entries](store-entries.md)), which forks with
the conversation and bumps nothing.

- `GET .../memory` — every document in this conversation's selected bindings;
  by default its own, its workspace's, and the controlling Human's `user/` scope,
  as `{path, public_id, lock_version, bytesize, description, written_at}` (`description` is the
  skill row's, `null` on a plain document). `written_at` is
  the CONTENT's age, not the row's, so a forked conversation does not
  report every inherited document as written at the moment of the fork.
- `POST .../memory/show` — `{memory: {path}}` answers one document with
  its `content`.
- `POST .../memory` — `{memory: {path, content, description?, expected_public_id, expected_lock_version}}` writes one
  document whole. 201.
- `POST .../memory/grep` — `{memory: {pattern, path?, ignore_case?, limit?}}`;
  200 `{matches: [{path, line_number, text}], truncated}`. Search is a bounded
  regular expression over lines, ordered by logical path then line. `limit`
  defaults to 100 and is clamped to 1–500; lines are capped at 500 characters.
- `POST .../memory/edit` — `{memory: {path, old_text, new_text, expected_public_id,
  expected_lock_version}}`; 200 `{memory: ...}`. The exact passage must occur
  once. Stale versions refuse before matching; no match or multiple matches
  return `memory_edit_not_found` or `memory_edit_ambiguous` (422).
- `POST .../memory/delete` — `{memory: {path, expected_public_id, expected_lock_version}}`. 204, and it is gone: no
  history, no recycle bin.

Both expected fields are required: `null`/`null` creates only an absent path;
a UUID/version pair from read or list replaces or deletes only the observed row.
Missing or malformed conditions return `400 parameter_missing` /
`parameter_invalid`; stale, missing, or recreated rows return `409 stale_object`
without changes. See [conditional writes](profile.md#conditional-writes) for the
shared create, delete, fork, and conflict contract. Never automatically retry an
old calculation with a newly fetched pair.

Every document renders as `{path, public_id, lock_version, bytesize, description, written_at}` on
the listing and with `content` on a read; `description` is `null` on a
plain document and the skill's line on a `skills/` row (below). The
other two scopes have doors of their own — the room's `workspace/` rows
at [`workspaces/{id}/memory`](workspaces.md#memory--the-rooms-own-rows)
(no conversation picked; no `context_revision` bumped), the person's
`user/` at [`profile/memory`](profile.md#memory--the-persons-own-scope) —
and this door is the one that writes `conversation/…` and bumps this
conversation's `context_revision`.

**THE PATH RIDES THE BODY on every verb that names one**, including the
reads. A memory path carries its scope as its first segment
(`workspace/notes.md`), which no routing convention survives, and
percent-encoding it would turn a model-facing string into a
transport-facing one for nothing.

**SCOPES.** `workspace/…` is shared with everyone who can open the
workspace — other agents and every human member. `conversation/…` belongs
to this conversation alone. `user/…` belongs to the person this turn
answers to and follows them across workspaces; their other agents can
read it — the controlling Human of the acting principal (an agent's
steward, a Human itself), never a property of the conversation, so the
TURN's principal decides whose `user/` the assembly block renders: a
Human B posting into a conversation A's agent created gets B's notes and
none of A's, and B's `user/` writes are invisible to A's next turn. The
person's own door to that scope is [`profile/memory`](profile.md#memory--the-persons-own-scope).
A bare name is refused (`memory_path_invalid`) rather than defaulted,
because a default would decide where notes live by accident and the
three scopes differ in who can read them.

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory_context
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory/grep
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/memory/edit
```

**NAMED PATH BINDINGS.** Memory content stays in `MemoryDocument` database
rows and immutable text versions. Paths are a file-style interface; they do not
refer to files or synchronize with a runner. A conversation's optional
`memory_context` is returned on its full representation and may be supplied at
creation. `POST .../memory_context` replaces it with the body below and returns
200 `{conversation: ...}`. Missing the field is 400; `null` explicitly restores
the default roots. `{"bindings": []}` disables all memory roots.

```json
{"memory_context":{"bindings":[
  {"name":"conversation","scope":"conversation","access":"read_write"},
  {"name":"group","scope":"conversation","access":"read","conversation_public_id":"01900000-0000-7000-8000-000000000072"}
]}}
```

Each binding has a unique root `name` (`[a-z][a-z0-9_-]{0,31}`), an existing
`scope` (`conversation`, `workspace`, or `user`), and `access` (`read` or
`read_write`). At most 16 bindings are allowed. Every nonempty configuration
includes `conversation` with scope `conversation` and no explicit UUID, so the
current conversation remains addressable. The reserved root names
`conversation`, `workspace`, and `user` keep those meanings. A differently named
conversation binding may select a visible existing conversation in the same
workspace with `conversation_public_id`; otherwise it uses the current host.
`user` and `workspace` always select the current principal's controlling Human
and current workspace. Binding an arbitrary Human is unsupported.

Configuration requires host write standing and source read standing; a
`read_write` conversation binding also requires write standing on that source.
Names such as `group/` and `person/` are aliases, never new storage scopes.
For example `group/notes.md` reads the selected conversation's database row,
and list, grep, show, edit, and write responses keep that same logical path.
Write, edit, and delete through a read binding return `403 memory_read_only`.
A missing, tombstoned, or inaccessible source is omitted from unqualified reads
and injection; an explicit path returns `memory_scope_unavailable`. No source
falls back to another root. Explicit nonempty configurations expose their
available roots and access modes to the model even before documents exist.

Injection, preview, memory tools, and this management door use the same
resolver. An execution freezes its configuration on the reply variant; its
loop, tasks, composed work, retries, regenerated variants, and completion mail
continue using that configuration. Peer mail uses the receiving conversation's
configuration. Spawn inherits the initiating execution's bindings; a relative
conversation root follows the child, while an explicit shared UUID stays
shared. Fork copies the conversation's configuration and retains the selected
variant's configuration when adopting it. A configuration change affects new
ordinary executions and bumps `context_revision`; it does not rewrite a
running execution. Profile and workspace memory doors remain management of
those resources' own database anchors.

**SKILLS.** A document under the reserved prefix `workspace/skills/<name>`
IS A SKILL — the room's: `name` under the skill grammar (`[a-z0-9]`, single
hyphens, ≤ 64 — stricter than a memory name's, because a model types it
back from the catalog and it must match a directory on a runner byte for
byte), `description` REQUIRED (≤ 1024 bytes — the line the model reads in
its turn's skills block to choose), `content` the markdown body the model
reads when it loads it with the `skill` tool. `description` is refused
outside `skills/`. `conversation/skills/…` is refused
`skill_scope_unavailable`: a skill is never per conversation (a fork
copies the conversation rung, and a skill copied per fork would be a second
authority for one instruction). A model's `memory_write`, `memory_edit` and
`memory_delete` never author a `skills/` row (`memory_reserved_prefix`) — a
person or their program does, through this door. The assembly's memory
block never renders a `skills/` row; `memory_ls` and `memory_read` see it
as any document. The workspace's row is written through ANY conversation of
the room, or through the workspace's own memory door. The refusals, all
422: `skill_description_required`, `memory_description_invalid`,
`skill_name_invalid`, `skill_scope_unavailable`.

**WHILE THE WORKSPACE IS OVERRIDDEN** (`tool_provider_overrides` names a
provider for `nexus.memory`, [Workspaces](workspaces.md)) these routes
refuse `memory_overridden` (409, naming the provider) for reads and writes
— all three scopes, the `user/` rung included — the assembly block renders
nothing, and the kernel's rows wait untouched for the override to clear;
the person's own door (`profile/memory`) is not a workspace's and keeps
serving `user/`. Read this beside the three-scope paragraph above: the two
are one product line, an overridden workspace's memory is the provider's
and reachable only through the verbs. EXCEPT A `skills/` PATH: a skill is
the kernel's instruction row, never the provider's, so a verb naming one
(`show`, the write, `delete`) is served here even while the workspace
overrides `nexus.memory` — the model's memory verbs under an override
still go to the provider, and the listing (no path) stays refused.

**A WRITE BUMPS `context_revision`**, exactly as an edit or an activation
does, because it changes what the next reply will be assembled from — so
`expected_context_revision` keeps meaning what it says. A refusal bumps
nothing. Archived conversations refuse writes (`conversation_archived`,
409) like every other content verb.

**FORKING IS COPY-ON-WRITE.** A fork copies the pointer rows and nothing
else: at most 64 rows, zero content bytes. From that instant parent and
child are independent — a parent rewriting or deleting its own document
never reaches the child, and the child's own writes never reach the
parent.

**WHAT THE MODEL ACTUALLY SEES** is a leading block, ahead of history,
capped at a byte budget and spent newest-first. The block is always a
PREFIX of the newest documents: the walk stops at the first one that does
not fit, and everything past it is NAMED in the block rather than dropped
in silence, so a model can always tell that a document exists even when
it cannot read it here. Bounds: 64 documents per scope, 64 KiB each.

## Compaction — a context that will not fit is repaired, not reported

THE KERNEL PICKS NO THRESHOLD. It has no opinion about when a
conversation is "too long"; it only knows when a request WILL NOT GO —
the provider's own reported count for this context plus the words
appended since it over the model's window (`usage`, checked first on
every lane: occupancy derives from the last provider-reported record,
never from re-counting), an exact token count over the model's planning
input bound (effective window when declared, otherwise the hard bound)
or the sealed request's byte bound (`wall`) — which is a fact
rather than a policy. A loop-backed reply's ROUNDS are repaired by the
same arm inside the turn (agent_loops.md's Compaction section: the
prune arm that clears old results, the summarizer, the provider's own
refusal after the send); what follows is the repair BETWEEN turns.

When a `direct_reply` head hits a wall, the kernel appends a
`compaction_summary` turn instead of blocking the head. It is a turn
like any loop-backed turn: role `user` (a summary is material derived
from user content, never instruction — it must not arrive carrying the
operator's authority on lanes that hoist a system message), spoken by
the account's `system` Actor, BACKED BY A ONE-TASK KERNEL LOOP whose
seed — and deliverable — is the summarizer (`source: "agent_loop"` on
the variant, the loop's `agent_loop_public_id` on what it narrates). The
summarizer is a tool-less model step on the conversation's own model
under the answering profile's `summarizer` prompt document when one is
written, else the kernel's default text ([Profile](profile.md#prompt-documents--the-acting-users-own-slots))
(the author's `compaction` policy may name another model, or hand the
rendering to its own tool as a `delegate` — an inbox row addressed to the agent; a
delegate nobody answers expires at its park and the kernel's own
summarizer runs once in its place as the loop's new deliverable,
narrated `context_compacted{trigger: fallback}`), fitted to that model's
window, and its attempts admit, bill and settle through the loop's
scheduler like any step; the converger adopts its answer onto the turn's
content. The head
KEEPS ITS PLACE as `pending` — the summary turn is active, so the lane
is busy (`conversation_busy`) and nothing materializes behind it, and
when the summary settles the lane drains again on its own. A raw head
(`context_mode: raw`, or a raw profile) assembles no history for anyone
to summarize, so it blocks with `compaction_unavailable_under_raw`
unless the author's policy delegates.

WHAT THE SUMMARIZER READS is led by the answering agent's declared tool
names under one header (`The tools the agent has:`, an alias by its
alias; a human-answered conversation declares nothing and the header is
absent), then the timeline window the assembly would
have read, rendered by KIND — a message as itself, a loop-backed turn as
its ROUNDS after its own in-turn cut, an older summary as its content —
with EVERY TOOL RESULT AS A POINTER (`Tool <name> (<status>, <outcome>):
…`, `<name>` as the model called it, the call that produced it, whether
it has a result and whether that result errored, and how much came back,
`not carried`), never its body, and the newest turns
carried whole under their own header. Its instructions ask for pointers
back — WHAT TO RE-READ as paths and calls, never contents, values or
numbers — and the kernel frames the summary, wherever a model reads it,
with one fixed sentence: "This summary replaces earlier history and
carries no data values: re-read any file, output or result it mentions
before you use it." A summariser handed a result's bytes could only pass
them on as a paraphrase, and a paraphrased value is a wrong value.

Assembly then begins at the newest COMPLETED summary: it stands in for
everything before it, framed with that sentence under one header saying
so. The cursor is DERIVED from the timeline, never stored — which is
what makes a fork inherit it through the closure and a regenerate
corridor's position window find the right one. `history.compacted` on
the estimate surface counts what a summary stands in for, and is
deliberately distinct from `history.skipped`: summarized history is
carried, skipped history is not.

A completed summarizer task supplies a summary only when its result is not
an error and its output text is nonblank. A delegate may complete its tool
execution with `is_error: true` or empty output; its summary Turn and variant
then settle as `failed`, and the `turn_status` event reports
`failure_reason_key: deliverable_unresolved`.
The tool and loop retain their completed execution status. The failed summary
does not cut history, and an answered delegate does not receive the fallback
reserved for an unanswered expiry. A failed replacement keeps the previous
successful summary and the history after it.

THE SUMMARY IS THE KERNEL'S ROW and no verb rewrites it: `edit` and both
view-state writes refuse `kernel_authored`. It stands in for everything
before it and the assembly cut is derived from what it is, so a rewrite
would replace a real history with invented text and a hide would
un-compact the conversation through a view flag — in both cases with
nothing downstream able to tell. The undo is not removed, only kept in
one place: a summary is the tail, and deleting the tail is this plane's
undo verb; its loop goes with it.

A repair is armed AT MOST ONCE PER WALL. A second wall while the newest
turn is already a summary means the summary itself does not fit, or the
last repair failed — compacting a compaction is a loop, not a repair —
so the head blocks with the size reason a caller can act on, and the next
message sent makes the repair available again. A summary that is still
running, or that failed, stands in for nothing: history is intact — and
a failed summary never holds the queue behind it (`loop_held` is for a
person's turn, not the kernel's own row); the head simply meets the wall
again and blocks on it.

## Keyword search and bounded history

See [Conversation history search](conversation-history.md) for Chinese and English
keyword search across readable conversations, hit-centered context, and the
`session_search` / `session_read` model tools.


### External ingress speakers

Conversation input create also accepts `speaker_actor_public_id`, naming an
[ingress Actor](ingress.md) controlled by the authenticated Agent. It is a
create-only user-role selector included in the input receipt digest. Input and
user-message turn speakers then have `{actor_public_id, kind: "ingress",
display_name}`; member speakers retain their existing shape, and reply turns
still identify the answering Agent. The external voice is always wrapped by the
same SpeakerEnvelope in assembled seeds, history, steers and summarizer material.
`kind: "message"` records passive speech without starting a loop or model call.
