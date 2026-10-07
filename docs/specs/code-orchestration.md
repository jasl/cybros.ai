# Code orchestration specification

Status: accepted semantic specification. The first transport binding is implemented
under the [executor task API](../agent-api/v1/executor.md); the first language host is
[rho-codemode](../../agents/rho/rho-codemode/README.md). The
[task operations API](../agent-api/v1/executor-operations.md) defines its public binding.

## Purpose and scope

An Agent application requests work from Nexus, observes its results, and decides what
to do next. It may evaluate model-authored code or use another orchestration strategy.
Nexus owns durable execution and general task-graph operations. The application owns
the programming interface, language, model-facing adaptation and orchestration strategy.
This specification replaces compose without requiring any particular application,
programming language, VM, SDK, database schema or queue.

**MUST**, **MUST NOT** and **MAY** express conformance requirements. Names in the
logical operations below describe semantics, not HTTP paths, method names or new
domain entities. An execution is the existing owning task; an operation and observation
are subordinate facts, not independently managed workflows.

The general Nexus API MUST be usable without codemode. Its task-scoped acceptance,
bounded batch submission, controlled replacement of future work, observation and
lifecycle operations MUST NOT require program source, a language selector, a code-tool
invocation or rho-specific state. Code execution adds the definition and isolation
obligations below at its owning task; it does not create a separate graph authority.

The [JavaScript binding](code-orchestration-javascript.md) defines the first language
surface. Another language can supply a different binding against this same contract.
No implementation is required to emulate JavaScript, Promise objects, microtasks,
Ruby classes or a particular VM's saved stack.

## Roles and authority

| Role | Responsibility |
| --- | --- |
| Agent controller | Chooses orchestration strategy and requests general task operations, with or without model-authored code |
| Program | Requests operations, consumes observed outcomes and computes output through a language binding |
| Language host | Evaluates the program and retains its live control flow while awaiting outcomes |
| Nexus execution owner | Accepts operations, records observations, owns child work and final disposition |
| Task executor | Performs accepted work through the existing addressed task and claim protocol |

The language host MUST NOT perform a program's external effects outside the declared
bridge. All consumers of these child-work operations MUST use task-scoped executor
authority. Nexus MUST derive parent ownership,
execution principal, origin, frozen declarations/defaults and applicable lifecycle
from that authority. A client cannot choose arbitrary parent nodes, graph edges or a
more privileged origin, substitute another execution's result for this operation's
outcome, or bypass result-read authorization. Explicit kernel read/wait operations
may observe other executions within their existing authorized scope.

Model-generated operations MUST retain model origin and their ordinary approval
rules even when a trusted Agent program submits them. Member-authored execution
retains its own declared origin; transport identity is never a way to change it.
Canonical tool identity and providing authority MUST survive language-level naming.
Discovery changes visibility, not the authorized callable set.

The same contract MUST serve conversation work and standalone/member-authored
workflows. A program has an eligible addressed language host. An unserved capability
fails explicitly; an announced but disconnected host uses normal delivery/deadline
recovery. Presence is not an admission gate. There is no kernel-runtime fallback.

## Durable facts and values

The execution owner MUST retain these facts while their owning execution and result consumers require them:

| Fact | Meaning and consumer |
| --- | --- |
| Code execution definition | For code execution, original source or executable definition, binding identity, parameters and frozen execution context; consumed by the host for this invocation. General graph operations do not require source or a language |
| Operation identity and request | Stable execution-local identity plus normalized semantic request; consumed by acceptance retries and receipt reconciliation |
| Acceptance or observable refusal | The accepted task reference, or a binding-visible deterministic refusal; consumed without submitting a second operation |
| Observations | Ordered references to the outcomes actually exposed to the program, including observable refusals; consumed in that order by the live host, including after response loss |
| Outstanding ownership | Existing tasks and their lifecycle relationships; consumed by observation, Stop and finalization |
| Final output and disposition | The existing task's write-once result; consumed by its caller, history and result delivery |

Parameters and ordinary structured values use the existing public JSON value domain
and limits. Content/media use existing content and authorized upload references.
Language-native objects, closures, exceptions, pointers and database ids MUST NOT be
required protocol values. Operation keys are local coordinates; externally referenced
Nexus resources use their existing public identifiers.

Editing the program definition creates a new execution. The live invocation MUST use
the accepted definition and context, not a mutable file or a new tool mapping. Binding
identity identifies language semantics; it is not a host fingerprint or a claim of
package integrity. An incompatible definition/binding change fails closed and uses
ordinary retry/replanning rather than silently changing unfinished computation.

Existing child task results are the authority for their values. An observation MUST
reuse that authority rather than create another result ledger. Local VM state owns
in-process control flow; it does not replace Nexus as the authority for accepted work,
observations, child disposition or committed results.

## Logical operations

The transport binding MUST implement the following semantics within the existing
task/inbox and content authorities. It may combine compatible operations in one
request without changing the rules below.

### Accept work

Input is an execution-local operation identity, an operation target and its semantic
arguments/policy, under the active parent claim. Nexus MUST atomically accept the
identity/request and its child work. Work MUST NOT become executable before that
acceptance is durable.

- An exact retry of an accepted identity recovers the same accepted operation/task.
- Reusing an identity with a different semantic request MUST NOT create or modify work.
- A response lost after commit MUST be recoverable without creating another child.
- A business refusal exposed to the program and usable for subsequent decisions MUST
  be recorded as an observation-capable outcome, even when no child task was created.
- Invalid transport/authentication and stale-claim responses are execution-control
  failures, not ordinary program outcomes that grant permission to continue.

The scope is the execution, not the current HTTP request. Reading a receipt does not
reset operation identity or consume an external task's retry budget. Two executions
can intentionally request the same work; this contract prevents accidental duplication
while reconciling one execution, not all repeated user work. Durable operation receipts
do not authorize automatic re-execution of a lost program or arbitrary tool handler.
It does not promise exactly-once remote IO; an effect with an unknown outcome still
requires the existing task's reconciliation/adjudication policy.

### Accept a batch of child work

A consumer MAY submit a bounded set of child requests and their logical placement,
dependencies and result reads as one operation. Nexus MUST accept the complete child
subgraph and its operation identity atomically, or accept none of it. No member may
become executable before the whole accepted batch is durable. Exact retry recovers
the same acceptance and child references; changed content under the same identity
MUST NOT add or modify work.

The public shape expresses kernel task semantics, including sequencing, parallel
work and named joins/reads. It MUST NOT expose raw edge writes, scheduler internals or
arbitrary edits to another execution. Nexus resolves scoped logical references and
derives the graph. Request byte/shape limits bound one submission; they do not impose
a cumulative work ceiling. Atomic batch acceptance does not promise atomic external
effects: each accepted task keeps its ordinary approval, dispatch and result lifecycle.

Single acceptance and batch acceptance use the same child-work authority and semantics.
A batch can encode work already known by the Agent; later observations can lead to
another batch. Neither the general API nor a language binding requires every ordinary
tool call to be compiled into a complete graph in advance.

### Replace unstarted downstream work

An Agent MAY use an observation to replace a scoped portion of its own accepted future
work with a new bounded child subgraph. This is a named task operation, not arbitrary
graph editing. Nexus MUST atomically record its operation identity, retire the selected
old future work and publish the replacement, or leave the original work unchanged.
Replacement tasks have their own identities; the request does not rewrite the old
tasks' definitions or reuse their execution identities.

Every affected old task and every consumer whose future dependency/read is changed
MUST still be unstarted. Work dispatched or claimed for execution, an external effect
already initiated, and completed or consumed results are outside the replacement
boundary. The operation MUST preserve prior results, observations, usage and historical
facts. It cannot alter a running task, retract a delivered answer or rewrite its
execution's earlier decisions. Explicit cancellation of started work remains a
separate lifecycle operation with its existing uncertainty about effects.

Replacement and ordinary task start MUST have a single authoritative winner: either
the old work starts and replacement refuses without partial mutation, or replacement
wins and that old work cannot start. Nexus MUST validate the complete affected scope
and resulting dependencies before publication. Unaffected tasks retain their identity,
ownership and behavior; replacement cannot silently rewire an already-started consumer
or leave a surviving future consumer reading a retired task.

Lost-response reconciliation uses the same replacement identity and recover its
recorded outcome. An exact retry never retires a different set or adds another batch.
Each operation retains the result task identities accepted in its own receipt. If
replacement retires an original operation's terminal result task, observing that
original operation reports the retired task's cancellation; observing the replacement
reports the newly accepted work. Rewriting an unstarted downstream consumer's reads
does not rebind an already accepted operation to different result identities.
This capability changes pending work within an execution; editing accepted program
source still creates a new execution under the definition rule above.

### Observe an outcome

An outcome becomes observable only after its observation position is durable. Nexus
MUST preserve one causal order of program-visible external observations and accepted
operations for that execution. An implementation may use an equivalent partial-order
representation internally, but its language host MUST receive an unambiguous order.

Task completion order and timestamps do not establish observation order. If two
children are already complete, their first delivery establishes the program's order;
receipt reconciliation MUST retain it. A callback that issues more work becomes part of the same
causal history. A host MUST NOT expose a speculative result and persist its chosen
order afterward.

Re-reading a recorded observation returns the same outcome/reference. Receipt loss
after observation publication does not choose a different next result. A live host
recovers the saved observation and delivers it to its existing control flow; it MUST
NOT publish another durable observation or repeat the operation's external effect.

An outstanding task remains outstanding. Transport loss, missing output or a timeout
in the host is not a successful, failed or safely retryable task result. Reconcile
with the authoritative task. Preserve its real terminal outcome, including uncertainty
about an effect that may have escaped.

### Waiting and execution ownership

A program awaiting an external outcome retains its ordinary ToolTask claim and live
language state. Waiting MUST yield the local scheduling capacity its own children need.
The host MUST prove progress with one worker and with every configured worker initially
hosting a waiting parent. Increasing worker count alone does not satisfy this rule.
Nexus accepts, schedules and settles children through the same task lifecycle.

The original claim token, execution owner and deadline remain authoritative throughout
waiting. The host uses finite observation waits, ordinary bounded deadline extensions,
and the existing cancellation path. A failed control request grants no extension.
Queued handlers MUST NOT renew before starting. Extensions do not grant new child-work
authority or survive Stop, claim loss or the applicable execution fence.

CPU, memory and input bounds constrain individual evaluation and transport operations;
waiting time is not cumulative interpreter CPU time. A waiting parent retains its
execution context and owned resources while yielding worker capacity. This requires no
second tool category, suspend/rearm protocol, task clock or scheduler.

If the live language state or execution owner is irretrievably lost, the invocation
uses ordinary failure, timeout or uncertainty handling and its existing retry/adjudication
policy. Nexus MUST NOT automatically rerun its source or handler. An external-work
adapter MAY explicitly reconnect to work already owned by its native service, using
that service's existing identity; that capability is not a generic replay promise.

### Finalize

An execution publishes one final output/disposition through its task owner. An exact
retry recovers that committed result; a different final result cannot replace it.
Receipt reconciliation MUST NOT duplicate final result delivery or durable user-visible output.
Transient progress may be best effort under the existing progress contract.

Success requires every accepted child to be settled or explicitly assigned to the
existing background lifetime/delivery mechanism. Accidental outstanding work prevents
successful completion. Failure stops further acceptance and cancels ordinary attached
unfinished work through its owner; completed effects, uncertain outcomes and explicit
background obligations retain their truthful facts and existing ownership.

Requesting cancellation is not proof of no effect. Terminalizing a parent does not
erase a still-owed child disposition, usage receipt or result-delivery obligation.

## Outcomes, control flow and lifecycle

| Situation | Required treatment |
| --- | --- |
| Determinate admission refusal | No child was accepted for that operation; record the refusal if the program can observe it and continue |
| Acceptance response lost | Acceptance is unknown to the host; reconcile using the same operation identity |
| Child effect is uncertain | Keep the accepted task and its explicit outcome; use its existing reconciliation/adjudication path |

The outcome distinguishes execution status, tool error data, content/structured value,
and any execution error. A tool's `is_error` flag MUST NOT silently become a lifecycle
command. A language binding MUST define how this envelope maps to values or typed
errors and MUST retain the original task/outcome identity. An uncertain outcome MUST
remain distinguishable; neither recovery nor the bridge automatically retries it.

Only binding-visible outcomes belong in program control flow. Unknown transport state,
lost authority and Stop remain host/execution control. Deterministic bridge refusals
that a program can handle and continue from MUST be recorded like other observations.
Pure language errors fail that invocation without inventing another task.

Bindings MUST define the supported concurrency behavior and explicit disposition of
losers/outstanding calls. The core does not prescribe a language's promise, future,
exception or scheduling semantics. Joining all, selecting the first observed outcome,
quorum, cancellation and explicit background ownership remain kernel capabilities;
a syntax choice cannot silently drop children.

Waiting, execution lifetime and callback wake are separate axes. Turn-owned work
retains final-reply obligations; conversation-owned background work remains owned by
the original execution. Pause, Stop, origin-variant replacement and deadlines use
existing lifecycle fences. After its applicable fence, a host MUST NOT accept/start
new work or revive the parent/callback from a late result. Already-in-flight effects
settle truthfully rather than being promised away.

Model work, addressed asks, tool approval and delegation MUST keep their existing
authority, usage, addressing and result contracts. A language frontend does not create
a second provider client, approval system or result-mail scheduler.

## Language state and isolation

A language host retains one live invocation across external waits. It MUST stop before
issuing further work after losing its claim or executable state. Recorded operations
and observations reconcile transport ambiguity; they do not reconstruct the program's
locals, stack or effects after process death. Explicit retry creates an ordinary new
attempt under the task's existing effect and approval policy.

Bindings MUST document their available language APIs and resource bounds. External
IO and observations go through declared operations or frozen inputs. A binding may
exclude ambient time, randomness and module loading to keep its programming surface
small without promising deterministic source replay.

The protected assets are host credentials/files and external effects governed by the
declared tool/approval surface. Untrusted program source and external content can
choose code and arguments; the language execution environment and host bridge are their
boundary. The installed
Agent package and operator are trusted. A conforming host MUST prevent source from
bypassing that bridge or reading host credentials directly, while allowing declared
Runner tools through their ordinary approval path. This is not a filesystem allowlist
over the user's legitimate Runner tools.

## Conformance scenarios

Each language binding and production adapter MUST exercise equivalent observable
scenarios. The notation below is abstract work, not executable JavaScript or an API.
`A`, `B`, and `C` are operation identities local to one execution.

| Scenario | Required observation |
| --- | --- |
| Accept A; lose response; recover its receipt in the live invocation | Same accepted task; no additional external dispatch or approval bypass |
| Resubmit A with different arguments, or edit the accepted definition | No divergent work accepted under the old identity/execution |
| Submit a batch containing A and B; lose its response and retry | One durable acceptance and the same children; no partial batch becomes executable |
| Refuse one member of a batch during acceptance | No child from that batch is accepted or dispatched |
| Observe A; replace unstarted B with C; lose the response | A and its observation remain unchanged; B cannot start; the same C and replacement outcome are recovered |
| Replacement races with B starting or names a started/consumed task | Either valid replacement wins before start, or the complete replacement refuses without changing existing work |
| A consumer without source or a language binding submits and replaces future work | It uses the same general task authority, results and lifecycle as a code host |
| Accept A and B; observe B then A; B's callback requests C | The live VM preserves B-before-A and C's causal position, independent of storage/query ordering |
| Persist observation of B; lose the HTTP response before local delivery | Receipt recovery observes B at that position in the same VM; no second observation or changed race winner |
| Record a bridge refusal and branch from it | The saved refusal is delivered once without asking a changed live rule to decide again |
| Lose the VM or process while waiting | No automatic source replay or new dispatch; the original task follows ordinary failure/timeout and child disposition |
| A has no output after a lost connection | Reconcile its authoritative outstanding or terminal outcome; missing output alone never authorizes a replacement effect |
| A completes with null, false or is_error data | The value/error data remains distinguishable from missing output or execution failure |
| Parent waits on child or human approval with one worker; all workers host waiting parents | Waiting yields scheduling capacity, children progress, and every parent's context and resource ownership remain intact |
| A started handler waits across successive finite deadline grants | Ordinary extensions keep the same invocation alive; queued handlers and failed control reads cannot renew |
| Deny approval; or Stop before new acceptance | No unapproved/new post-fence work starts; a late observation cannot revive control flow |
| Return while an attached child remains outstanding | No success that silently abandons the child; explicit background ownership is distinct |
| Commit final result; lose response; recover the receipt | One durable final result and delivery; no duplicated output, work or usage |
| Standalone invocation lacks a served host | Explicit failure; no fallback language interpreter inside Nexus |
| Retention runs while a parent still owns child work | Required operation, observation and result references remain available |
| Program attempts host IO/credential access outside the bridge | Access is unavailable; permitted declared tool work still follows ordinary approval |

Different bindings pass by their public operation/outcome traces and lifecycle facts,
not identical source, intermediate locals, graph node counts or scheduler timing.
Shared language-neutral fixtures and contract tests belong with implementation; they
must not require Ruby source inspection or a JavaScript VM for a non-JavaScript client.
No second-language implementation is required merely to deliver the first binding.

## Transport binding and readiness

Before production use, the Agent API binding MUST document routes, authentication,
request/response shapes, identity scope, equality rules, limits, refusal/status mapping,
atomic batch and future-replacement scope, observation publication, claim ownership,
finite waits, deadline extension and lost-state failure. Kernel, SDK, fixtures and public
manuals must implement that binding together. This semantic spec does not authorize
inventing `steps` inside today's opaque executor result or treating member append as
task-scoped child acceptance.

The replacement is usable only after these conformance cases and the complete
tool/model/ask/delegation, atomic batch, future-replacement, concurrency, lifetime/wake,
result/media and retention
capabilities work through the production boundary. Graph publication alone is
insufficient. Deterministic public-API tests establish that boundary; optional bounded
model diagnostics inform authoring quality and do not become a paid release gate.

For supported models and tasks, including weaker models in that supported set, the
authoring acceptance floor is the ability to produce an acceptable, structurally correct,
executable work structure. Runtime conformance separately proves that accepted programs
execute as specified; graph admission alone does not establish execution correctness.
Model task success is measured separately from structural generation. Voluntary
selection of codemode, use of every
available capability and optimal parallelism are separate quality measurements, not
mandatory acceptance criteria. Agent-owned prompting/adaptation may help meet the
floor; Nexus MUST NOT acquire model-specific code-authoring policy to do so.

At cutover, compose, its aliases, `g.*` and nested pure-script DSL/runtime, old public
script-step contract and dedicated adapters retire together. There is no translator,
fallback or permanent dual path. Generic task/DAG, storage, result, approval and
lifecycle mechanisms remain. Incompatible unfinished old executions fail closed and
regenerate; historical content remains tolerantly readable without executing the old
language. Exact transport names and storage layout are implementation decisions,
not permission to retain compatibility or introduce a second execution authority.
