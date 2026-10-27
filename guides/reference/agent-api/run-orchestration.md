---
title: Run orchestration
description: The kernel orchestration tools a model calls to branch, wait, ask, spawn and message, and the agent-side code path beside them.
---

# Run orchestration

How work inside a run grows: the kernel tools a model calls to branch,
wait, ask a person, spawn a child conversation and message a peer, and
the agent-side code path that authors the same work from outside. The
step grammar a client authors with, and the round driver that runs it,
are on the [Runs](runs.md) page.

## The agent-side code path

Agents can implement code authoring and evaluation outside Nexus using the
[task operation API](executor-operations.md). The kernel accepts operations
and atomic step batches, observes real task results in a durable order, and
publishes the executing tool's final result. These capabilities also serve
clients that do not execute code.

Every ordinary externally claimed ToolTask can use these operations within its
frozen execution context. Its live handler retains the same claim while waiting
and renews the ordinary deadline; yielding local capacity does not end that
execution. Nexus has no program interpreter or fallback runtime. The Agent
owns source syntax, bindings, prompts and model adaptation. rho's `code`
extension supplies one such runtime; its tools, model requests and waits use
these same durable operations. Lost handlers or VMs are not reconstructed by
replaying their source. A stopped external connection or session can be recovered
only through that external protocol's own reconnection semantics.

Attached child results stay behind the parent's final-result boundary.
Explicit background operations transfer work to the existing lifetime/wake
mechanisms. Controlled replacement accepts only the caller's unstarted work;
it does not rewrite completed effects or permit arbitrary graph edits.

## The seven tools

Nine kernel tools an Agent may select for its declaration, published
as `Nexus::Tools::DELEGATE_TASK`, `::WAIT`, `::ASK`, `::SPAWN`, `::SEND`, `::REQUEST`,
`::LINKS`, `::STATUS` and `::CANCEL` (`nexus.graph.{delegate_task,wait}`,
`nexus.human.ask`, `nexus.conversation.{spawn,send,request,links,status,cancel}`;
wire names `delegate_task`, `wait`, `ask`, `spawn`, `send`, `request`, `links`,
`status`, `cancel`). Each is a small adapter over a door that exists
anyway — the shared append door (a lowering, a splice), the
conversation create, the one input door, the conversation's stop. The
published texts are the un-aliased render;
a profile's aliases (`Agent`, `spawn_agent`, `AskUserQuestion` —
[profile.md](profile.md)) re-spell the tool names these texts mention,
and a call made under an alias becomes a row under the wire name below
with the alias beside it (`tool_alias`).

### delegate_task

`delegate_task({prompt, model?, wait?, lifetime?, wake?, tools?})` — one bounded job to a new agent with an
EMPTY context. The kernel places ONE model step `<call>-model-1` under
the call: marked `branch`, `absorb`, carrying the round's request
surface (options, instructions, compaction) and its tools, narrowed to `tools` when given.
Delegation remains available when it is declared, under its original name or alias;
explicit narrowing may remove it, and an undeclared call is still refused. Nested
tasks retain the same result and Stop ownership, without a kernel depth limit.
Omitted or blank `model` inherits the calling round's configured lineage model;
an explicit `provider/model` selects only this branch at that model's reasoning
default. It changes neither the parent's continuing model nor any Agent profile.
An unavailable explicit selection returns a `model_not_authorized` error in the
call's result; it never silently inherits another model. Recovery follows the
execution's captured ordered candidates and model/provider constraints under
the [model recovery contract](models.md#model-selection-and-recovery).
An explicitly selected branch's result envelope names the requested model and
the actual model of its final owning round, or `not started` if that round never
started provider execution. This includes a changed model after fallback and a
tool result attributed to its declaring round; the tool retains its own call identity.
The task read's `model` field and model-change events also retain model selection.
Detached (the default), the step is
placed `detached` with no reads and no head: the continuation runs on,
the call answers with the background sentence ("Task r3t1 started in the
background. Its <task_result task="r3t1"> reaches you in a later message
that is not from the person …"), and the answer is delivered later by
an in-run wake for turn lifetime, or as kernel mail after the reply is final
for conversation lifetime (including when the background work finished early).
`lifetime: "turn"` requires
that result and a synthesizing continuation before final delivery. Omission
inherits the caller; it does not change immediate waiting. `wait: true` splices the branch under the
round's continuation, which waits on it and reads it; attach forwarding
keeps that edge on the branch's frontier as it grows rounds of its own,
and at assembly the branch's last word is rendered as the call's paired
result (the stored result says only `Task r3t1 started.`). Several
waited calls in one message run at once and answer in call order. The
id the model reads back is the CALL's key (`r3t1`); the branch is
namespaced under it. Refusals are error envelopes of the call, never a
failed round: `prompt is empty. …`, `wait must be true or false.`,
`tools: "browse" is not one of your tools. You have: …`. The
continuation reads the mainline, every call and every waited branch, and
that list is bounded (`too_many_reads` past 256 waited calls in one
message — 257 reads including the mainline, `Tasks::Compile`'s kernel bound
— request hygiene, not a ceiling).

### wait

`wait({task, run_public_id?, timeout_ms?})` — observe work that was already
started, when its result becomes necessary. `delegate_task` and `spawn`
launch receipts include `Task reference: run_public_id="<UUID>", task="<key>"`
so a later turn can select the original execution. Omit `run_public_id` to use
the current run. Targets are restricted to that run or other executions in
the same conversation; a standalone run can target only itself.

The tool places a finite `await_task` under the calling continuation. Work in
other branches continues. A target whose logical work is complete resolves immediately;
otherwise the observation follows its final work, including model tool rounds,
operation-owning tool results, and a race's selection — a failed race's partial winners,
then its failure. Only a completed spawn
with a non-error launch receipt follows the original child request's reply,
even after the child starts later work. Other spawn outcomes use ordinary task
result projection: a spawn denied or canceled before execution preserves its
failed or canceled result.
Waiting on an ordinary send observes its dispatch acknowledgement, not a
future reply. Repeating a wait reads the result again without relaunching work
or consuming/removing any queued result mail. Its ordinary wake policy remains
in effect independently.

Timeout and cancellation stop only this wait. The continuation receives an
error result and the target can still finish. If a target is collected while
being observed, the observation completes with `is_error: true` and
`structured_content.status: "unavailable"`, with
`structured_content.error.key: "wait_target_not_found"`. The member-authored `wait` leaf and
the task `wait` operation expose the same mechanism.

`wake: "passive"` on `delegate_task` or `spawn` keeps a late result in conversation
history without starting another model reply. The setting does not disable an
explicit wait or a turn-owned result's required synthesis. On `spawn`, it
selects the original request's return-mail behavior; it does not change how the
child receives its brief or choose the child's own task defaults.

### ask

`ask({prompt, options?, multi?})` — one question to the person, its
choices as DATA beside it. The kernel places ONE await `<call>-ask-1` under the call,
tokenless (it answers to write standing — `POST …/resolution` with no
token), `halt` on expiry, parked for up to 24 hours, and the run
announces `awaiting_human` naming it. The continuation waits on it. A
question inside a detached branch holds that branch's continuation. With
turn lifetime it also holds final delivery; with conversation lifetime an
otherwise complete foreground reply may finish. Its attention remains on the originating
run, and the same task resolution door can answer it after another turn
starts. A standalone run still waits for all its work.

ONE field name on every surface — `ask({prompt})`, the task `ask` operation, the
door's `{"ask": {"prompt"}}` — so `question:` is refused by naming the
repair: `question is not a parameter; the fields are prompt, options and
multi.`; `options` that are not strings and a `multi` that is not a
boolean are refused by sentence too. The choices are stored on the await
row and shown to the person on every read of it; the `<answer>` the model
reads is the person's text, unchanged.

### spawn

`spawn({prompt, declaration?, agent?, label?, wait?, lifetime?, wake?, model?,
model_selection?, fallback_models?, default_runner_executor_public_id?})`
creates a durable child Conversation under the Run's own Conversation. Archive
and delete follow the subagent tree; Stop follows each request's originating
execution ([Conversations](conversations.md)). The first input contains `prompt`,
has origin `agent`, and records the spawning Agent and the parent's
`sender_conversation_public_id`.

The captured [delegation catalog](profile-configuration.md#delegation-catalog)
determines which selector the call accepts:

- With a catalog, `declaration` must name one captured entry and `agent` is
  refused. An empty catalog permits no target. The child retains the caller's
  answering principal and owns the selected agent configuration; no new Agent
  identity or credential is created. rho publishes its Subagent roles this way.
- With a null catalog, omit `declaration`. `agent` selects an eligible Agent by
  `@handle` or public UUID; omission uses the caller's answering Agent. The child
  uses that Agent's standing declaration. `agent` selects who answers; `to` on
  other conversation tools selects an existing Conversation.

For a declared child, an explicit `model` or `model_selection` overrides the
entry's model policy. Otherwise `model_mode: caller` captures the actual model
of the spawning round, including a recovery switch; `default` uses the entry's
default model. `fallback_models` replaces the entry's ordered list, and `[]`
disables fallback. The child retains those defaults and selection constraints
for later work; later parent or catalog changes do not retarget it. See
[model selection and recovery](models.md#model-selection-and-recovery).

For identity-based spawn, `model` supplies a concrete `provider/model` at its
reasoning default. An unavailable selection is refused as
`model_not_authorized` with the resolver's reason. Without `model`, the brief
carries the calling round's configured model, or the Run's current main reply
selection when no round issued the call. The answerer's own default model takes
precedence under the ordinary [answer-engine order](conversations.md). This path
does not inherit the caller's tool-name narrowing or approval tightening; the
answerer's declaration supplies them.

The kernel adds no depth or fan-out ceiling. The child copies the parent's
access carrier (entries plus the parent's
derived-full pair materialized, minus the child's own creator/answerer
pair), its billing pair, and the caller's frozen default Runner. Supplying
`default_runner_executor_public_id` explicitly replaces that default; null clears
it. A selected Runner must be eligible for the child's answerer or spawn
refuses. Memory inherits the initiating execution's bindings and Speaker
subject, narrowed by the selected declaration or answering profile. rho's role
declarations narrow this to the child's own `conversation/` memory. Any permitted `speaker/` rows
belong to that answerer and the same Speaker, never the answerer's steward.
An inherited `subtree` reach remains limited to the child and its descendants
([memory bindings](conversation-memory.md#named-bindings),
[configuration limits](profile-configuration.md#memory-limits-and-conversation-reach)).
The child hangs off the conversation, never a
branch: the call itself completes at once. Detached (the default), the
call answers "Spawned conversation `<id>`, answered by `@handle`, in the
background …" and, with conversation lifetime, the child's first reply reaches
the parent later as kernel mail — `<task_result task="r3t1" status="…" conversation="<child
id>">` in a message that is not from the person. `wait: true` parks ONE
await `<call>-spawn-1` under the round's continuation, KERNEL-HELD
(tokened, `dispatched`, off every inbox, never announced as a person's
question — zero new states) with the default clock (1 h, clamped by the
24 h hold) and `absorb` on expiry: the child's reply settles it and is
rendered AS THE CALL'S PAIRED RESULT in the spawn envelope above; expiry
or canceling only the immediate await is DETACH + NOTIFY — the await ends
`timed_out|canceled`, the continuation reads "(still running; its reply
reaches you later as a message that is not from the person)", the child
is untouched. Its report follows the selected lifetime: in-run consumption
for turn lifetime, the mail path for conversation lifetime. `label` names the child
(`[a-z0-9][a-z0-9_-]*`, ≤ 64, normalized lowercase, unique among one
parent's children) beside the public id, which stays the wire's one
truth. Refusals are error envelopes of the call: `prompt is empty. …`,
`wait must be true or false.`, `label must be …`, `agent: "…" names no
member of this account. The agents are: …` (the door word
`principal_unknown`), `agent: … cannot answer a conversation here …`, a
taken label, a side conversation as spawner, and a standalone run
(`spawn needs a conversation: this run has none.`). The call runs in
its own job (`Runs::ConversationToolJob`, one job for the
conversation verbs). Completion and optional await are prepared before Input
publication. With `establish_link: true`, child, link and first Input publish
atomically; both Agents must permit messaging, and refusal leaves no child,
link or initial request. Unlinked spawn retains its resumable child creation.
Every spawn lifetime has a completion Task that retains its original Input identity.
A retried job uses that owner after short transport receipts expire.

#### A turn-lifetime spawn

With `lifetime: "turn"`, spawn creates a detached `delegation_task`
that owns its original request's completion. It holds final delivery independently
of the immediate wait. The child's initial execution inherits turn lifetime;
its explicitly cross-turn work may continue after reporting. The result belongs
to the original execution, including when regeneration, editing, concealment,
or a later request changes the displayed child answer. A held repairable child
remains outstanding. Replacing a held answer makes the original execution stop
and yields a non-success outcome without touching the replacement.

Deleting the published brief before it executes settles `delegation_abandoned`.
A refused launch settles the completion task and any immediate wait. When the
report arrives, an open immediate wait and the completion task settle together;
the continuation reads one report. If the wait already ended, its outcome remains
and an in-run continuation consumes the report once. No next-Turn mail duplicates
it. The completion task cannot be authored, externally resolved, or retried; repair
the child's real work, or explicitly dispatch a new request. Its cancellation stops
only the pending original input or original execution and its unsettled turn-owned
delegations. Later independent child activity remains outside that ownership.
A completed report releases this completion-task obligation. A whole-run or
Conversation Stop still cancels unfinished work derived from that original
request, including its remaining background work and undelivered results;
later independent child requests survive.

#### A conversation-lifetime spawn

The completion Task observes the original Input, Turn, Variant and Run. Recovery
uses a bounded completion frontier, so a lost wake does not lose the obligation.
An open immediate await consumes that completion once. After an expired or canceled
await, an unread completion becomes kernel mail only after the requester finishes
its reply. The same completion cannot be consumed by both await and automatic mail.

Mail has `origin: child`, the child's Conversation UUID as sender, and the original
spawn or request call's Task key. It uses the requester's creator and answerer,
model selection, approval tightening and the intersection of its seed tools with
the current declaration. `wake: "passive"` records history without starting a model.
A later `request` has its own completion and mail policy; ordinary `send` has neither.
Automatic result mail retains the originating execution's ordered
`fallback_models` and `model_selection` constraints. There is no additional
fallback to the recipient's current default. The mail turn uses a run even
for a tool-less profile. Recovery covers the whole mail run's main reply
path, not independently selected model branches. Exhaustion holds the run
at `needs_attention`, preserving its received prompt and failed task.
An explicit task retry retains spent route budgets and the original
deadline. See [Model selection and recovery](models.md#model-selection-and-recovery) and
[result delivery](../../build/orchestration.md#how-results-come-back)
for the recovery and ownership rules.
If the seed could not be prepared until retry, an implicit history-window
overflow holds with `history_exceeds_fit` rather than silently discarding
history. Retry with a larger-window model or an explicit template history
budget; this delayed preparation does not start a conversation summary. The
200-turn candidate window's end is no overflow there — no retry changes a
turn count — so that request sends the newest window, narrated as a
`context_trimmed` event.
Spawn owes the original brief's result while its source execution has not been
stopped. Later explicit `request` calls own separate completions and return-mail
policies. Stopping an earlier source does not suppress a later independent
request. An ordinary `send` creates no formal result obligation, and a person's
own exchange in the child is never relayed. Only the original brief may settle
the spawn await. Passive mail carries no model selection or model fallback.
An await appended but not yet parked defers the initial reply's relay to the
next pass rather than mailing a reply the await would then time out
against. If the reply arrives after the await's deadline but before the
timeout sweep, the relay expires the await and still delivers the reply as
mail. An expiry is not a reply delivery. A reply already delivered through
the await is never also delivered by another relay attempt.

### send, request, status and cancel

`send({to?, agent?, link_public_id?, message, delivery_mode?, expected_steering_run_public_id?, on_target_end?, deliver_in?, deliver_at?})`
queues an ordinary message. `request({to, agent?, prompt, model?, lifetime?, wake?, wait?, deliver_in?, deliver_at?})`
starts work with an independently readable completion Task. `status({to})` and
`cancel({to})` retain their Conversation access rules.

#### Addressing

`to` is a child label or Conversation public UUID, resolved through the member
read funnel. Unknown or concealed addresses refuse `unknown_conversation`,
Sides refuse `side_conversation`, and ancestors refuse `ancestor_conversation`
for send, request and cancel. Status can read an ancestor. A send to a parent
waiting on its child refuses `parent_waiting`. Requesting work from the caller's
own Conversation refuses `request_target_self`; sending it a message is allowed.

`agent` selects the receiving Agent by handle or public UUID; omission selects
the Conversation answerer. Direct send and request require the sender's full
standing, an eligible answerer and the recipient's Workspace messaging permission.
Unknown Agents refuse `principal_unknown`; an ineligible answerer refuses
`answerer_not_eligible`. Archive, queue capacity and execution reach still apply.

Instead of `to` and `agent`, send can name a [Conversation link](conversation-links.md)
with `link_public_id`. The calling Run's actual Conversation and answering Agent
must match one endpoint. The other endpoint supplies the target Conversation and
Agent. A link grants message delivery without granting peer history, status,
request or cancel access. A closed link refuses `conversation_link_closed`.

#### Ordinary messages

Send defaults to `delivery_mode: "queue"`. `steer` and `steer_now` require
`expected_steering_run_public_id` for the exact receiving execution; absence refuses
`steering_target_required`, and a changed target refuses `steering_target_changed`.
A guard on queue delivery refuses `steering_guard_requires_steer`.
`on_target_end: "queue"` explicitly permits fallback; the default is `discard`.
Fallback preserves the same Input UUID, requested delivery mode and target guard,
while exposing actual `delivery_mode: "queue"` and `fallback_reason`.
Source Stop or link closure still discards unconsumed messages. Archive permits
accurate steering of existing work but rejects fallback that would start new work.

Send does not accept the legacy `steer` boolean, `model` or `wake`; these refuse
`unsupported_send_field`. `deliver_in` and `deliver_at` use the
[input clock rules](conversation-inputs.md) and cannot schedule steering.
A retried accepted call preserves its original deadline.

The Input retains its sending Agent, Conversation, Run and Task attribution.
Before consumption it remains subject to source Stop. Consumption creates
recipient-owned processing with the recipient's model and memory selection;
subsequent source Stop does not cancel that processing. Send creates no completion
obligation, including when the recipient is a child Conversation.

The call's `structured_content` and JSON text contain `input_public_id`,
`conversation_public_id`, `answering_user_public_id`, nullable `link_public_id`,
`delivery_mode`, `requested_delivery_mode`, nullable `expected_steering_run_public_id`,
nullable `fallback_reason`,
nullable `deliver_at`, and `state`. Input publication and this receipt commit
together. A completed Task retry cannot create another Input after the hosted
24-hour receipt expires. Input and Turn reads expose `communication_kind` and
`link_public_id`; ordinary messages use `communication_kind: "message"`.

#### Requests and exact results

Request queues `communication_kind: "request"` through the same Input owner.
Its `model`, `lifetime`, `wake` and finite `wait` follow the existing delegation
rules. A turn-owned completion must be synthesized before final delivery;
a conversation-owned completion can arrive after that reply. Canceling the
original worker yields a canceled result to a still-live requester and does not
Stop the requester.

The acceptance receipt contains `input_public_id`, `conversation_public_id`,
`answering_user_public_id`, `delivery_mode`, `deliver_at`, `state`, and
`completion: {run_public_id, task_key}`. Read that completion through the existing
[Task resource](run-steps.md). It observes the original Input's Turn and execution,
never the latest Turn in the target Conversation. Its structured result identifies
`input_public_id`, `turn_public_id`, `variant_public_id`, `run_public_id` and
`status` (`completed`, `failed` or `canceled`). Stopping the worker produces a
failed completion Task with `delegation_canceled` and structured status `canceled`.
Canceling the completion Task itself records its Task status as `canceled`.
A late result
from an earlier request cannot settle a newer request using the same Conversation.

#### status

It answers three facts — "conversation `<id>`
— running|idle; queue: N waiting; answered by `@handle`." — and a fourth
only when messages from that conversation wait in the caller's own
queue, where a running turn keeps them: "1 message from it waits for
you, delivered when you end your turn." ("N messages … wait …"). Every
field is a model-facing name to measure.

#### cancel

It stops all existing execution owners in the addressee, including historical
background work, then cancels derived requests by source run/task. It does
not cancel an independent request merely because it occupies the same reusable
child conversation. Authorization is the sender's `full` on the addressee.
A reply the addressee owed the still-active sender can arrive marked canceled;
a reply whose sender was also stopped is suppressed. An idle addressee can
still have background work to stop. Only an addressee with no remaining source
cut or active cancellation answers that nothing remains to cancel. A standalone
run refuses these Conversation verbs.

## The result envelope

One renderer, `Runs::TaskResultEnvelope`. Every
unpaired source a round reads — a tool's output, an await's answer, a
branch's last word, a wake's delivered tips — is ONE user-role message:

```
<task_result task="r3t1" status="completed">
<prompt>Review app/models/user.rb for N+1 queries. Answer file:line …</prompt>
…the tip's text…
</task_result>

<task_result task="r1t0-probe" status="completed">
<call>bash {"command":"bin/probe bravo"}</call>
bravo: 200 OK (2s)
</task_result>
```

`task` is the id the model saw — the CALL's key for a branch a flat
tool made, the step's own key for composed work (`r1t0-summarize`),
found by walking back through the kernel's promptless continuations to
the root; `status` is the tip's own (`completed | failed | canceled |
skipped | timed_out | uncertain`); `<prompt>` is the first 80 characters of the
brief, omitted when there is none. A tool's tip carries `<call>` in
`<prompt>`'s place — a tip has at most one of the two lines: the name the
model called (an alias by its alias) and its stored input as JSON — the
kernel's spelling of an aliased call's parameters — cut to 200 bytes with
`…`; a name a client declared is written as stored, so one holding a line
break spans lines. Every model result a step reads — named or delivered —
carries its `<prompt>` and its root's key, so two results handed to one
step are told apart by their briefs and the order the author listed them. A read ACROSS
### An operation owner's boundary

It instead names the parent tool's own key and
retains its `<call>` line. Only its published result crosses the boundary;
internal prompts, history and intermediate results do not. A model inside the
same operation boundary reading a sibling keeps that sibling's `<prompt>`. Durable
observations carry typed result envelopes and task coordinates rather than
these model-facing XML fragments. A model step that
names a race in `results` is delivered each selected tip once; a winner
that is the round the step continues is rendered only in the history it
replays, as any `results` entry naming that round is.
An ask's answer is `<answer task="…">…</answer>`, with the key selected by the
same rule. The rendering is UNCONDITIONAL: a tip with no
output says `(task completed with no output)`; a tip that could not run
carries its error key and detail — nothing a round reads ever vanishes
from its request. A step a provider DECLINED is such a tip, never an
empty one: its detail is the kernel's sentence for the reading model —
who declined, the provider's category, that the step failed, and why
nothing re-ran it — and never the provider's own explanation, which is
written for people and rides the round's narration instead; one line
after it says what the model can do next:

```
<task_result task="r2t0-model-2" status="failed">
<prompt>Normalise the fetched output</prompt>
model_refused: anthropic/claude-opus-5-5 declined this step (cyber), so it failed with no output; @rho declares no fallback model, so nothing re-ran it
(the same request is likely refused again: continue without this result, or report that the provider refused it)
</task_result>
```

A spawned child's direct reply a provider declined reaches its parent —
as the delegation's result, the waited spawn's paired result, the `wait`
tool's read and the relayed mail alike — as `status="failed"` with
`(the reply ended failed: <provider/model> declined it (<category>), so it
has no text)` and the same next-step line, read from the sample that
answers the original request (the answerer's `fallback` sample when one
re-asked it) and never before that sample's converger has decided.

The compaction summary is not a delivery and
reads as plain material. The wrapper is bytes in the sealed request,
never a stored field. The prompt, the call and the body ride through the one
narrow escaper every kernel envelope shares: exactly
`</task_result`, `</message`, `<task_result ` and `<message ` are
spelled with `&lt;` for their `<` — nothing a tip says can close this
envelope or forge another, and `&`, every other `<` and code in the
body stay as written.
