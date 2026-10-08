# Nexus multi-environment execution

Status: the multi-environment cutover was implemented and locally verified on
2026-10-06. The tool-assembly follow-up was implemented and locally verified on
2026-10-07. This document defines the accepted multi-environment execution
contract. The companion
[terminology specification](nexus-terminology.md) supplies the Run, Task,
RunnerEffects and default-runner names used below. The [Profile](../agent-api/v1/profile.md)
and [Tool assembly](../agent-api/v1/tool-assembly.md) manuals document the current
declaration and assembly APIs. Agent applications own background-work and
environment-selection policy.

The owner subsequently authorized the complete Nexus, SDK and rho breaking
cutover. New native computer-control features remain outside this implementation.
Schema and API compatibility with the unused development deployment is not a
constraint. This document authorizes no deployment or database reset.

## Outcome and scope

One Conversation or standalone AgentRun can use several explicitly selected
Runners. An Agent can inspect files on a Mac, run a build on a Linux Runner and
observe both results in the same execution. Each accepted Runner task names
exactly one destination. Changing a host's default never moves accepted work.

Agent applications retain planning, prompt meaning and environment selection.
Nexus owns task acceptance, authorization, approval, delivery, observation and
lifecycle. Runner-local files, processes, browser contexts, login state and local
network access remain where they were created. Moving a file or Git revision is
an explicit plan made of ordinary tools and artifacts; it is not migration of
the running conversation or its external effects.

This change covers Nexus, its public contracts, the Ruby SDK, rho, cmctl and
deterministic product integration tests. Native computer control, attaching a personal browser,
new desktop UX and cross-call desktop ownership are deferred. Mac personal use and a
fixed Linux cloud desktop remain the intended first computer-use consumers;
Windows and arbitrary Linux desktop coverage require their own implementation
and qualification. None is a prerequisite for this kernel change.

## Superseded behavior

Before this cutover, the implementation had four relevant constraints:

- `InputHost` stores one `runner_executor_id`; hosted loops derive it from their
  Conversation. `Executors::Handoff` changes that binding and readdresses
  dispatched, unclaimed Runner tasks.
- `Executors::Address` chooses the bound Runner at start. During approval,
  `ScheduleReady` stores the Agent application's inbox address, and `Tasks::Approve`
  resolves the execution address again. The inbox address therefore cannot also
  represent an immutable execution target.
- The SDK already supports a targeted `request` by creating an ordinary one-tool
  standalone loop. That facility does not provide several targets within one
  existing loop or its continuation operations.
- `AgentLoops::World` selects one first claimed write per loop; `WorldAt` selects
  one across the source timeline. Explicit retry reuses the node with a new
  `execution_generation` and clears its claim and result metadata.

The replacement keeps the existing queue, claim token, task deadline, result
commit, operation trace and upload mechanisms.

## Identity and authority

An environment in this version is the execution surface advertised by one
Runner TaskExecutor. Its public identity is that executor's UUIDv7. There is no
new Environment, Machine or Session resource. Display names, OS descriptions,
paths and announced metadata are descriptive, never routing identities. Several
Runner identities may describe the same physical machine; Nexus does not infer
shared state or exclusivity from that description.

The Agent, its member credential, the Agent application's executor
address and a Runner executor address remain distinct. Every target is checked
against the execution's answerer and the existing Runner assignment scope;
the submitting principal also needs the ordinary host write standing. Choosing
a target grants no Runner management authority and no broader filesystem scope.

The correctness boundary is delivery to the intended executor under the task's
existing authority. The asset is the intended environment and its effects;
malformed model/tool input can select an undeclared route or confuse two names.
The distinguishing test is that B cannot claim or execute work accepted for A,
even when both announce the same tool. The account operator and deliberately
installed Runner software are trusted; no new host-attestation or sandbox layer
is proposed.

## Defaults and the point of freezing

Conversation and standalone-run configuration use
`default_runner_executor_public_id`, nullable. It is a convenience for future
execution, not an exclusive binding or a set of permitted targets.

| Boundary | Rule |
| --- | --- |
| Conversation input acceptance | Stores input intent; a queued input has not yet frozen a turn's configuration |
| Turn/model execution materialization | Freezes the default, declared routes and supplied environment context with that execution |
| Model call or task-operation child acceptance | Resolves within that frozen declaration; persists the concrete target before the task can be scheduled or approved |
| Independently member-authored tool acceptance | A Runner route with an omitted UUID resolves the current host default once; an explicit UUID wins |
| Accepted-operation replay | Returns the original receipt/refusal before consulting changed defaults or announcements |
| Explicit task retry | Keeps the original target; runs a new generation through the ordinary approval stage |
| New independent turn | Materializes a new execution using its applicable current configuration; it does not move previous work |
| Regeneration | Reuses the original execution's frozen tools, environment and approval configuration; it does not import changed profile or Runner declarations |

A model execution's later mainline model tasks, branches and task-operation children
inherit its frozen default, tools, environment and approval configuration.
Updating the host default cannot change tools that a model already saw.
An independent later append may use the new default when its own execution is
materialized; it cannot mutate an earlier
execution's context.

The default writer accepts a Runner UUID or null and records a public
`default_runner_changed` fact. Null clears the convenience value. It never scans,
readdresses, restarts or changes the deadline of outstanding tasks. Host creation
and explicit default changes validate eligibility; a later loss of eligibility
causes a refusal, never automatic selection of another Runner.

## Tool declarations and target selection

A Runner call's execution identity is the pair of Runner UUID and served tool
name. The model-visible function name is a declaration-local name. Nexus accepts
two declaration paths, which can be combined:

- The Agent declares `kernel_tools`, ordered `runner_executor_public_ids`
  candidates and `runner_tool_names`. Nexus imports the explicitly allowed
  kernel definitions and the selected Runner's exact model tool announcements.
  Only the selected Runner contributes automatic tools; declaring a candidate
  does not import its tools. Omitted or null `runner_tool_names` imports all
  selected Runner model tools, while `[]` imports none. A nonempty list imports
  the exact-name intersection with that Runner's model announcements.
- The Agent authors explicit `tool_definitions`, including concrete Runner
  routes. This remains the lower-level path for declaring tools on several
  Runners in one execution or supplying a particular callable schema.

An import selection must belong to the declared candidates and be eligible for
the answerer. With no selected Runner, no Runner tools are imported, even when
candidates exist.
Kernel imports require exact canonical names; omission, null or `[]` imports
none and does not disable separately authored kernel definitions or aliases.
Operator-only announcements without model schemas are not imported. Allowlisted
names without a selected Runner model announcement contribute no tool; other
candidates never fill the gap. An explicit concrete route to an unserved tool
still refuses with `tool_not_served`. An input's `tool_names` that names a callable
absent from the assembled declaration refuses with `tool_not_declared`.

Two Runners may serve `read_file` with different schemas. Explicit declarations
use separate callable names when exposing both to one model, for example:

```json
{
  "type": "function",
  "function": {
    "name": "mac_read_file",
    "description": "Read a file on the selected Mac.",
    "parameters": {
      "type": "object",
      "properties": {"path": {"type": "string"}},
      "required": ["path"]
    }
  },
  "route": {
    "kind": "runner",
    "runner_executor_public_id": "019a0000-0000-7000-8000-000000000001",
    "tool_name": "read_file"
  }
}
```

`route` is Nexus declaration metadata alongside the function definition. It is
stripped from the provider wire, retained in frozen declarations, and never
inserted into opaque tool arguments. Its Runner UUID is required in the assembled
declaration: Nexus supplies it for imported tools, and callers supply it for
explicit routes. The SDK can submit import configuration without reconstructing
Runner schemas. Changing a default cannot send A's schema to B. Existing kernel
aliases retain their canonical/parameter-mapping grammar; a declaration cannot
combine a kernel alias with a Runner route or reroute a reserved kernel name.

Names in one declaration set are unique. Imported descriptions and schemas
retain the selected Runner's exact announcement. Imported callable names that
collide with explicit or kernel names receive stable target-qualified names;
the route retains the served name. A remaining duplicate is refused. Nexus does
not union schemas, rewrite accepted tools from later announcements, or expose one
catch-all `invoke(environment, tool, arguments)` tool. The existing kernel,
Agent-application and provider-pool authorities remain distinct. A Runner route
never falls through to another authority serving the same name. New Runner
declarations must use explicit route metadata; remove the old inference that a
plain unknown tool name should first try the host's Runner.

The read-only [Tool assembly API](../agent-api/v1/tool-assembly.md) returns the
same rendered declaration and environment that current sources would produce,
without creating work or updating a profile/default. The SDK exposes it through
`client.tools.assemble`. This is an observation, not a reservation: acceptance
assembles and freezes its own current result. Callers use returned callable names
instead of reproducing the qualification algorithm.

The model calls `mac_read_file` with ordinary arguments. Acceptance resolves
that name to the saved route, persists `read_file` and the target, and retains
the display alias for transcript/history. A claimed parent tool uses the same declared
name; its single-tool operation needs no redundant target selector. Nested
model-origin steps may use the shared step selector only when it matches the
inherited declaration; a mismatch is refused. Narrowing and intersection compare canonical
authority, target and served name, not merely an alias string. Reusing an alias
for another Runner in a later Agent configuration cannot confer new authority
on an inherited execution.

Member-authored tool steps name the served tool and a route beside the input:

```json
{
  "tool": {
    "name": "read_file",
    "route": {"kind": "runner"},
    "input": {"path": "README.md"}
  }
}
```

Here `route.kind` explicitly requests Runner execution, and its optional
`runner_executor_public_id` selects a concrete Runner. Omitting the UUID
resolves the current default once; explicit null is invalid. Omitting the whole
route does not request a Runner: kernel/provider/Agent calls retain their
existing authority, or a model-origin call resolves its inherited declaration.
They reject an incompatible Runner route. No name or announcement heuristic
decides whether omission means Runner execution. This same rule applies to ordinary
step batches, replacement steps, background steps and the existing one-task
request helper. All use one normalization/acceptance owner.

## Discovery, environment context and skills

Existing executor discovery exposes eligible Runners with their UUID,
announcements, environment and documents. Lifecycle, credential readiness and
presence remain separate facts. Presence never selects a destination or refuses
otherwise eligible work. There is no automatic nearest, online or cheapest
Runner, and no implicit pool of Runners.

The Agent selects the environments and tool declarations appropriate to its
execution. Discovery is visibility, not permission to expand the frozen tool
set. The accepted environment freezes the current default, selected/explicitly
routed executor facts and ordered eligible `runner_candidates` together with
the tools. Candidate facts contain UUID, display name and announced environment;
they remain available when no Runner is selected or no Runner tools are imported.
Unknown or ineligible candidates contribute no metadata. This context contains
the Agent's declared choices, not the entire Account inventory or another copy
of tool schemas. Nexus preserves opaque environment data without interpreting
paths or OS capabilities.

The optional kernel tool [`nexus.runners.list`](../agent-api/v1/runs.md#runner-environment-discovery)
(wire `runners_list`) reads this frozen candidate list and current Runner UUID.
It neither rereads live announcements nor derives candidates from tool routes.
It imports no tools and changes no selection. A model can choose a candidate
for newly created work through `spawn.default_runner_executor_public_id`;
omission inherits the source execution's frozen default, and null selects none.
There is no model-facing `runners.change` or default-mutation tool. Runner
selection does not select a model; model routing remains Agent application policy.

rho marks Runner, external provider and skill schemas `defer_loading: true` and keeps
the kernel search/call entry points eager. Nexus retains the complete declaration
as execution authority but projects a stable eager schema set to the model.
Searching that frozen set returns exact callable schemas and concrete public
targets; adding a discovered Runner does not itself enlarge the provider's
leading schema block. Per-turn default Runner context and the named-agent roster
belong after history, without copying the full tool inventory into a system slot.
Explicit tool narrowing remains authoritative; when it omits the search/call
pair, the selected schemas are exposed eagerly.

The existing source-routed `skill` mechanism must also preserve the document's
source executor. Runner documents use target-qualified declarations such as
`mac_skill` and `build_skill`, each routed to that Runner's served `skill` tool.
Their input remains `{name}`. Each catalog entry identifies its declared callable,
document name and source UUID. Equal document names on A and B remain distinct;
the frozen catalog and declaration choose the source, never a later name merge.
The existing source-routed skill family is the explicit exception to the ban on
Runner routes for kernel names; other reserved names remain forbidden. Kernel
and Agent-application documents retain their source authority and existing
non-Runner precedence, frozen for the execution. Withdrawal fails on that source
rather than loading a same-named document elsewhere. Loading a skill from A
cannot implicitly send its environment-local script to B when a default changes.
Input `tool_names` and all branch narrowing still apply. There is no new registry.

## Acceptance, approval and delivery

Acceptance saves the Runner target separately from the current inbox addressee.
Queued, approval-held, dispatched and claimed work all retain it.
An approval inbox item is delivered to the Agent application while showing the
actual Runner UUID/display name, served tool, display alias, arguments and
effect profile. The displayed target is the one approval releases.

At release, Nexus rechecks the same Runner's live lifecycle, eligibility and
served capability. If its effect profile changes, the existing reapproval rule
applies on that same target. A target change requires new work and a fresh
approval decision. The original approval deadline is checked before re-parking;
an expired request cannot be revived by a changed announcement or default.

At dispatch and claim, the target's current authority still matters. No longer
served means `tool_not_served`; a revoked or ineligible target uses the owning
lifecycle/eligibility refusal. A selected but disconnected Runner uses ordinary
task delivery and deadline recovery. No case silently substitutes another
Runner, an Agent application, a provider pool or a kernel implementation.

Runner transport remains outbound HTTP with droppable Cable hints. Claim
checks the precise task address and execution principal. Commit requires the
current claim token and keeps its write-once result semantics. Stale commits,
deadlines and possibly escaped effects keep the current timeout/uncertain rules.
Explicit targeting creates neither exactly-once external IO nor automatic retry
of an uncertain write.

Process progress must also stop using the host's default as its authority.
Retain the ordinary task-progress claim fence. A host-keyed process frame adds
`source: {run_public_id, task_key, claim_token}` naming the
originating claim. Nexus verifies the source's retained claimant/token and immutable
target against the transport executor, and verifies that source
and destination have the same host. A settled source task is allowed: its local
process may outlive the tool call. An unclaimed source grants nothing. The token
is request-only and is never broadcast or narrated. This read of an old claim
does not renew its deadline or grant new execution authority; internal generation
counters stay off the public wire.

If retry or detail collection removes that claim evidence, refuse the ephemeral
frame; do not infer cancellation of the process or add a process registry to
preserve progress. Explicit process reads remain ordinary targeted tools.
Default changes never cut original-process progress. Stop and host lifecycle
retain their existing task and Runner-local cleanup responsibilities; suppressing
a frame or stopping a task is not proof that an OS process has terminated.
Parent-conversation UUIDs likewise describe structure, not shared directories
or inherited process/browser handles on a different Runner.

## Child operations and execution lifetime

A Runner-hosted parent tool retains its accepted Runner target while waiting and
through explicit retry. Agent-application and provider-pool tools retain their existing
addressing and reconnection contracts; they do not acquire a permanent machine binding.
Each child operation can use a different declared Runner. An Agent-application parent
can therefore await work on A and B without becoming either Runner or carrying their
transport credentials.

Operation identity includes the submitted route where one is accepted. A single-tool
operation resolves its name against the parent's frozen declaration. Exact receipt
reconciliation returns the original acceptance and frozen target, including when the
selector was omitted. Changed requests under the same operation key retain the existing
conflict rule. The original declared scope and model origin survive receipt recovery.

The live parent keeps its ordinary claim, finite deadline extensions and cancellation
owner while yielding local execution capacity for its children. Irretrievable loss of
that owner or its VM uses ordinary failure/timeout and child disposition; the kernel does
not automatically replay source or reissue accepted children. A native adapter may
explicitly reconnect to its existing external work using that service's identity.

Pause/resume, graceful/force Stop, deadlines, turn/conversation lifetime,
delegation and replacement keep their existing owners. Stop reaches owned work
on every target through the same task graph and executor notifications. It
does not undo completed effects or cancel unrelated work using the same Runner.
Changing a default is never a lifecycle operation.

Fork copies the source host's default as a convenience, without copying an
environment. Spawn inherits its originating execution's frozen default unless
an explicit child default is supplied, and validates it for the child's
answerer. An ineligible inherited target must be reported, not silently changed
to null or another Runner. Child tools/configuration are materialized under the
child's own answerer; a default override cannot reroute the parent's schemas.

## Runner effect evidence and restoration

`RunnerEffects` replaces World: a read projection containing a collection of facts grouped by Runner UUID.
A claimed Runner write may have affected that Runner even if it times out or
has no checkpoint. An unclaimed task has no such effect evidence. Each run
reports its first claimed write for each target, ordered by claim time. A
fork-point query takes the first relevant write per target across every source
variant, including hidden candidates and background work, as the existing
physical-history rule requires.

```json
{
  "runner_effects": {
    "status": "touched",
    "runners": [
      {"runner_executor_public_id": "019a0000-0000-7000-8000-000000000001",
       "run_public_id": "019a0000-0000-7000-8000-000000000010",
       "task_key": "t1", "checkpoint": {"store": "local", "hash": "opaque"}},
      {"runner_executor_public_id": "019a0000-0000-7000-8000-000000000002",
       "run_public_id": "019a0000-0000-7000-8000-000000000010",
       "task_key": "t2"}
    ]
  }
}
```

`untouched` means complete retained evidence contains no claimed Runner write.
`touched` means complete evidence with at least one such fact. If relevant
execution details were pruned, report `unavailable` with
`reason: execution_details_pruned`; any included retained entries are explicitly
partial and cannot establish the complete target set. This avoids claiming
that an unknown deleted target was untouched. Missing checkpoint, JSON null and
a present opaque checkpoint are distinct. Nexus never interprets its contents
or judges whether a Runner can restore them.
Removing or collecting an executor does not erase retained effect evidence:
the original Runner UUID remains touched even when the restore destination is
unavailable. Evidence completeness and restorability are separate facts.

Retry must not erase the first write's attribution or checkpoint. Preserve a
bounded `first_runner_write` capture on the existing task: original generation,
Runner UUID and claim time, plus the checkpoint key only if supplied by that
generation's accepted result. Claim creates the capture atomically the first
time this task claims a Runner write. Matching commit may add its checkpoint
once; a stale commit or later generation cannot modify it. Retry clears its
ordinary current result/claim as today but retains this capture. Since a task's
Runner target is fixed, one capture per task is sufficient for the existing
first-write consumers. This is not a full attempt or effect audit ledger.

`RunnerEffects` readers aggregate these retained captures. Feed events are not their
authority because feeds can expire while execution details are retained. The
capture follows task execution-detail retention and collection, and contains
no claim token or independent lifecycle.

Restoration is an explicitly targeted composition of ordinary Runner tools.
Each checkpoint is sent to its own Runner, with per-target results. The SDK
uses `restore_checkpoints` to compose `checkpoint_restore` calls against the
original Runners, returning a separate `restoration` outcome.
Restoring A successfully and failing on B is a partial outcome; it is not a
global rollback. File checkpoints need not cover processes, browser logins,
GUI actions or external services. No atomic cross-machine snapshot or automatic
compensation is promised.

## Deferred shared-resource control

Per-task claims do not protect a shared desktop across several calls. A second
run can change focus between another run's screenshot and click even when
each click runs serially. A future computer-use design must identify the actual
shared input/display/session resource and own control over an interaction
scope, with acquisition, loss, release, Stop and fresh observation after
human takeover. Different resources should remain independently usable.

That future design must specify what happens across model waits, approval,
pause, process death and resume, and how the Runner checks ownership at the
effect boundary. Database cancellation cannot recall OS input already sent.
An executor address is not itself the resource identity, and the human is an
authorized participant. This phase adds no resource table, lease API, heartbeat,
priority queue or new scheduler. It must not advertise safe concurrent control
of a shared desktop before that separate mechanism and consumer exist.

## Completion criteria

The implementation plan's deterministic acceptance matrix is the gate. A single
run must execute and observe A/B work, preserve both targets across approvals,
default changes and restart, and expose truthful per-target Runner effect evidence.
Completion also requires rho and every shipped consumer to use the new contract,
with their full local suites and deterministic product journeys passing. Native
computer control and shared-desktop ownership remain separate future work.
