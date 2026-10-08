# Orchestration, task lifetime, and result delivery

Nexus separates a conversation's reply from all the work that reply started.
A turn can finish while its loop still owns background work. A child
conversation has its own turns and can remain useful after its first reply.
These are different resources, even when a client calls both of them agents.

## Choose the resource before choosing whether to wait

| Need | Mechanism | Ownership and result |
| --- | --- | --- |
| One delegated job with an empty context, or several (one call each, in one message) whose answers the caller reads itself | `delegate_task` | A model branch in the existing loop. Inherits the caller's request surface, with optional model selection and tool narrowing. Returns one branch answer. |
| Ordered, parallel, or result-driven operations whose results go on to further steps without passing through the caller | Agent-provided `code` tool, or the neutral task operation API | One parent task accepts child work in the existing loop, observes its results and returns selected final output. The Agent owns the language runtime; Nexus owns the tasks. |
| An agent to keep talking to, or another agent's configuration | `spawn` | A child Conversation. Its answerer owns its tools and policy; the parent can send further inputs. |
| Another conversation's participation | `send` | An input addressed to that conversation, optionally selecting its answerer. It does not create a task dependency. |
| Observe work that was already started | `wait` | A finite AwaitTask referencing a task key and its loop. It can observe earlier turns in the same Conversation without restarting or owning that work. |
| Work without a conversation transcript | Standalone AgentRun | An independently driven loop. It has no later conversation turn to receive background mail. |
| One-time or recurring work that should run independently of the current reply | Scheduled job | A saved instruction on the main Conversation. Each dispatched occurrence creates a child execution and returns its original result through the main Conversation's input queue. |

`delegate_task({prompt, model: "provider/model", wait: true})` selects a model for
that temporary job. Omission inherits the caller's configured lineage model. The
assignment changes neither the parent conversation's continuing model nor a named
Agent's profile. An unavailable explicit model is refused. The existing declared
fallback for classifier refusal or exhausted provider overload can still change
the executing model; an explicitly assigned task's result names both its requested
model and the actual model of its final owning round. The task read and model-change
events expose the selection as well. A named peer reached through `spawn` retains
its own documented answer-engine selection order.

A delegated task may delegate further when its inherited or narrowed declaration
still includes `delegate_task` or an alias. Each child begins with its brief and
receives only declared tools. A waited parent consumes the child's final answer
before it continues; nested branches retain the same Stop and result ownership.
Nexus imposes no delegation depth limit. Applications may guide preferred depth
through instructions and briefs.

Waiting and lifetime are independent choices on `delegate_task` and `spawn`:

| Options | Immediate continuation | Final reply |
| --- | --- | --- |
| `wait: false, lifetime: "turn"` | Continues alongside the work. | Waits for its result and a model round that consumes and synthesizes it. |
| `wait: true, lifetime: "turn"` | Waits at the call. | Still owes the result if a spawn wait expires or is canceled. |
| `wait: false, lifetime: "conversation"` | Continues alongside the work. | May finish before the work; the later result uses mail. |
| `wait: true, lifetime: "conversation"` | Waits at the call. | Existing wait dependencies still apply. |

Agent code uses its binding's ordinary wait syntax: rho uses `await` on an operation
Promise. Returning requires every attached operation to settle. Explicit
`nexus.background` transfers work to the same lifetime and wake machinery described
below; it does not invent a successful result for unfinished work.

`wait` defaults to false. Omitted `lifetime` inherits the enclosing work's
selection; ordinary reply roots default to `conversation`. Explicit selection
overrides inheritance, including choosing `conversation` inside turn-owned
work. Each member-authored DAG step can also select its own lifetime. A sibling's
override does not change later siblings' inherited default.
If a background branch explicitly starts turn-owned work, the final reply
still incorporates that result even when the branch itself may continue
afterward. A planned read by that background branch alone does not fulfill
the final reply's reporting obligation.

“Turn” ownership belongs to the concrete AgentRun execution producing the
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

An input with `delivery_mode: "steer_now"` can insert a model boundary ahead of
pending tools. The model reads a pending receipt for each unfinished call; those
tools retain their claims, lifetime and original join. Their actual results enter
the later consuming request once, and the turn still waits for its foreground work.

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

Use a [scheduled job](agent-api/v1/schedules.md) for an independent execution
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
paired answer. For detached tasks or work explicitly released by an operation owner:

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
original requester, model, tools, approval policy, execution memory context, and
frozen execution environment match. The input queue groups only a bounded
contiguous prefix, without waiting for more workers or reordering incompatible
receipts. Each source is checked
before consumption. Once multiple independent worker finals are consumed, the
receiving conversation owns their combined reply: stopping one worker afterward
does not retract its read result or stop that combined reply. Single-worker
replies and ordinary task/tool receipts retain their source execution's
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

The `wait` tool takes `task`, optional `agent_run` (default: this loop), and
optional finite `timeout_ms`. The loop UUID and task key identify an existing
operation; a child Conversation UUID is not a task key. Hosted executions can
observe other loops in the same Conversation. Standalone loops observe their
own tasks. The SDK exposes an authored `wait` step. Agent code can submit that
same step through `nexus.steps`. Its target is an existing task's actual key,
not a JavaScript Promise or operation key.

Waiting follows the operation's logical result: a model branch or operation-owning tool
settles at its final output, and a spawn waits for its exact initial request's
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
| `results: [...]` on a model step | Adds dependencies and reads their final result envelopes in declaration order — the whole of what the step reads beside its prompt. Does not borrow their conversation history. A top-level model step naming the round it continues reads that answer once, in the history it replays, never also as an envelope. |
| A race in `after`/`results` | Waits on the race's barrier alone, never on a member, so nothing it names keeps a loser running. In `results` a model reads each result selected when the race settled. The observed race outcome carries its selected results beside its status. Naming a member instead waits for and reads that member as shared work. |
| Task operations | A claimed tool accepts child operations and records observations while its live handler waits under the same renewable claim. Its own final result is the readable boundary; internal child results stay inside unless explicitly released to background delivery. |
| Tool-using model branch | New rounds extend the branch. Its dependents wait for its final answer, not merely its first model response. |
| Detached subgraph | Internal dependencies remain intact while the parent continuation proceeds independently. |

An append request reads earlier appends by key, never by position: its
`after` and `results` may name any earlier task of the loop. Splitting
`diff → parallel(review, check) → checkpoint → summary` before `summary`
gives that model the same inputs as one envelope when the summary names
them — `results: [diff, review, check, checkpoint]`. Its top-level model
step still continues the loop's latest round. Detached work does not move
the loop's answer.

Of the work a `task` call or detached step starts, every result no step reads
comes back to the caller — the waited continuation
reads it, or the wake or mail delivers it — one set whether or not the
call waits. A race's barrier stands for every task placed in its arms, and a
model expansion for the task it replaced. An operation-owning tool's attached children
stay behind its own final-result boundary. A result comes back once nothing
that waits on it through written order is still running, so a chain comes back
whole when its last step settles.

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

Task groups and operation joins support `losers: "cancel"` or `"run_out"`.
A released race does not automatically detach foreground losers: those rows can
still hold final delivery while they run out. JavaScript `Promise.race` only
selects an observed outcome; use the explicit join, cancel or background helper
to choose what happens to outstanding work.

A model-authored branch retains ordinary tool use but does not receive `task`,
so graph delegation has one level. It can retain `spawn`, whose child
conversations can delegate further. rho additionally omits its own `code` tool
from code-created tool calls and model declarations. That binding policy is
owned by rho; the kernel has no concrete Agent or language-runtime names.

## Agent code and result-dependent work

An Agent can provide a tool whose implementation orchestrates child operations outside Nexus.
rho supplies `code`, an ordinary JavaScript async function body with immutable
`params`, declared `tools`, and the `nexus` helper object. Awaiting a call gives
its recorded outcome, so later work can depend on real results without another
model round. No graph-building handles or nested script steps are required.
Other Agents can implement the same neutral protocol without JavaScript.

rho's `code_mode` setting defaults to `on`; a conversation or request can override
it. Off omits the code tool and its authoring hint from new rho-authored turns.
Executor support stays registered for already accepted work. This is application
policy over ordinary tool selection; the Nexus task operation API has no code-mode
switch. See the [rho usage guide](rho-usage.md#choose-code-mode) for controls.

The following body captures a patch and runs tests concurrently. Review starts
as soon as the patch arrives; assessment waits for both producers. The reporter
receives the review and assessment, and only its selected output returns to the
calling model. Tool names and input fields must match the execution's declarations.

```javascript
const patch = tools.bash({command: "git diff -- app lib test"});
const tests = tools.bash({command: "bin/rails test"});
const review = patch.then(result => nexus.model({
  prompt: "Review this patch for correctness, including any capture failure:\n" + JSON.stringify(result),
}));
const assessment = Promise.all([patch, tests]).then(results => nexus.model({
  prompt: "Assess the patch and test outcomes:\n" + JSON.stringify(results),
}));
const findings = await Promise.all([review, assessment]);
const report = await nexus.model({prompt: "Combine these findings:\n" + JSON.stringify(findings)});
text(report.output || JSON.stringify(report));
```

`nexus.model` inherits the parent's frozen model defaults and permitted tools;
an operation may narrow tools but cannot add undeclared ones. Each generated
model starts from its supplied prompt and selected named results, not the
surrounding conversation's history. Use the ordinary public `results` field on
model steps inside an atomic `nexus.steps` batch to reference earlier task keys.
Those references preserve producer lifetime and cancellation ownership.

Ordinary JavaScript can select further work after any observation. This example
assumes `ls` returns `structured_content.paths` and `read` accepts `{path}`:

```javascript
const listing = await tools.ls({path: "lib"});
if (listing.status !== "completed" || listing.is_error) {
  text(JSON.stringify(listing));
  return;
}
const paths = listing.structured_content.paths.filter(path => path.endsWith(".rb"));
const results = await Promise.all(paths.map(path => tools.read({path})));
const selected = results.map((result, index) => ({
  path: paths[index], status: result.status, is_error: result.is_error,
  output: result.output, structured_content: result.structured_content,
  error: result.error,
}));
text(JSON.stringify(selected));
```

Every tool outcome retains status, error flags, text/resource content and
structured-value presence. A completed tool with `is_error: true` remains a
resolved value; inspect it before selecting later work. Recorded operation
refusals reject and can be caught; transport failure, cancellation and an
unsupported runtime binding remain host control. Returning JSON selects
structured output, while `text` selects model-visible text. `resource` selects
an authorized resource link. Intermediate results remain internal unless the
program includes them in its final output.

`Promise.all` waits for all inputs and returns their input order. `Promise.race`
uses recorded observation order and leaves losing work outstanding. Before a
successful return, settle all operations or explicitly transfer ownership with
`nexus.background({operation_key, lifetime, wake})`. `nexus.join` names operation
keys and an all/any/quorum policy; `nexus.cancel` requests cancellation.
`nexus.steps` accepts one atomic batch. `nexus.replace` may replace only the
parent's accepted future work that has not started; completed effects and
recorded observations are never rewritten.

The parent retains its live handler, claim and cancellation owner while waiting.
Its executor yields local capacity so child work can progress, observes results, and
renews the ordinary task deadline before expiry. Losing an acceptance response can
be resolved by retrying the same operation identity. Losing the handler or VM does
not automatically replay source: absent adapter-supported reconnection to the same
external work, the task follows its ordinary failure or uncertain-effect path.
The parent publishes its selected final result; accepted background work uses the
ordinary lifetime and mail rules above.

rho evaluates bounded source in a fresh VM with no filesystem, network, module
loader, clock or randomness. Its declared schema records the supported JavaScript
binding identity; a later incompatible interpreter refuses the old task before
new effects and requires newly authored work. Nexus stores those declarations
without interpreting the language. Standalone code tasks require an eligible
executor and explicit model defaults when they need model work; there is no
kernel interpreter fallback.

See the [task operation API](agent-api/v1/executor-operations.md) for
acceptance, observation and finalization, and
[rho-codemode](../agents/rho/rho-codemode/README.md) for JavaScript helpers and
runtime limits.

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
retained. Schedules have their own pause/cancel controls; stopping the
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
[AgentRun API](agent-api/v1/runs.md),
[Conversation API](agent-api/v1/conversations.md), and
[executor protocol](agent-api/v1/executor.md).
