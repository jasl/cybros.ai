---
title: Conversations
description: The conversation resource — creating one, its answerer and access carrier, lists and projections, archive, delete, subagents, forks, side conversations, usage and cost limits.
---

# Conversations

A Conversation is the timeline aggregate: a position-ordered sequence of
turns, each with its variant candidates and settled content; a durable
input queue that is the message envelope; fork-without-copy lineage; and
a per-conversation replay event stream.

The kernel compiles the reply prompt by default from the knowledge it
holds. `context_mode: "raw"` is the advanced escape hatch where the
caller owns the whole prompt verbatim.

Completed conversation executions follow
[execution retention](execution-retention.md): text stays readable after
execution detail expires.

## The rest of this resource

| Page | What it owns |
| --- | --- |
| [Conversation inputs](conversation-inputs.md) | The waiting room: posting, the queue and its edit surface |
| [Conversation input fields](conversation-input-fields.md) | Every field an input carries, attachments included |
| [Kernel mail](conversation-kernel-mail.md) | The inputs the kernel writes itself |
| [Conversation turns](conversation-turns.md) | The timeline, candidates, edit, regenerate, activate, undo, stop, view state |
| [Conversation context](conversation-context.md) | The estimate and preview, compaction, the automatic repair, the sealed request |
| [Conversation memory](conversation-memory.md) | The documents a reply assembles from, their scopes, bindings and skills |
| [Conversation feeds](conversation-feeds.md) | Event replay, the cable channel, the transcript and progress feeds |
| [Prompt assembly](prompt-assembly.md) | What an assembled turn compiles, and the template grammar |
| [Conversation history search](conversation-history.md) | Keyword search across readable conversations |
| [Conversation diagnostic export](conversation-export.md) | Download retained content, execution, usage and events |
| [Conversation reasoning](conversation-reasoning.md) | The stored reasoning window of a completed candidate |

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
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/forks
PUT    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/default_runner
PUT    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/access
```

## Create a conversation

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations
```

### Request

Under the caller's `Idempotency-Key`:

```json
{
  "conversation": {
    "title": "Kitchen",
    "metadata": {},
    "cost_limit": null,
    "billing_subject": null,
    "default_runner_executor_public_id": null,
    "answering_user_public_id": "@lark",
    "access": { "default": "full", "entries": [{ "handle": "@ada", "level": "read" }] }
  }
}
```

### Response

`201`, and exact receipt replay returns `201` with the original response
body. `Idempotency-Replayed` is `false` for a new creation and `true` for
a replay.

### The answerer

`answering_user_public_id` names the Agent that answers this
conversation: whose declaration chooses the engine of every reply head,
whose `system_prompt` slot leads every assembled turn, and whose standing
the runner is judged for.

Omitted, the creator answers its own conversation: an agent creator
brings its engine, and a Human creator has a plain chat until a profile
is named. It is refused `422 answerer_not_eligible` unless it names an
agent of the account that may write in this workspace — absence, a Human,
the system user, a removed or dedication-fenced profile all conceal as
ineligibility. It never changes after create, and a fork copies it.

### The default Runner at birth

`default_runner_executor_public_id` optionally selects a live Runner
eligible for the answerer. Omission leaves the default null. Runner steps
without an explicit target use that default at acceptance, while model
declarations carry concrete Runner routes. The creation envelope includes
this preference for idempotency.

The full document carries `default_runner: {executor_public_id,
display_name, presence, last_seen_at?} | null`, where presence is a
display hint. The listing omits this projection, and
`answering_user_public_id` on both shapes.

### The cost limit at birth

`cost_limit` is an optional decimal string in the Account's configured cost
unit; omission or null leaves it uncapped. It belongs to the create idempotency
envelope. The [cost-limit rules](#cost-limits) define its amount bounds,
admission scope and recovery.

### Memory at birth

The optional `memory_context` selects named memory bindings; `null` uses
the default roots. The full document returns the saved selection as
`memory_context` and the resolved, profile-limited bindings as
`effective_memory_context`. An unbound Speaker root waits for an input's
actual Speaker when an execution starts; management reads do not infer a
subject from previous turns. The [memory reference](conversation-memory.md)
owns the binding grammar and access rules.

### The access carrier at birth

The document carries `access: {default, entries: [{user_public_id,
handle, kind, display_name, level}]}`: the level (`full | read | none`)
of every principal the entries do not name, and one entry per named
principal. The creator and the answerer are `full` by derivation and
never appear as entries; `none` conceals. Every conversation is born
`full` for every member, and that is not create-frozen.

`access` on the create body names the default and the entries — each
`{user_public_id, level}` or `{handle, level}`, the member's handle
written `@lark` or `lark`, resolved at the door, one spelling per entry.
The ids and handles come from `GET …/workspaces/{id}/principals`.
Omitted, it is `full` with no entries.

A principal that may not be named is refused `422
principal_not_eligible`, one code with no detail, since every id named is
the caller's own account's and the listing says which: the creator, the
named answerer (both full by derivation — a row would lie), the system
user, an unknown id or handle, a principal named twice by either
spelling, or an entry spelling both. An unknown level or default is `422
validation_failed`.

`access` rides the idempotency envelope in the request's own entry order.
Array order is request identity on this surface, so a replay that lists
the same entries in another order, or omits them, is `409
idempotency_envelope_mismatch`; a refused create writes no receipt, so
its key is free. It is not on the listing shape and never null. An entry
is self-describing: it includes the principal's `display_name`, so a
client can render the access list without another lookup.

### The level is the door

`none` conceals. Every member-plane door over the conversation — the
lists, show, turns, events and the events channel, inputs, store, memory,
fork, the replay of a create or fork receipt, and every route of a run
one of its turns hosts — answers `404` for a `none` principal, exactly as
a tombstone does, never a `403` that admits the row exists.

`read` is read: every read answers, and every write is `403
not_authorized` — an input, a rename, archive, unarchive, delete, fork, a
turn's edit, regenerate, cancel, delete and view-state, a compaction
request, the store, the memory door, the default Runner preference, and
every verb on a hosted run.

`full` is what write standing has always meant, still conjoined with the
workspace's.

The kernel's own acts never consult the level: the answerer's engine
writes its turns, and a task's receipt lands as kernel mail whatever the
run's creator holds.

## Replace the access carrier

### Endpoint

```http
PUT /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/access
```

### Request

`{ access: { default, entries?: [{ user_public_id | handle, level }] } }`
— a whole replacement of the default and the named entries, entries
omitted being the empty set. It is the replacement shape: PUT, never a
PATCH twin, idempotent by value, no receipt.

### Who may change it

Full control includes changing permissions: `full` on this row — the
creator, the answerer, or a `full` entry — with write standing on the
workspace. A principal the row lists at `read` is `403 not_authorized`,
because it cannot escalate itself; one it conceals finds the door `404`
before any standing is judged.

The creator and the answerer can never be locked out, being full by
derivation. A `full` peer may narrow the default: a product that wants
less narrows.

### Response

`200` with the conversation document; the same set is a plain `200` with
nothing written. `422 principal_not_eligible` and `422
validation_failed` apply as on create, a tombstone is `404`, and the
archived bin accepts it, since who may read the bin is not content.

The kernel narrates one `access_changed` item on the feed per change —
`{default, entries: [{user_public_id, level}], by, kind}`, the actor's
kind recorded (`human | agent`) — and never bumps `context_revision`,
because assembly does not read the carrier.

An agent learns its own id from `GET /agent_api/v1/profile`
(`member.public_id`), and its peers' — and its own steward's — from `GET
…/workspaces/{id}/principals`.

## Set the default Runner

### Endpoint

```http
PUT /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/default_runner
```

### Request

`{default_runner: {executor_public_id: UUID | null}}` replaces the
nullable default. The answerer on its member credential, or a Human with
conversation and workspace write standing, may make this choice; other
agents and transport credentials cannot.

### Response

`200` with the conversation document; repeating the same value is
idempotent. A missing Runner returns `404 runner_not_found` and an
ineligible one `409 runner_not_eligible`.

A change emits `default_runner_changed` and affects only later task
acceptance. Existing target identities, holds, clocks, claims, processes
and frozen declarations remain tied to their original work.

## List conversations

### Endpoints

```http
GET /agent_api/v1/conversations
GET /agent_api/v1/workspaces/{workspace_id}/conversations
GET /agent_api/v1/workspaces/{workspace_id}/conversations/archived
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{public_id}/children
```

### Which rows each list holds

The default list is the working surface: unarchived, top-level, and never
a side conversation. `?side=1` lists the workspace's sides only, under
any parent — a side is a child row a UI may hide, and the flag is the one
way to see them; any other value is the default.

`/archived` is the recycle bin's own view.

`GET /agent_api/v1/conversations` lists readable root conversations across
accessible workspaces, including archived workspaces and excluding deleted ones.
It includes both active and archived conversations by default. Set
`archived=0|false` or `archived=1|true` to select one state. Spawned children
and side conversations are excluded; an ordinary fork remains a root.

The cross-workspace list and the workspace working/archive lists accept
`answering_user_public_id`. The cross-workspace list additionally accepts a
paired `metadata_key` and `metadata_value` for an exact top-level string match.
Both must be nonempty; the key is limited to 128 bytes and the value to 1024
bytes. These filters and the caller's read permissions apply before pagination.
Application metadata has no kernel-defined meaning.

Basic and Full projections both include `workspace_public_id` and `lock_version`. Use the saved
locator when reading or controlling a historical conversation; the caller's
currently selected workspace does not change its location.

A subagent conversation (`parent` present) is a lifecycle follower:
readable by id, listed only through its parent's `/children` — the nested
resource, the Rails-native shape a follower has always been listed by,
through the one read funnel, keyset-paged. There is no `?parent=` filter
on the working list.

### Ordering and cursors

The cross-workspace, working, archived and child lists accept
`order_by=public_id|last_activity_at` and `order=asc|desc`; the defaults
are `public_id` and `asc`. Activity order uses `public_id` as the
tie-breaker in the same direction. For a recent-first sidebar, request
`order_by=last_activity_at&order=desc`.

Continue with the returned `pagination.next_after`, keeping both ordering
parameters unchanged. A cursor for another key shape or direction returns
`400 parameter_invalid`, and unknown ordering values do too. The activity
cursor retains timestamp microseconds.

Pagination reads current activity: a conversation that becomes active
between requests can move across the page boundary, so a sidebar
refreshes from its first page to incorporate new activity.

### Lineage on both shapes

Both Basic and Full include `source_conversation_public_id: UUID | null`:
the direct source of an ordinary fork or Side, including a Side created
from an empty conversation. It is derived from the direct ancestry edge,
independently of the turn's original owner, and is null for roots, when
the current caller cannot read the source, and when the source is
tombstoned. An archived readable source is still named.

This field does not change `parent`, which describes a spawned subagent,
or the captured `forked_from_turn_public_id` and variant.

## Update a conversation

### Endpoint

```http
PATCH /agent_api/v1/workspaces/{workspace_id}/conversations/{public_id}
```

### Request

```json
{
  "conversation": {
    "title": "Kitchen plans",
    "lock_version": 2
  }
}
```

Supply the `lock_version` from the Conversation you read and at least one of
`title`, `metadata` or `cost_limit`. Omitted fields remain unchanged. A null or
blank title clears it; metadata is an object and replaces the previous object.
`cost_limit` accepts a decimal string; explicit null removes the limit.

### Response

`200` with the full Conversation, including its current `lock_version`.
An unchanged edit with the current version succeeds without changing the version.

### Status codes

A stale version returns `409 stale_object` without changing any field. Refetch
and reconcile before submitting another edit; the server never retries an edit
against newer state. Missing or malformed versions return `400`; versions are
integers from `0` through `2147483647`. Invalid fields return `422`, and metadata
over its persisted size bound returns `413 content_too_large`.

An archived Conversation accepts a cost-limit-only edit so accepted work can
be repaired. Including `title` or `metadata` returns `409 conversation_archived`;
unarchive to change them. Workspace operability and Conversation write standing
still apply.

## Archive and unarchive

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{public_id}/archive
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{public_id}/unarchive
```

Archive moves the Conversation and its subagent tree into the reversible bin
immediately. New independent inputs refuse `409 conversation_archived`.
Already accepted queued inputs and executions continue in their original
Conversation: tasks, claims, approvals, questions, result mail, continuations
and execution memory writes may finish. A steer is accepted only when
`expected_steering_run_public_id` names the exact live Run; it cannot fall
back to a new queued turn. An existing held steer may advance to `steer_now`.
An accepted Run can still spawn, and its child stays in the archived tree.
Archive does not invoke Stop. Explicit Stop, Workspace lifecycle, deletion
and side cleanup keep their separate contracts.

The visibility change is narrated: one `conversation_ended` (`reason: archived`) on
every member stamped, in the verb's transaction
([Conversation feeds](conversation-feeds.md)). Followers retain accepted
execution and delivery until they settle; this event is not execution completion.
A fork of an archived
source is permitted, being a pure read-derivation.

A subagent target refuses `409 subagent_follows_parent`: the parent's
verb stamps it. A side conversation is never archived (`422
side_conversation`); the parent's archive reaps its live sides first, a
running one cancelled by the kernel's own act, never refused.

Unarchive blanket-restores the tree. A side refuses `side_conversation`
and a subagent `409 subagent_follows_parent`; the reaped ones do not
return.

## Delete

```http
DELETE /agent_api/v1/workspaces/{workspace_id}/conversations/{public_id}
```

Delete intent: the tombstone command. It refuses `409
subagent_follows_parent` on a subagent target, and `409
conversation_busy` while live work runs anywhere in the tree.

It narrates `conversation_ended` (`reason: tombstoned`) on every member
stamped, as the last item its feed carries: on the cable at once, and the
next poll is the `404`. A repeated delete answers `404`, the condemned
phase concealing like absence. Physical reclamation follows after the
frozen 30-day window, deferred further while any fork child's closure
still pins the row.

On a side conversation DELETE is tombstone and reap at once: its running
turn, if any, is cancelled first, and the row is stamped and reaped in
the same call (`204`, then `404`). That is exact when idle, and bounded
by the reap sweep's cadence only while a cancelled attempt's settlement
is still pending. A side has no children, so leaves-first holds; the
parent's tombstone reaps its sides first, and a side never pins its
parent's reap.

Reclaiming a conversation also marks its hosted runs for deletion: their
execution history follows the existing settlement and retention rules,
and they never reappear as independent workspace-visible runs.

## Subagent conversations

A subagent conversation is born by the kernel's `spawn` tool alone
([Runs](runs.md)), off the spawning run's conversation, never a branch.
It is never a direct archive or delete target — the parent's verbs stamp
the whole tree, and the parent's `POST …/cancellation` stops work derived
from its execution owners, including their subagent requests.

When the caller captures a [delegation catalog](profile-configuration.md#delegation-catalog),
`spawn.declaration` selects a leaf configuration and the child retains the
caller's answering principal. The Conversation owns that captured declaration,
model-selection intent and fallback list independently of its first input or
spawning Run. Its detail projection reports `agent_configuration_present:
true`; ordinary Conversations report `false`. Forks preserve these defaults.
Unqualified sends and context estimates resolve the child's own current model
and defaults. An explicit per-input override affects that work without editing
the saved role or Conversation defaults.

The parent facts ride both shapes as one block, `parent: {public_id,
spawn_node_key, label} | null`:

**`public_id`** is the parent's, a public-id snapshot that survives the
parent's reap, as every child's does.

**`spawn_node_key`** is the key of the `spawn` call that minted it, the
id the spawning model read back. It is null once the spawning run is
reaped: `spawn_node_id` is unique, one child per call, and nullifies with
the run.

**`label`** is what `spawn` gave it, null when none: `[a-z0-9][a-z0-9_-]*`,
at most 64 characters, unique among one parent's children.

Without a captured delegation catalog, the child is created by the spawner's profile and answered by the chosen
one — the creator's own (a subagent) or a named peer — through the same
answerer door as `POST …/conversations`. It copies the parent's access
carrier (the parent's entries plus its derived-full pair materialized,
minus the child's own derived pair) and billing pair.

Spawn inherits the caller's frozen default Runner, unless
`default_runner_executor_public_id` explicitly supplies another Runner or
null. Nexus assembles the child's tools from its own answerer's source
configuration and the selected Runner, rather than copying the parent's
tool table ([Tool assembly](tool-assembly.md)). An ineligible selected
Runner refuses creation. The child inherits the source execution's memory
bindings and Speaker subject, narrowed by its own answering profile.
`speaker/` then belongs to the child answerer and that same Speaker; it
never selects the answerer's steward. An inherited `subtree` conversation
reach remains limited to the child and its descendants. A Side never spawns and is
never a child's answerer.

Spawn's `lifetime` controls the initial request's completion obligation,
not the child conversation's lifetime: `turn` requires the original
execution's report before its caller's final reply, while `conversation`
permits later mail. The child remains reusable in both modes, and later
sends, human inputs and regenerated executions are separate work.

## Forks

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/forks
```

### Request

`fork: { turn_public_id, variant_public_id?, title? }`.

### Response

`201` with `{conversation, runner_effects}`, and exact receipt replay
returns `201` with the original body; `Idempotency-Replayed`
distinguishes a new child (`false`) from a replay (`true`).

The child is closure by reference, the boundary turn adopted as the
child's own editable latest message — content entry-copied onto the same
fragments, zero content bytes — with the source's view-state frozen at
the fork.

The child answers as its source does: `answering_user_public_id` is
copied, never re-derived, and the forker is never the answerer.

The access carrier forks with it: every principal's level on the child
equals its level on the source, except the forker, who becomes the
creator. `access.default` and the entries are copied at the fork instant,
the source's derived-full principals (its creator, its answerer)
materialize as `full` entries unless they are the child's own creator or
answerer, and the forker's own entry is dropped. A Human who opened a
`none` conversation reads its answerer's side of it.

A concealed target or variant answers `404`; an unsettled variant refuses
`variant_not_forkable`; oversized lineage refuses `fork_too_large`.

### Runner effects

The effect projection contains `{status, runners: […]}`. Each touched
Runner entry records `{runner_executor_public_id, run_public_id,
task_key, checkpoint?}` from its earliest claimed write strictly after
the fork point, across every candidate and concealed turn in the source
reach. Claim order determines the earliest entry separately for each
Runner, and a retry cannot replace that first write. `untouched` has an
empty array, and pruned evidence is `unavailable` with a reason. Receipt
replay returns the same projection.

Rewind composes the existing fork and task APIs. The SDK requests
`checkpoint_restore` separately on each recorded Runner using its
checkpoint and store identifier. If needed, `checkpoints` recovers
evidence by the source `run_public_id`. The result reports each Runner
independently, including unavailable checkpoints, refusal and partial
restoration. A new default Runner does not acquire another Runner's files
or checkpoint ownership.

## Side conversations

`fork: { side: true, title? }` names no turn. It inherits the live head's
settled history and takes a fixed snapshot of the persisted current turn
when that turn is running, or when its undelivered run can still recover
from a hold. A delivered reply remains settled while its background tasks
finish. `turn_public_id` and `variant_public_id` beside `side` are not
read, though the envelope digests them.

### The reference turn

The settled prefix stays linked through the ordinary closure. The current
turn becomes a child-owned reference turn at its original position, with
`reference: true`, a completed snapshot variant and no `run_public_id`.
Completed here means the reference was sealed, not that the parent's work
finished.

The snapshot includes its prompt and preface, persisted model rounds,
completed tool results, pending-work status and bound attachments.
Reasoning remains subject to the target model's ordinary replay policy.
Source completion, retry, compaction, pruning and retention cannot change
this captured material. Streaming tokens that have not landed in a
persisted model round are unavailable. A Side opened during the parent's
first turn can therefore inherit that turn's available work.

The reference turn owns no run or tasks and cannot be edited,
regenerated, activated as a replacement candidate or hard-deleted. The
parent continues independently. `forked_from_turn_public_id` names the
captured current turn; without an unsettled turn it names the newest
remaining settled turn, and vacant slots left by undo remain vacant. The
Side answers as the running or recoverable tail does, otherwise as that
remaining turn does; empty history falls back to the conversation's
default answerer.

### The boundary

The child carries `side: true` on both projections. Assembly places one
boundary after inherited history and its reference snapshot, before the
Side's own input: a user-role message reading `[The turns above are
inherited from the parent conversation as reference. Only the turns after
this point belong to this conversation.]`, emitted after the last
included inherited or reference turn.

A first-turn snapshot therefore receives the boundary even without a
settled prefix, and a window containing neither inherited nor reference
material renders no boundary. It is merged by the wire rule with the
Side's next user text.

User role, not system: the Anthropic protocol hoists every system-role
entry into the top system block, which would move the first bytes of the
request.

### What the shared prefix buys

Settled history retains its source content and order, with the captured
current work appended before the boundary. Identical emitted prefix bytes
also require the same reasoning replay and budget choices. The snapshot
stays fixed across later Side turns, and reasoning replay and
history-budget selection still follow the ordinary target-model rules.

The shared bytes are the kernel's; a provider cache hit also needs the
same tool block. OpenAI-shaped wires render the tool declarations ahead
of the messages, so a side turn that narrows `tool_names` can prevent
reuse of the parent's cached prefix. Cache reads also depend on the
provider's cache state and must be measured separately.

The instruction text a product wants — "you are in a side conversation,
answer briefly" — is the caller's own inline `tail` entry, never kernel
bytes, and the tool posture is the caller's per-turn `tool_names`
narrowing as on any turn.

### What a Side copies and refuses

The copy list is the fork's: the answerer, the default Runner preference,
the billing pair, memory pointers, store rows. `fork_created` is narrated
into the parent's stream as for any fork, and the parent's transcript is
never written.

A side is never forked again, plain or side (`422 side_of_side`). A side
cannot spawn a child, and `send`, `status` and `cancel` refuse a side
addressee with `side_conversation`. Its lifecycle is above: no archive,
DELETE reaps at once, the parent's cascade. One open side per parent and
an idle TTL are an agent's bookkeeping (rho's), not kernel
rules.

## Cumulative usage

The full conversation document always includes `usage_summary`; listing
summaries omit it. It counts recorded model attempts owned by this
conversation, independently of which turns or candidates the timeline
currently displays:

```json
{
  "usage_summary": {
    "request_count": 2,
    "input_tokens": 1200,
    "cache_read_tokens": 900,
    "uncached_input_tokens": 300,
    "cache_creation_tokens": 100,
    "cache_hit_rate": 0.75,
    "output_tokens": 200,
    "reasoning_tokens": 40,
    "total_tokens": 1400,
    "cost_amount": "0.0042",
    "cost_complete": true,
    "cost_unit": "USD"
  }
}
```

`request_count` counts immutable attempt receipts, including retries and
fallbacks. Direct replies, every regenerated candidate, compaction model
calls, and every model step in a conversation-backed run contribute.
Background work remains attributed to its original conversation after the
reply finishes, and a supplementary reply contributes its own calls to
the conversation that receives it. Stopping work, switching candidates,
undoing turns or reclaiming execution details does not subtract recorded
usage.

A spawned child, fork or side conversation counts only its own
executions. Sharing an earlier transcript or inheriting a
`billing_subject` does not copy another conversation's usage. A parent's
total excludes its child's calls, while including the parent's own calls
that read the child's result. Standalone runs and InferenceRequests are
not included through a shared billing key.

Token counters sum the quantities providers actually reported; an absent
quantity contributes zero to these cumulative counters.
`uncached_input_tokens` is input minus cached input, with cached input
capped at input for this calculation. `cache_hit_rate` uses the same
capped quantity divided by input, rounded to six decimal places, and is
absent when input is zero. Reasoning and cache counters describe parts of
the reported usage and must not be added again to `total_tokens`.

`cost_amount` is an exact decimal string containing the known monetary
subtotal, never a floating-point value. `cost_unit` is the Account's
opaque configured unit, or null when none is configured. `cost_complete`
says whether every counted billable or abandoned attempt has known money;
non-billable failures count as complete without an amount. An unpriced
success keeps it false, while an explicitly priced zero is known money.
Display an incomplete amount as a known subtotal, not a complete total.
Changing prices never reprices previous receipts. Before any receipt
exists, all counters and the amount are zero and `cost_complete` is true.

This is usage recorded so far, not a prediction of work still running.
The optional [cost limit](#cost-limits) uses this known subtotal at admission.
The separate `context` block continues to report
occupancy from the latest successful request; it is never this cumulative
total. The summary follows the conversation's ordinary member read
permissions, including read-only access and concealment, and introduces
no administrator access to conversation detail.

## Cost limits

The full Conversation document includes `cost_limit` (decimal string or null)
and `cost_limit_reached` (boolean). Basic listing summaries omit both. The
boolean is true when a limit is set and `usage_summary.cost_amount` is greater
than or equal to it. Before any receipt exists, known cost is zero.

Set the limit on create or through [Update a conversation](#update-a-conversation).
Amounts must be finite, nonnegative, below `1e20` and exactly representable with
18 decimal places. A non-null limit requires a configured Account cost unit;
invalid amounts or an unset unit return `422 validation_failed`. Zero immediately
refuses new priced attempts. Null removes the limit. A member with `full`
Conversation access and Workspace write standing may change it, including an
Agent; read-only access grants no adjustment authority.

Nexus checks the known subtotal before admitting each priced model attempt,
alongside the payer's budget. Direct replies, regeneration, retries, fallback
candidates, kernel compaction and model tasks in Conversation-backed Runs share
this check. A refusal reports `conversation_cost_limit_reached`, makes no
provider call and records no new usage receipt. It does not trigger model
fallback. Known-free and unmetered work retain their ordinary admission rules.
Unknown money remains unknown; `cost_complete` can be false even below the limit.

This is a soft limit: already admitted work may finish and record its cost.
Concurrent calls and results not yet recorded can overshoot, with no fixed
monetary overshoot bound. The limit reserves no money and does not govern a
delegated tool's external spending. It covers this Conversation's own usage;
forks, Sides and spawned Conversations start without a limit and keep independent
totals. Sharing a billing subject does not include another Conversation,
standalone Run or InferenceRequest.

For a Run, the refused task holds for repair even if its declared `on_failure`
is `absorb` or `propagate`; the declaration remains unchanged. Existing explicit
failure resolution and settled-race rules still apply. If the refusal remains
unresolved after admitted work settles, the Run reaches `needs_attention`.
Raise or clear the limit, then
explicitly [retry that task](runs.md#retry-a-failed-task). The same Run, Turn, Variant,
task key and completed results remain; completed tools are not repeated and
waiting dependents remain available. Changing the limit does not restart work.
`Resume` applies to a paused Run, and a stopped execution stays canceled.

For a direct reply, the Variant remains failed and the `turn_status` event's
`failure_reason_key` reports the refusal. After adjustment, use
[Regenerate](conversation-turns.md) to create another Variant of the same Turn.

## External ingress speakers

Conversation input create also accepts `speaker_public_id`, naming an
[ingress Speaker](ingress.md) controlled by the authenticated Agent. It
is a create-only user-role selector included in the input receipt digest.

Input and user-message turn speakers then have `{speaker_public_id, kind:
"ingress", display_name}`; member speakers retain their existing shape,
and reply turns still identify the answering Agent. The external voice is
always wrapped by the same SpeakerEnvelope in assembled seeds, history,
steers and summarizer material. `kind: "message"` records passive speech
without starting a run or model call.

## Agent removal

Removing an Agent synchronously revokes its member access and its
Agent credentials, then asynchronously force-stops related
work. This is a consequence of the existing remove operation, not a new
conversation endpoint or an Agent suspension API. The independent Runner
registration is unchanged, and its work in a stopped run receives the
ordinary cancellation.

Related work includes a conversation whose creator, default answerer,
current turn's initiator or answerer is the removed Agent, its related
spawned descendants, and still-live historical or background runs using
that Agent. Historical participation alone does not stop another Agent's
unrelated current turn, and a fork's shared prefix does not create a stop
relationship. The stop uses the existing force-stop behavior; it does not
delete transcript or previously accepted results, and late results cannot
overwrite canceled terminal tasks.

The response guarantees the access cut, not an already-terminal
conversation or task. Status can lag, and tasks may instead reach their
ordinary deadlines. An after-commit wake starts cleanup, and a bounded
recurring scan recovers lost wakes, including for paused work whose
ordinary clock is frozen. Cleanup checks that the Agent is currently
removed; after restore it skips that Agent, so an old cleanup wake does
not stop new work admitted after restore. Restore does not wait for
cleanup or revive old credentials or stopped work. There is no durable
removal episode or promise to withdraw every old delivery across an
intervening restore. A fresh DeviceFlow connection reuses the retained
Agent address with new credentials.

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | A read, an update, or a replaced carrier or default Runner. |
| `201 Created` | — | A conversation or a fork, new or replayed. |
| `204 No Content` | — | A tombstone. |
| `400 Bad Request` | `parameter_invalid` | A cursor for another key shape or direction, or an unknown ordering value. |
| `403 Forbidden` | `not_authorized` | A write at `read` level, including a carrier change by a `read` principal. |
| `404 Not Found` | `not_found` | The workspace or conversation is not visible, is concealed, or is tombstoned. |
| `404 Not Found` | `runner_not_found` | The named default Runner does not exist. |
| `409 Conflict` | `idempotency_envelope_mismatch` | The key was used with a different request, entry order included. |
| `409 Conflict` | `conversation_archived` | A write to the bin. |
| `409 Conflict` | `conversation_busy` | A delete while live work runs anywhere in the tree. |
| `409 Conflict` | `subagent_follows_parent` | An archive, unarchive or delete aimed at a subagent; the parent's verb stamps it. |
| `409 Conflict` | `runner_not_eligible` | The named Runner is not live or not eligible for the answerer. |
| `422 Unprocessable Content` | `answerer_not_eligible` | The named answerer may not answer here. |
| `422 Unprocessable Content` | `principal_not_eligible` | An access entry names a principal it may not. |
| `422 Unprocessable Content` | `side_conversation` | An archive or unarchive of a side. |
| `422 Unprocessable Content` | `side_of_side` | A fork of a side. |
| `422 Unprocessable Content` | `variant_not_forkable` | The fork target variant has not settled. |
| `422 Unprocessable Content` | `fork_too_large` | The lineage is oversized. |
| `422 Unprocessable Content` | `validation_failed` | An unknown level or default, or another malformed field. |
