---
title: Conversation turns
description: Reading the timeline and one turn, following a candidate, the tail content verbs — edit, regenerate, activate — undo, stop, and view state.
---

# Conversation turns

A turn is one position in a conversation's timeline. Under it sits a deck
of candidates (variants); the active one is what the conversation
displays. Every content verb aims at the tail: the frozen prefix answers
`branch_required`, and a turn still referenced by a descendant's closure
is frozen too, even with no local successor. Rewrite history by forking
and editing ([Conversations](conversations.md)).

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{public_id}
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/edit
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/regeneration
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/regeneration_receipt?idempotency_key={key}
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{variant_public_id}/activation
PATCH  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{public_id}
GET    /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{input_public_id}/materialization
POST   /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/cancellation
```

## Read the timeline

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns?limit=&after_position=&before_position=&include_hidden=
```

### Response

The merged timeline, inherited prefix entries included and marked
`inherited: true`. Each entry carries its active variant's model identity,
preview and rendered content, and on a reply turn `prompt_text` — the
person's words that opened it, the seed's readable text and the same words
the sealed request carries. `prompt_text` is absent on a `message` turn,
whose `content` is the person's words, and on a seed carrying no text, a
picture alone. A history reader can therefore say what was said without a
second read.

Every turn names **who answered** and **who spoke**.
`answering_user_public_id` is the addressee of a reply, the conversation's
answerer on a message, or the kernel's summary. `speaker: {user_public_id,
handle, kind, display_name}` is a message turn's speaker or a reply turn's
answerer — the agent whose engine wrote it — and is absent on the kernel's
summary, which names no principal. Every input carries the same two, its
addressee and its author, so a follower can read which agent's turn is
running and which agent each earlier turn was.

A run-backed variant (`source: "run"`) also carries `run_public_id`, the
feed's correlation key, and `rounds`: the run's newest mainline rounds as
the run transcript's rows without their calls (`task_key`, `status`,
`text_preview`, `usage`, and by presence the compaction cut,
`compacted_before` or `pruned_before`). Never an edge, a join or a
mainline mark — a turn shows rounds, not a graph. Both keys are additive,
absent on every other source and read by presence; the run's own
transcript route is the paginated window when a page's rounds are not
enough.

A run-backed variant also carries `runner_effects`: an aggregate `status`
and a `runners` array with one earliest claimed write per Runner. Each
entry retains its Runner UUID, source Run UUID, task key and optional
checkpoint. Missing checkpoint evidence is distinct from an untouched
Runner, and pruned details yield `unavailable`. The reader evaluates
restore support for each recorded Runner independently.

### Hidden turns

The default window excludes hidden turns, while `excluded_from_context`
rows appear here and never in assembly. `include_hidden=true` explicitly
includes hidden turns for management and execution recovery, with their
original `visibility` and the same position pagination — which discovers a
hidden held execution even after its `active_turn_public_id` clears.

The option uses the same conversation access rules and inherited view
overrides, and concealed turns remain absent. It changes neither context
assembly nor transcript streaming, and clients must still respect each
turn's visibility when displaying content. The Ruby SDK exposes it as
`conversation.turns.list(include_hidden: true)`.

## Read one turn

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{public_id}?include_hidden=
```

### Response

`{turn: …}` under the same canonical projection and effective visibility
as the window, resolving reachable inherited turns through the fork's view
overrides. An unknown, concealed or normally hidden turn is `404
not_found`; `include_hidden=true` includes hidden turns but never
concealed ones. The Ruby SDK exposes this as
`conversation.turns.fetch(public_id, include_hidden: true)`, and recovery
with a saved turn UUID needs one point read, without searching history
pages.

Displayable reasoning for a completed candidate is available through the
[stored reasoning window](conversation-reasoning.md), which pages that
candidate's model tasks without adding their reasoning bodies to this
response.

## Following one candidate

Both the point and window reads include an optional `running_variant` when
a pending or running regeneration differs from the displayed
`active_variant`. It uses the full variant projection with `active:
false`, including its own run UUID and Runner effect facts. If the active
candidate itself is running, only `active_variant` is returned. A client
following a particular accepted input or regeneration must retain its
variant UUID rather than switch to whichever candidate currently runs or
displays.

Variants derived from another candidate also expose
`origin_variant_public_id`. An automatic model fallback has `source:
"fallback"` and points to the candidate it continues. A follower of an
accepted input may follow that exact fallback chain, including after event
expiry; manual edits and regenerations are separate requests and must not
replace the accepted input's result. The materialization read keeps
identifying the original candidate throughout.

Every variant carries `memory_context`, the bindings frozen for that
execution, on the timeline, the variant deck and content-verb responses
alike. It is independent of the conversation's current `memory_context`.
The key is always present: `null` selects the default roots, while
`{"bindings": []}` explicitly disables memory. Regeneration retains the
source variant's value.

## Read one candidate

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/variants/{public_id}
```

### Request

Use the saved turn and variant UUIDs, including those in a schedule execution or
callback source. This read has no `include_hidden` option.

### Response

`{variant: ..., turn: {public_id, inherited}}`. The variant uses the same body,
status, model, memory context, and provenance projection as the deck. It remains
the requested candidate when another candidate becomes active. Inherited turns
resolve through the requested conversation's effective view and overrides.

A readable candidate remains available after Run detail retention. Run fields,
rounds, and Runner effects appear only when the caller can currently read the
source Run; reading the candidate does not grant access to that Run.

### Status codes

`200` returns the requested candidate. An unreadable conversation, hidden or
concealed turn, concealed or missing candidate, or a candidate under another
turn returns `404 not_found`. A deleted source remains unavailable.

## Source stamps and callback provenance

`sender_conversation_public_id`, `sender_run_public_id` and
`sender_task_key` are durable turn fields, present when recorded on the
input. They identify the sending conversation, source execution and source
task independently of the receiving turn's `run_public_id`, and remain
available after input consumption and event retention, so a follower can
correlate a callback with the original execution without reconstructing it
from retained feed events.

`input_public_id` retains the accepted input's UUID after consumption. A
worker final receipt exposes a nullable `callback_result` with the UUID
fields `conversation_public_id`, `input_public_id`, `turn_public_id`,
`variant_public_id` and `requester_speaker_public_id`. They name the
independent worker's exact formal result and original requester, and later
manual regeneration does not retarget this pointer. An unknown requester
is `null`, which prevents cross-source batching while preserving the exact
worker result. These are kernel-written read projections, not input
creation fields.

Materialized worker callbacks retain `callback_sources`, an immutable
array of objects with the callback receipt's `input_public_id`, `origin`,
`sender_conversation_public_id`, `sender_run_public_id`, `sender_task_key`
and `result` (the `callback_result` object above). A single worker receipt
retains one element. The combined reply retains all consumed sources and
has no singular sender ownership, while earlier receipt message turns keep
their own source. Ordinary turns expose an empty array. This records
provenance without creating a result resource, a batch group or a new task
identity. Consumers read the fixed variant through the existing worker
conversation's variant API under its current access rules, and must not
substitute that turn's current active variant.

An adopted fork boundary is a new turn without input consumption: it keeps
its existing fork and source references, without `input_public_id` and
with an empty `callback_sources`. It must not masquerade as another
materialization of the original input. Inherited prefix turns retain their
original projections.

## Recover an accepted input

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs/{input_public_id}/materialization?include_hidden=
```

### Response

```json
{
  "materialization": {
    "input_public_id": "<accepted input UUID>",
    "turn_public_id": "<original turn UUID>",
    "variant_public_id": "<original candidate UUID>",
    "run_public_id": null
  }
}
```

The run UUID is present as a string for a run-backed original; it is null
for a message or direct inference, and after the original run is removed.
The read derives the original identity from the retained turn and its
first candidate, so it survives waiting-room consumption and event
retention without adding a receipt lifecycle, and it never substitutes an
edit or regeneration.

The same conversation access, inherited reach, concealment and
hidden-turn rules apply as on the point read. A pending input, a steer
consumed into an existing model round, a deleted turn, or a concealed
original candidate has no readable materialization and returns `404
not_found`. A fork's adopted boundary has no new input identity, and
inherited prefix entries remain readable. The Ruby SDK's
`conversation.inputs.materialization(input_public_id)` returns this
projection or nil on `404`, and propagates other errors. This read belongs
to conversation inputs; standalone run inputs have no turn
materialization.

## The shape every content verb answers

Every verb below answers the variant block in one shape, the deck's and
the turns page's: `prompt_text` (a reply turn's seed words) and
`attachments` ride it by presence, as on the turns page.

## Edit

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/edit
```

### Request

`edit: { text }`, or raw `entries`.

### Response

The content becomes a new activated candidate (`source: "edit"`), never a
patch. It works on both kinds: fix your message, or hand-override the
assistant's answer. On a reply turn the candidate carries the turn's seed,
so its answer names `prompt_text`; on a message turn there is none.

An edit on a hold-settled run-backed tail is the person answering for the
run: the run's adjudication verbs (`retry`, `abandon`, the repairing
append) then refuse `not_adjudicable`, and no later run status flips the
turn behind the edit.

## Regenerate

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/regeneration
```

### Request

`Idempotency-Key` is required; the body's `regeneration: { model,
configuration, agent_configuration, model_selection, fallback_models }` is optional. The nested model may supply only
`reasoning_enabled` or `reasoning_effort` to change that control on the
current model. Omitted or `null` controls preserve the current selection
when the model stays the same; another model uses its own defaults.

### Response

`202`. A compatible sealed request is re-asked for a new sample, which
lands as a sibling beside the original; a caller-supplied model re-asks
elsewhere. The `202` carries no `content` yet, but the turn's seed is
cloned onto the newborn candidate, so `prompt_text` rides it by presence.

The turn reopens to `running` and the old candidate keeps rendering until
the new one completes: a completed sample becomes the rendered one, while
a canceled or terminally failed sample sits in the deck and the turn
returns to `completed`. A run held at `needs_attention` instead activates
its failed candidate and leaves the turn `failed`, retaining its
adjudication and same-turn retry and reopen behavior.

### The receipt

The key is scoped to the caller, conversation and regeneration operation
for 24 hours. Retrying the same key and envelope, including the target
turn, replays the original `202` body with `Idempotency-Replayed: true`,
even after the candidate has completed. A changed turn, model or
configuration with that key is `409 idempotency_envelope_mismatch`: use a
new key to request a new candidate. The receipt preserves acceptance, not
current execution status — read the turn or its variant for current state.

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/regeneration_receipt?idempotency_key={key}
```

returns that caller's retained acceptance as `200`, or `404` when no
retained receipt is visible. It is read-only and does not validate a new
envelope. An application that performs work before regeneration can check
this receipt before repeating that work, then POST the original key and
envelope to validate and replay. Treat other lookup failures as an unknown
outcome. The receipt makes the Nexus command atomic; it does not transact
an external file restore with that command.

### What is re-asked, and what is rebuilt

Changing the model, disabling reasoning, or a default-replay downgrade on
native-bearing content requires rebuilding, as does an active candidate
without a sealed request — a fork-adopted or edited turn.

An assembled prompt uses the current context strictly below the turn, then
the turn's sealed preface — the per-turn text its request carried behind
history, laid verbatim and never re-rendered, a lead the turn relied on
the window for laid when this window no longer carries it — then appends
the turn's original prompt with its speaker and attachments. The new
candidate keeps the preface its request laid, as an entry-copied request
already carries it.

A raw prompt instead restores its original messages, roles, order and
upload occurrences, without adding history, templates or speaker
envelopes. The input mode stays with the prompt across regeneration, edits
and forks, independently of later profile changes. A target unable to
accept a raw attachment refuses regeneration; raw content is never
replaced with an attachment placeholder. Native reasoning tagged with its
producing model keeps the usual wire compatibility rules: portable text
may cross models, but foreign signatures and encrypted material do not.
Untagged native payloads supplied by a raw caller remain that caller's
responsibility.

### Configuration

Omitted or `null` `configuration` reuses the original candidate's
generation configuration when it has one. An inference candidate inherits
its original request's resolved parameters on the same model; on another
model it inherits only what its caller chose — every sealed value that
differs from the old model's catalog default — and the new model's
defaults for the rest. That is the same reading the kernel's own
`fallback` candidate takes, because the old model's defaults would refuse
every model whose parameter vocabulary differs.

A run-backed candidate inherits its seed's submitted configuration, with
unspecified parameters taking current catalog defaults. A supplied object
replaces the entire configuration, and `{}` selects the chosen model's
current defaults. On another model the original's reasoning controls are
not carried, so the new model resolves at its own enablement and effort
defaults unless `model` supplies either control. The chosen model
validates the configuration before accepting regeneration, including
inherited parameters when switching models.

Original raw `instructions` remain separate from those generation
parameters and are retained when the candidate has its own execution
record. Edited and fork-adopted candidates do not recover configuration
from older executions. The turn's own answer never rides its
regeneration.

### Captured execution configuration

Omitted or null `agent_configuration` reuses the origin candidate's
captured declaration. A supplied object replaces it whole for the new
candidate, using the [inline declaration grammar](profile-configuration.md#inline-agent-configuration).
It is distinct from the provider parameters in `configuration`.

An omitted `model_selection` retains the origin's intent on the same
model. If the request changes the initial model, omission creates default
intent for that new route; send explicit intent to preserve a user's
constraint. An omitted `fallback_models` retains the origin's captured
list, except that a supplied declaration supplies its own list. A top-level
array replaces that list whole, including `[]` to disable fallback.
These authored fields participate in the regeneration idempotency envelope.

### A run-backed turn

`direct_reply` turns regenerate as themselves; another kind is
`unsupported_turn_type`. A run-backed turn regenerates as a new candidate
with its own run (`source: "run"`, the answer carrying its
`run_public_id`): the origin run's seed round is re-asked — its sealed
input entry-copied when compatible, else rebuilt using the prompt's
original raw or assembled mode — under the origin run's own approval
freeze, and the old candidate keeps its run, rounds and picture.

Successful regeneration permanently stops that old execution and its
undelivered derived work; a refused regeneration leaves the source
unchanged. Reassembly uses the original seed's tool set for its skill
catalog, even when the profile's declaration has since changed. An edited
or fork-adopted candidate regenerates without tools or their skill
catalog, retaining the original prompt, its preface and its mode but not
the old execution's parameters or instructions. The new running
candidate's approvals remain decidable while the old completed answer is
displayed.

While the origin's run is `needs_attention` the door refuses
`run_needs_attention`: adjudicate it first. The kernel judges nothing
about the Runner environments the origin's run changed — the variant's
`runner_effects` says what happened, and whether to restore it first is
the caller's (the SDK's `rewind`, rho's `regenerate`).

## Activate another candidate

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/variants/{variant_public_id}/activation
```

### Response

The swipe switch: point the tail turn at another settled candidate. An
unsettled target is `variant_not_active`, and re-activating the active one
is an event-free no-op. The answer is the candidate's own block,
`prompt_text` included on a reply turn. Selecting a completed candidate
also leaves the turn `completed`, including when the previously selected
candidate was failed.

Changed activation permanently stops the replaced candidate's unfinished
work and undelivered derived requests and results. Selecting an old
candidate never revives canceled work. Reading a candidate or
re-activating the active one has no stop effect.

### What an edit or activation narrates

An edit or a changed activation emits `turn_variant` followed by
`turn_status` in the same transaction, and publishes the selected sealed
turn on the transcript stream after commit
([Conversation feeds](conversation-feeds.md)). Both durable events
identify the turn and candidate; a run-backed selection also names its
`run_public_id`. The status item describes the turn, without replacing the
run's own status. A reader can recover the selected body from the variants
list and that run's current tasks and attention from its trace.

## The kernel's own fallback candidate

A tool-less reply can advance through its captured ordered fallback list
under the shared [model recovery rules](models.md#model-selection-and-recovery).
A classifier refusal or exhausted retryable provider failure can trigger
the next permitted candidate. The kernel does not reread the profile's
current list. A content block or a terminal request error does not switch.

The re-ask is a `source: "fallback"` candidate beside the failed one, with
`origin_variant_public_id` linking its origin. It uses the original
poster's identity, the caller's generation parameters and the new model's
defaults for unspecified controls. The captured declaration, initial intent
and remaining recovery chain stay with it.

The turn remains `running` through a switch. The failed candidate stays in
the deck; a completed fallback becomes the rendered answer. The existing
turn events report the switch and any `model_skips`. Every attempted route
stays spent, including across further fallback candidates or a restart.
If no permitted available candidate remains, the failure stands. Foreign
tool history and attachment incompatibilities retain their ordinary
validation rather than silently changing the input.

Result mail is run-backed and uses its source execution's captured list;
it has no separate current-default fallback.

## Provider generation errors

A provider generation error (`finish_quality: error`) fails the
direct-reply candidate with `failure_reason_key: provider_error`. The turn
settles as a failed candidate does, and a failed regeneration does not
replace an already completed answer. The completed exchange retains its
reported usage, but partial answer text, reasoning and tool calls are
discarded. This finish triggers no automatic retry or fallback. If public
output already streamed, `stream_reset` with `reason: failed` withdraws
it.

## Undo the tail turn

### Endpoint

```http
DELETE /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{public_id}
```

### Response

`204`. The apex — and only the apex — physically removes; mid-history
conceals instead (`apex_only`). The vacated slot never refills.

Live work ends first (`not_terminal`). A fork still reading the row
refuses, naming the pinning conversation (`descendant_pinned`). Held
steering mail refuses rather than dying silently (`steering_holds`):
cancel the steer, then delete. An original child turn still owing a
turn-owned delegation report refuses `delegation_pending` until relay
preserves the report on its parent's completion task; concealment does not
discard that original execution or retarget its report. A turn whose run
is still live refuses `run_live` — stop it first; a deletable turn
tombstones its runs before the row goes.

## Stop the conversation

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/cancellation
```

### Response

`202` when a source cut or active cancellation is accepted, and `409
not_running` when nothing remains to cut. It stops all existing execution
owners in the addressed conversation: earlier turns' background work,
completed sources with unconsumed results, and the current reply or
regeneration. The source cut is permanent, a later user input starts new
work normally, and ordinary queued user inputs are retained.

The running invocation terminalizes as canceled and convergence settles
the timeline. A regeneration's completed original keeps the pointer. A
declined or overloaded sample that has not yet settled settles as failed
without a fallback: Stop wins over the switch. A run-backed running reply
drains to canceled, and a hold-settled tail's run is stoppable while its
settled variant stays readable. Stopping a completed source does not
rewrite its delivered body or status.

Derived cancellation follows the immutable sender run and task of each
child request and supplementary reply, recursively. It removes pending
derived inputs and stops already-started undelivered replies, including
their background work. The same rule excludes an already-consumed combined
worker report: that reply belongs to the receiving conversation, whose own
Stop still cancels it. The same reusable child conversation may contain a
later independent request, and that request is not canceled just because
its room was originally spawned by a stopped run. A child Stop does not
stop its parent.

Full access on the addressed conversation is required; cancellation of its
derived work neither rechecks the caller against child access settings nor
grants access to child content. Cancel also works in the bin. Already
published replies and external tool effects are not undone.

## View state

### Endpoint

```http
PATCH /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{public_id}
```

### Request

`turn: { visibility?, concealed? }`.

### Response

This is the one view-state writer over both sides of the fork boundary: a
local turn's own columns, or — for an inherited prefix row — the child's
override row. The shared row is never touched and every other descendant
is unaffected.

The tail-only constraint has specific error codes: the apex never conceals
unless a descendant's pin already refuses its hard delete
(`apex_never_conceals`), only terminal rows conceal (`not_terminal`), and
restore lands only where the row would again be the tail
(`branch_required`; chains restore bottom-up).

## The deck

```http
GET   /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/variants
PATCH /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/variants/{public_id}
```

The list reads a reachable turn's live deck with `active` flagged, each
row the variant block as the turns page renders it — `prompt_text` (a
reply turn's seed words) and `attachments` by presence.

`PATCH …/variants/{public_id}` with `variant: { concealed: }` conceals or
restores a local turn's candidate. The active candidate refuses
(`variant_active`: activate another first), and a restore whose freed slot
was retaken refuses honestly (`slot_occupied`).

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The timeline, a turn, the deck, a content verb's candidate, or a retained regeneration receipt. |
| `202 Accepted` | — | A regeneration was accepted, or a cancellation was. |
| `204 No Content` | — | The tail turn was deleted. |
| `403 Forbidden` | `not_authorized` | A write without write standing, or a cancellation without full access. |
| `404 Not Found` | `not_found` | An unknown, concealed or normally hidden turn, an unreadable materialization, or no retained receipt for that key. |
| `409 Conflict` | `branch_required` | The target is not the tail, or a restore would not land on the tail. |
| `409 Conflict` | `apex_only` | A hard delete of a mid-history turn; conceal it instead. |
| `409 Conflict` | `apex_never_conceals` | Concealing the apex, which is not pinned by a descendant. |
| `409 Conflict` | `not_terminal` | Live work on the turn, or a conceal of a nonterminal row. |
| `409 Conflict` | `run_live` | The turn's run is still live; stop it first. |
| `409 Conflict` | `descendant_pinned` | A fork still reads the row; the message names the pinning conversation. |
| `409 Conflict` | `steering_holds` | Held steering mail aims at the turn; cancel the steer first. |
| `409 Conflict` | `delegation_pending` | An original child turn still owes a turn-owned delegation report. |
| `409 Conflict` | `run_needs_attention` | The origin's run is held; adjudicate it first. |
| `409 Conflict` | `variant_not_active` | The activation target has not settled. |
| `409 Conflict` | `variant_active` | A conceal of the active candidate; activate another first. |
| `409 Conflict` | `slot_occupied` | A restore whose freed slot was retaken. |
| `409 Conflict` | `unsupported_turn_type` | A regeneration of a turn that is not a `direct_reply`. |
| `409 Conflict` | `idempotency_envelope_mismatch` | The key was used with a different turn, model or configuration. |
| `409 Conflict` | `conversation_archived` | A content verb on an archived conversation. |
| `409 Conflict` | `not_running` | A cancellation with nothing left to cut. |
| `422 Unprocessable Content` | `validation_failed` | A malformed body, or a configuration the chosen model refuses. |
| `422 Unprocessable Content` | `agent_configuration_invalid`, `model_selection_invalid`, `fallback_models_invalid` | Regeneration received an agent configuration, model intent or ordered fallback list outside its grammar. |

Authoring also accepts `executor_contexts`; see [captured executor context](run-steps.md#captured-executor-context) for its shape and inheritance rules.
