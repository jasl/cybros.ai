# Codemode durability experiment

Research date: 2026-10-04. This is a local, deterministic experiment, not a
production codemode implementation. It makes no model requests and adds no
production dependency, table, route, executor capability, or CI job.

The question is whether rho can execute ordinary async JavaScript while Nexus
owns the information needed to recover it. The experiment separates rebuilding
JavaScript control flow from accepting and executing durable tasks.

This record is historical. Both the pre-cutover ScriptTask storage probe and the
independent replay implementation have been retired. Production now retains one live
VM under an ordinary ToolTask claim and does not automatically replay lost source.
The measurements below remain evidence for the earlier experiment, not qualification
of the selected runtime.

Current acceptance lives in the [task operations tests](../../../nexus/test/controllers/agent_api/v1/executors/operations_test.rb),
[finalization tests](../../../nexus/test/services/executors/operation_finalization_test.rb),
[live VM tests](../../../agents/rho/rho-codemode/test/runtime_test.rb),
[worker/claim integration tests](../../../agents/rho/rho-codemode/test/claim_bridge_test.rb)
and [product journey](../../test/codemode_test.rb).

## Recorded checks

Recorded local checks on 2026-10-04: the offline probe passed 13 tests / 49
assertions in 1.09 seconds; the Nexus storage probe passed 2 tests / 49 assertions
in 1.12 seconds. These are Minitest's test-body timings, excluding command and
Rails startup. RuboCop passed for all four Ruby files. No paid evaluation ran.

## What is replayed

`Replay.call(record:)` creates a new VM on every call. Its input consists of:

- The original source and frozen callable tool names.
- Interleaved `issue` entries recording a local call ordinal, name, and arguments.
- `deliver` entries recording the order in which results were observed by the VM.

The tool bridge returns pending Promises. Replay matches each historical issue
against the next generated call, then resolves or rejects one historical result
and drains its microtasks before reading the next event. The returned snapshot
contains only new requests, still-pending call ordinals, recomputed output, and
the script result or error. **The replayer has no tool execution port.**

The record is an authored fixture/input shape for this experiment. The experiment implemented no log writer, durable scheduler, or production persistence adapter.
Results are inline so the probe can run independently; an integrated design
should read the existing task's output instead of copying it into another ledger.
Call ordinals are local replay coordinates, not Nexus database identifiers.

## Observations

| Observation | Evidence and meaning |
| --- | --- |
| Sequential control flow survives VM/process replacement | A new process waits for an accepted write and, once its result is supplied, proposes the following read. It does not propose the write again. |
| Result values alone are insufficient | Identical calls and values delivered in opposite orders produce different `Promise.race` winners. `Promise.all` preserves array order while its callbacks still observe completion order. |
| Interleaved issue/delivery order is sufficient for the authored concurrent examples | Tests retain the race winner, callback order, and calls generated inside `then` callbacks across fresh processes. |
| An accepted call with no result remains outstanding | The probe does not assume it failed, fabricate success, or propose a retry. The task owner must distinguish running work from an uncertain escaped effect. |
| Call matching cannot make edited source safe to resume | Changing only arithmetic after the last call changes the answer while every call still matches. Recovery must load the original source. |
| Returning does not settle outstanding children | A normal return with pending calls reports `unjoined`; a failed script also retains its pending calls. The owner must settle/cancel them according to its lifecycle contract. |
| Source and independent child results had Nexus storage owners | The separate pre-cutover storage probe exercised sealed ContentBody membership, expansion ownership, task result bodies, and one StoreEntry snapshot with optimistic concurrency. |

The offline tests include negative controls for changed arguments, duplicate or
unknown result delivery, changed source, missing `await`, and a Promise with no
possible tool result. Time and randomness are excluded from this experiment;
inputs requiring either must arrive as recorded values.

The first test's lost-response point is represented by an accepted `issue` entry
without a delivered result. It proves replay behavior given that fact, not the
atomic publication of the fact or the recovery of a real lost HTTP response.
No real filesystem write or remote side effect runs. There is no exactly-once
external-effect claim.

## Recorded pre-cutover storage assessment

The storage available at the time supplied these owners to evaluate. This table
records that initial assessment, not a pending implementation plan:

| Fact | Owner evaluated before the cutover |
| --- | --- |
| Original script and parameters | The execution task's input ContentBody and immutable fragments |
| Accepted external operation | Its existing ToolTask/model/delegation task, with a stable identity |
| Result and execution outcome | That task's output and ordinary settlement |
| Relationship to the script | Task ownership within the loop; `expansion_parent_id` demonstrates an existing association, without a separate Subgraph entity |
| Order of result observation | An execution-scoped sequence of task references; a scoped StoreEntry can hold a small opaque research snapshot |

Pure calculations do not need DAG nodes. Calls that perform work do need an
execution owner so approval, Stop, deadlines, result delivery, and retention can
reach them. A graph projection can group those child tasks under their script;
that does not by itself justify a new persisted Subgraph model.

The former ScriptTask executed pure `g.*` graph-building code. Its expansion
settled/replaced the stage; it was not a running async parent waiting on children.
The retired storage probe deliberately used that behavior. It did not turn
ScriptTask into a codemode host or make executor `structured_content` executable.

The storage probe also fed freshly read child arguments/results into the
replayer using an equivalent authored async fixture. The delivery order was
provided by the test's own sequence, not inferred from database completion
timestamps. This connected the two probes without supplying a production adapter.

The probe found that sealed bodies preserved their entries and ordinary content
replacement refused a sealed body. The internal `Replace.call(seal: true)` creation
path could create a new body, so sealing alone did not prevent privileged owner
replacement. Script definitions were attached at task creation without a public
edit operation. This established the experiment's recovery requirement: edits could not change
an existing replay's source. The current contract retains immutable invocation inputs
without promising source replay.

## Contract questions recorded before implementation

The experiment recorded the following questions before the production work. This
list preserves the assessment made under its replay proposal; it is not a current
requirement for a continuation category or automatic reconstruction. Current
[task operations](../../../docs/agent-api/v1/executor-operations.md) retain acceptance,
observation and child ownership, while the live host retains execution state.

1. Child-call acceptance needed the current task claim to bind the parent, frozen
   declarations, model origin and approval policy on Nexus's side. The member
   append available then started from the deliverable and used author origin.
2. Child acceptance and stable operation identity needed one commit so a lost
   response could be recovered without a duplicate task. A separate KV write
   followed by append could not provide that atomicity.
3. Observation order needed recording before delivery to the VM. Task completion
   timestamps did not prove observed order, and StoreEntry CAS supplied neither
   executor fencing nor a transaction spanning task creation.
4. A waiting parent needed a durable continuation without holding the execution
   capacity required by its children. Approval waits, deadlines, pause, Stop and
   restart needed to share the existing task lifecycle.
5. Replay retention needed to preserve child inputs while a parent required them.
   Final publication needed its ordinary write-once owner so recomputed output
   could not be published as duplicate progress.

The MiniRacer wrapper is for trusted synthetic scripts. It is not a qualification
of an untrusted-code sandbox, all ECMAScript behavior, module loading, arbitrary
promise graphs, or runtime upgrades. It uses finite VM time/memory bounds, but
does not establish production resource limits. Replaying a growing prefix can
repeat substantial pure computation; these small tests establish correctness of
the covered examples, not production performance.

## Historical conclusion

Keep recovery facts in Nexus and execute the programming-language frontend in
rho. Test deterministic replay of recorded calls/results before considering VM
stack snapshots. The additional fact needed for ordinary concurrent JavaScript
is **result observation order**, not just script bytes and a completed DAG.

The current product uses Agent-side code orchestration and Nexus-owned task
operations under a [language-neutral specification](../../../docs/specs/code-orchestration.md).
The [JavaScript binding](../../../docs/specs/code-orchestration-javascript.md) retains
one live VM. The experimental replay technique is no longer its execution contract. Compose and its kernel script evaluator are retired without
compatibility aliases, translation, fallback or a second execution path. The
[product design](../../../docs/plans/2026-10-04-agent-code-orchestration-design.md)
records the decision. This experiment alone does not prove the implemented public
protocol, effect safety or cross-model task completion.

An optional, separately budgeted model comparison should use final task artifacts,
first-pass completion, repair count, total cost, and elapsed time. The stopped
evaluation matrix is not unfinished acceptance work: its time/cost and method
were rejected. No multi-hour matrix or paid-model release gate follows from this
storage/control-flow experiment.

## Sources and evidence

- The retired offline replay and ScriptTask storage probes are recorded by the
  dated measurements above; current acceptance uses the production paths above.
- Shared
  [task result projection](../../../nexus/app/services/agent_runs/task_result_projection.rb),
  and [executor result contract](../../../docs/agent-api/v1/executor.md).
- Pi codemode at commit `200387122ca450d6387f033949423114a270b96c`:
  [runtime and storage behavior](https://github.com/earendil-works/pi/blob/200387122ca450d6387f033949423114a270b96c/packages/codemode/README.md).
  Pi supplies the programming-interface reference; this probe uses the existing
  Ruby/MiniRacer dependency and imports no Pi implementation.
