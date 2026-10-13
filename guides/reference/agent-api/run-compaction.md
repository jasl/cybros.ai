---
title: Run compaction
description: How a run repairs a round whose request will not fit — the prune arm, the kernel summarizer, a delegate, and what each one leaves behind.
---

# Run compaction

The repair inside a turn: what happens when a round of a run cannot be
sent for size. The repair between turns, which appends a summary turn to
a conversation, is in
[Conversation context](conversation-context.md#automatic-repair); this
page is the same arm serving a round.

A round whose request WILL NOT GO is not a failure to report; it is a
round to make fit. The kernel never picks a threshold at which someone's
context gets shrunk — that stays the app's policy — but it does refuse
to let a round die for size when it could be repaired, because the typed
refusal was otherwise a dead end with nothing on the far side consuming
it.

ONE ARM, TWO HOSTS. The same repair serves a ROUND of a run — standalone
or backing a turn; this section — and, between turns, a conversation's
timeline ([Conversation context](conversation-context.md#automatic-repair)):
one summarizer task, one rendering, one set of instructions, one
`context_compacted` item. A mid-turn summary is an entry INSIDE the turn
it repairs, never a second turn.

FOUR TRIGGERS, named on the event as `trigger`:

- `usage` — THE PROVIDER'S OWN COUNT, checked first on every lane. The
  last usage record the provider reported for this context (the mainline
  source's `input_tokens` — the request this round's prefix replays)
  plus the cost of what was appended since it (the tail: the round's
  answer, its results, any steer) over the model's window arms the
  repair BEFORE any counter runs. Occupancy derives from the last
  reported record, never from re-counting; a round with no record behind
  it — round one, or a lane that reports no usage — falls to the counter.
- `wall` — the composer's byte bound (`context_overflow`) or the model's
  window by the lane's own counter (`estimated_input_exceeds_model_limit`).
  ONLY AN EXACT COUNT MAY FAIL A ROUND — estimates advise and bytes
  enforce — but an estimate from a real tokenizer is enough to ARM,
  because compacting a little early costs a summary while not compacting
  costs the round. A lane declaring no counter is measured
  bytes-as-tokens, a bound that overstates, so it never arms before the
  send; on such a lane the usage trigger is the pre-send gate.
- `overflow` — the provider's own length rejection, AFTER the send. It is
  classified as `provider_context_overflow` and repairs instead of
  retrying: the round is requeued WITHOUT charging its retry budget (a
  repair is not a failed attempt) and the summarizer is armed. The
  classification reads typed provider codes or narrow error sentences.
  Responses can answer 200 and fail inside the stream with
  `context_length_exceeded`. HTTP 400/413 errors can carry that code or
  llama.cpp's `exceed_context_size_error`; the same status gate also
  recognizes the specific length-rejection sentences from Anthropic,
  Gemini, OpenRouter, llama.cpp and Strata. Only structured error fields
  and the parsed error message are read, never an echoed raw request.
- `manual` — somebody asked: COMPACT NOW below, or the conversation's
  `POST .../compaction` reaching a running run-backed turn's next queued
  round.

A REFUSAL IS THE GOOD CASE. Some endpoints answer 200 having silently
discarded most of an oversized input — observed live on two OpenRouter
models, unaffected by `transforms: []`. The kernel narrates the
suspicion and never acts on it: a round that reports FEWER input tokens
than its source did, by more than its own tail could explain, settles
with `input_truncation_suspected: true` on its `round_result`; evidence
for a watcher, not a trigger.

A caller can set `configuration.max_output_tokens` when the selected
model declares that control in its `generation_parameters`; an undeclared
parameter is refused. The caller chooses the cap, and the kernel validates
and forwards it through the model's declared protocol. Shared-window
planning bounds the input without reserving the requested output tokens,
so the provider can still reject a request whose combined input and output
budget exceeds its window. Recognized context-overflow errors use the
overflow trigger.

The configured window must match the provider's actual loaded context. An
overflow repair does not discover or rewrite it. If that configuration is too
large, the summarizer may also be rejected; if the requested output budget alone
is too large, removing history cannot repair it. Repeated rejection of the same
round does not trigger another summary. Correct the model's context and output
configuration, and shorten the input when its fixed content cannot fit. Once
the repair is unavailable or exhausted, a context-length rejection fails the
step without spending its ordinary retry budget on the unchanged request. This
also applies to a summary request that is itself rejected for context length;
transient provider failures keep their normal retry behavior.

THE CHOICE, ONCE PER WALL — `mode` on the event:

- `prune` — preferred, and chosen when already-consumed tool results of the rounds
  OUTSIDE the keep-recent tail cover the overshoot, after charging the
  replacement placeholders. Byte limits use stored result sizes; token
  limits also require the selected model's counter to confirm enough
  token savings. Without a usable counter, a token-triggered repair
  summarizes. Nothing is appended:
  the round is marked `pruned_before: <the first retained round>`: the earlier
  of the ordinary tail and the current fan's round (its own key when neither
  retains a round). The current fan's first read never contributes savings or
  clears, even when it exceeds the tail budget. The round is re-scheduled in the same pass and
  composes from ROWS — every result of a round before the mark renders
  as the kernel's placeholder `[Older tool result cleared to fit the
  context window; call the tool again if you need it]`, calls and words
  verbatim, and the recent results stay EXACTLY what they were. A call
  that settled without a result keeps its error envelope: clearing it
  frees nothing, and the placeholder would read as a result that
  existed, so the arm never counts it as freed either. A
  trigger with no number behind it (`overflow`, `manual`) never prunes.
- `kernel` (the default) — the kernel's own summarizer runs as a
  tool-less model task on the round's model, with no tools; pass
  `model`, `reasoning_enabled` or `reasoning_effort` on the policy to override.
- `delegate` (`{"mode": "delegate", "tool_name": "…"}`) — the same text
  is handed to the AGENT's own tool as a `tool_task`, which is how an
  agent supplies its own implementation: an inbox row addressed to the
  run's declaring profile's address ([Executor](executor.md)). Its
  `tool_input` carries `history`, `retained_tail` and the address of what
  it summarizes: on a run-backed turn `conversation`, `turn` and the
  round's `task`; on a standalone run `run_public_id` and `task`; between
  turns `conversation` and `turn`. The two texts are clamped so the WHOLE
  `tool_input` fits the 64 KiB envelope bound once encoded, address
  included — the oldest material yields first, and the tail yields only
  after the history is gone. It settles into the same slot, and the
  composer cannot tell the two apart. A delegate nobody answers expires
  at its park and the kernel's own summarizer runs ONCE in its place,
  narrated `context_compacted{trigger: fallback, fallback_from,
  fallback_reason}`; a second failure is the honest size failure. A run
  with no declaring agent — a person's own standalone run — has
  no address to delegate to: `compaction: {mode: delegate}` on any of its
  model steps is refused at the append door, `invalid_steps` with
  `{code: delegate_requires_agent, path: steps[i].compaction}`.
- `{"mode": "off"}` — keep the typed refusal. A client driving its own
  run needs the signal, not a repair it did not ask for.

`compaction` is authored on a model task and inherited by every round
that continues it — a continuation that could not carry it would lose
the policy at round two. The repair's MARKS are not inherited: a
continuation of a pruned or summarized round replays that round's sealed
request byte for byte and carries no mark of its own.

ARMED, THE ROUND WAITS. One summarizing task is appended, the round
gains a dependency on it, and when it runs again it reads that summary
IN PLACE OF the history it replaced — a deliberate chain break. The
summary is spliced as MATERIAL, never as a mainline: replaying the
summarizer's own request would put the whole history back, which is the
one thing compaction exists to avoid.

The repaired round still reads its current tool fan, waited child results,
ask answers and named results after the summary. These have their first
consumption at this boundary: calls retain their original pairing and required
native replay, and current captures retain their bindings. A source named in
both ordinary and explicit result slots is delivered once. Later history and
row reconstruction keep that consumption position; they do not restore the
replaced history or an older launch acknowledgement.

WHAT THE SUMMARIZER READS is led by THE NAMES THE MODEL SAW — the
repaired round's declared tools under one header (`The tools the agent
has:`), an alias by its alias, so the summary's next steps can only name
a tool the run declared (a summarizer told none once wrote
`execute_command` to a run that had `bash`) — then a rendering of the
chain back to the last cut: each round's words verbatim, and EVERY TOOL
RESULT AS A POINTER — `Tool <name> (<status>, <outcome>): <the call's
arguments, head> → N bytes, not carried; re-read it if needed`, `<name>`
being the spelling the model called (an alias, never the kernel's wire
name behind it), the outcome being `ok` or
`error` on a completed row (its envelope's `is_error`), `no result` on
any other settled one and `no result yet` while it runs — never its
body, in the older rounds and in the recent ones alike. A `no result`
pointer is followed on its next line by the error envelope the model
read for that call (`<tool_use_error>…</tool_use_error>`, its typed
failure in the kernel's words), because the summary is read in its
place: without it a call failed as `tool_input_too_large` reads
`{} → 0 bytes`, and the repaired round learns that something failed
but never why. A summariser
handed a result's bytes can
only pass them on as its paraphrase, and a paraphrased value is a wrong
value: the fifty-two invented first lines of the long-session lane were
paraphrased two-kilobyte heads. Its instructions ask for the same shape
back — WHAT TO RE-READ as paths and calls, never contents, values,
lines or numbers, and which results the summary does not carry — and
the KERNEL, not the model, frames every summary a round reads with one
fixed sentence ahead of it: "This summary replaces earlier history and
carries no data values: re-read any file, output or result it mentions
before you use it." Recent results stay verbatim through the prune arm,
which keeps the rows.

EVERY DROP IS ANNOUNCED, and cut on a boundary. The newest work rides
under its own header and is carried whole — the tail is bounded both by
bytes and as a FRACTION of the history, because an absolute cap alone
would keep a small history entirely verbatim and shrink nothing, and
the oldest round is always summarized; the cut falls on round
boundaries, so a call and the result answering it are never separated.
When the rendering does not fit, whole ROUNDS are dropped oldest first
and the text leads with `[... N earlier round(s) elided to fit ...]` —
the count is honest only because the cut is on a round boundary. On a
lane that counts, the older section shrinks the same way until the
summarizer's request counts under ITS reader's window: a history that
walled is by construction larger than the window that walled it.

THE RAW RULE. `prompt_mechanism` rides the run (`raw` when the turn's
input said `context_mode: raw` or its profile declares it): the kernel
assembles no history under raw, so `kernel` mode refuses
`compaction_unavailable_under_raw` — the round fails on size with that
key — while `delegate` arms, because the agent's own tool is the one
reader of a raw request.

COMPACT NOW: `POST .../tasks/{task_key}/compact`. The kernel picks no
threshold, and this does not change that — it is a CALLER asking, which
the wall-only trigger never left room for. Task-grained like every other
verb here: the caller names the ROUND, because a run can hold many in
flight and "compact the run" would have no referent. Answers `202` with
the task and the `summary_task_key` it authored (a manual repair always
summarizes), so the repair can be followed without diffing the graph. A
QUEUED model task only — `task_not_queued` otherwise — and that is what
the repair means rather than a restriction: the summary is spliced AHEAD
of the round that reads it, and a started round's request is already
sealed and on the wire. Refusals name which precondition failed
(`compaction_disabled`, `already_compacted`, `nothing_to_compact`,
`compaction_unavailable_under_raw`), because the automatic caller has
one answer to all of them and a person who asked is owed which.

A ROUND IS REPAIRED AT MOST ONCE, by either arm. Compacting a compaction
is a run, not a repair: if a pruned or summarized round still will not
fit, the refusal is the honest answer. And a first round with no history
behind it is simply too big — there is nothing to summarize.

THE CUT MARKER is not a row. The transcript's round row carries
`compacted_before: <its own key>` when the round read a summary in place
of everything before it, and `pruned_before: <key>` when it read the
rounds before that key with their results cleared — absent otherwise —
and a reader draws the line from those; on a conversation's timeline the
line is a `compaction_summary` turn's own kind.

COMPACTION IS THE ONE LICENSED PROMPT-CACHE BUST. Every other rule here
protects the prefix; this one spends it, consciously, for a context that
fits — once per wall, not per round.
