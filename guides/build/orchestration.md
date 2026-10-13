# Orchestration

Nexus separates a conversation's reply from all the work that reply started. A turn can finish while its run still owns background work; a child conversation has its own turns and can remain useful after its first reply. Choose the resource before choosing whether to wait.

## Choose the resource

| Need | Mechanism | Ownership and result |
| --- | --- | --- |
| One delegated job with an empty context, or several in one message, whose answers the caller reads itself | `delegate_task` | A model branch in the existing run. Inherits the caller's request surface, with optional model selection and tool narrowing. Returns one branch answer. |
| Ordered, parallel or result-driven operations whose results feed further steps without passing through the caller | The agent's `code` tool, or the task operation API | One parent task accepts child work, observes results and returns selected output. The agent owns the runtime; Nexus owns the tasks. |
| An agent to keep talking to, or another agent's configuration | `spawn` | A child conversation. Its answerer owns tools and policy; the parent can send further inputs. |
| Another conversation's participation | `send` | An input addressed to that conversation, optionally selecting its answerer. No task dependency. |
| Observe work already started | `wait` | A finite await of a task key in a run. Observes without owning or restarting. |
| Work without a conversation transcript | Standalone run | An independently driven loop with no later turn to receive mail. |
| One-time or recurring work independent of the current reply | [Schedule](schedules.md) | A saved instruction; each occurrence runs in a child conversation and reports back. |

`delegate_task({ prompt, model, wait })` selects a model for that job; omission inherits the caller's lineage model. A delegated task may delegate further when its declaration still includes `delegate_task`; Nexus imposes no depth limit. A model-authored branch retains tool use but does not receive `task`, so graph delegation from a model has one level; it can retain `spawn`.

## Waiting, lifetime and wake

Waiting and lifetime are independent choices on `delegate_task` and `spawn`:

| Options | Immediate continuation | Final reply |
| --- | --- | --- |
| `wait: false, lifetime: "turn"` | Continues alongside the work | Waits for the result and a model round that consumes it |
| `wait: true, lifetime: "turn"` | Waits at the call | Still owes the result if a spawn wait expires or is canceled |
| `wait: false, lifetime: "conversation"` | Continues alongside the work | May finish first; the later result arrives as mail |
| `wait: true, lifetime: "conversation"` | Waits at the call | Existing wait dependencies still apply |

`wait` defaults to false. Omitted `lifetime` inherits the enclosing work's selection; ordinary reply roots default to `conversation`. `wake: "auto" | "passive"` (default `auto`) controls completion mail after final delivery: `passive` makes the result readable history without starting a reply.

## How results come back

- A waited call reads its result as the tool call's paired answer.
- Turn-lifetime results enter a synthesizing model round before the reply is final.
- Unconsumed conversation-lifetime results wait for the original reply to finish, then become a kernel-origin input in the same conversation. It queues behind a running turn and drains before ordinary inputs; with `wake: "auto"` it starts a new reply when idle.
- Each result is consumed in the loop or mailed, not both. Durable state and recurring recovery cover lost wake-ups.

A mail reply uses the originating execution's selected model, captured ordered fallback list and model-selection constraints. It has no additional current-default fallback. If recovery is exhausted, the run holds at `needs_attention` with the failed task and reason, and the received result stays in the prompt. An explicit retry retains spent route budgets and the original deadline; see [Model selection and recovery](../reference/agent-api/models.md#model-selection-and-recovery).

Only replies to inputs sent by the parent are relayed to it. A person's separate exchange with a child is not copied back. Already-arrived worker finals with matching requester, model, tools, approval policy and context can share one supplementary reply; the receiving conversation then owns that combined reply.

## Normal completion and regeneration

A model response without tool calls ends that round. It becomes the final reply only when the designated answer is complete and remaining foreground and turn-owned work permits completion. Outstanding questions, approvals and halted failures still need a decision. Normal completion never cancels outstanding work; later cross-turn results use mail.

Regenerating a run-backed answer creates a new candidate and run and permanently stops the replaced candidate's unfinished work. Selecting an old candidate again never revives it.

## The DAG

Callers author ordered steps, parallel groups and references to earlier leaves or races; the kernel constructs the edges. Position decides what a step waits on, never what it reads: a model step reads its prompt and the results its `results` list names, in that order, and nothing else.

| Composition | Meaning |
| --- | --- |
| Ordered steps | Later work waits on the current frontier |
| Parallel group, `until: "all"` | All dependencies must be satisfied; propagated failures skip dependents, halted failures await adjudication |
| Parallel group, `until: "any"` or `until: k` | One, or `k`, successfully completed branches satisfy the join |
| `after: [...]` | Adds dependencies without reading results |
| `results: [...]` on a model step | Adds dependencies and reads their final result envelopes in order |
| A race in `after` or `results` | Waits on the race's barrier and reads its selected winners; naming a member waits for that member instead |
| `losers: "cancel"` or `"run_out"` | What happens to a race's outstanding branches |

Join success is an execution fact, not a judgment that an answer is correct: a completed tool result can carry `is_error: true`, and a completed model answer can be wrong. Envelope caps: 64 steps per request, 32 members per fan, 33 reads per model step, 1 MiB payload.

## Agent code

An agent can provide a tool that orchestrates child operations outside Nexus. rho supplies `code`: a JavaScript async function body with immutable `params`, declared `tools` and a `nexus` helper. Awaiting a call gives its recorded outcome, so later work can depend on real results without another model round.

```javascript
const patch = tools.bash({command: "git diff -- app lib test"});
const tests = tools.bash({command: "bin/rails test"});
const review = patch.then(result => nexus.model({
  prompt: "Review this patch for correctness:\n" + JSON.stringify(result),
}));
const assessment = Promise.all([patch, tests]).then(results => nexus.model({
  prompt: "Assess the patch and test outcomes:\n" + JSON.stringify(results),
}));
const findings = await Promise.all([review, assessment]);
const report = await nexus.model({prompt: "Combine these findings:\n" + JSON.stringify(findings)});
text(report.output || JSON.stringify(report));
```

`nexus.model` inherits the parent's frozen model defaults and permitted tools; an operation may narrow tools but never add undeclared ones. Every tool outcome keeps its status, error flag and content; inspect `is_error` before selecting later work. Before returning, settle all operations or transfer ownership with `nexus.background({ operation_key, lifetime, wake })`; `nexus.join`, `nexus.cancel`, `nexus.steps` and `nexus.replace` cover joins, cancellation, atomic authored batches and replacing not-yet-started future work. Other agents can implement the same neutral task operation protocol in any language.

## Cancellation

Normal reply completion is not a stop. Conversation **Stop** cuts every existing execution owner in that conversation, including earlier turns' background work, and removes pending supplementary inputs. Derived work is canceled through its immutable sender run and task, recursively, without rechecking the caller against child access. Schedules have their own pause and cancel; stopping the conversation's current execution does not cancel future occurrences. Cancellation never undoes side effects a runner already performed.

## Wait for existing work later

`wait` takes `task`, optional `agent_run` (default: this run) and a finite `timeout_ms`. It follows the operation's logical result — a branch settles at its final output, a spawn at its exact initial request's reply. A timeout or cancellation ends only the observer. For a workflow that should reply only when asked, start work with `wait: false, wake: "passive"`, keep the run and task keys, and `wait` in a later turn.
