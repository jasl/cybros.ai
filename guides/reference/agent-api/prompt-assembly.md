---
title: Prompt assembly
description: How the kernel compiles an assembled turn — the default block order, the prompt-document slots, macros, the skills block, history and the assembly template grammar.
---

# Prompt assembly

An assembled turn is one the kernel compiles from the knowledge it holds,
rather than one whose entries the caller sends verbatim. Which compiler
runs is the answering profile's `prompt_mechanism`
([Agent configuration](profile-configuration.md)): `default` is the
built-in block order below, `assembly` is the same compiler reading its
order from a stored `prompt_template`, and `raw` compiles nothing and
sends the input's own entries. The sealed request records exactly what
was compiled ([Conversations](conversations.md)).

This page owns no routes. It describes what the blocks are, where they
come from and how they are funded, for both hosts: a conversation's
`direct_reply` and a run's model rounds compile through the same grammar.

## The default order

```
[system_prompt] [character] [persona] [memory] [skills] [history] [inline lead] [inline tail] [input]
```

`default` is the kernel's word when a profile declares none, and a
profile under `default` compiles this fixed order whatever template it
stores.

## Slots

The slots are prompt documents: durable rows, each on the anchor that
owns it, read live at every materialization. A write bumps no
`context_revision`, so the next turn of every conversation sees it.

| Slot | Whose | Door |
| --- | --- | --- |
| `system_prompt` | The agent's identity: the answering profile's row | The agent's own [`profile/prompt_documents`](profile-prompt-documents.md) |
| `character` | The room's identity and scenario: the workspace's row | [`workspaces/{id}/prompt_documents`](workspaces.md#prompt-documents) |
| `persona` | The person this turn answers to: the poster's controlling Human's row | The person's own [`profile/prompt_documents`](profile-prompt-documents.md) |

The answering profile is the conversation's stored answerer, whoever
posted; a Human-answered conversation compiles no `system_prompt`. The
`persona` row follows the poster's controlling Human. The template selects
which slots participate; memory limits do not select prompt slots.
This slot is distinct from
the explicit Human-only `user/` memory scope
([Conversation memory](conversation-memory.md)). The workspace's door
needs write standing under the dedication fence.

An absent slot renders nothing. Each present slot is one block of its
document's `role` — `system` unless the author said otherwise — and
adjacent same-role blocks join for the wire. With every slot at its
default the sealed list therefore opens with one system item whose parts
are the three documents in that order, each its own text; a `developer`-
or `user`-role slot breaks the run and stands as its own item, the
author's choice.

Anthropic's wire lifts the leading system items into its system field; a
chat-shaped wire sends them as the first messages. Either way the system
text rides the sealed list and never the wire's `instructions` field, so a
run-backed turn's round `r1` is byte for byte the tool-less reply's
request plus the tool block, and every continuation round carries it
once.

## Macros

Macros inside a slot's text are a closed registry substituted at compile
time:

| Macro | Renders |
| --- | --- |
| `{{agent}}` | The declaring profile's display name |
| `{{user}}` | The poster's controlling Human's display name |
| `{{workspace}}` | The workspace's name |
| `{{date}}` | Today, ISO 8601 |
| `{{conversation_kind}}` | `standalone`, `conversation`, `child`, `scheduled` or `side` |

A slot naming the date moves the cached prefix once a day, which is the
author's choice. A scheduled execution is `scheduled` even though it also
has a parent; a side fork is `side` and an ordinary fork is
`conversation`. The kind follows the host's durable identity and stays
stable when a parent or schedule is collected: it describes the host, not
a turn's input origin or execution lifetime. The same value is available
in registered slots, inline slot overrides and template inline blocks at
compilation, including the first scheduled request.

A source that is absent renders empty, never the braces. A word outside
the registry is refused when the document is written — and when an inline
`slot` override carries one — as `422 prompt_document_macro_unknown`
naming it, so a typo never reaches a model as literal braces.
`{{history}}` is a block, not a macro.

## The skills block

The skills block follows memory when the turn declares a skill callable
([Runs](runs.md)). It renders one line per document as `- callable / name
[executor UUID]: description`, omitting the UUID for kernel memory
sources, under the tool's "Skills available now." header.

Each Runner callable contributes its named Runner's documents without
merging same-named documents from other Runners. A non-Runner callable
uses the [memory skill precedence](conversation-memory.md#skills), with
collection and document identities fixed in its catalog. Database sources are limited to the execution's
effective memory bindings; an excluded root contributes no catalog entry
or loadable skill. The block is bounded by `skill_catalog_bound` (16
KiB), including a count of omitted entries when needed.

It is rendered once per turn into the sealed seed and frozen for the run,
exactly as memory is: a skill written or announced mid-run is the next
turn's fact. A turn without the tool has no catalog, a `direct_reply`
never carries one, and a `raw` turn is not assembled and shows none. The
memory block never renders a `skills/` row — the catalog is its pointer,
and the body is loaded on demand.

## The order is the cache's

The slots, memory and the skills catalog change when their content, source
selection or availability changes; history changes every reply. So they lead, the stable cache marker
lands after them ([Runs](runs.md)), history rides behind them, and the
per-turn text — the `inline` lead and tail, then the input — rides behind
history.

What a turn laid between history and its input is its **preface**, sealed
with the turn as it was sent: every later turn of the same answering agent
replays it in place, so a turn's request is the earlier request whole plus
its own tail — the prefix a provider cache and a signed thinking block are
bound to.

`[history]` holds each earlier turn by its kind: a `message` turn as its
content in its role; a reply turn as its preface (the assembling agent's
own turns only — another agent's reply never carries its preface), the
words that opened it (its prompt, user role), then what it produced — a
tool-less reply's text, a run-backed turn's rounds — or its in-turn
summary in place of all three; a summary turn as its summary under the
kernel's header.

Adjacent same-role items merge into one message whose parts are each
item's own, never folded into one text. The exception is the user
messages a run round's request carried on their own — each delivered
result, the abort marker, each steer it read — which stay their own
messages in history as that request sent them, so a wire that sends one
item per message (the Responses and chat wires) and one that merges
same-role neighbours (Anthropic, Gemini) both see the earlier request
whole. A regenerated or edited answer keeps its turn's preface.

The slots, memory and the inline entries are funded ahead of history in
the self-fit budget: they never yield, history does, down to none
(`history.selected: 0`, `skipped_reason: budget_exceeded` on the
estimate). Only a prompt the model itself cannot take refuses, at the
window gate.

## Where a direct_reply's words live

A `direct_reply` whose `text` is the person's words — the shape rho's
`do` and `say` post, one row and one materialization — creates no user
turn. The text rides as the final user message of that turn's sealed
request, and is kept on the reply turn as its prompt.

A later turn's assembled history renders each earlier reply turn as its
preface — the per-turn text its request placed between history and the
words, replayed for the answering agent's own turns
([Prompt assembly](prompt-assembly.md)) — then the words that opened it,
in the user role, then what it produced: a tool-less reply's text, or a
run-backed turn's rounds (text, calls, results and captured pictures)
from rows. The timeline therefore records the assistant's turn alone and
the model still reads the question before the answer.

The kernel's own receipt is such a turn: its words are the
`<task_result>` envelope, delivered to a later turn exactly once — there,
never again at the call that started the task. A turn whose in-turn
summary arrived renders the summary in place of everything before its
repaired round, its preface and opening words included.

Each such turn is one more history entry, funded by the history budget
like any other: under a tight budget a turn's rounds outlive its opening
words, and older turns leave the window sooner. Each round's eligible
tool captures follow all of its results in one user message, in result
and link order, with repeated images shown once per round. The current
turn's model selection places each picture natively or as an attachment
index line, and only native pictures bind to the new request. The round
and its pictures share one history-budget decision. Pruning a result
removes its pictures too. A summary or execution-details retention does
not resurrect replaced captures, and a fan first consumed after an
in-turn summary still carries its own pictures. Another agent's reply
contributes its final text, not its tool captures.

A client that wants the person's words as a turn of the timeline's own
still posts a `message` first.

## The speaker envelope

The unlabelled user voice a model reads is its person's. A row posted
directly into the conversation by one of its own voices — its creator,
the answerer of the turn the row is read for, or the Human that answerer
answers to (an answering profile's steward; the human themself on a
human-answered turn) — renders bare.

The answerer is the turn's: the input's addressee on the wire, the turn's
own `answering_user_public_id` in history — the conversation's default
everywhere but a group turn, so a 1:1 conversation keeps its bytes and
B's turn bares B's person, not A's.

Every other user-side row is rendered, wherever the model reads it, in
the line-structured speaker envelope, naming its author by handle, kind
and id, and the conversation it was sent from when the row carries a
sender stamp. A turn's author is its speaker — `speaker`'s User, which a
fork's adopted boundary turn keeps while control passes to the forker, so
a colleague's word stays the colleague's in the fork.

```
<message from="@lark" kind="agent" user="<public_id>" conversation="<sender conversation id>">
…the row's words…
</message>
```

That is another human's word, another agent's, and every row sent from
another conversation whoever sent it: a peer's `send`, a spawn brief —
the spawner's row on a copy of itself. The kernel's own rows (`origin:
task_result | child`) are never wrapped: their text is the `<task_result>`
envelope.

One renderer serves the five sites the model reads a row at — the
trailing user message of the turn it opens, that turn's seed in later
history, a user-role `message` turn's content, the steer tail of a
running round, and the summarizer's transcript — so the sealed request
and the next turn's prefix carry the same bytes. The envelope is rendered
at assembly and never stored: the row and the turn's prompt keep the bare
words, and a renamed handle re-renders from the row.

Inside any envelope, a body may not forge or close one. Exactly four
forms — `</task_result`, `</message`, `<task_result ` and `<message ` —
are spelled with `&lt;` for their `<`; `&`, every other `<` and code stay
as written, and the spelling is reversible. A child whose reply echoes
its brief's tag lines therefore reaches its parent with those lines
spelled inside one `<task_result>`, never as a second envelope.

Adjacent user-role segments still merge into one user entry on the wire —
the envelope, then the person's next word, each its own part. The merge
is the wire's, and no envelope goes around the kernel's.

## Another agent's turn in history

History is assembled for the turn's answerer. A reply turn that answerer
wrote is its own work and renders as its seed, then its rounds or its
text.

A reply turn another agent answered is not the model's work. It renders
as one user-side segment: its seed under the seed's own voice — the
question that agent answered — then that agent's final text (the turn's
`content`, the same text the timeline shows) in the speaker envelope of
the agent that answered. Never that agent's rounds: a wire pairs calls
with results of one run.

Two seeds are skipped: one the assembling answerer itself posted, whose
addressed row is already the call in its own rounds, and a kernel-origin
one, whose receipt was the other agent's. A turn that produced no text
renders only its seed.

So A reads B's answer as `<message from="@b" kind="agent" user=…>`, and B
reads A's turns the same way while seeing its own as assistant history:
each agent sees itself as the model and every other agent as a
correspondent. The summarizer's transcript and the estimate render every
turn as spoken.

A Side uses the answerer of the captured turn. It retains the source
content and ordering; matching emitted prefix bytes additionally requires
the same answerer, reasoning replay and budget choices. A Side taken
during another agent's turn renders the parent's turns under that agent's
reading. Current-turn snapshots can also move which turn qualifies for
`last_turn` reasoning replay.

## Per-turn overrides

An `inline` entry naming a `slot` replaces that slot's registered document
for this turn alone, in slot order, and the row stands untouched —
`version` does not move. The effective word is written onto the turn's run
row (`prompt_mechanism: default | assembly | raw` on a run-backed turn's
full read).

## The assembly template

`assembly` is the same compiler as `default` with the block order read
from the answering profile's `prompt_template`
([Agent configuration](profile-configuration.md)) — the same blocks, the
same merge rule, the same funding. The template is a JSON object:

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

| Block | Fields | Count |
| --- | --- | --- |
| `slot` | `slot`: `system_prompt`, `character` or `persona` | At most once per slot, ahead of `history` |
| `inline` | `role`: `system`, `developer`, `user` or `assistant`; `text` | Any |
| `memory` | — | At most once |
| `skills` | — | At most once |
| `lead`, `tail` | — | At most once each |
| `history` | `max_entries`? (1–200), `budget`? `{ share?, min_tokens?, max_tokens? }` | Exactly once |
| `input` | — | Exactly once, last |

**`slot`** renders the registered document, or the turn's inline override,
in its role with macros substituted. A slot the template does not name is
neither rendered nor read. A slot after `history` is refused at its path:
it would ride the turn's preface into every later turn's history, and a
`system`-role one would be hoisted into the top system block by the
Anthropic and Gemini wires.

**`inline`** renders the template's own text with macros and variables
substituted. A `system` inline is admitted only in the leading run —
before the first block that is neither a slot nor a system inline —
because the Anthropic and Gemini wires lift every system entry wherever it
sits; elsewhere it is refused at its path. Between `history` and `input`
it rides the turn's preface as the macros rendered it, replayed by later
turns rather than rendered again.

**`memory`** renders the memory block; absent, no memory is rendered.

**`skills`** renders the turn's skill catalog for eager skill callables:
one line per skill, `- callable / name [executor UUID]: description`,
across declared Runners, the agent address and kernel memory skills.
Deferred callables retain their frozen catalogs for `tool_search`, names
retain their owning source, and the whole block fits
`skill_catalog_bound` with one omission-count tail. It is absent from a
`raw` turn, and absent from the template means no catalog is rendered.

**`lead` and `tail`** are where the turn's slot-less `inline` entries
land; absent, such an entry is refused at the door. Placed between
`history` and `input`, as `default` places both, they are the turn's
preface, sealed with it and replayed by later turns. Placed ahead of
`history` they re-render every turn: an identical text keeps the cached
prefix, a changed one moves it, the template's own policy.

**`history`** renders the timeline. `share` is the default of the turn's
`token_budget_share` — the same flat mapping onto the window, and the same
`history_budget_unavailable` park on a windowless model; `min_tokens` is a
floor funded only when room remains after every other block; `max_tokens`
caps it. The turn's `history` intent overrides these numbers.

**`input`** renders the turn's prompt; any block after it is refused.

`blocks` holds 1–64 entries. `variables` holds up to 32, named
`[a-z][a-z0-9_]*`, never one of the built-in macro names, each defaulting
to a string. Every `{{name}}` in an inline text must be a macro or a
declared variable. The whole template is bounded like a prompt document,
at 64 KiB. A refusal names its JSON-pointer path (`/blocks/2/role`,
`/variables/Scene`).

## The budget

The budget is one allocation over the model's window: the advisory bound
first, else the hard bound, less an eighth under reasoning replay.

Every slot, inline, memory, skills, lead, tail and input block is a
required floor at its own cost, and history is the one optional child, so
history trims first, newest-first, down to nothing.

A floor the window cannot fund is evidence — the block reports
`floor_unmet` on the estimate — never a byte change. The request compiles
whole and only the window gate refuses, on an exact count against that
same window: the advisory bound first, else the hard bound
(`estimated_input_exceeds_model_limit`). The hard bound alone is the
provider's own refusal. A model that declares no window sizes nothing:
history is unbounded, as under `default`.
