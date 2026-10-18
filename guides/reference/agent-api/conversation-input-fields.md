---
title: Conversation input fields
description: "Every field an input carries: its kind and steps, the model and addressee, delivery and scheduling, the context and tool fields, inline text, history and variables."
---

# Conversation input fields

What a caller may put in the `input` envelope, field by field. The door
itself, its receipt and the queue it lands in are on
[Conversation inputs](conversation-inputs.md); every refusal named here is
in that page's [status codes](conversation-inputs.md#status-codes).

## Attachments

An input may carry `attachments: [upload_public_id, …]` beside its
`text`: ids of the caller's own staged uploads (`POST
/agent_api/v1/uploads`, creator-scoped). An unknown, another creator's or
a fileless id refuses `422 unknown_input_upload`, whole or nothing; a
malformed id is `400 parameter_invalid` at the boundary.

The door composes one message entry — the words, then the attachments in
the order given — and binds the uploads for liveness, so a bound upload is
never reaped. A file with no words is a message (`text` reads `""`).

A steer takes none: `attachments` beside `delivery_mode: steer|steer_now`
refuses `422 attachments_not_steerable`, and rho's `--attach` implies
`--mode queue`. `attachments` never ride beside raw `entries` (`400
parameter_invalid`): the raw grammar places its own `{"type": "upload"}`
parts, and the door binds what those placed. The set is in the
idempotency envelope, so a replay naming another set is a mismatch. The
row shows its files as `attachments: [{public_id, filename, content_type,
byte_size}]` in part order — the row's fact, whatever the answerer reads.

### What the model reads

It is decided per part, per turn, at assembly against the turn's resolved
engine. A row whose `capabilities.input_modalities` includes `image`, and
whose wire takes the type, receives the picture natively: the sealed
request carries the `upload` part and binds the row. Any other engine
reads, in the picture's position, one text part — `[Attachment:
diagram.png (image/png, 184,213 bytes) — image content omitted: this
model does not support image input]`, or `— this model does not take
image/heic` when the row takes images but the wire refuses the type — and
the sealed request binds nothing.

The picture survives on the reply turn's kept prompt either way, so a
later turn under a vision engine reads it natively and under a text
engine reads the line: a later turn sees the attachment in history. A
native picture is funded in the history budget at the wire's declared
per-image cost, 0 where the wire declares none; the byte wall counts
words only.

Images and PDFs may be carried natively. A PDF needs the selected model's
`file` input modality and `application/pdf` in its wire's allowed types.
Unsupported PDFs and other files (Office, text, code and archives) are
indexed with filename, detected type, size and a
`nexus://uploads/<public_id>` reference. Executors can import those bytes
through their active claim's
[attachment resources](executor-inbox.md#read-bound-attachments), then
parse or inspect them with their workspace tools. Nexus does not execute
or parse arbitrary documents. Native PDFs carry their original bytes,
with no text extraction or page rendering, under the existing inline
media bound.

PDFs follow the same per-turn placement and retained-history rules. A
model without native PDF input reads the tool reference in the PDF's
position, and switching back to a document-capable model restores native
carriage from the retained prompt. Planning uses the wire's declared
per-file token estimate, or zero when none is known; this is not a claim
that reading a PDF is free. Actual usage comes from the provider's
receipt.

### After a summary

A compaction summary reads an attachment as a pointer in its position —
`[Attachment: diagram.png (image/png, 184,213 bytes) — not carried past
the summary; ask for it again if needed]`, the index line's grammar with
the summary's reason, and PDF pointers also retain their
`nexus://uploads/<public_id>` reference. The summarizer is told to name
it, never to describe what it showed; after the cut the picture leaves
the wire with the turns the summary replaced.

### Reading the bytes back

`GET /agent_api/v1/uploads/{public_id}/bytes` serves any reader of the
conversation ([Uploads](uploads.md): one rule for every upload a row
names — a tool result's capture reads the same way), and a picture of it
for a UI comes from the two named reads beside it, `…/thumbnail` and
`…/preview` (presets named in code; an upload with no representation of
that kind is `404 representation_unavailable`). Every one of the three
carries a strong `ETag` and answers `If-None-Match` with `304`. A
narrowing to `none` closes those reads with the rest.

The SDK spells the field `inputs.create(attachments: [...])` — ids or the
`Upload` values `uploads.create` answered, `update` the same, `[]` to
unbind — and reads the row's files back as `UploadRef`s. `rho run
--attach PATH`, and rho-dev's `rho do/say --attach`, posts the path to the
daemon, which stages the bytes on its member plane as rho's own user and
binds the ids.

## The fields

### kind

`message` (content, born completed at materialization) or `direct_reply`
(asks the kernel for an assistant reply).

### steps

Optional authored trailing work, using the
[Run append grammar](runs.md). Only a conversation's queued
`direct_reply` admits this field; `message`, `steer` and standalone-run
inputs refuse it with `422 validation_failed`. The stored array is
bounded to 1 MiB of canonical JSON (`413 content_too_large`), and a
non-array is `422 validation_failed`. Omission or null stores no steps,
and `[]` also schedules no trailing work. Queue projections include a
supplied array, including `[]`, and omit null.

At the input's original materialization, Nexus creates the usual first
model task (`r1`) and invokes ordinary authored append with these steps,
all in the same transaction before execution can start. The input author
remains the author of this work (`authored_by: author`); the answerer's
tool declarations, hooks, selected model and approval rules keep their
existing owners. Existing compilation and graph guards apply, including
`tip_live` for a step that reads the live mainline. Runner targets and
referenced uploads are checked and bound at materialization, so queued
steps do not retain staged uploads or freeze the current default Runner.
A refusal rolls back the candidate turn, run and all appended work, then
leaves the input `blocked` with the append's reason for correction or
deletion.

The input's `public_id` is this append's idempotency key. An authorized
writer can call the existing run append door with that key and the
identical steps to obtain the ordinary receipt, including authored Ask
resolution tokens. The existing run append eligibility and
receipt-retention rules still apply; this creates no token-bearing GET or
materialization response. Regeneration rebuilds its model seed without
replaying these steps, and later inputs inherit none. Inputs without
steps create no additional task.

### model

The reference and the independent `reasoning_enabled` and
`reasoning_effort` controls described in
[Models](models.md#reasoning-selection). Queued inputs retain the
caller's intent; the reply variant reports the resolved selection,
including an effective enabled switch when its model cannot honor a
request to disable reasoning.

### agent_configuration

Optional complete, identity-free execution configuration, including tools,
approval, prompt assembly, prompt documents, memory limits and model
defaults. The [declaration reference](profile-configuration.md#inline-agent-configuration)
owns its fields and validation. It is separate from `configuration`, which
contains provider generation parameters.

Input admission captures the authored object. Materialization assembles and
freezes the runtime authority from it. Omitting it uses the answering
User's standing declaration at materialization, then freezes that result.
A supplied object replaces the declaration whole, including on an input
update; omission or null on update preserves the queued declaration.

### model_selection and fallback_models

`model_selection` records selection intent as
`{source, model, constraint, alternatives}`. `fallback_models` is a complete
ordered array of recovery routes; omission or null inherits the selected
declaration's list and `[]` disables automatic fallback. A queued update
with either field omitted or null retains its existing value. An explicit
array replaces the list whole.

The accepted execution freezes the effective selection and candidates.
A model argument by itself does not establish an explicit Human choice.
See [Model selection and recovery](models.md#model-selection-and-recovery)
for the grammar, availability skips, same-model identity and bounded retries.

### answering_user_public_id

Who answers this turn. The create door's word is an address — `@handle`
or a public id, resolved at the door within the account. The SDK spells
it `to:` and rho `--to`; the `send` tool spells it `agent`, because on
every model-facing tool `to` is a conversation and `agent` a principal.
Absent is the conversation's stored answerer, and a Human's plain chat is
answered by the Human.

The named profile must be a member that may answer here: an agent of the
account that may write in the workspace, holding `full` on this
conversation — `read` cannot post, so it cannot answer. A name that is
nobody's is `422 principal_unknown`; a Human, the system user, a
`read`-level or fenced profile is `422 answerer_not_eligible`. The
kernel's own mail carries its mailing run's answerer on the same field
and is never judged.

It is frozen on the row and on the reply turn it opens
(`answering_user_public_id` on both, in `input_accepted` and
`turn_created`): the addressee's engine, tools, `approval_mode` word and
`system_prompt` answer that turn, and its `tool_names` and
`approval_mode` are judged against the addressee's declaration. It is
create-only — the edit surface drops it — and in the idempotency envelope,
so a replay naming another addressee is `idempotency_envelope_mismatch`.
The run door refuses it by name.

**The addressee's engine** is the agent's own preset first, else the
initiator's. A reply row addressed away from the conversation's stored
answerer, and every row a peer sent (an agent's `send`, the spawn brief),
runs on the engine that answers for that addressee, in one order: the
addressee's own `default_model` ([Profile](profile.md), at the model's
own reasoning defaults), else the addressee's last reply turn's model
selection in this conversation, else the conversation's last reply turn's,
else the row's own `model`. On a `send` or a brief that last one is the
initiator's: the call's `model` when it named one, else the round it ran
in ([Runs](runs.md)). The kernel stores the fact and carries the
initiator's model; it chooses nothing.

The conversation's own rows posted as itself — the person's `model` on a
1:1 lane, the user's own choice — and the kernel's mail keep the model
they name. A `send`'s `agent`, when named, is the addressee, else the
conversation's answerer: the addressee's conversation, the addressee's
engine. The model an addressed turn runs on is readable on its run's
`turn.model` ([Runs](runs.md)) and on the turn's
`active_variant.model`.

**The wake rule of a group** falls out of this one column. The idle unit
is the conversation — one active turn per conversation, the queue read in
order — and an agent is addressed, never woken: a `to: B` while A's turn
runs queues and opens B's turn at A's boundary, an unaddressed word wakes
the default answerer alone, and the kernel never fans out (a product that
wants N answers posts N addressed rows). The conversation's default
Runner preference, its default Runner selection, its `memory_principal`
and the inbox's scope stamp stay the host's — the default answerer's and
the poster's Human. A group's environment is the conversation's, not each
agent's.

### delivery_mode

`queue` (the default: an idle recipient begins immediately, a busy one at
the next turn boundary, and what the kernel's own mail always is), `steer`
(bind to the in-flight reply at the next model boundary), or `steer_now`
(also advance past a waiting tool fan immediately, with truthful
pending-call receipts).

Under `steer_now` the tools continue under their original execution
ownership, and their actual results are consumed once when available. The
original continuation still joins the tools and any inserted work before
final delivery. An already-sent model request stays immutable.

For either steering mode, a principal's input steers — a person's, or an
agent's `send` with a steering mode — never the kernel's mail. A steer is
a redirect, so it needs something to redirect: with a reply in flight the
row is held `steering` against that turn; with the lane idle there is
nothing to redirect and the row simply queues (`pending`). The words are
still worth delivering, and the state tells the sender which it got.

Only a `direct_reply` turn binds a steer — a message or a summary turn
has no request to land in — and only one answered by the row's addressee.
An unnamed steer addresses the running reply's answerer, so the
correction reaches the agent actually running and never the default past
it. A named `to` that differs from the running answerer queues for its own
turn (`pending`, no binding): nothing corrupts, so there is no refusal.

**Pinning a steer.** An optional `expected_steering_run_public_id` pins a
conversation steer to one run execution. The door compares it with the
reply's running candidate under the conversation and run locks. An idle
room, another addressee, a different candidate, a tool-less reply, or a
run that has already delivered, stopped or begun canceling refuses `409
steering_target_changed`; it never queues instead. The selector is a
canonicalized UUID (`400 parameter_invalid` when malformed), requires
`delivery_mode: steer|steer_now` (`422 steering_guard_requires_steer`),
and is not admitted on the standalone run door. It is fixed on the
accepted input and included in its idempotency envelope, and exact
receipt replay still returns the original acceptance after the execution
ends. If the target ends before consuming the correction, that input is
canceled with the existing `input_deleted{steer_canceled: true}` event. The
acceptance and deletion events carry the fixed target as
`expected_steering_run_public_id`; see [Conversation feeds](conversation-feeds.md).
It
never reaches a replacement execution or a later turn, and it grants the
caller no authority.

**Without that selector**, when the bound turn settles — completed,
failed or canceled alike — the binding is over and the row falls back to
the queue, narrated `input_edited{state: pending, reason:
steer_target_settled}`, releasing the caller's bound. A steer no longer
sits `steering` forever waiting on a reply that already ended. This also
covers inputs accepted after the run finishes but before its turn status
converges, and replies delivered while their background work continues. A
previous candidate's background completion does not release steers for a
running regeneration.

**One exception, on a run-backed turn.** A hold — the turn `failed`
because its run is `needs_attention` — keeps steers bound, since a retry
or an answer reopens that same turn and the steer lands with it. The same
hold gates the queue: a queued row that predates it waits, narrated once
as `input_blocked{blocked_reason: run_held}` with no state written. Only
a caller-authored input typed after the hold and addressed to the held
answerer materializes behind it — it is the person's answer, and it opens
the next turn. A post-hold row addressed to another agent waits like a
pre-hold one, because opening that agent's turn would replace, and so
kill, the repairable run. The gate is judged per row in read order, so a
held kernel receipt at the head never keeps that answer from reaching it;
the one `run_held` item names the first row in read order, whichever it
is, and the receipt drains once the repaired turn stands.

### deliver_at and deliver_in

Not before this time. Exactly one: `deliver_at` an ISO 8601 time with an
offset or `Z` (a wall-clock time with no offset is `400
parameter_invalid`), or `deliver_in` a delay from now (`90s`, `20m`,
`2h`, `1d`).

The row is accepted now, sits in the queue at its arrival position, and is
invisible to the drain until the time passes: it neither heads nor blocks
the queue before then, and when due it drains in read order and wakes an
idle conversation, the receipt's own path.

More than two minutes past is `422 deliver_at_in_past`; more than ten
years ahead is `422 deliver_at_too_far`; both fields is `422
deliver_at_ambiguous`. It is `queue` only: beside `delivery_mode:
steer|steer_now` it refuses `422 deliver_at_not_steerable`. The kernel's
own mail never carries one. A scheduled row counts toward
`input_queue_limit` while it waits. It is a conversation-door field; the
run door refuses it by name. The listing shows `deliver_at` on the row.

Create receipts digest the authored absolute instant or relative
duration. A relative duration resolves only on first execution: retrying
the same key and duration returns the original input and deadline, even
after that deadline passes. Equivalent durations (`20m` and `1200s`)
share intent; a different duration, or switching between absolute and
relative intent, is a mismatch.

### context_mode

`assembled` (the default: the kernel compiles history and prompt,
adjacent same-role messages merged for the wire) or `raw` (reply lane
only: `entries` is the verbatim message array, with no history and no
merging; bounds and the window gate still apply).

A raw assistant entry may carry `phase` beside the `native_origin` that
licenses it, exactly as a sealed entry does
([the preview's `entries`](conversation-context.md#the-preview)), and the
compiler resends it under the same rule. Verbatim describes the sealed
semantic input: the selected model's declared prompt format can project
instruction roles when compiling the outgoing request, and that
projection never rewrites the input or history. Regeneration, including a
model change, retains the original raw entries and compiles them for the
selected model; it cannot undo a role rewrite the caller made before
submission.

### instructions

The system field under `context_mode: raw`, the `raw` grammar's one field
outside `entries`. It is sealed as sent in the wire's own slot —
`request_options.instructions` on a tool-less reply, the round's system
field on a run-backed one, inherited by every continuation — one copy per
round, never a list item.

It is refused `422` on an assembled input, whose system text is the slot
blocks the kernel compiles into the list, and refused by name on the run
door. It is rendered on the row when present, and editable while queued.

### tool_names

The turn's tool subset: exact callable names from the tools Nexus
assembles using the answerer's source configuration and the
conversation's selected Runner ([Tool assembly](tool-assembly.md)).

Absent means that whole assembled surface. An empty list means no tools at
all — a reply from context alone, still under the declaring profile's
engine. A list narrows by name and never adds: a name outside that
assembled surface is `422 validation_failed` naming it, a list that names
a tool twice or names a blank is `422`, and a scalar is `400
parameter_invalid`.

The input already carries the turn's model, so the turn's tools ride
beside it — the `context_mode`-overrides-`prompt_mechanism` precedent.
They are frozen onto round `r1` at materialization: Nexus renders and
narrows the current assembled declarations, then freezes those bytes in
callable-name order, through the same narrowing a `delegate_task({tools})`
branch uses, inherited by every continuation of that turn.

It is a reply-lane field: on a `message`, which compiles no request, it is
`422`; on the run door it is refused by name like the model selection,
because the run's one turn carries its seed's tools. A tool absent from a
turn's bytes is refused if guessed: the declaration is the round's only
gate, kernel tools included, so a model calling a withheld
`delegate_task` gets `unknown_tool` and the round goes on. It is rendered
on the row when present and editable while queued, where `[]` is no tools
as on the create, and "back to the whole declaration" is the whole
assembled surface by name.

### approval_mode

The turn's tightening of the declaring profile's approval mode: `ask` or
`rules` on a `bypass` profile, `rules` on an `ask` one. Only ever
stricter than the declared word (bypass → ask → rules, each step removing
a grant path), never looser: a loosening, a word outside the vocabulary,
or a word on a profile that declared no mode is `422 validation_failed`
naming `approval_mode`.

Absent means the profile's own word. It is frozen onto the run row at
materialization beside the profile's `approval_rules`
([Run approval](run-approval.md)),
so the turn's every tool call crosses the stage under it. It is a
reply-lane field: `422` on a `message`, refused by name on the run door,
because the run's one turn carries its shell's word. It is rendered on
the row when present and editable while queued — there is no clear
gesture, so send the profile's own word, and a rank-equal word is lawful.

### Reasoning in history

Assembled replies also carry the earlier turns' reasoning back to the
model, by default every turn, in the target wire's own field: signed
thinking blocks, encrypted reasoning items, Gemini's thought parts, the
chat message's `reasoning_details` or `reasoning_content`, DeepSeek's
plain-text reasoning item — when the target can read its origin.
Anthropic's and Gemini's cross their own models, the API dropping what a
model cannot read, unbilled; every other format rides the exact model
that produced it.

Reasoning the target cannot read carries nothing: no text stands in for
it, and signatures and encrypted material never cross. Replayed reasoning
is history — it is priced with its turn in the one fit and leaves the
window only with its turn.

### reasoning_replay

The policy knob beside `history`: `{ "mode": "none" | "last_turn" | "all"
}`, where `all` replays every traced turn.

The kernel default is `all` on every model, because reasoning is history:
every trace the target can read rides on every later request exactly as
the request that first carried it did, so each request extends the
previous one. Person turns, kernel mail, regeneration and the estimate
share it.

A trace is priced with its turn in the one fit — the provider's reported
reasoning count, and its bytes against the sealed request's storage bound
— and leaves only with its turn. When history and its traces outgrow the
fit with no bound the caller stated, the timeline compaction runs and the
head waits behind the summary; never a cut of traces alone, and never a
request re-sent without them. Under a compaction policy of `off` the
request slides, dropping the oldest turns with their traces to both the
window and the bytes. The fit leaves the turn's own answer room on a hard
or shared window, `min(32k, 12.5 %)` of it; a model planned to an
advisory bound below its window has that room already.

What puts a trace back on a later turn is the caller's own word for one
turn: a narrower mode named for it, a `history` bound stated for it, or
effective `reasoning_enabled: false` on a native lane, since reasoning off
replays none. The next turn at the default carries again what that turn
left out. After a model switch the earlier traces the new model cannot
read carry nothing — one change at the switch — and later turns on that
model extend each other.

A provider's non-transient HTTP refusal (4xx) of a request carrying
native reasoning disables default replay for later assembled requests in
that conversation. A context-window refusal is the compaction's instead —
the between-turn summary on a direct reply, the in-turn repair on a run —
never a reason to drop reasoning. The switch is read where each turn's
request is compiled, so a run keeps replaying its own turn's reasoning: a
tool turn must pass it back. One `reasoning_replay_downgraded` event
identifies the failed task's turn. An explicit caller mode still wins.
Already sealed requests, including retries, keep their content, and raw
messages are also explicit content and are not rewritten by this default
change.

The mode governs reasoning material only. An assistant message's wire
label (`phase`) is the round's own fact, not replay material, and rides
whatever the mode, to its producing wire and lane only.

### inline

The client's own text placed into the assembly — the block primitive,
usable directly, no template needed. A list of up to 16 entries, each
`{ "role": developer|user, "text": …, "position"?: "lead"|"tail" }` or
`{ "slot": system_prompt|character|persona, "text": …, "role"?:
system|developer|user|assistant }`.

An entry naming a slot replaces that slot's registered prompt document
for this turn — the agent's system prompt, the room's character, the
person's persona ([Prompt assembly](prompt-assembly.md#slots)) — in slot
order, whether or not anything is registered there. Its role is the
registered document's when it names none, else `system`. `slot` and
`position` never ride together (`400 parameter_invalid`). A
`system_prompt` override may name the addressee's declared template
variables beside the built-in macros, as its document may too; the other
slots see the built-ins alone.

A slot-less entry is placed by `position`, where the addressee's template
puts its `lead` or `tail` block. A template without that block has
nowhere for it, and the entry is refused `422 validation_failed` naming
`inline_position_unplaced`; the built-in order places both. `lead` (the
default) then `tail` ride behind history and ahead of the prompt.

They are funded like the prompt in the self-fit budget: the client's text
never yields, only history does. What a turn places between history and
its prompt is its preface
([Prompt assembly](prompt-assembly.md#the-order-is-the-cache-s)): sealed
with the turn and replayed by every later turn of the same answering
agent where it was sent.

A lead matching, by role and text, the whole lead or an exact prefix of
complete segments from the newest preface of this answering agent's own
turns still in the window is laid once — the window already carries it,
so an unchanged lead re-sent every turn costs one copy per window, not
one per turn. A changed one is laid with its own turn and never edits an
earlier one. A lead the window no longer holds, because a summary or a
stated bound removed its turn, is laid again. Another agent's history
never carries it. A turn that relied on the window for its lead records
the lead it relied on — never laid, never replayed — so a regeneration
whose own window no longer carries it lays it.

A `tail`, and a template's own post-history inline text, are per-turn text
and ride every turn that renders them.

A positioned entry is therefore `developer` or `user`. A `system` entry
there would be a mid-conversation system message the Anthropic and Gemini
wires hoist into the top system block, an `assistant` one words the model
never said, and both are refused `422 validation_failed` naming
`inline_role_unplaced`; a slot override keeps every role. An `assembly`
template that places `lead` ahead of `history` makes the lead a per-turn
block of the prefix instead: an identical lead keeps the cached prefix, a
changed one moves it, the template's own policy, and nothing ahead of
history is sealed or replayed. `developer` is accepted on every lane —
the Anthropic and Gemini wires lower it to `user` in place, the
OpenAI-shaped wires carry it — and a role the target lane's wire refuses
is the lane's typed refusal, exactly as in raw mode.

### history

Per-request assembly intent, in the estimate surface's exact vocabulary.
Assembled replies only: a message has nothing to compile and `raw` skips
the compile, so both refuse a stored intent that would silently do
nothing.

At most `max_entries` (≤ 200) newest turns, and/or `token_budget_share`
(0 < x ≤ 1, six-decimal precision) of the model's own window. It is
stored on the row as `context_options`, honored at materialization, and
editable while queued; `history: null` (or `{}`) clears the intent.

The closed vocabulary refuses at the boundary: an unknown key or a
malformed shape is a `400`, never a silent drop. A share against a model
that declares no window parks the head blocked as
`history_budget_unavailable`, and the estimate returns the same refusal.
The prompt itself never yields to the bound — only history does.

### variables

The turn's values for the names the addressee's `prompt_template`
declares (`{ name: "value" }`, strings), over the template's defaults
([Prompt assembly](prompt-assembly.md#the-assembly-template)). It is
body-read like its siblings, so a non-object is a `400`.

It is admitted only when the addressee's standing word is `assembly` —
anywhere else nothing would read them and the intent is `422
validation_failed` — and a name the template does not declare is refused
by name (`variable_undeclared`). It is judged against the addressee's row
of the day it is written: if the profile re-declares its template before
the drain, a name the current template lacks parks the head blocked as
`prompt_template_invalid`, never rendered as literal braces and never
silently dropped.

## How history fits

Whenever no `token_budget_share` is stated — a `max_entries`-only intent
composes with it — history fits itself to the model's own window, the
advisory bound first, else the hard bound, minus the prompt's own cost,
newest-first.

Once the timeline overflows that fit the head does not send a trimmed
request: it arms the timeline compaction, a `compaction_summary` turn,
the same repair the size walls arm
([Conversation context](conversation-context.md#automatic-repair)), and
waits behind it, so the prefix after the summary is stable instead of
sliding by one turn per reply.

Only when no summary can be armed — the author's compaction policy is
`off`, or the summary itself overflows the fit — does the trimmed request
go, narrated as a `context_trimmed` event; regenerate's reassembly
fallback narrates its trims the same way. A stated share is the caller's
own bound and trims to it as asked.

Only a prompt the model itself cannot take still blocks
(`estimated_input_exceeds_model_limit`), and the gate fires only on an
exact tokenizer count: inexact upper bounds never refuse.

At most the newest 200 turns are considered per assembly. Older
content-bearing turns count in the skipped evidence as `candidate_limit`,
and with no stated bound, reaching that end is the wall as well and arms
the same compaction.
