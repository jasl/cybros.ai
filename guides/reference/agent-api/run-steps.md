---
title: Run steps
description: The step grammar a client authors with, what each verb accepts, how a round expands into more work, and the task kinds the kernel compiles steps into.
---

# Run steps

What a client writes when it authors work, and what the kernel makes of
it. Steps are placed in written order; nobody outside the kernel authors
an edge or a barrier ([Runs](runs.md)). The tools a step may declare are
on [Run tools](run-tools.md), and the tools a model calls to grow the
graph itself on [Run orchestration](run-orchestration.md).

## The envelope

An envelope is `{steps: [...]}` and a step is an object with ONE verb key:

    { "tool":  { "name", "input"?, "route"?, "key"?, "timeout_ms"?, "model_defaults"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "after"? } }
    { "model": { "prompt", "key"?, "model", "workload"?, "tools"?, "instructions"?, "configuration"?, "compaction"?,
                 "fan_on_failure"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "attachments"?, "after"?, "results"?,
                 "kernel_tools"?, "runner_executor_public_ids"?, "runner_tool_names"?, "mcp_tools"?, "model_selection"?, "fallback_models"? } }
    { "ask":   { "prompt", "options"?, "multi"?, "fields"?, "key"?, "timeout_ms"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "after"? } }
    { "wait":  { "task", "run_public_id"?, "key"?, "timeout_ms"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "after"? } }
    { "parallel": [ step | [step, ...], ... ], "until"?: "all" | "any" | k, "losers"?: "cancel" | "run_out",
      "key"?, "on_failure"?, "lifetime"?, "wake"? }

## Written order is the graph of waits

Every step waits on the step before
it (the tips of everything placed so far); a `parallel` runs its members
at once and the step after it waits on all of them; a member that is an
Array is a sequence run one after another inside the fan. Reads never
come from position: a `model` step reads its prompt and the results its
`results` names, in that order, and nothing else — not the step before
it, not a fan's members, not another step's conversation. The run's own
conversation is the one difference: a TOP-LEVEL `model` step of an
authored envelope continues the mainline — the run's tail for the first
one, the top-level `model` step before it after that — so its request
replays that round's history ahead of the results it names. A `model`
step inside a `parallel` member is a fresh agent that starts from its
prompt, whether or not the fan races, and never becomes the mainline. So
the flagship shape stays a list — a fan of model branches followed by
one synthesis step naming them in `results` — with exactly one
conversation, and one cache prefix, per step. A `tool`, `ask`, or `wait`
reads nothing. `detached: true`
on a step — the node column's word — says **this envelope does not wait for
it**: the next step is placed as if it were not there, a detached `model`
step still waits on the preceding frontier but starts from its own prompt
without the mainline's history (its `results` still apply), and its answer
reaches the run as the kernel delivers it (the wake round); it is the same
mechanism a model's `delegate_task` call uses for its whole subgraph
when the call is not `wait: true`. A fan's `until` says how many
successes end it: `until: "all"` (the default) places no barrier row;
`"any"` and a quorum number place ONE hidden `join_task` the
kernel names (`key` or `s{n}-parallel-{i}`), and `losers` says what the
race does to the branches that lost — `cancel` (the default on every
public surface) or `run_out`; `losers`/`key`/`on_failure` on an `all` fan
refuse `invalid_losers`/`key_needs_a_race`/`invalid_on_failure`. An envelope
must end at one attached tip: an `all` fan with multiple exits needs a
follower (`fan_needs_follower`), while a race's single barrier can be its
end. An envelope cannot be empty (`steps_required`), and a `parallel`
cannot (`empty_parallel`).

## after and results

Leaf steps accept `after?: [key, ...]`: additional waits that read nothing.
Model steps also accept `results?: [key, ...]`: waits plus the
producers' final result envelopes, in declaration order — the whole of what
the step reads beside its prompt and, for a top-level `model` step, the mainline
it continues. That one round is read once: when a top-level step's `results`
name the mainline round whose history its request replays, that answer reaches
it as history and never also as an envelope, while its other results keep
theirs. A model that round's own replayed request carries further back is not
the round it continues and keeps its envelope. Both accept earlier emitted
leaves and earlier placed races of this envelope and, on an authored
envelope, any earlier row of this run by its key — how a client hands a
value from one append to the next; a named row still queued or running is
waited on like any other. Duplicate entries, self or forward references,
unknown keys, other runs, and an `all` fan (it places no row to name) are
refused; a race's own member
cannot name the race, which is placed after its members. A race named by its
`key` is ONE dependency on its barrier, never on its members, and in `results`
it reads what the race selected — the same selection a detached subgraph ending
on the race delivers and the `wait` tool returns (the race selection above). A
successful barrier is never material: `input_from` never names one. A
reference naming a race's member instead waits on that member and reads its
own envelope: a live consumer, so the race spares it as shared
work rather than canceling it — name the race to read the race's answer. A
reference follows the producer's logical completion through model tool rounds,
an operation-owning tool, or a graph-authored `ask` / `spawn(wait: true)` waiting for
its answer. A nonwaiting spawn still returns its launch acknowledgement.
It adds to written-order dependencies; it never replaces
them or gives the consumer ownership of the producer.

### What a reference reads

A named model answer is result material, never a replacement conversation
history: the reader gets the producer's final answer after its tool rounds,
not its request. A race reaches a reader only by
name: `results: [race]` reads the selection captured when the race settled,
or a failed race's partial winners followed by its failure, and never a
member the race did not select; a step after a race that names nothing reads
its prompt alone (a top-level `model` step, the mainline it continues). Across
appends the rule is the same: a later envelope reads an earlier one's rows by
key, never by position.

## lifetime

Every step accepts `lifetime?: "turn" | "conversation"`. Omission inherits
its enclosing authoring context; ordinary roots default to `conversation`.
An explicit value overrides that context for the step's work and descendants,
without changing later siblings. A parallel group's value supplies its members'
default. Dependencies do not transfer lifetime. `turn` adds a final-delivery
obligation even on detached work: its result must be consumed before this
Run's reply becomes final. Unconsumed `conversation` background results
arrive in a separate supplementary turn after the original reply is final, even
if the result finishes early. This removes no foreground dependency or failure
hold. Standalone runs still wait
for all work. Append and retry refuse new turn-owned work after final delivery
with `turn_already_delivered`; a replayed successful append receipt is unchanged.
See [orchestration](../../build/orchestration.md) for examples and cancellation scope.

## wake

Every step also accepts `wake?: "auto" | "passive"`, with the same enclosing
context and descendant inheritance rules; ordinary roots default to `auto`.
It controls completion mail after the reply is final. `auto` starts a new
reply; `passive` records a kernel-origin `message` in conversation history
without invoking a model. The next active input reads that result normally.
Passive mail uses the ordinary input queue, does not block subsequent active
inputs, and needs no available model to materialize. It does not change
explicit result consumption, an explicit dependency, or the mandatory final
synthesis of turn-owned work. `wake`, `lifetime`, and waiting are independent
choices. Dependencies do not transfer wake policy.

## Keys, visibility and failure policy

Every step: `key` (`[A-Za-z0-9][A-Za-z0-9_-]{0,63}`, unique per run;
minted `s{revision}-{verb}-{n}` when absent),
`visibility` defaults per kind (model `visible`, tool `collapsed`,
ask/wait/barrier `hidden`); `on_failure?: absorb|propagate|halt` (defaults:
model `halt` — a failed execution asks for repair via the attention hold; retry/abandon are the
answers; wait `absorb`; tool/ask/barrier `propagate` — an authored pipeline step
that could not run skips its dependents). Model recovery uses bounded provider
attempts and the captured ordered fallback list; steps cannot add another retry
budget. A `retry` step option is refused as `unknown_step_option`.
Kernel-driven tool fans differ at
S5: a tool that RAN and errored is a COMPLETED task whose result
carries the error envelope the model reads — and a could-not-run
failure there is authored `absorb`, so the continuation always hears
what happened.

A model task's `conversation_cost_limit_reached` refusal uses effective `halt`
regardless of the authored policy. Its dependents wait for explicit repair; the returned
`on_failure` remains unchanged. See [Failure policies](run-statuses.md#failure-policies).

## What a task reads back as

On the trace and the single-task read:

| Field | Meaning |
| --- | --- |
| `key` | The task's own key |
| `kind` | `model_task`, `tool_task`, `await_task`, `join_task` for a kernel barrier, or `delegation_task` for a turn-owned child's report |
| `lifetime` | `turn` or `conversation`, the resolved selection |
| `wake` | `auto` or `passive` |
| `status` | The engine's `queued` is the product's `waiting` |
| `on_failure` | The policy the step was authored with |
| `model?`, `tool_name?`, `tool_alias?` | What ran, and under which spelling |
| `result?`, `error?` | What it came to |
| `visibility` | The row's own word |
| `result_delivered_at?` | Present only on a background answer that outlived its turn and was delivered to the conversation as the kernel's own input |

**`after?`** is the task's current dependency keys, at every status,
absent for a root. The kernel can update them when a model task expands
into more work; settlement alone does not remove them.

**`waiting_on?`** is the keys of the tasks it still waits for, present
only while the task has spent nothing — `waiting`, or a tool call's
`needs_approval` — and only for upstream tasks not yet settled. Once
started, its status says what it waits on (the kernel, a machine, a
person), and once settled the question is moot: a racing barrier
completes with sources still running, and a live list would contradict
the status, which `after` does not.

**`failure_resolution?`** is the adjudication axis, a person's stamp:
`abandoned`, or `canceled` for a person's branch cancel. An `absorb`
policy ordinarily resolves its failure by derivation and stamps nothing. A
client also checks `kind` and `error.key`: a model task's cost-limit refusal
remains unresolved under the effective `halt` rule until adjudicated.

**`target?`** is `{executor_public_id, display_name?}`, the immutable
accepted Runner destination, present before delivery and retained after
withdrawal. For an MCP call it is
`{kind: "mcp", connection_public_id, display_name?, account_label?, tool_name}`;
`tool_name` is the remote name and the UUID fixes the external account even if
its display name changes. MCP calls have no executor delivery or claim.
The single-task read also includes **`effect_profile?`**, the accepted tool's
effect metadata. MCP uses `kind: "write"`, `destructive: true`,
`effect_scope: "open"`, `idempotency: "none"` and `reconciliation: "none"`.
Show the target, callable `tool_alias || tool_name`, input and effect together
when requesting approval.

The target is distinct from **`addressed_to?`**, who a started tool
call or ask is for: `{role, executor_public_id}` for an addressed row and
the role alone, `{role: tool_provider}`, for a pool row; absent on a
kernel-executed or model task
([Executor](executor.md#where-a-tool-call-goes)). **`claimed_by?`** is
`{executor_public_id}`, the executor that took the call, a snapshot kept
after the executor is gone; absent until a claim.

**`approval?`** is `{origin, decided_by?, decided_at}`, the stage's fact
on a tool call, absent until it was decided. `origin` is `mode`
(bypass), `rule` (an allow rule), `author` or `kernel` (pre-approved by
the row's writer), or `human` or `agent` (an approve or a deny by a
principal — the status and `error.key` say which); `decided_by` is the
deciding principal's public id on the last two.

A barrier's `until` and `losers` draw on the graph route, where the
picture needs them. Nothing else: not whether a round is the mainline's
continuation or a composed branch, not that a step was placed in the
background.

## The four verbs

- `model` — `model: {model: "provider/ref", reasoning_enabled?, reasoning_effort?}`
  (required on this API; task operations can inherit their frozen model defaults),
  with independent enablement and effort as described in
  [Models](models.md#reasoning-selection), and
  `workload?: text_generation|image_generation` (default `text_generation`).
  An image step is a finite prompt branch: it never reads text history and
  accepts no tools, instructions, compaction, reasoning controls or `results`.
  Its `configuration` uses the selected image model's generation options;
  image references use the same authorized `attachments` door below.
  Task model operations may inherit image `model_defaults`. An image operation
  from a text context requires its own image model and inherits no text model,
  generation options, tools, instructions, compaction or fallback policy.
  Its output carries persistent upload resource links. ModelTask projections
  include `workload` so readers can distinguish these results.
  `prompt` is required on this door and in task model operations (the kernel's own
  rounds carry none). `attachments?: [upload_public_id, …]` carries the
  files beside the prompt — the caller's own staged uploads,
  resolved against the door's member — the run's creator on create,
  the acting member on append — bound for liveness, composed as one
  message with the prompt's words; `invalid_attachments` positionally for a malformed or empty
  list; never authorable by the kernel or by a model-origin task operation. The
  round reads them as an input door's does: natively on an engine whose
  row takes images, as the `[Attachment: …]` line in place otherwise.
  Ordinary files carry their `nexus://uploads/<public_id>` reference in that
  line and are available to the run's active claimant through the executor
  attachment resources. Later rounds re-read the index through the sealed prefix.
  `configuration?`, `tools?: [tool objects]` (the
  declared tool surface, stored verbatim and carried to the wire as a
  first-class request fact, with the [profile's function strictness
  default](profile.md) preserving optional parameters — gated by the model's `tool_calls`
  capability; an empty array or a non-object entry refuses
  `invalid_tools`; a step with none that continues a model round which
  sent tools on the same provider and model sends that round's `tools`
  by value under `tool_choice: none` — the tool list heads the cached
  prefix and binds the reasoning the step replays, so it stays while the
  model cannot call, and the step's declared set stays empty). The calls a completed round made come back
  normalized as a sealed `tool_calls` envelope beside the answer
  (id/name/arguments/ordinal, call order — the fan expansion and the
  continuation both read it), `instructions?` (the system channel: one
  byte-stable block on the wire's own field, the most cacheable position
  — not a message), and `fan_on_failure?: absorb|propagate` governing the
  tool fan this round's driver materializes (default `absorb`: a tool
  that could not run must still reach the model as an error envelope;
  `propagate` is the fail-fast option, and either choice is inherited by
  every continuation so one authored intent governs the mainline).
  The model step also accepts `model_selection` and `fallback_models` to
  capture its intent and ordered candidates; omission inherits its Run's
  values and an empty list disables automatic switches. See
  [Model selection and recovery](models.md#model-selection-and-recovery).
- `tool` — `name` is the served execution name. A kernel name refuses
  `reserved_tool_name`, except an explicitly Runner-routed source skill or
  an MCP-routed remote tool.
  `route?: {kind: "runner", runner_executor_public_id?: UUID}` selects Runner
  delivery. An omitted UUID resolves the host's nullable default once at
  acceptance; no default refuses `runner_target_required`, explicit null is
  `invalid_tool_route`, and an unserved selected tool is `tool_not_served`.
  An absent route never infers a Runner by name. An accepted call can wait for
  an offline target until its own deadline. Task-scoped child calls resolve declared
  callable names against their frozen context and refuse `unknown_tool_name`
  or `tool_route_mismatch` when they try to expand that authority.
  `route: {kind: "mcp", connection_public_id: UUID}` selects one steward-owned
  [MCP connection](mcp-connections.md). The UUID is required
  (`mcp_target_required` if omitted); explicit null is `invalid_tool_route`.
  `name` is the remote tool name, including names that also happen to name a
  kernel tool. This route never falls back to a kernel tool or executor.
  A connection unavailable to the answering Agent or a tool absent from its
  current catalog refuses `mcp_connection_unavailable`. Acceptance freezes the connection UUID, and
  execution rechecks current authority before external IO. MCP calls use
  the same approval, deadline and settlement rules without an executor claim.
  `input` is a JSON object (`{}` when absent); `timeout_ms?` sets its clock.
  An eligible executor may also consume explicit `model_defaults` on a standalone tool:
  `model`, `workload`, `configuration`, `tools`, `instructions`, `compaction`, `on_failure`,
  `fan_on_failure`, `kernel_tools`, `runner_executor_public_ids` and
  `runner_tool_names`, `mcp_tools`, `model_selection` and `fallback_models`. Import intent uses the same grammar and acceptance-time
  assembler as a model step. This is its immutable child-authoring context,
  not a language runtime or a promise that an executor is available. Model-origin
  tools inherit their declaring model's context instead. See
  [executor operations](executor-operations.md).
- `ask` — `prompt` (the question a person reads on the single-task read),
  `options?` (the choices as data: one string each, in the order to show
  them; `invalid_ask_options` otherwise), `multi?` (`true` when several
  may be taken; `invalid_ask_multi` otherwise), `timeout_ms?` (clamped per
  park to 24 hours); an authored ask is minted a `resolution_token` that
  rides out in the receipt. The choices land on the await row and ride
  every read of the question — the single-task read's `options`/`multi`
  beside `prompt`, the executor inbox's ask row — and are absent when the
  asker gave none. The answer is the person's text (`<answer>` carries it
  as it always did; none of the references echoes the option list).

- `wait` — `task` names existing work by task key; optional `run_public_id` is
  the source execution's public UUID, defaulting to the current run. A
  conversation-hosted run may also observe earlier runs in that same
  conversation; a standalone run can observe only itself. `timeout_ms`
  follows the await clock: default one hour, at most seven days requested,
  clamped per park to 24 hours. This creates an ordinary `await_task`,
  dispatched and held by the kernel, with no resolution token in the receipt
  and no executor inbox entry. Its default `on_failure` is `absorb`.
  The single-task detail adds `wait: {run_public_id, task, timeout_ms}` with the
  resolved source UUID and authored timeout (`3600000` when omitted).
  An unknown or inaccessible target refuses `wait_target_not_found`; a
  direct self/ancestor wait refuses `wait_cycle`. Expiry or cancellation ends
  only the observation, not the target. See the `wait` tool below for what
  completion means and how repeated observations interact with mail.

## The round driver

A model round that answers with tool calls is the middle of a turn, not
its end. The kernel expands it in the same transaction that applied the
answer, through the same door and grammar a client uses: it places
`parallel` (one `tool_task` per call — carrying the provider's own
`tool_call_id` as the pairing key, the parsed arguments as `tool_input`,
and the fan policy) and then one continuation `model_task`, which by
position waits on the whole fan and reads the round and every result.
The continuation inherits the source round's complete
request surface (model, effort, configuration, tools, instructions), and
if the source was the run's deliverable the deliverable moves to it —
a run must not complete on a round that only asked for tools. Every
queued consumer the round had — a step placed after it, a branch
continuation — is handed to the continuation in the round's place
(attachment forwarding), so nothing ever reads a round's tool-call
chatter as its answer.

### No ceiling, one repeat brake

A run's size is a function of
model behaviour — one tool row per call, one continuation per round —
and the kernel puts no round, task or model-step ceiling on it:
long-horizon work is the norm, concurrency is the only capacity control
and the admission plane owns it. The per-request envelope bounds below are request
hygiene, never totals. What the kernel does bound is repetition without
novelty. Each round's calls are read with their results: the call as its
row stores it (the kernel's name and mapped input; a call over the
tool-input bound with none of its arguments), and the result as it
settled — a completed result's text and pictures and whether it was an
error; any other status with its error key and detail; for a `delegate_task`,
`spawn` or `wait` answered by a branch or a child, that answer rather
than the launch receipt; for a background `delegate_task`, `spawn` or
`send`, the launch alone, the work it started judged in the round that
delivers its result. A round is stale when each of its elements was
already brought by one of the sixteen rounds before it on the same chain
and nothing new reached the model: a landed steer, an ask's answer, an
authored brief or a re-run (a person's retry, a retried or resumed model
call) make a round new; a compaction mark, and a round that made no call,
end the look-back. When the eight rounds up to the one the model just
read are all stale and it asks only for calls those sixteen made, the
round is refused `round_expansion_refused` with detail
`repeat_call_loop`, which fails the round and hands the run to the halt
policy — on a mainline, a halt for a person; inside a branch, a failed round
its consumer reads in its envelope. So a cycle of calls whose results
never change halts eight rounds after its last new result; one call whose
result keeps changing — draining a queue an item per call — is never
refused; one call with one unchanging result is refused at its tenth
round. A fan is a set: reordering or regrouping calls already brought is
not new. A round of nothing but `read_process` polls is the runner's
designed wait: never refused, never stale, and outside the count — unless
one of the above reached the model with it, or material was delivered
beside it, which keeps it in the count. The brake reads at most
twenty-four rounds back, whatever the run's length.

### Kernel-materialized rows

These rows are kernel-materialized: `revision` does not tick (the
counter coordinates concurrent writers, never the execution trace), no
CAS applies, and `tool_call_id` is refused on the public door
(`invalid_tool_call_id`) — a client must not reach for another round's
tool result; the mainline mark is the tip's, never a step's word. The
round continues IFF calls arrived: no provider's `stop_reason` is
trusted for it. A call whose arguments are not a JSON object is still
authored as a task (the pairing law owes every call a result) and
failed at once with `invalid_tool_arguments`; a stream the provider cut
mid-call (`max_tokens`) arrives with exactly the partial text it
emitted as its arguments, never an empty object, so it lands here and
the refusal is the tool result the continuation reads — nothing runs.
When the round's own `finish_quality` is `output_budget_exhausted`, that
same unparseable call is failed as `truncated_tool_arguments` with an
`error_detail` naming the cut ("the response hit the output token limit
and its arguments are incomplete. Re-issue it with complete
arguments."), and the envelope the continuation reads carries the
detail after the key — the model reads WHY, not "bad JSON". A complete
sibling in the same cut batch still runs: the batch is never refused.
A call whose arguments are larger than one tool task's input may carry —
64 KiB of canonical JSON, the `tool_input` bound — is authored with none
of its arguments and failed as `tool_input_too_large`, its
`error_detail` naming the size it sent and the bound ("Its arguments are
N bytes, over the 65,536 bytes one tool call may carry. Re-issue the work
as several smaller calls."), and its siblings still run. A call whose
arguments the row store cannot hold — text carrying U+0000 (JSON's
`\u0000`), or a number the canonical encoder refuses — is likewise
authored with none of its arguments and failed as `invalid_tool_input`,
its `error_detail` the encoder's own sentence ("A string carrying U+0000
cannot be stored: remove it before submitting."); the round is never
refused for it, and its siblings still run. The model's own
arguments stay in its replayed turn as it sent them, so a round that sent
one may arm compaction on its next request; a summary that then replaces
that turn carries the call's failure in its pointer, and a prune keeps
the call's error envelope (see compaction below). A call whose name no
row can hold (over 128 characters) is failed on its own as
`unknown_tool`, like any undeclared name, and a provider call id longer
than the 128 characters a row keeps is replaced by a pairing key the
kernel mints — the replayed call and its result carry that same key.

### The mainline

The continuation is the engine's main-thread mark: the chain of marked
model tasks IS the mainline, structural, never inferred from a key
convention. The trace does not render the mark. A client follows the
conversation through the TRANSCRIPT, whose rounds carry `mainline`
(`true` for the mainline, `false` for composed work), and a client that
must splice onto the mainline's latest round reads `deliverable_task_key`:
the kernel moves the deliverable from a round to its continuation and to
the waking round, so it names the main thread's tip whenever the author
designated a mainline round as the answer.

## Task kinds

The kinds a step compiles to, and what each one parks on.

### A tool task

A `tool` step's `name` and `input`, `timeout_ms?` (≤7 days;
when absent the park's deadline is the executor's announced `timeout_ms`
for that tool, else the kernel's 10-minute default — [Executor inbox](executor-inbox.md)
"the park's deadline"); tool steps that must run one after another are
written one after another. A tool task parks on its
runner exactly as an await parks on its holder — same derived
deadline from its own authored timeout, same sweep, same settle
engine — and its answer arrives through the executor plane's commit
([Executor inbox](executor-inbox.md)), never through a member door.

### An await task

Shared by human questions, finite waits for existing work,
and a waited spawn's original reply. Human questions carry `prompt?`
(the question: an await that cannot say what
it is waiting for hands a human a task key), `timeout_ms?` (≤7 days;
default 1 hour). The park's effective deadline is
`min(timeout_ms, 24 hours)` — a clamp each park carries on its own,
never a budget the run's parks share: a run may park as many times
as its work needs (there is no cumulative park-time ceiling). The authored timeout is never rewritten — what
moves is the derived deadline. An attention hold is not a park and has
no clock at all.

**Who may answer depends on who asked.** An authored ask — appended
through this API, which is the only append that returns a receipt — is
minted a `resolution_token` at create, returned ONLY in that receipt
(the trace never carries it; replaying the create's `Idempotency-Key`
recovers a seed token, and replaying the append's key recovers one added
later). Answering it presents that token as
a second factor beside the door's own authorization.

An explicit `wait` or a spawn's immediate wait is kernel-held instead:
its token never leaves the kernel, it appears in no executor inbox, and
callers cannot resolve it. The observed work's completion or the ordinary
park timeout settles it. The `wait` task detail identifies its source.

A kernel-authored await — the one a model requests through a task operation, or plants with the one-call `ask` tool (`nexus.human.ask`,
"`delegate_task` and `ask`" above; the model's two ways to ask a human anything,
both kernel-planted) — is minted NO token,
because the kernel's command carries no `Idempotency-Key`, persists no
receipt, and so has nobody to hand one to. It answers to the
resolution door's own authorization alone: write standing on the
workspace, the same standing that could have authored the await by
hand. `resolution_token` is absent from its trace projection, and
`POST .../resolution` omits the field.

### The barrier

Never authored: the kernel places one hidden `join_task`
for a `parallel` whose `until` is `"any"` or a number, and none for
`"all"` (the follower simply waits on every member). Its `losers` says
what the race does to the branches that lost: `cancel` (the default on
every public surface) stops them the moment the barrier settles —
every pending task in the barrier's upstream that nothing live is still
waiting for is canceled (`error.key: join_loser_canceled`), which by
construction never touches work a live branch — or the winner —
still needs; `run_out` lets them finish (honest spend, their answers
stay available). Once no other live consumer needs a losing branch,
its later `halt` failure does not hold the run at `halt_failure`;
its row still reads `failed` with no `failure_resolution`. A live consumer
that still needs it retains the declared failure policy. A barrier that
FAILS its race (`join_starved`, `quorum_unreachable`) ends the race the
same way: sources may still be in flight, but only other consumers can
still need their results. `result.outcomes` is a SNAPSHOT taken when the barrier
settled, so a source shown `waiting` there may since have been
canceled; the task's own row is the live answer. A quorum larger than
the fan refuses `unsatisfiable_until` at compile; barriers settle
structurally: `any` completes on the first success and fails
`join_starved` when none can arrive; a quorum fails
`quorum_unreachable` when successes plus pending can no longer reach
k. A starved barrier never hangs.

**The race rule:** a race reaches a reader
only by name. `results` naming the race read the selection captured when
it settled — a member still running then is never in it, even if it
finishes before the reader starts — or, for a failed race, the partial
winners it captured followed by its failure. No step reads a race's
members by position, and no row placed in a race's arms — an arm's
intermediate step, a loser, a run-out loser's later rounds — comes back
to the caller on its own: the barrier stands for them all. A continuation
a failed race lets run keeps the conversation it continues and reads the
race only if it names it.
`results` naming a member are independent: they wait for that producer's final
result and include it even when it completes after losing the race.

## Typed questions

An `ask` may supply `fields` instead of the top-level `options` and `multi` hints.
The same definition is available on the task detail and its ask inbox row. It stays
with the existing waiting task across client disconnects.

```json
{"ask":{"key":"settings","prompt":"Choose delivery settings","fields":[
  {"name":"enabled","label":"Enable delivery","type":"boolean","required":true},
  {"name":"count","label":"Copies","type":"integer","required":true},
  {"name":"format","label":"Format","type":"choice","options":["pdf","text"]}
]}}
```

Each field has `name`, `label`, and `type`; `required` defaults to false.
Names are unique and match `[a-zA-Z][a-zA-Z0-9_]{0,63}`. Labels are nonblank text.
Types are `string`, `integer`, `number`, `boolean`, `choice`, and `multichoice`.
Choice fields require `options`: 1–64 distinct strings. Other types accept no options.
There are 1–32 fields, with a 64 KiB canonical JSON limit on the whole definition.
Unknown field properties, mixed top-level hints and fields, malformed definitions,
and oversized definitions produce an `invalid_ask_fields` compile error.

The answer is an object keyed by field name; optional fields may be omitted.
Required means the key must exist: empty strings and empty multiple selections
are valid values. Null, unknown names, out-of-list choices, duplicate multiple
selections, and type coercion are refused. `false` and `0` remain typed values;
`"false"` and `"0"` cannot substitute for them. Integer fields require an integer
JSON value; number fields also accept supported finite decimal values.
There are no defaults, nested forms, arbitrary JSON Schema, conditional fields,
secret controls, or file fields.

Submit through [Resolve a task](runs.md) with `answer`. An authored model step
consumes this answer by selecting the ask key in `results`; a model's own `ask`
uses its existing automatic continuation. Answering collects data and does not
approve subsequent tool calls. Clients without typed-question support must show
that limitation and keep the question pending, rather than submit text or an empty answer.

## Captured executor context

Member-authored Model steps accept `executor_contexts`, a JSON object keyed by
concrete Executor UUID, with an opaque JSON object as each value. The same field
is accepted in a standalone Tool step's `model_defaults`, in conversation input
create/update, and in schedule create/update. It is bounded by the snapshot JSON
limit. UUID keys are normalized to lowercase; duplicate normalized keys and
non-object values are refused.

A member-authored Tool step can also carry `executor_context` for its own
concrete target. If both the singular value and a matching map value are supplied,
they must agree. The captured value is delivered as `executor_context` on the
[executable task row](executor.md#executor-context). Nexus treats
the payload as application data; it does not interpret paths or fetch application
Store entries to fill missing values. Do not place credentials in the payload.

Model-generated continuations inherit the accepted map and cannot replace it.
Each generated tool receives only the value selected for its execution address,
including a tool provider. Pool viewers and claimants follow the
[executor context selection rules](executor.md#executor-context); missing values
never fall back to a different address. Model tool
arguments and provider tool schemas contain no context field. Retry, approval,
compaction, regeneration and child execution preserve captured context through
their existing execution configuration. A later independent input may capture a
new map; changing current defaults does not rewrite accepted tasks.
