---
title: Conversation context
description: Sizing an assembled context before sending, compacting it on demand, the kernel's automatic repair, and reading the exact bytes a candidate was sealed with.
---

# Conversation context

Three things a caller does with a conversation's context: size it before
sending, repair it when it will not fit, and read exactly what was sent.

The kernel picks no threshold. It has no opinion about when a
conversation is too long; it only knows when a request will not go. The
manual door exists so a caller can compact earlier than that, to reduce
cost.

## Routes

```http
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/context_estimate
POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/compaction
GET  /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{public_id}/request
```

## Estimate the context

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/context_estimate
```

It sizes the assembled context the way the reply lane will build it:
advisory, write-free, never a provider call.

### Request

```json
{
  "context_estimate": {
    "prompt": "and this question",
    "model": { "model": "openai_api/gpt-6.1-sol" },
    "history": { "max_entries": 20, "token_budget_share": 0.5 }
  }
}
```

`execution_declaration`, `model_selection` and `fallback_models` use the
same fields as [conversation inputs](conversation-input-fields.md). An
inline declaration replaces the profile configuration for this estimate;
omission uses the Conversation's owned execution defaults when present,
otherwise the current answering User. A declaration-based child or its fork
may also omit `model`: the estimate resolves its own current actual model
and captured selection intent. The estimate compiles the same
candidate constraints, availability checks, tools, prompts and memory
policy as materialization, without capturing or reserving that future
execution. Send the same authored values with the input to retain the
intended configuration.

The body also takes `reasoning_replay: {mode}` and `inline: […]`,
modeling the same replay and the same client text the send will carry —
the caller's mode, the kill-switch, the model row's default, the same
rule in the same order. An entry naming a `slot` is priced exactly as the
send prices it, in place of the registered document. The registered slots
and memory are always in the count.

`history` states intent — at most N entries, or a share of the model's
own window — and the kernel's history block owns the mechanics:
newest-first selection within the bound, chronological render, and the
evidence (`history.selected`, `skipped`, `skipped_reason`, `compacted`) a
trim-planning client reads. Positions never appear on this wire.

Two more fields ride the body. `variables` carries the turn's values for
the addressee's declared template names, as on an input. `template` is an
estimate-only trial template under the
[assembly grammar](prompt-assembly.md#the-assembly-template), compiled in
place of the addressee's so an author can compare an order before
declaring it; it is never stored and never rides an input.

### The caller and the addressee

The estimate models the send the caller would make, under the same rule
the input door applies. The caller remains the authenticated author.
`speaker_public_id` optionally selects an ingress Speaker controlled by
that Agent, using the input door's attribution rule; another Agent's ingress
Speaker is refused. Omission uses the caller's existing member Speaker.
The estimate uses that subject for an unbound `speaker/` root and applies
the same Speaker envelope as input assembly, without creating a Speaker or
writing conversation state. An explicit subject already in the conversation's
memory bindings remains selected.

`answering_user_public_id` — the input door's
own word, resolved through the same resolver — names the addressee whose
declaration, template and `system_prompt` the compile runs under, and
against whom history's speakers are enveloped; unnamed, it is the
conversation's stored answerer.

Memory and database skills use the conversation's effective bindings and
the addressee's `memory_context_limit`. `user/` requires an explicit binding
and a Human principal; an Agent's steward is never selected for that root.
Prompt slots follow the selected template independently of those bindings.

When addressing another agent, model selection follows the same order as
sending: the addressee's declared default model, its most recent direct
reply, the conversation's most recent direct reply, then the submitted
model. That selection supplies the preview's context budget, reasoning
default and attachment capabilities.

### Response

`200` with `input_tokens`, `tokenizer_exact`, `catalog_input_token_limit`,
`advisory_input_token_limit`, `message_count` and the `history` block.

The `context` block on a conversation read is the complementary fact:
occupancy from the newest succeeded usage record's provider-reported
tokens — never a local re-count — with `cache_read_tokens` beside
`input_tokens` when the provider reported how much of that prefix it
served from cache, absent otherwise. A side conversation's paid
confirmation reads that number. It stays independent of the
conversation's cumulative `usage_summary`: several calls increase
cumulative usage without adding their separate context occupancies
together.

## The preview

With `render: true` (a JSON boolean) the same answer carries what the
send would seal. Nothing is written.

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

**`mechanism`** is the word the compile ran under: `assembly` under the
addressee's template or a trial one, else `default`.

**`entries`** are the same bytes — the payloads the seal writes, read back
exactly as the sealed-request door reads them. A preview and the send that
follows on the same conversation state (same caller, same words, same
addressee) produce byte-identical entries, under `default` and under
`assembly`, in a 1:1 conversation and in a group addressed away from the
stored answerer. An assistant entry rendered from a round whose wire
labelled its messages carries that label as `phase` — the Responses
grammar's `commentary` or `final_answer` — beside the `native_origin`
(`provider_id`, `model_id`, `api_format`) that licenses it. The compiler
resends `phase` only to a target whose `api_format` and `provider_id`
both equal the origin's, and drops it silently on every other wire. An
unlabelled message carries neither key.

**`storage`** is the seal's one measure: the canonical bytes of each
entry, summed, against the seal's bound. Over it the preview still
answers `200` with `within_bound: false` and `refusal: content_too_large`
— the word the seal refuses with — because showing the overflow is the
point.

**`blocks`** is one row per block of the template, in its order: `block`
(the key — `slot:<name>`, `inline:<index>`, `memory`, `lead`, `history`,
`tail`, `input`), `type`, `role` (the first segment's, null when the block
rendered nothing), `state`, `tokens` (its fill cost, exact when
`tokenizer_exact`, else bytes/4) and `allocated_tokens` (the allocator's
grant, null on a model with no declared window, where nothing is sized and
history is unbounded).

| `state` | Meaning |
| --- | --- |
| `selected` | The block rendered and was funded |
| `empty` | The block rendered nothing |
| `floor_unmet` | The window could not fund a required block |
| `carried` | A `lead` equal to the one the window already carries, laid once; its tokens are 0 |

Exclusion is evidence, never a byte change. `floor_unmet` marks a
required block the window could not fund on bytes that still send whole,
history having been trimmed to nothing first; the count says what the
drain's window gate will refuse, and the preview itself refuses nothing on
size. There are no per-block bytes: no wire carries a pre-merge number.

**`memory`** gives the `included` and `omitted` document counts of the
memory block. **`slots`** gives the registered documents compiled, `slot →
version`; an override carries none and an unfilled slot is absent.

Without `render` the answer is the count alone. `rho prompt preview
CONVERSATION --to @handle [--var name=value…] [--template FILE]`
(rho-dev) prints the rendered answer from a terminal, and the SDK's
`estimate_input(render: true, to:, variables:, template:)` reads it typed.

## Compact on demand

### Endpoint

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/compaction
```

### Request

```json
{ "compaction": { "model": "openai_api/gpt-6.1-sol", "reasoning_enabled": false, "reasoning_effort": "low" } }
```

All fields are optional. Unnamed, the model is the conversation's own —
the newest variant's — and the reason to name one is to run a summary
somewhere cheaper than the conversation itself. Enablement and effort are
independent controls with the selection rules in
[Models](models.md#reasoning-selection).

### Response

It reaches whichever host is live, under the conversation's lock and then
the run's.

**Idle** is the between-turn repair: a `compaction_summary` turn is
appended, backed by a one-task kernel run whose only task is the
summarizer, and it settles through the converger like every run-backed
turn. It answers `202 {turn}` with the turn `running`. A caller waits for
it the way it waits for any turn, and its `turn_status` items say
`turn_kind: compaction_summary`, so a word queued behind it tells the
summary's run from its own turn's.

**A run-backed reply running** is the mid-turn repair, on the mainline's
newest queued round — a round on the wire has a sealed request. It is the
run's own `compact` ([Runs](runs.md)), answering `202 {turn, task: {key,
status}, summary_task_key}`: the running turn, the round made to fit, and
the summarizer it waits on. A `model` named on the request applies
between turns only — mid-turn the round's own `compaction` policy decides
— and a manual repair always summarizes, never prunes.

A regenerate is not repairable this way, and the reason is structural. A
summary is a turn and turn positions only ever append, so it lands above
the turn being regenerated, while the re-ask reads strictly below it or it
becomes a continuation of its own answer. A regenerate also re-asks
material the origin already sent and fitted, so it does not newly
overflow.

This is the same repair the kernel arms automatically, not a second one:
same summarizer, same rendering, same instructions, same cut, same
narration. The `context_compacted` event carries `trigger: "manual"` where
the wall's carries `"wall"` and the provider's count's `"usage"`, which is
the only difference a client can see.

## Automatic repair

A request will not go when the provider's own reported count for this
context plus the words appended since it exceeds the model's window
(`usage`, checked first on every lane: occupancy derives from the last
provider-reported record, never from re-counting), when an exact token
count exceeds the model's planning input bound (the effective window when
declared, otherwise the hard bound), or when the sealed request exceeds
its byte bound (`wall`). That is a fact rather than a policy.

A run-backed reply's rounds are repaired by the same arm inside the turn
([Run compaction](run-compaction.md): the prune arm that clears old results, the summarizer,
the provider's own refusal after the send). What follows is the repair
between turns.

When a `direct_reply` head hits a wall, the kernel appends a
`compaction_summary` turn instead of blocking the head. It is a turn like
any run-backed turn: role `user` — a summary is material derived from
user content, never instruction, and must not arrive carrying the
operator's authority on lanes that hoist a system message — spoken by the
account's `system` Speaker, and backed by a one-task kernel run whose seed
and deliverable is the summarizer (`source: "run"` on the variant, the
run's `run_public_id` on what it narrates).

The summarizer is a tool-less model step on the conversation's own model
under the answering profile's `summarizer` prompt document when one is
written, else the kernel's default text
([Profile prompt documents](profile-prompt-documents.md)). The author's `compaction`
policy may name another model, or hand the rendering to its own tool as a
`delegate` — an inbox row addressed to the agent. A delegate nobody
answers expires at its park and the kernel's own summarizer runs once in
its place as the run's new deliverable, narrated `context_compacted
{trigger: fallback}`. It is fitted to that model's window, and its
attempts admit, bill and settle through the run's scheduler like any step;
the converger adopts its answer onto the turn's content.

The head keeps its place as `pending`. The summary turn is active, so the
lane is busy (`conversation_busy`) and nothing materializes behind it;
when the summary settles the lane drains again on its own. A raw head
(`context_mode: raw`, or a raw profile) assembles no history for anyone to
summarize, so it blocks with `compaction_unavailable_under_raw` unless the
author's policy delegates.

### What the summarizer reads

It is led by the answering agent's declared tool names under one header
(`The tools the agent has:`, an alias by its alias; a human-answered
conversation declares nothing and the header is absent), then the timeline
window the assembly would have read, rendered by kind: a message as
itself, a run-backed turn as its rounds after its own in-turn cut, an
older summary as its content.

Every tool result is a pointer — `Tool <name> (<status>, <outcome>): …`,
with `<name>` as the model called it, the call that produced it, whether
it has a result, whether that result errored, and how much came back
(`not carried`) — never its body. The newest turns are carried whole under
their own header.

Its instructions ask for pointers back: what to re-read as paths and
calls, never contents, values or numbers. The kernel frames the summary,
wherever a model reads it, with one fixed sentence: "This summary replaces
earlier history and carries no data values: re-read any file, output or
result it mentions before you use it." A summarizer handed a result's
bytes could only pass them on as a paraphrase, and a paraphrased value is
a wrong value.

### Where reading starts

Assembly begins at the newest completed summary: it stands in for
everything before it, framed with that sentence under one header saying
so. The cursor is derived from the timeline, never stored, which is what
makes a fork inherit it through the closure — the child starts compacted
at the same place — and a regenerate corridor's position window find the
right one, or an older one, or none. The assembly reads the turns from the
summary onward and never touches the ones it replaced.

`history.compacted` on the estimate surface counts what a summary stands
in for, and is deliberately distinct from `history.skipped`: summarized
history is carried, skipped history is not.

### A failed summary

A completed summarizer task supplies a summary only when its result is not
an error and its output text is nonblank. A delegate may complete its tool
execution with `is_error: true` or empty output; its summary turn and
variant then settle as `failed`, and the `turn_status` event reports
`failure_reason_key: deliverable_unresolved`. The tool and run retain
their completed execution status. The failed summary does not cut history,
and an answered delegate does not receive the fallback reserved for an
unanswered expiry. A failed replacement keeps the previous successful
summary and the history after it.

### The summary is the kernel's row

No verb rewrites it: `edit` and both view-state writes refuse
`kernel_authored`. It stands in for everything before it and the assembly
cut is derived from what it is, so a rewrite would replace a real history
with invented text and a hide would un-compact the conversation through a
view flag — in both cases with nothing downstream able to tell. The undo
is not removed, only kept in one place: a summary is the tail, and
deleting the tail is this plane's undo verb; its run goes with it.

### Once per wall

A repair is armed at most once per wall. A second wall while the newest
turn is already a summary means the summary itself does not fit, or the
last repair failed — compacting a compaction would recurse rather than
repair — so the head blocks with the size reason a caller can act on, and
the next message sent makes the repair available again.

A summary that is still running, or that failed, stands in for nothing:
history is intact. A failed summary never holds the queue behind it
(`run_held` is for a person's turn, not the kernel's own row); the head
simply meets the wall again and blocks on it.

## The sealed request

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/turns/{turn_public_id}/variants/{variant_public_id}/request
```

### Response

`200` with the bytes one candidate's request was sealed with:

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
slot blocks, memory, history, the inline lead, the tail, the input, as the
assembler placed them and the wire rule merged them — and the
invocation's `request_options`, the generation bag plus the wire facts a
round carries (`tools`, `instructions` under `raw`, and `prompt_cache`,
the request's cache kind `{kind, tier?, tail?}` its markers are placed
by).

It is derived from the sealed body, never re-assembled: nothing here is
computed at read time, and no evidence block rides it. A run-backed
variant answers its first round's request — every later round is the
run's, read through [`…/tasks/{key}/request`](runs.md). A Side's sealed
request shows the shared settled prefix and the captured current-turn
material before its reference boundary, followed by its own input. This
read provides the exact bytes used by that invocation.

Browse standing reads it: these are the workspace's own bytes. `rho
request CONVERSATION TURN` (rho-dev) prints the active candidate's.

## Status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | The estimate, the preview, or the sealed request. |
| `202 Accepted` | — | A compaction was armed. |
| `403 Forbidden` | `not_authorized` | A compaction without write standing, or an estimate naming an ingress Speaker the caller does not control. |
| `404 Not Found` | `not_found` | The workspace, conversation, turn or variant is not visible to the caller. |
| `404 Not Found` | `request_not_sealed` | The variant has no sealed request: a reply that never minted, a round never scheduled. |
| `409 Conflict` | `conversation_busy` | A direct reply is in flight, or the conversation's own summary is still running. A running run-backed reply is compacted, not refused. |
| `409 Conflict` | `already_compacted` | The newest turn is already a summary, or the round already carries a repair. |
| `409 Conflict` | `task_not_queued` | Mid-turn: the running turn has no round left to repair before it is sent. |
| `409 Conflict` | `compaction_disabled` | Mid-turn: the turn's compaction policy is `off`. |
| `422 Unprocessable Content` | `nothing_to_compact` | There is no history to compact. |
| `422 Unprocessable Content` | `compaction_unavailable_under_raw` | A raw turn assembles no history; only a delegate can compact it. |
| `422 Unprocessable Content` | `principal_unknown`, `answerer_not_eligible` | The estimate's addressee is unknown, or is a Human, a `read`-level or a fenced profile. |
| `422 Unprocessable Content` | `estimate_unavailable_under_raw` | The addressee's standing word is `raw`, so there is nothing to compile. |
| `422 Unprocessable Content` | `prompt_template_invalid` | A trial template outside the grammar, naming its JSON-pointer path, or a variable the effective template does not declare. |
| `422 Unprocessable Content` | `execution_declaration_invalid`, `model_selection_invalid`, `fallback_models_invalid` | An inline execution declaration, model intent or ordered fallback list outside its grammar. |
| `422 Unprocessable Content` | `inline_position_unplaced`, `inline_role_unplaced` | A positioned inline entry the template does not place, or one of role `system` or `assistant`, as on an input. |
| `500 Internal Server Error` | `arm_failed` | The summary row could not be created: the one 5xx on these doors that carries a code. |
