---
title: Kernel mail
description: "How a background result, a spawned child's reply and a batched receipt reach a conversation as the kernel's own input."
---

# Kernel mail

The kernel writes inputs of its own: a background result that outlived its
turn, a spawned child's reply, a receipt batch. They ride the same door a
person's words do ([Conversation inputs](conversation-inputs.md)), under
two origins no caller may supply.

An unconsumed conversation-lifetime background result answers in a
supplementary turn, even when it finishes before the original reply.
After that reply is final, the kernel writes an input through this same
door: a kernel-stamped user-role `direct_reply`, `delivery_mode: queue`
always — never a steer, since a running turn finishes first — on the
mailing run's model and its seed's tools intersected with the answering
profile's current tools, assembled under the source execution's frozen
selected Runner.

The supplementary reply retains that source's frozen environment; later
profile or conversation-default changes do not move the receipt to
another environment. The receipt stores an explicit list, including an
empty one, so later additions cannot expand it. Kernel aliases match by
canonical identity and executor tools match by name. Approval keeps the
run's mode while it still tightens the profile's current mode, else the
profile's, and uses the current profile's rules.

The kernel's own word is `origin: "task_result"`, which no caller can
supply, with the sender stamp `sender_conversation_public_id` — the
conversation whose run produced it — addressed to the mailing run's own
answerer. A task A started answers to A's turn, never to the
conversation's default and never to everyone, and the door never judges
the kernel's mail for eligibility.

An idle conversation is woken by it: a new run-backed turn under that
answering profile whose trailing user message is the receipt, exactly as
a person's queued input wakes an idle recipient, bounded by what bounds a
turn.

It drains first. The queue's read order is the kernel's own rows
(`origin: task_result | child`), then arrival — `GET …/inputs` lists in
that order, and `queue_position` stays the arrival number — so a person's
word posted earlier reads after it, by design: the model finishes
absorbing what it asked for before it takes new instructions.

### Batching receipts

At a turn boundary, up to 16 already-arrived, contiguous compatible
callback inputs can share one supplementary reply. Earlier receipts
become individual message turns, and the last receipt opens the reply
whose history includes them. Every receipt retains its own content and
source stamps.

Compatibility requires identical principals, model, tool and approval
policy, and ordinary visible assembled input without custom context or
freshness fences; the total content is bounded by the snapshot size
limit. Ordinary task and tool receipts require the same source run.
Independent worker finals may cross source runs only when their frozen
original requester, execution memory context and frozen environment also
match. Each such receipt carries `callback_result`, the exact worker
result pointer ([Conversation turns](conversation-turns.md)). Unknown
result provenance cannot qualify.

Matching memory contexts include the captured collection UUIDs, subjects,
paths and access limits. Independent children using their own default
collections therefore receive separate replies. To share a summary, their
configuration must select the same shared collections and satisfy the other
batching conditions; the kernel never combines or redirects their sources.

There is no batching delay or reordering across an incompatible receipt.
The batch commits only when the actual assembled request includes uncut
history and opens a reply: a history cap, raw profile, unavailable model
or degraded reply instead leaves the remaining receipts queued and
processes the original head individually. All sources are locked in
stable order and checked before consumption.

After multiple independent worker finals are consumed, the receiving
conversation owns their combined reply: stopping one source does not
retract read material or cancel that reply. Its singular sender fields
are empty and `callback_sources` retains all sources. Single-worker
replies and ordinary receipts keep their existing source Stop fence.

### When mail cannot run

Result mail uses a run even if the receiving profile has no tools. It
retains its source execution's model intent and ordered fallback list.
There is no extra switch to the recipient's current `default_model`.
Unavailable candidates are skipped through the same [recovery
contract](models.md#model-selection-and-recovery) as other model work.

If selection or execution still fails, the mail turn retains its prompt,
recipient and execution configuration in a run held at `needs_attention`.
A task retry can name a different unspent model allowed by the captured
constraints without repeating completed tools or the child request. It
cannot renew the spent route budget or reset the original deadline.
Separate input or assembly refusals still degrade to
a completed message containing the received text; that message has no
retryable model task.

If an already-created mail run first prepares its request on retry,
implicit history overflow instead holds with `history_exceeds_fit`,
preserving the prompt for a larger-window model or an explicit history
budget. It does not initiate a separate conversation summary. The
200-turn candidate window's end is no overflow there — no retry changes a
turn count — so that request sends the newest window, narrated as a
`context_trimmed` event.

A tool-less profile retains the originating run's approval mode without
acquiring tools. An archived conversation admits the receipt and executes
it in that same archived Conversation; a woken turn with nothing to do simply ends.

### origin

`origin` is on every input and on the turn it becomes: the row's source
kind, one of four words — `person` (a human's word), `agent` (a peer's
`send`), `task_result` (this receipt), `child` (a worker conversation's
reply).

The kernel's two are the set every kernel rule reads — the read order,
the bound, the edit surface, the archive pass, the fallback — never
origin presence, and never the sender stamp, which a peer's `send`
carries too and which rides only the stamped rows, read by presence.
Input `origin: "person"` corresponds to an author whose User kind is
`human`; these fields have distinct vocabularies.

### Delivery and recovery

Settled, undelivered task results are rediscovered by the periodic
recovery sweep even if the immediate job wake is lost or the input queue
is full. Accepting the input and marking the result delivered commit
together.

Pausing or holding the originating run preserves already completed
results. Stopping it permanently suppresses further task mail, removes
its queued supplementary inputs and cancels its started but undelivered
supplementary replies — except a combined worker report whose results
were already consumed. A completed source can still be stopped; its
published answer remains.

The `input_accepted` item carries `origin` and `authored_by: {kind:
"human" | "agent", handle, display_name}` on every row, the author with
its kind recorded; `sender_conversation_public_id` when a stamp rides the
row (a peer's `send`, the kernel's mail); plus `run_public_id` and
`task_key`, the key the model saw, on the kernel's mail and on an agent's
`send`. The wake is narrated by the ordinary pair: `input_materialized`
naming the receipt, `turn_status{run_public_id}` naming the woken run.

### Spawn and request results

Every `spawn` and explicit `request` owns a `delegation_task` in its originating
Run. It observes the accepted Input and its original execution, including the
permitted fallback, never a later Turn or regeneration. The recurring recovery
sweep visits completion Tasks; terminal kicks only reduce latency. Scheduled
occurrences retain their separate original-reply relay over `turns.relayed_at`.

A turn-lifetime completion must be consumed before the requester reply becomes
final. A conversation-lifetime completion can outlive that reply; an unread result
becomes kernel mail after final delivery. The finite launch wait is independent:
an open wait consumes the same result once, while an expired wait leaves the
completion owed. A held worker remains repairable and outstanding. An ordinary
`send`, including a message to a spawned or scheduled child, creates no completion.

A later `request` has its own owner and can report after the original spawning
Run was stopped. Stopping that later source suppresses its pending result.
Stopping the worker reports cancellation to a still-live requester. A grandchild's
canceled result cannot wake a canceled child; a conversation-lifetime report to
the canceller still waits for the canceller's final reply before becoming mail.

Mail uses `origin: child`, the worker Conversation UUID as sender, and
`run_public_id` / `task_key` identifying the original `spawn` or `request` call.
Its text is `<task_result task="…" status="…" conversation="…">…`.
The stored completion retains the exact Input, Turn, Variant and Run identities,
so later worker activity or deletion of the original Turn cannot replace its result.

The recipient is the original request's answerer, even when a later requester
uses a different Agent or model from the original spawner. The author is the
requesting Run's creator. Mail reuses that Run's model selection, approval
tightening and seed tools intersected with the current declaration, including an
explicit empty set. It does not select the parent's current active Turn.
A steer joining a worker Run preserves that Run's original completion obligation.

A tombstoned recipient receives no mail; queue-capacity refusals are retried by
recovery. Accepted mail and its delivered marker commit together, and a result
consumed through the original wait is never mailed again.

### Consumption inside a run

A conversation-lifetime background tip that settles while the mainline
still runs waits for final delivery, then follows the same mail path as a
late result. Launch-time `wait: true` and explicit graph result reads
consume it in the original reply, preventing duplicate mail. The separate
`wait` tool remains an observer and does not consume queued mail.

Turn-lifetime obligations instead drain into a synthesis round before the
reply is final. Such an in-run acceptance still carries
`input_accepted{origin: task_result, run_public_id, task_key}` without an
`input_public_id`, and consumers must not treat it as a new turn. Once
per tip, on whichever path read it: a consumed tip is never delivered
twice.
