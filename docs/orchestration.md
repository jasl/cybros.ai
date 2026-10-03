# Orchestration, task lifetime, and result delivery

Nexus separates a conversation's reply from all the work that reply started.
A turn can finish while its loop still owns background work. A child
conversation has its own turns and can remain useful after its first reply.
These are different resources, even when a client calls both of them agents.

## Choose the resource before choosing whether to wait

| Need | Mechanism | Ownership and result |
| --- | --- | --- |
| One delegated job with an empty context, or several (one call each, in one message) whose answers the caller reads itself | `task` | A model branch in the existing loop. Inherits the caller's request surface, with optional tool narrowing. Returns one branch answer. |
| Ordered, parallel, or result-driven operations whose results go on to further steps without passing through the caller | `compose` | A task subgraph in the existing loop. Tool, model, question, and pure script steps share the kernel scheduler. |
| An agent to keep talking to, or another agent's configuration | `spawn` | A child Conversation. Its answerer owns its tools and policy; the parent can send further inputs. |
| Another conversation's participation | `send` | An input addressed to that conversation, optionally selecting its answerer. It does not create a task dependency. |
| Observe work that was already started | `wait` | A finite AwaitTask referencing a task key and its loop. It can observe earlier turns in the same Conversation without restarting or owning that work. |
| Work without a conversation transcript | Standalone AgentLoop | An independently driven loop. It has no later conversation turn to receive background mail. |
| One-time or recurring work that should run independently of the current reply | Scheduled job | A saved instruction on the main Conversation. Each dispatched occurrence creates a child execution and returns its original result through the main Conversation's input queue. |

Waiting and lifetime are independent choices on `task`, `compose`, and `spawn`:

| Options | Immediate continuation | Final reply |
| --- | --- | --- |
| `wait: false, lifetime: "turn"` | Continues alongside the work. | Waits for its result and a model round that consumes and synthesizes it. |
| `wait: true, lifetime: "turn"` | Waits at the call. | Still owes the result if a spawn wait expires or is canceled. |
| `wait: false, lifetime: "conversation"` | Continues alongside the work. | May finish before the work; the later result uses mail. |
| `wait: true, lifetime: "conversation"` | Waits at the call. | Existing wait dependencies still apply. |

`wait` defaults to false. Omitted `lifetime` inherits the enclosing work's
selection; ordinary reply roots default to `conversation`. Explicit selection
overrides inheritance, including choosing `conversation` inside turn-owned
work. Each member-authored DAG step can also select its own lifetime. A sibling's
override does not change later siblings' inherited default.
If a background branch explicitly starts turn-owned work, the final reply
still incorporates that result even when the branch itself may continue
afterward. A planned read by that background branch alone does not fulfill
the final reply's reporting obligation.

“Turn” ownership belongs to the concrete AgentLoop execution producing the
reply. Regeneration creates another execution; later requests in a reusable
child do not become part of the original delegation. `conversation` permits
work to outlive a reply, but does not require it to live until the Conversation
ends or exempt it from dependencies, failure holds, or explicit stop.
Several waited calls emitted together still run concurrently. Foreground
placement and existing dependencies continue to block regardless of lifetime.
Standalone loops wait for all their work because they have no later Turn.

`wake: "auto" | "passive"` is a separate choice, defaulting to `auto` and
inherited by authored work. It controls completion mail after final delivery.
With `passive`, that result becomes readable history without starting a model
reply. It does not remove an existing dependency or a turn-owned obligation.
`spawn` and `send` capture this policy for their particular request's return
mail; they do not change the child's own policy for work it starts.

A turn-owned `spawn` keeps its child Conversation reusable. Nexus tracks the
initial execution's report as a `delegation_task` in the parent's DAG. It
inherits turn lifetime in that child, so the child consumes its own turn-owned
results before reporting. Explicitly cross-turn work may remain there after
the report. The completion task has no independent deadline: the child's real
execution, questions, approvals, and failure holds own progress and repair.

`send` and `steer` remain messages, without a lifetime selector or implicit
join. A steer consumed by the child belongs to the execution it entered. A
steer released to the queue when that execution closes becomes a separate
message request. A branch's empty context and a child Conversation's persistent
identity are independent of waiting and lifetime.

The `claude` and `codex` tool-style presets are naming adaptations. They do
not promise the corresponding product's lifecycle, parameter, or mailbox
semantics. In particular, `Agent` currently names `task`, while `spawn_agent`
names `spawn` and omits its wait option.

## Schedule an instruction

Use `deliver_at` on a queued Conversation input when the instruction should
enter that same conversation at a later time. It waits for that conversation's
turn boundary, uses the ordinary input lifecycle, and runs once. An absolute
timestamp permits exact request replay; `deliver_in` is resolved when the request
arrives, so resubmitting the same relative delay later changes its idempotency
envelope.

Use a [scheduled job](agent-api/v1/scheduled-jobs.md) for an independent execution
or a recurring instruction. The saved rule is `once`, `interval`, or `daily`.
Each occurrence creates a child conversation while the main conversation may
continue working; its original final result queues for the main conversation.
The schedule belongs to the main conversation, so stopping the turn that
created it does not cancel future occurrences.

A job permits one unfinished scheduled execution at a time. Missed occurrences
coalesce after downtime; a due occurrence is skipped while the previous one is
still unfinished. Pause stops future occurrences. Cancel additionally removes
the last scheduled input if it is still queued; an already-running child uses
the ordinary stop controls. A schedule marked `completed` has dispatched its
one-time occurrence, which may still be running or waiting for repair.

## How results reach the conversation

For a waited task, the continuation reads the result as the tool call's
paired answer. For detached task or compose work:

1. Turn-lifetime results enter a synthesizing continuation before the
   reply is final, once nothing that waits on them is still running.
   Launch-time `wait: true` and graph result reads may also consume
   conversation-lifetime results; the separate `wait` tool only observes.
2. Unconsumed conversation-lifetime background results wait for the original
   reply to finish, even if they complete early, then become a kernel-origin conversation
   input. It queues behind the running turn, if any. With `wake: "auto"`,
   it starts a new reply when idle; with `wake: "passive"`, it materializes a
   message-only turn that the next active input can read.
3. These kernel inputs drain before ordinary queued inputs. Each result is
   consumed in the loop or mailed, not both. Durable state and recurring
   recovery cover lost wake-ups and a temporarily full input queue.

A turn-owned spawned child's initial report settles its completion task. If
its immediate spawn wait remains open, the continuation reads the completion
result once as the call's answer. If the wait has expired or was canceled,
that wait keeps its own outcome and the report enters an in-loop continuation.
It does not also become next-Turn mail.

A cross-turn child's initial reply uses its request's parked spawn wait when
one remains open. Other cross-turn owed replies become child-origin mail if the parent
still exists and the request's originating execution was not stopped. A later queued `send` that opens a new child turn is a new
request: stopping the original
spawning turn does not permanently disable replies from that child, and
stopping the later request suppresses that request's reply. A steer that
lands in an existing child turn shares that turn's reply obligation; it does
not create another reply or change the originating execution.
The reply goes to the answerer of the execution that opened that child
turn, using that execution's model and request configuration. For example,
if Agent A spawns a child and a later Agent B turn sends it another request,
the later reply returns to B. The same rule preserves a later request's
configuration when A sends again with a different model. Delivery does not
select whichever agent happens to be active in the parent conversation.
Existing mail rules still apply: approval settings must remain at least as
strict as the profile's current settings, and a tool subset is inherited
only while it remains valid for that profile.

Only the reply to the initial spawn request can settle that spawn's wait.
A later `send` opens a separate obligation even if the original wait is
still open. A steer accepted into an existing turn retains that turn's
original recipient and configuration.

Already-arrived worker finals can share one supplementary reply when their
original requester, model, tools, approval policy, and execution memory context
match. The input queue groups only a bounded contiguous prefix, without waiting
for more workers or reordering incompatible receipts. Each source is checked
before consumption. Once multiple independent worker finals are consumed, the
receiving conversation owns their combined reply: stopping one worker afterward
does not retract its read result or stop that combined reply. Single-worker
replies and ordinary task/tool/compose receipts retain their source execution's
ownership.

The combined turn's `callback_sources` preserves every receipt and exact worker
result pointer. Read those fixed variants when delivering an individual worker's
formal result; the worker's later active variant and the combined parent report
are different content. See [kernel mail and callback provenance](agent-api/v1/conversations.md#inputs--the-one-front-door)
for the compatibility, size, and history-fit rules.

Automatic result-mail replies first use the originating execution's model. Passive
delivery requires no model lookup or model call. If the captured model is
unavailable, Nexus may switch once to the same receiving Agent's current
`default_model`, provided it names a different model. There is no global
candidate search and no switch to another Agent. The replacement uses its
own default reasoning setting; tools, approval policy and the received
result remain attached to the same execution.

Unavailability includes a missing or disabled provider/model, unusable
credentials, an actual provider HTTP 401/403/404, and exhaustion of the
existing retries for transient provider failures. Cancellation, execution
deadline expiry, content refusal and invalid request/input errors do not
trigger a switch. Context overflow keeps its existing compaction path.

The receiving mail turn uses a DAG loop even when the Agent has no tools.
The automatic switch is limited to its main reply path and is spent once
for that loop, rather than once per model round. Ordinary bounded transport
retries remain separate. If no alternative is available or it also fails,
the loop holds at `needs_attention` and exposes the failed task and reason.
The received result remains in the turn's prompt; a failed attempt does not
mean the child must run again.

This recovery covers model selection and execution. A separate input or
assembly refusal that prevents constructing the mail reply keeps the
existing message-only degradation: the result text remains readable, but
that message has no failed model task to retry.

If neither model was resolvable when the mail arrived, its request is
prepared on a later task retry. If history then exceeds the model's window
without a declared history budget, preparation holds with
`history_exceeds_fit` and leaves the request unsealed. This recovery path
does not start a separate conversation summary: retry with a larger-window
model, or declare the intended history budget before retrying. An explicit
budget permits trimming and reports it through `context_trimmed`.

Explicit task retry resumes only the failed node. It can name a new model,
and does not reset the automatic fallback allowance. Completed tools and
child requests stay completed. Regenerating the whole turn is a separate
operation that starts a new loop, so it is not the recovery mechanism for
preserving already completed work.

The loop and turn projections show the current main reply model. Each
invocation retains the model and sealed request it actually used; earlier
reasoning traces are not relabeled when a later node changes model.

Only replies to inputs sent by the parent are relayed to it. A person's
separate exchange with the child is not automatically copied back. If the
child's own background task starts another child turn through result mail,
that turn is not another parent request and is not automatically relayed
upward. A child's initial report includes work owned by that execution's
turn lifetime; it does not promise that explicitly cross-turn work has finished.

This result mailbox uses the ordinary Conversation input mechanism. It is
different from the executor inbox, where runners and tools providers claim
work and commit results, and from member notifications, which convey
awareness without an execution obligation.

A background question remains discoverable and answerable through its
originating loop and task key, including after a newer turn starts. It holds
that branch. With turn lifetime it also holds final delivery; with conversation
lifetime it permits an otherwise complete foreground reply to finish.
A foreground question still holds the reply. A standalone loop waits for
all its work because it has no conversation mailbox to receive a later
answer. An expired question retains the existing halt/adjudication behavior;
detachment does not turn an unanswered question into success.

## Normal completion and regeneration

A model response without tool calls ends that model round. It becomes the
final reply only when the loop's designated answer is complete and its
remaining foreground and turn-owned work permits completion. An outstanding
question or approval in that work still needs a decision. A halted failure needs
adjudication; a terminal task status alone does not make the loop successful.

Before final delivery, unread turn-lifetime results can add another model
round. Conversation-lifetime background results instead produce a separate
supplementary turn through mail, regardless of when they finish. Each synthesis
round reads earlier output and the new results, and can itself call tools and
create further turn-owned obligations. A candidate answer can
stream while work remains, but is not final until those obligations settle and
their results are consumed. Normal completion never cancels outstanding work.
Final delivery closes this path; subsequent cross-turn results use mail.
Later conversation history retains human answers to `ask` and background
results before the round that consumed them. A later delivery does not
replace the original task launch acknowledgement. Pruning preserves this
delivered material, and summarization reads it too; tool outputs remain
pointers in the summarizer's transcript.
An optional [Stop hook](lifecycle-hooks.md) can ask for feedback-driven
continuation before final delivery. Forced stop bypasses that decision.
Appending or retrying turn-owned work after delivery returns
`turn_already_delivered`, preserving the historical answer. An already accepted
append receipt still replays; it does not create new work.
Ordinary queued inputs wait for the turn boundary, while steers enter an
available model boundary or return to the queue when their target ends.

Regenerating a loop-backed answer creates a new candidate and a new loop
within the same Turn and permanently stops the replaced candidate's unfinished
work and undelivered derived results. Changing the selected variant has the
same cancellation consequence. Reading old candidates is inert, and selecting
one again does not revive its canceled work. Ordinary derived work stays owned
by the original loop and candidate, including its supplementary replies. The
combined worker report described above becomes the receiving conversation's
work only when it consumes those independent results.

## Wait for existing work later

The `wait` tool takes `task`, optional `agent_loop` (default: this loop), and
optional finite `timeout_ms`. The loop UUID and task key identify an existing
operation; a child Conversation UUID is not a task key. Hosted executions can
observe other loops in the same Conversation. Standalone loops observe their
own tasks. The SDK exposes an authored `wait` step; compose offers `g.wait`
with the same target fields. Its target is an existing task's actual key,
not a handle to another step in the current script.

Waiting follows the operation's logical result: model and compose expansions
settle at their final output, and a spawn waits for its exact initial request's
reply, rather than its launch acknowledgement. Race and quorum outputs retain
their selected winners; a later observer does not join run-out losers. A failed
race returns the partial winners it captured, then its failure.

An observer may start before or after completion. A timeout or cancellation
ends only that observer; it does not cancel the target. Repeated waits do not
rerun work, consume mail, or suppress the target's configured delivery. A
collected target returns an explicit failed observation. Direct self and
ancestor waits are refused; finite timeouts bound other waits.

For an asynchronous workflow that should reply only when explicitly asked,
start work with `wait: false, wake: "passive"`, retain its loop and task keys,
then invoke `wait` in the later turn. Leaving `wake: "auto"` enabled means
completion can also schedule its ordinary automatic reply independently.

## What the DAG expresses today

Tasks have durable identity, execution state, dependencies, and results.
The kernel constructs the edges; callers author ordered steps, structured
parallel groups, and references to earlier leaves or races.
The graph endpoint exposes the resulting nodes and edges
for inspection.

Position decides what a step waits on, never what it reads. A step reads
only what it is handed: a model step reads its prompt and the results its
`results` names, in that order, and nothing else — not the step before
it, not a group's members, not another step's conversation. The one
continued conversation is the loop's own: a top-level model step of a
member-authored envelope continues the loop's latest round, and a round
that called tools is continued by the kernel with those calls' results.

| Composition | Meaning |
| --- | --- |
| Ordered steps | Later work waits on the current frontier. Order reads nothing: a model step naming no `results` reads its prompt alone. |
| Parallel group, `until: "all"` | All dependencies must be satisfied. Absorbed or adjudicated failures can satisfy them; propagated failures skip dependents, and halted failures await adjudication. |
| Parallel group, `until: "any"` | One successfully completed branch satisfies the join. |
| Parallel group, `until: k` | The join requires `k` successfully completed branches. |
| Nested sequences and groups | A branch can perform multiple dependent operations while sibling branches run concurrently. |
| `after: [...]` | Adds dependencies without reading their results. Written-order dependencies still apply. |
| `results: [...]` on model or script | Adds dependencies and reads their final result envelopes in declaration order — the whole of what the step reads beside its prompt. Does not borrow their conversation history. A top-level model step naming the round it continues reads that answer once, in the history it replays, never also as an envelope. |
| A race in `after`/`results` | Waits on the race's barrier alone, never on a member, so nothing it names keeps a loser running. In `results` it reads what the race selected when it settled — a model step each selected result, a script one envelope-shaped slot (the first selected envelope, or the race's failure, with `selected` beside it). Naming a member instead waits on it and spares it as shared work; compose refuses that reference once the race has formed. |
| Script stage | Runs a pure calculation over selected results, returning JSON or building a finite subgraph with one final readable leaf. |
| Tool-using model branch | New rounds extend the branch. Its dependents wait for its final answer, not merely its first model response. |
| Detached subgraph | Internal dependencies remain intact while the parent continuation proceeds independently. |

An append request reads earlier appends by key, never by position: its
`after` and `results` may name any earlier task of the loop. Splitting
`diff → parallel(review, check) → checkpoint → summary` before `summary`
gives that model the same inputs as one envelope when the summary names
them — `results: [diff, review, check, checkpoint]`. Its top-level model
step still continues the loop's latest round. Detached work does not move
the loop's answer.

Of the work a `task` or `compose` call starts, or a detached step, every
result no step reads comes back to the caller — the waited continuation
reads it, or the wake or mail delivers it — one set whether or not the
call waits. A race's barrier stands for every task placed in its arms, an
expansion for the task it replaced, and a stage's internal steps stay
behind its boundary. A result comes back once nothing that waits on it
through written order is still running, so a chain comes back whole when
its last step settles.

Join success is an execution fact, not a judgment that an answer is correct.
An ordinary completed tool result can contain `is_error: true`, and a
completed model answer can be wrong. A workflow that needs business-quality
validation must express that validation; a race does not supply it.

A race reaches a reader only by name, and its selection is fixed when the
join settles: `results: [race]` reads the winning results, and a losing
branch that finishes later never enters them; when the race fails, the
partial winners it captured and then its failure envelope. A detached
subgraph ending at a race, an observer of the race and a step naming it all
get that same reading. A step after a race that names nothing reads its
prompt alone, and no task placed in a race's arms — an intermediate step,
a loser, a run-out loser's later rounds — comes back to the caller on its
own: nobody naming the race means its selection comes back, never an arm.
`results` naming a MEMBER instead wait for and read that producer's final
result, including a late race loser. Work required by another live consumer
is retained; its failure continues to follow its declared policy for that
consumer.

When failure policy allows a later model to continue, a failed model's status
and reason accompany any output it produced. If it failed before creating
a request, a round that continues it still inherits the earlier history and
tool results it would have read; the failed step does not erase them.

Model-authored compose races cancel losing work. The task API additionally
offers `losers: "run_out"`; its failure and retry controls are also broader
than compose's. A released race does not automatically detach foreground losers:
those rows can still hold final delivery while they run out. These surfaces share a compiler and scheduler, not an
identical option vocabulary.

A model-authored branch retains ordinary tool use but does not receive
`task` or `compose`, so bounded graph delegation has one level. It can retain
`spawn`, whose child conversations can delegate further. This is a current
policy distinction between graph branches and persistent collaboration.

## Compose construction and result-driven script stages

The first compose script builds tasks before they execute. It receives `g`
and `params`; each builder returns an identifying handle, not a result.
Ordinary JavaScript can filter or map known parameters, but a handle cannot
be interpolated into a prompt or tool input. The kernel owns all execution.

Every composed model step is a fresh agent: it reads its prompt and the
results handed to it, never what ran before it and never another step's
conversation. Use `results: [handle, ...]` on a model or script to hand it
earlier results, or `after: [handle, ...]` on any leaf to wait without
reading. `results` takes any array of handles, so `results: runs` names
every handle a `.map` built. A model step without `results` reads its
prompt alone, and the compose call's answer names each such step by its
script line. The member API and Ruby SDK use task keys instead of handles.
A compose script refers only to preceding leaves and races in its own
submission, never a future task, another call's task, another loop, or a
parallel group's join; a member-authored append may also name an earlier
append's task. These references add dependencies; they do not remove the
waits implied by written order.

For example, A captures a patch while B runs tests. C can review the patch as
soon as A finishes; D needs A and B but need not wait for C. Place the
producers and consumers as peers of the same group, each consumer naming
what it reads:

```javascript
const a = g.tool({key: "patch", name: "bash", input: {command: "git diff -- app lib test"}});
const b = g.tool({key: "tests", name: "bash", input: {command: "bin/rails test"}});
const c = g.model({key: "review", prompt: "Review the selected patch for correctness.", results: [a]});
const d = g.model({key: "assessment", prompt: "Assess the selected patch and test results.", results: [a, b]});
g.parallel([a, b, c, d]);
g.model({key: "report", prompt: "Combine the review and the assessment.", results: [c, d]});
```

C and D receive the same captured patch without rerunning it, and the report
reads C and D alone; A and B were theirs, so only the report comes back. A
named model result means its final answer after any tool rounds, not its
initial response or its conversation history; it carries the start of its
prompt, so two results handed to one step are told apart. A named script
result similarly follows the final leaf of its expansion. References do not
transfer the producer's lifetime or cancellation ownership to the consumer.

Two shapes cover most compose work. A chain per item is a group whose members
are sequences, `[run, review]`, so each item moves on as soon as its own step
is done; the group returns one chain per item, and a reader names each chain's
last step, `results: chains.map((c) => c[c.length - 1])`. A group that holds a
chain beside a single step, `g.parallel([[read, review], other])`, returns the
chain and the step, so its reader writes each chain's last step in its place:
`results: [review, other]`. A panel is a fan of verifiers or judges, each
briefed alone, and one reader that names them all — a model step, since
weighing them takes judgement. The compose description draws the door from
who reads the answers: when the calling model will read them itself, it makes
`task` calls, several in one message, and a long command whose result it
wants later is one `task` call, never a one-step compose. Compose is for
answers that must go on to further steps without passing through the caller:
a panel, a chain per item, or a question for a person in the middle of the
work.

Known lists can still use ordinary construction-time JavaScript. Filter the
values before calling builders: filtering returned handles does not remove
already placed tasks. Skip an empty group, since `g.parallel([])` is refused.

```javascript
const reads = params.files
  .filter(path => path.endsWith(".rb"))
  .map(path => g.tool({name: "read", input: {path}}));
if (reads.length > 0) {
  g.parallel(reads);
  g.model({prompt: "Summarize these Ruby files.", results: reads});
}
```

For a future result, place `g.script`. Its `script` is a separate JavaScript
function body evaluated only after its dependencies settle. It receives
`g`, `params`, and `results`. `results[i]` corresponds exactly to the i-th
entry of its declared `results` list. Each entry has `status`, `is_error`,
`output` (text), `content`, `structured_content`, and `error`. Check failure before parsing;
use the producing tool's documented structure for `structured_content`.
An entry naming a race (`results: [race]`) is the race's answer: the first
envelope it selected, or its failure, with `selected` listing every envelope
it hands a reader, first finisher first — a failed race's partial winners,
then its failure.

A script stage has two outcomes:

- Return a JSON value, including `null`, `false`, an empty array, or an empty
  object. It becomes the stage's structured result and canonical JSON text.
- Place tasks with `g` and return nothing. The generated graph must end in
  exactly one readable tool, model, ask, wait, or script leaf. Finish a fan or race
  with a reducer; a bare terminal fan or join is refused.

Here is a dynamic read-and-reduce workflow. It assumes the declared `ls`
tool returns `structured_content.paths` and `read` accepts `{path}`. Substitute
your tools' actual names and result contract. The outer script encloses the
listing as well, so the reporter receives only the reduced output:

```javascript
const scan = g.script({script: `
  const listing = g.tool({name: "ls", input: {path: "lib"}});
  g.script({results: [listing], script: \`
    const listing = results[0];
    if (listing.status !== "completed" || listing.is_error) {
      return {error: listing.error, output: listing.output};
    }
    const files = listing.structured_content.paths.filter(path => path.endsWith(".rb"));
    if (files.length === 0) return {files: []};
    const reads = files.map(path => g.tool({name: "read", input: {path}}));
    g.parallel(reads);
    g.script({results: reads, script: "return {files: results.map(r => ({status: r.status, text: r.output, data: r.structured_content, error: r.error}))};"});
  \`});
`});
g.model({prompt: "Summarize the selected file results, including failures.", results: [scan]});
```

A stage reads immutable selected results in a fresh bounded evaluation: no
clock, randomness, I/O, `async`/`await`, Promises, or durable JavaScript stack.
It cannot both return a value and build tasks. Exceptions or invalid output
settle through normal task failure policy. A synchronous `try`/`catch` can
handle a construction error, but cannot catch a later tool failure; inspect
that tool's envelope in another stage instead. A completed tool can still
carry `is_error: true`, so status alone does not establish success.
Returning an object such as `{error: ...}` is still a successful JSON result;
throw an exception when the stage itself should fail. Compilation refusals
identify the authored step and source line when available.

Each `g.script` task is a result boundary. The compose call's top-level `script`
only builds the graph; it does not create that boundary: every result no step
names comes back to the caller, so end the work with one step that names the
rest. The task's generated fan, model history, and intermediate outputs stay
local; only its returned value or final leaf's output reaches outside readers
or comes back. A tool placed before the task and named in its `results` is
consumed by it like any named result, so it does not come back either. When
the list itself is computed from results, place the entire listing, fan, and
reduction inside one enclosing `g.script` task, as in the example. A script
task does not become the surrounding conversation's history source or change
its current model.

Use a model step when selecting calls needs reasoning. It retains ordinary
tools and can issue multiple calls in one response, but its declaration
omits `task` and `compose`. A pure script stage supplies deterministic
selection without a model round; it is not recursive tool execution inside
JavaScript. A script's generated models use its frozen `model_defaults`:
model-authored compose captures the caller's request surface, while a member
supplies these defaults explicitly when generated model steps need them.
Tool-only stages and JSON calculations need no default model.

A compose worker can stop after committing its children but before reporting
success. Redelivery reuses those children. Without redelivery, the compose
call expires through its normal timeout; already committed children become
eligible to run. A waiting parent still waits for them and receives both the
compose timeout and their results. A script stage publishes its expansion,
consumer rewrites, and settlement together; repeated delivery cannot append
its children twice.

## Cancellation and external effects

Normal reply completion is not a stop. Explicit loop stop, branch cancel,
stopping a spawn wait, and stopping a conversation have different targets.
Conversation Stop cuts every existing execution owner in the addressed room,
including earlier turns' background work and completed sources with queued
results. It removes their pending supplementary inputs and cancels started but
undelivered supplementary replies. A combined worker report already consumed
by another conversation belongs to that receiving conversation and is stopped
there, not by stopping one of its sources. Published content stays readable.
New user inputs create new execution owners; ordinary queued user inputs are
retained. Scheduled jobs have their own pause/cancel controls; stopping the
conversation's current execution owners does not cancel its future schedule.

Derived work is canceled through its immutable sender loop/task, recursively.
This includes the original child request and its execution, not every request
later posted to that reusable child room. Authorization is checked on the
addressed conversation; derived cancellation neither rechecks the caller against
child access settings nor grants access to child content.

Canceling only a turn-owned delegation completion task retains its narrower
scope: its pending original input or unfinished original execution and its
unsettled turn-owned delegations. Canceling only the immediate wait leaves that
completion obligation intact. A whole-loop Stop cuts that execution's remaining
derived work even when a report has already settled.

Deleting the published brief before execution settles the obligation with
`delegation_abandoned`. A child held for repair stays outstanding. If an edit
replaces that held answer and makes its original execution unrepairable, Nexus
stops that original execution and reports non-success; the replacement remains.
Hard deletion of an original Turn still owing its report returns
`delegation_pending` until relay has preserved the result on the parent's task.

Background work does not gain immunity from explicit cancellation or Agent
removal. These operations do not undo side effects already performed by a
runner.

A background shell process is another kind of resource. Rho's process tools
currently have no interactive stdin/TTY, and completion notices are attached
to a subsequent tool result in the same conversation. Such a process exit
does not itself create the kernel task-result mail described above.

For exact parameters and cancellation outcomes, see the
[AgentLoop API](agent-api/v1/agent_loops.md),
[Conversation API](agent-api/v1/conversations.md), and
[executor protocol](agent-api/v1/executor.md).
