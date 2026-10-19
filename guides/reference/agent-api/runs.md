# Runs — the task-grained surface

The run's engine is a dynamically growing DAG. **The write surface is
task-grained and placed in WRITTEN ORDER**: clients author STEPS — `tool`,
`model`, `ask`, `wait`, and `parallel` for a fan — and nobody outside the kernel
authors an edge or a barrier: the kernel places both from the order the
steps were written and the declared `after`/`results` references to earlier leaves or races.
Raw graph-authoring fields (`tasks`, `depends_on`, `input_from`, `kind`, `mode`,
`quorum_k`, `loser_policy`, `serial`, `join`, `reading`, `detach`,
`deliverable`, `window`) are refused BY NAME, `edge_authoring_refused`;
raw `nodes`/`edges` authoring is refused (`graph_authoring_not_available`).
That is what keeps the graph sound. **The
graph is readable**: a task reads back as a key, a kind, a status,
`after` (its current dependency keys, which can change when a model task
expands) and, while it has not
started, `waiting_on` (the tasks it still waits for); the whole run —
every node, every edge, a Mermaid flowchart — is served on the graph
route for debugging, e2e evidence and a UI drawing the workflow, and how
far it got on the phases route. The graph and transcript also expose
`mainline`, a boolean identifying mainline model rounds. These are read
projections, not authoring fields. Internal row IDs, continuation-source
values, dependency countdowns and generations remain private.

**A standalone run is a HOST**: it hosts the
conversation's own contract at its own address — the one waiting room
(`…/inputs`, the run door) and the one event plane (`…/events`, the
run's feed) — and renders a TURN shape beside its own row (`turn`,
below), so a chat-shaped client reads one vocabulary on both. A run
created alone carries the shell a conversation would have declared
(`prompt_mechanism`, `approval_mode`, `approval_rules`). A conversation-hosted Run — one a
conversation's turn materialized — has no door and no feed of its own:
both are its conversation's, and the run address answers 409
`conversation_hosted` naming it.

## Route list

```
GET  /agent_api/v1/tools
GET /agent_api/v1/runs
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs
POST /agent_api/v1/workspaces/{workspace_public_id}/runs
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{public_id}
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{public_id}/start
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{public_id}/pause
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{public_id}/resume
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{public_id}/stop
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/phases
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks
DELETE /agent_api/v1/workspaces/{workspace_public_id}/runs/{public_id}
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/request
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/resolution
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/transcript
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/graph
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/retry
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/inputs
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/inputs
PATCH /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/inputs/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/inputs/{public_id}
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/inputs/reorder
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/abandon
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/approve
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/deny
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/cancel
POST /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/compact
PUT  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/default_runner
```

## Routes

### Create a run

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs
```

Creates a Run with
`{run: {steps: […], billing_subject?, prompt_mechanism?, approval_mode,
approval_rules?, default_runner_executor_public_id?, speaker_public_id?,
model_selection?, fallback_models?}}`.
The nullable default selects an omitted target on an authored Runner step.
A named default must be a live, eligible Runner for the creator. Model tool
declarations carry their concrete target; a Run can contain tasks on several
Runners. Acceptance freezes each target, independently of delivery and claim.
The full Run document exposes nullable `default_runner` and `runner_effects`.

`speaker_public_id` optionally selects an ingress Speaker controlled by the
creating Agent, as on the [conversation input door](conversation-inputs.md).
Omission or null selects the creator's member Speaker. The selected subject
is frozen into the Run's memory bindings; the creating User remains the
execution principal. An unknown Speaker, another Agent's ingress Speaker,
or an explicitly selected member Speaker returns `403 not_authorized`.
The selector participates in the create receipt: changing it under the same
`Idempotency-Key` returns `409 idempotency_envelope_mismatch`.

`model_selection` captures initial model intent and substitution constraints;
`fallback_models` captures an ordered replacement list. Omission uses the
creator Agent's standing candidates and `[]` disables fallback. Authored
model steps may override these values for their own accepted work. See
[Model selection and recovery](models.md#model-selection-and-recovery).
The standalone Run door does not take an inline `agent_configuration`.

### Set the default Runner

```http
PUT /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/default_runner
```

Replaces a standalone Run's default using
`{default_runner: {executor_public_id: UUID | null}}`. It returns the Run
document and emits `default_runner_changed` when the value changes. A missing
Runner is `404 runner_not_found`; an ineligible Runner is `409 runner_not_eligible`;
a caller without standing receives `403 not_authorized`. Repeating the value
succeeds without another event. Accepted tasks, approvals, deadlines, retries,
and claims retain their existing targets. Hosted Runs return
`409 conversation_hosted`; their preference belongs to the Conversation.
### What the run answers with

Nothing names a deliverable: the run's answer is the envelope's end
by construction (the last step placed, or the follower of a fan), moved
by the engine round over round, and the receipt's `deliverable_task_key`
says which key that is. `tasks`, `deliverable`, `tools` and
`compaction_policy` on the shell refuse 422 `edge_authoring_refused`
with `path` naming the word — a step's `tools` and `compaction` ride the
seed's `model` step. `billing_subject` is verified at create
(created-or-verified in the account, owned by the caller — a key
owned by someone else refuses `billing_subject_not_owned`) and the
frozen pair rides every step's usage receipt.
### The shell

A standalone run is created
with the configuration a conversation's turn would have frozen.
`prompt_mechanism` is one of the three words. `raw` (the default when
unnamed): the seed task's own `prompt`, `instructions` and `tools` are
the request. `default` and `assembly`: the seed is compiled once at create
by the one assembler — the creator profile's `system_prompt`, the
workspace's `character`, the creator's controlling Human's `persona`,
and the effective memory roots (no conversation rows or history), then the
words. An Agent's roots include its own `agent/` notes, `workspace/` and
its notes for the captured `speaker/`; they do not include the controlling
Human's `user/` memory. The creator's `memory_context_limit` narrows those
roots; the template separately selects prompt slots, including `persona`.
No model is resolved at create (no window sizes
it; the exact window gate is the scheduler's) and sealed in place of the
first step's authored body, so every round replays it as the prefix and
memory is frozen at create for the run's life. The template is the
creator's under the shell's word (the shell is the run's declaration):
`assembly` reads the creator's stored `prompt_template` whatever its
standing word — a creator with none (a Human, or an agent that stored
none) is 422 `prompt_template_missing` — and `default` the built-in
order whatever the creator declares. Under either the first step must
be a `model` step (`invalid_steps` at `steps[0]`, `seed_not_a_model_step`)
and its `instructions` is refused by name (`steps[0].instructions`,
`instructions_raw_only`): the system channel rides the sealed list. The
step's `prompt` stays the task read's `prompt` and the summarizer's
`User:` line — no slot text and no memory value reaches a summary. A
word outside the vocabulary is 422 `invalid_prompt_mechanism`.
#### A raw single-tool run

Under `raw` — the default — the seed may be a single `tool` step: the
run's answer is that step's result, read on `GET …/tasks/{key}` when
the task is terminal; no round runs, no model is called, no receipt is
delivered. This is how a member requests something only a runner can
answer (`executor.md`, "Requests"): create with `{steps: [{tool: {name,
input, route: {kind: "runner", runner_executor_public_id: UUID}, timeout_ms?}}],
approval_mode, prompt_mechanism: raw}`, then `start`. The row is granted by its
origin (`author`) unless a rule naming that origin denies it or says
`ask` — a rule with no `origin` addresses the model's rows alone. A
tool deliverable that does not complete holds the run
`needs_attention deliverable_unresolved` like any other.
### Approval mode and rules

`approval_mode` is required — `bypass | ask | rules` — and
nothing is defaulted: nil or a word outside the vocabulary is 422
`invalid_approval_mode`. `approval_rules` is optional — the rule list
("Approval" below), frozen onto the run row beside the mode; a
malformed list is 422 `invalid_approval_rules`. All three ride the
create digest: a different shell under one `Idempotency-Key` is a 409
mismatch. `tools` and `compaction` ride the seed step as before. A run
backing a turn carries the turn's own
`prompt_mechanism` (`raw` under `context_mode: raw` or a raw profile),
which the compaction arm reads (the raw rule, below).
### Compile failures

A run is born with its graph or not at all, and compile failures answer
positionally:
`{ error: { code: invalid_steps, steps: [{code, path}] } }`, the path in
the request's own tree — `steps[0].model.depends_on`). A tool step's
`input` is bounded where its row is, at 64 KiB of canonical JSON:
over it is `tool_input_too_large` at that step's `input`, while the
whole envelope's 1 MB bound stays `steps_payload_too_large`.
### Idempotency

Create honors `Idempotency-Key` (≤36 bytes, else 400): a retried create
returns `200` with the standing run, `replayed: true`, and the original
seed `receipt`, including its `resolution_tokens`. Later appends do not
replace this receipt. The retry cannot know the id the lost response minted,
so the workspace-scoped receipt finds it; a different envelope under the
same key is a 409. The key is scoped to the caller within the workspace
and reserved for 24 hours from run creation. After expiry,
the same key is treated as a new create; the original run is unaffected.

### Append work

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks
```

The ONE append door:
`{ steps: […], expected_revision?: n }` plus
`Idempotency-Key`, plus `resolve: [...]` — atomic await resolutions
applied AFTER the append, so a step placed in the same envelope may
already wait on the ask it resolves. An authored envelope starts from
the run's answer: its first step waits on the deliverable; a top-level
`model` step continues the mainline's tail and reads what its `results`
names; `after` and `results` may name any earlier row of this run by
key — this envelope's or an earlier append's — and the envelope's end
becomes the new answer. An earlier row is read, and waited on, as what
stands for it now: a `model` step that used tools as its last round's
answer, or an operation-owning tool as its final result — never a
first draft or an internal child's intermediate result. `diff → parallel(review, check) →
checkpoint`, followed by a separately appended summary naming
`results: [diff, review, check, checkpoint]`, supplies the same four
to that summary.
Nothing carries across appends by position: a repair appended from the
hold names the failed task the same way. Detached work does not move
the answer.
Two door-level refusals stand
before any row exists, 409 and unpositioned: `tip_live` — a step that
continues the mainline round (a top-level `model` step) placed while that
round is still live (an envelope whose steps do not continue it —
`ask`/`tool` steps, a `parallel` of fresh members, a detached step —
hangs below the live round instead); `tip_unresolved` — the answer
failed or was skipped and nobody adjudicated it (retry, abandon, or
append the repair from the hold). Two more 409s name the envelope
against the run: `duplicate_task_key` — a step key the run already holds (a key twice in
one envelope is refused the same way); `run_not_appendable` — the
run is not `pending`, `running`, `paused` or `needs_attention`, or is
tombstoned. The receipt is `{accepted_task_keys, steps, deliverable_task_key,
revision, resolution_tokens}`: `steps` mirrors the request tree by key
(a race's group as `{parallel: [...], key}` with the barrier key the
kernel minted), and every authored envelope leaves its receipt — the
plan the phases route renders — a keyless one under a minted key
nobody holds. Entries are a task key or
`{task, content?}`; COMPLETED OUTCOMES ONLY (a failed outcome must
never be silently inverted into success by an authoring envelope —
send it to the resolution door instead, 422
`unsupported_resolve_outcome`). Any bad entry takes the WHOLE envelope
back: nothing is appended and nothing is resolved
(`unknown_await`, `await_not_resolvable`).
Fences: `expected_revision` mismatch is a 409
`stale_revision` carrying `current_revision`; a replayed key answers the
ORIGINAL receipt (`replayed: true`, resolution tokens included); same
key + different envelope is a 409 `idempotency_envelope_mismatch`.
Append keys are shared within the run, not partitioned by caller, and
reserved for 24 hours. After expiry the ordinary append checks apply again;
expiry never removes tasks or changes the run's revision.
The counter is the append door's own fact: an author fences on the
`revision` of its last receipt, and the trace does not carry it — a
writer that only read the trace appends unfenced under its
idempotency key.

### Read the trace

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}
```

The trace: run status,
`deliverable_task_key`, `tasks[]`, `task_progress` counts, lifecycle
stamps (`started_at`/`paused_at`/`completed_at`) and, while the run
holds, `attention: {reason, blocked_task_keys, blocked_task_overflow?}` — rendered whenever a reason STANDS, which
includes a `running` run (a model's question), not only when the
status holds. The keys use the same selection and bound as the
`attention_required` event, including graph settlement after a race.
This lets a reader recover the current question or approval after selecting
an older candidate without reconstructing graph rules from task statuses.
The compact run listing still carries only `reason`.
The full trace also carries `approval_mode`, the mode frozen on this
run. Applications creating deferred work from a tool call can preserve
that mode together with the calling round's model and tool declaration.
The full trace also carries nullable `requester_speaker_public_id`: the original
requester's Speaker UUID, following a spawned execution's accepted source and
retained callback receipts. It is `null` for a standalone Run or when the
original requester cannot be determined. A combined callback reply names the
requester shared by its receipts. This field survives execution-detail
collection and is absent from compact Run listings.
Still no deadline here: a hold has no clock, and an
ask's is on its own task — it parks up to 24 hours (`deadline_at`) and
holds for a person when it expires.
`turn: {status, failure_reason_key?, public_id?, conversation_public_id?, answering_user_public_id?, model?}`
is THE TURN SHAPE beside the run's own row (on `basic` too):
for a standalone run `status` is the frozen algebra over its rows —
`pending` (created), `running` (running, paused, canceling, or holding
a question on its clock), `failed` (`needs_attention` with its reason,
or a reasoned cancel), `completed`/`canceled`, and back to `running` on
retry or answer — with no ids; for a conversation-hosted Run it is the TURN
row's, with the turn's and the conversation's ids, its frozen
`answering_user_public_id` (which can differ from the conversation's current
default), and
`failure_reason_key` only while the turn's active variant is still the
run's (a person may have overridden it), and `model` — `{model:
"provider/model", reasoning_enabled?, reasoning_effort?}`, a task's own model shape — THE
STATED PLACE a follower reads the model a run-backed
turn runs on: the answerer's own `default_model` when it declared one,
else the initiator's the row carried, so a conversation an agent was
spawned into is never a transmission failure for a program that only
attached to it (rho's `say` reads it after its own `default_model`).
Absent on a standalone run, whose tasks each carry their own. The
run's own `status`, `failure_reason` and `attention` stay as they
were — the turn shape is ADDED beside them, never mapped over them. A standalone run's `full`
also carries `input_queue: {limit, held}`, its waiting room's occupancy
(the queue itself is `GET …/inputs`); a conversation-hosted Run's is its
conversation's.

### Read the transcript

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/transcript?before=&limit=&prefix=
```

THE
THREAD: what a person sees, as opposed to what the graph is doing. The
trace above is the orchestration view; this one is the MAINLINE — every
round whose mark is not `branch`, by the kernel's own mark and never by
a key's shape — newest-first behind an opaque cursor and returned in
reading order, `{rounds: [...], pagination: {next_before, has_older}}`,
`next_before` null once `has_older` is false;
a `before` that does not parse is 400 `parameter_invalid`. It is a
WINDOW, never a document — a run has no round ceiling, so every rule
here keeps one page's cost independent of the run's size.

Each row is `{task_key, mainline, status, visibility, text_preview?,
text_bytes?, usage?, error?, compacted_before?, pruned_before?,
started_at?, completed_at?, calls: {count, items: [...]}, branches:
[...]}` — the two marks are the compaction cut, by presence; `calls`
are the tool rows this round READ, keyed `r<n>t<i>` under its own
number (a round's calls carry its continuation's number: `r1` makes
`r2t0`, and `r2` reads it), `items` the first 24 in order with `count`
the whole — a kernel fan may be hundreds wide, and bounding only the
round COUNT would leave one wide round unrenderable — each `{task_key,
tool_call_id?, name, tool?, status, is_error?, title?, metadata?,
output_preview?, output_bytes?, started_at?, completed_at?}` (`name` is
what the model called, and `tool` the kernel's wire name beside it when
the call was made under an alias — [Profile](profile.md)); `branches`
are the calls under which a VISIBLE branch hangs — a `delegate_task` call's
`<call>-model-1`, an operation-owning task's explicit children — and never an `ask` or a
`spawn`, whose await is hidden and whose face is the call row itself. A
queued or running round shows the calls it is waiting on: the thread's
"now". `?prefix=<call>` answers the branch under that call in the same
envelope — its roots and its own rounds in reading order (`mainline:
false` on every row), paged the same way; a `prefix` that is no call
of this run is 404 `not_found`. The projection reads the rows'
keys, marks and reading lists and never the edge table; the whole run
with its edges is the graph route below.

No content body is loaded at any density: previews are stamped where
the answer lands, and `GET …/tasks/{key}` remains the full-content
door, one task at a time. Tasks whose `visibility` is `hidden` are
omitted entirely — that is the one thing the class is for, and the
half no client could compute; `visible` and `collapsed` are ADVICE a
client may override.

### Read the graph

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/graph
```

The picture: `{nodes, edges,
mermaid}`, the whole run at once, for debugging, as e2e evidence, and
for a UI to draw the workflow (the graph is readable, but
cannot be written from outside). `nodes[]` is every
task in authoring order — hidden ones included, `visibility` rides so
a UI may filter — as `{key, kind, lifetime, wake, status, visibility, deliverable,
mainline?, error_key?, join?: {until: any | k, losers: cancel | run_out},
input_from, result_from, expansion_parent?}`. A race's barrier uses the
authoring vocabulary; an `all` fan places no row and draws no node. Status
uses the trace's vocabulary (`waiting`, never `queued`), and identifiers
are task keys, never row ids or STI names. `mainline` is present on every
model round: `true` for the conversation's thread, `false` for a branch
or summarizer. Round keys use a run-wide counter, so use `mainline` rather
than a key's shape to distinguish the thread from branches.

`edges[]` contains scheduling dependencies as `{from, to, structural}`,
ordered by head then source: `to` depends on `from`, and a join applies
its `until` rule across its dependencies. The boolean `structural` is
always present. `true` also records placement in the
authored sequence or branch; `false` is an additional wait or selected-result
dependency. A pair appears once, with `structural: true` when it serves
both roles. This flag does not distinguish original tasks from tasks
generated during execution.

Each node's `input_from` and `result_from` are ordered arrays of task keys,
always present as `[]` when empty. `input_from` names ordinary history and
material sources; it does not promise to replay every referenced model's
history. `result_from` selects results without importing those tasks'
histories. `expansion_parent`, when present, is the key of the task that
generated this task. Generation ownership is independent of scheduling
dependencies. A dependency can also supply material or a selected result;
preserve these separate relationships when drawing the graph.

#### Reading it as work grows

The graph reflects the current expanded structure. As work grows, its
dependencies and queued consumers' source lists can change. Race selection,
compaction and recovery also affect the content a model actually reads;
inspect `GET …/tasks/{task_key}/request` for its sealed request. The graph
response contains no prompt or tool-result bodies.

Reading the graph does not pause execution. Work added during the read may
appear on the next refresh; dependency edges always name nodes present in
that response.

`mermaid` is a `flowchart TD` text drawing the nodes and scheduling
dependencies, without material-source or generation-ownership links:
positional ids (`n0`…), the
status as a class (`:::completed`), the deliverable in the subroutine
shape (`[[…]]`), labels sanitized so no task's words can close a quote
or draw an edge. Same scoping as the trace: a browse-only principal
may read it, a tombstoned or foreign run — or a run of a conversation
the caller may not read — is 404. JSON only — the
family selects no other representation, and the text is one field of
it. THE RUN IS A SECOND DOOR onto its conversation: a
run-backed run reads and writes exactly as its conversation does —
a principal the conversation conceals (`none`) finds every run route
404, the list included; one it lists at `read` reads the trace, the
graph, the phases and the transcript and is 403 `not_authorized` on
every verb (append, resolution, approve, deny, retry, abandon, compact,
the lifecycle four, delete, the run's input door). A standalone run
has no level of its own and keeps the workspace rule.

### List runs

```http
GET /agent_api/v1/runs
GET /agent_api/v1/workspaces/{workspace_id}/runs
```

The global collection spans currently readable Runs. Its optional
`workspace_public_id` selects one accessible Workspace; the nested collection
selects that Workspace through its path. Both apply the same Run and
Conversation access rules as the individual read.

Each row carries `public_id`, `workspace_public_id`, `status`, `created_at`,
`turn`, and optional `details_pruned_at`, `failure_reason` and
`attention: {reason}`. The `turn` shape is described above. A listing loads no
Tasks; fetch the Run for its execution trace.

| Query | Meaning |
| --- | --- |
| `status` | Comma-separated Run statuses; an unknown status is refused |
| `attention` | `any` selects a standing attention reason, including on a running Run |
| `from`, `to` | Optional creation-time bounds, inclusive start and exclusive end |
| `answering_user_public_id` | Captured Conversation Turn answerer UUID |
| `agent_public_id` | Captured answering Agent or standalone creator UUID |
| `executor_public_id` | Retained Task target or current claimant UUID |
| `kind` | `all` (default), `standalone`, or `conversation` |
| `order`, `after`, `limit` | Common keyset pagination |

Time bounds are independently optional; supply ISO8601 instants. When both are
present, `from` must precede `to`. The answerer filter excludes standalone Runs.
Resource filters apply after content authorization and before pagination. The
Executor filter matches `target_executor_public_id` or
`claimed_by_executor_public_id` on retained Tasks, without duplicating a Run
that has several matches. Retrying can clear an earlier claimant; collected
details provide no association. A pool Task without a target or claimant is not
attributed to any pool member. Neither management rights nor the current default
Runner grants additional content access.
Unknown status, attention or kind values and malformed time bounds return
`400 parameter_invalid`. Ordering follows the
family's keyset grammar (`order=desc` for most-recent-first; the cursor carries
its direction). Use [Attention](attention.md) for the Task decision queue and
the [work report](work-report.md) for scoped counts and period measurements.

### Start

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/start
```

`pending → running`; creation
authors the graph, starting it spends money — two intents. Wrong
state is a 409 (`not_startable`).

### Pause and resume

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/pause
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/resume
```

`{force?: bool}`,
default false. Graceful pause stops SCHEDULING only: steps already in
flight run to their terminal and their results still apply.
`force: true` is the immediate pause: every running model step aborts
NOW and — a pause is NOT a failure — RE-QUEUES under a fresh
generation (with one carve-out: a step nothing live is waiting for —
a race loser whose join settled in the abort window — settles
canceled instead of re-queueing; resurrecting it would spend on a
dead branch); parked awaits keep their PARKS but not their clocks —
time stands still under pause (the virtual clock: no deadline can
pass, and a resolution arriving mid-pause is adjudicated against the
frozen deadline and accepted) — and detached
children survive. `resume` shifts every frozen deadline forward by
exactly the pause before the clocks re-expose (stop-from-paused
repays the same debt). Either way nothing new starts until `resume`, which re-mints
the aborted steps with the bound steers (the waiting room's
`steering` rows) draining into the fresh request: pause(force) + a
`steer` input + resume is "stop, do this instead" as explicit calls a
client can bind to one key — noting a steer lands only at an
unambiguous boundary (the next mainline round about to run; a wide
resume keeps it bound until one is). `force: true` also
ESCALATES an already-graceful pause; a plain pause of a paused run is
409 `not_pausable` (someone else paused it).

### Stop

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/stop
```

`{force?: bool}`, default TRUE (stop
means stop): waiting tasks cancel at once, in-flight steps and parked
awaits terminalize, and the run drains `canceling → canceled` as the
terminals apply. `force: false` is the GRACEFUL stop: no new graph
tasks dispatch, but already dispatched model steps and tool calls may
finish, including prepared invocations and unclaimed tool parks. Their
answers are kept, and parked
awaits keep waiting for their answer or deadline — the drain settles
only when the last of them does; stopping again with force ends the
wait. The drain itself is bounded: `canceling` clocks keep
running (a park nobody answers still expires), and a drain older than
24 hours — the longest any await may park — is escalated by the drain
sweep, since nothing legitimate can outlive it. The first Stop also permanently
invalidates results and derived requests owned by a completed run, without
rewriting its published answer or completed status. Once a terminal run
has already been stopped, repetition answers 409 `already_terminal`.
Pending derived inputs are removed; started undelivered replies and their
work are canceled by source ownership, including across child conversations.
A combined report that has already consumed multiple compatible independent
worker finals belongs to its receiving conversation. Stopping one of those
sources does not retract the read result or stop that report; stopping the
receiving conversation still stops its own work. Its `callback_sources`
records the exact consumed results without singular sender ownership.
The stop queues a bounded, source-directed recovery hint immediately, including
through completed intermediate owners. Existing recurring recovery handles a
lost hint; cancellation does not require waiting for that recurring pass.

### Delete

```http
DELETE /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}
```

Soft delete: the run leaves every
product surface now and its rows are reclaimed after 30 days. A LIVE
run refuses 409 `run_busy` — stopping a run is `stop`'s
decision, never a side effect of hiding it.

### Read the phases

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/phases
```

HOW FAR ALONG, derived
from rows that already exist, nothing stored for it: `{phases, current,
background, spend}`. Named for what it answers — the word `progress` is
the executor plane's ephemeral feed (executor.md, "Progress"; `items:
progress` below), and one word carries one meaning on the wire. A PHASE is one top-level step of an authored
envelope, read from the receipts' `steps` mirrors in write order —
`{label, keys, done, total, status}`, the label the step's key (a fan's
members joined by ` · `), `done` of `total` keys settled, the status one
of `waiting | running | awaiting_human | needs_approval | completed |
failed`; every kernel round — a tool fan, a continuation, composed work
— counts inside the phase of the round it extends, found by walking its
sources back to a named key. `current` is the index of the first phase
not completed (null when nothing is left); `background` names the
detached tips nothing waits on — still to settle, or already delivered
after the reply was final (`{key, status, result_delivered_at?}`); `spend` sums the run's
usage receipts (`input_tokens`, `output_tokens`, `cache_read_tokens`,
`cache_hit_rate` — cache read over input to six places, null on no
input — `cost_amount`, `cost_unit` — null unless every priced receipt
agrees), and `by_model` splits the same receipts by the model each
names — `{"<provider>/<model>" => {input_tokens, output_tokens,
cache_read_tokens, cost_amount, cost_unit}}`, the unit again null unless
that model's priced receipts agree — so a run a step of which re-ran on
another model through its captured recovery policy, including a result-mail
switch, says whose spend was whose without anyone re-pricing
a receipt. Receipts age out
after 24 hours; a phase whose receipt has gone is not rendered.

### Replay the event feed

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/events?after=&limit=
```

The replay window
(`limit` 1..200, default 100). Answers
`{ events: [...], pagination: { next_after, watermark } }`. Cursors are
opaque and must be stored with the host identity. A malformed cursor or
one from another event plane is a 400; the prefix does not bind it to an
individual host. A blank `after` starts at the oldest retained item;
`watermark` is the committed allocation head and survives item expiry.
An empty page with a watermark beyond the consumed sequence requires a
durable-state refresh; its `next_after` remains null. The event
vocabulary is on [Run feeds](run-feeds.md).

### The run's own waiting room

```http
GET    /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/inputs
POST   /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/inputs
PATCH  /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/inputs/{public_id}
DELETE /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/inputs/{public_id}
POST   /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/inputs/reorder
```

The run door: the conversation's waiting room
([Conversation inputs](conversation-inputs.md)), hosted by a standalone run at its own
address, same verbs, same `Idempotency-Key` contract, same 202
`{input}` and `input_queue {limit, held}`. Optional `speaker_public_id`
selects an ingress Speaker controlled by the submitting Agent, with the
same attribution and replay rules as conversation inputs. It changes no
member authority or captured memory subject on the running execution.
The run admits `kind:
message` only (it is already replying), `role: user` only, and
nothing that names a model or an assembly — `model`, `configuration`,
`context_mode`, `history`, `reasoning_replay`, `inline`,
`visible_in_context` and the two freshness fences are 422
`validation_failed` naming the field. `delivery_mode: steer` binds to
the run's one turn (`state: steering`) and lands at the NEXT
unambiguous model boundary as the person's trailing user message, in
queue order with any others. `steer_now` can insert that model boundary before pending tool
work completes, with truthful pending receipts; the original tasks keep running and are
still joined before final delivery. `queue` is the run's FOLLOW-UP, bound at
quiescence and landed BEFORE the turn-shaped `completed` — `completed`
means the queue was empty. Queued follow-ups may carry `attachments`,
with or without text: the next request carries each picture when its
model supports it, otherwise the ordinary attachment index line. The
durable landing retains the pictures for retry and history reconstruction;
a summary reads their pointers. Explicit `delivery_mode: steer|steer_now` still
refuses pictures with `attachments_not_steerable`.
The queue is bounded (16; 409
`input_queue_full`); a terminal or canceling run is 409
`run_settled`; a conversation-hosted Run's door is its conversation's
(409 `conversation_hosted` with `conversation_public_id` and
`turn_public_id`). A bound steer admits only a timing promotion via
`PATCH {input: {delivery_mode: "steer_now"}}`, with optional `expected_lock_version`;
its content stays fixed (409 `steering_held` for other edits).
`DELETE` on one IS steer-cancel. On landing the sealed request is the
audit record, the round keeps the landed messages as its own `steers`
body — what later history (the next turn's prefix), a pruned round's
composition from rows and the summarizer render before that round's
answer, each steer its own user segment in the bytes the wire carried
— and a retry or force-pause/resume of that round retains those landed
messages before any newly arriving steers, without materializing the
earlier inputs again. `input_materialized{input_public_id, task_key,
run_public_id}` names the round; at the run's terminal a steer
that never landed falls back to the queue (`input_edited{reason:
steer_target_settled}`) and stays readable here.

### Read one task

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}
```

An ask additionally exposes its captured `fields`, when present, as defined in
[Typed questions](run-steps.md#typed-questions).

The single-task read: the trace row plus the
task's full `output` text (a completed run's answer lives on its
deliverable task; this is the retrieval path) and its `output_preview` —
the bounded preview the settled call's feed item carries, so a reader
that attached after the call settled renders what a live follower
rendered (absent where no output was stamped) — its `content` and
`structured_content` blocks — `content` may carry `resource_link` blocks
naming captures, readable through `GET /agent_api/v1/uploads/{public_id}/bytes`
(uploads.md) — its `title` and `metadata` when the executor sent them
(`metadata.checkpoint` reserved: the runner's own record of its environment
before the call, verbatim — [Executor](executor.md)), the `prompt` it was AUTHORED with — any kind
that has one, absent for a spliced continuation — a round's
`instructions`, the system field it was authored with under `raw`
(absent on a round authored without one) — and, for a tool task,
the `tool_input` it was asked to run. The trace deliberately carries
neither: a task list says what a task IS, not what to execute. This read
does, because a reader with no arguments cannot render a call at all, and
it already returns that call's output, which is strictly more revealing
than the path or command that produced it. A round carries
`request_bytes`, the size its request was sealed with — the stored size
of the sealed body, so a per-round series costs one read per round and
never a body load; absent on every other kind and on a round never
scheduled. Every model task also carries `tool_definitions`: its frozen
declaration in the same schema and under the same 1 MiB canonical-JSON
`tool_definitions_bound` as the profile's declaration, including
kernel-alias `canonical`, `params` and `omit` facts and the `defer_loading`
presentation annotation. `[]` explicitly means
no tools. This field is available before scheduling, stays independent of
later profile changes, and is absent on other task kinds and trace rows.
The whole step payload and frozen execution context retain their separate
1 MiB aggregate bounds; per-field acceptance does not enlarge those bounds.
It states what that round may call; a sealed provider request's `tools`
can omit deferred schemas or an unavailable skill, or retain historical tools under
`tool_choice: none`, and is not equivalent. Missing declaration evidence
must not be interpreted as an empty set. Collected execution details
retain the existing `410 execution_details_pruned` response.
A tool task also carries `declaring_task_key` when its declaring model
round is available. Read that round for its frozen model and
`tool_definitions`; a nested call may have a narrower declaration than
the seed round. Do not derive this relationship from task-key spelling
or treat a missing key as permission to use the seed's declaration.

### Read a task's sealed request

```http
GET /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/request
```

The debug door: the bytes this
round's request was sealed with, `{request: {entries, request_options}}`
— the entries in position order, verbatim (round `r1` of a run-backed
turn: the slot blocks, memory, history, the inline lead, the input; the
seed of a standalone run under `default`/`assembly`: the creator's
slots, the workspace memory, the words; a continuation: the prior
round's sealed prefix then the results), and
the round's `request_options` with its `tools` and, under `raw`, its
`instructions`. Derived from the sealed body, never re-assembled;
nothing else rides it. A task with no sealed request — a tool task, a
round never scheduled — is 404 `request_not_sealed`. Browse standing
reads it; `rho request RUN KEY` (rho-dev) prints it.

### Answer an await

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/resolution
```

For an ask with [typed fields](run-steps.md#typed-questions), send `answer`:

```json
{"resolution_token":"the authored ask token","answer":{"enabled":false,"count":0,"format":"pdf"}}
```

Omit the token for a model's own ask. A successful resolution requires an answer
matching the captured fields. `answer` cannot be combined with non-null `content`
or a supplied `structured_content`, and cannot be used for an untyped ask.
Invalid answers return `422 invalid_ask_answer` without completing the task.
Nexus generates canonical JSON model text and the structured result from the same
answer: task detail returns that text as `output` and the object as
`structured_content`. The combined stored result uses the existing 1 MiB limit;
the UI-only meaning of ordinary tool `structured_content` does not change.
`outcome: failed` accepts the ordinary explanatory `content` without an answer.
Terminal duplicates stay idle and deadline expiry still takes precedence over
answer validation. The atomic append `resolve` entry accepts the same `answer`;
invalid resolution rolls back the accompanying appended steps.

Answer a parked `await_task`:
`{ resolution_token?, content?, structured_content?, answer?, outcome?: completed|failed }`. THE
PERSON'S DOOR: a console, or a member with write standing. The token
is a SECOND FACTOR, not a credential of its own: the call is
workspace-scoped and member-authenticated like every other write, and
the token proves the caller is the one the await was handed to. It is
therefore OMITTED for an await the kernel authored — a model's own
`ask` — which was issued no token to present; write standing is the
whole authorization there, and a factor that was never issued cannot be
required. Kernel-held task waits and spawned-reply waits issue no caller
token and cannot be resolved through this door. WHO ANSWERED is recorded: the settle's own
`task_status` item carries `resolved_by: {kind: "human" | "agent",
public_id, handle}` — the acting user's kind, id and the handle a
person reads, the approval-origin precedent, never a
column and never a proxy (a spawned child's relay says
`{kind: "conversation", public_id}` on the same key).
A model's `ask` on an AGENT-created run is ALSO listed on that agent's
inbox with its `prompt` — the notice that a person is waited on, never
claimed and never committed there ([Executor inbox](executor-inbox.md));
this door is the one door for every ask, and a second answer is `200`
with the task as it stands (`idle`). On a run a person created the ask
is addressed to nobody and lists on no inbox at all. A wrong token, or
any token on an await that was issued one
and did not get this one, is 409 `stale_claim`; a task that has not
been dispatched yet is 409 `task_not_running` (completing it early
would release successors out of order); an outcome outside the
pair is 422 `invalid_outcome`; a body over 1 MB is 422
`result_too_large` and leaves the park standing. THE DEADLINE WINS: an
answer arriving after the park expired settles the task `timed_out`
(`error.key: await_timeout`) and its content is discarded — it never
quietly succeeds late.

### Where a runner answers

The runner's claim and commit are the EXECUTOR plane's
([Executor inbox](executor-inbox.md)): a member bearer holds neither door, and a
runner holds no member bearer.

## Tools

See [Run tools](run-tools.md) for the kernel tool catalog (`GET
/agent_api/v1/tools`) and how a step imports tools, Runner environment
discovery, deferred tool search, the result envelope every tool answers
in, the `skill` tool, and the kernel’s naming registry.

## Adjudication verbs

### Retry a failed task

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/retry
```

Adjudicate an unresolved failure by
re-running it under a fresh generation (any late stale result applies
to nothing); a `needs_attention` run returns to `running`. 409
`not_retryable` unless the task is `failed`/`timed_out`/`uncertain` and
unresolved — and always for a join or delegation task, which has no execution
to re-run. A failed join is answered by abandon
or an appended repair. A failed model task may name a replacement using
`{ "model": { "model": "provider/model", "reasoning_enabled": true, "reasoning_effort": "low" } }`.
A nested model containing only a control, such as `reasoning_enabled: false`,
keeps the current reference. Omitted or `null` controls keep the current
values on the same model; naming a different model uses its defaults for
unspecified controls. The task's prompt, tools,
configuration and dependencies are retained. This retries one node and
does not repeat completed tools or start another child request. The
previous run's answer, error and outcome summary (`result`) go with it,
so a re-run never reads a stale `refused`; a step a provider declined
(`model_refused`) or was overloaded for (`provider_overloaded`) is
retried this way, on the same model or on one the person names. Explicit
retry does not renew an exhausted or refused model route. Such a repair
returns `model_route_spent`; a different unspent route must satisfy the
execution's captured model/provider constraints. The captured fallback
list and original deadline are retained, including for result mail.

A task refused with `conversation_cost_limit_reached` remains eligible for
repair even if its declared `on_failure` is `absorb` or `propagate`. Raise or
clear the [Conversation limit](conversations.md#cost-limits), then retry the
same task. A retry before adjustment reaches the same admission guard again.
Changing the limit does not resume a paused Run or revive stopped work.

### Abandon a failed task

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/abandon
```

Adjudicate by giving up: the task
settles `abandoned`, plain dependents proceed without it, joins
recount by their own modes, and quiescence judges the deliverable
honestly. The run's next state is judged in the same commit: an
abandoned sole deliverable leaves the run `needs_attention
deliverable_unresolved` at once (never a transient `running` a
converger could reopen the turn on); with work remaining the run
returns to `running`. 409 `not_abandonable` on the same terms as retry.

### Approve a held call

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/approve
```

The approver's grant ("Approval"
below): releases a tool call resting at `needs_approval` past the
stage through the one grant site the `bypass` path also takes. It
revalidates the accepted target through the addressing site. A change to
the host's default never retargets the call. If the same target's effect profile changed under the
park RESTS AGAIN with the new profile and its clock re-armed, so the
person reads the new profile before granting it: 200 with the task
still `needs_approval`. Otherwise 200 with the task `dispatched` (or
`running` for a kernel tool) and `approval: {origin: human | agent,
decided_by, decided_at}`; a runner that no longer serves the name fails
the row `tool_not_served` under its own `on_failure`. 409
`not_awaiting_approval` unless the row rests at `needs_approval` before
its deadline. At or after the deadline, the verb first commits
`timed_out approval_expired` under the task's `on_failure` and returns
that 409, even if the timeout sweep has not run. It neither dispatches
nor re-arms the park, and records no approval fact. The run's virtual
clock applies, so time spent paused does not consume the hold. 409
`not_adjudicable` unless the run is `running | paused |
needs_attention` (a `needs_attention` run approves without releasing
its hold); 403 without write standing on the workspace — the approver
is any principal with it, the agent application acting for its person
included.

### Deny a held call

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/deny
```

The approver's refusal: the
row fails `approval_denied` with `reason` (text, the first 256 bytes)
as `error.detail`, the fact stamped `approval: {origin, decided_by,
decided_at}`, and the row's own `on_failure` decides the cascade — a
model-composed call is `absorb`, so the next round reads
`<tool_use_error>This tool call was declined by the approver; do not
run it again unchanged. (approval_denied) reason</tool_use_error>` and
corrects itself; an authored `halt` step holds `needs_attention
halt_failure`, and its `retry` parks it again at its next start. 200
with the task `failed`; the same deadline check, 409s and 403 as approve
(a late denial preserves `approval_expired`, with no decision fact); a non-text
`reason` is 400 `parameter_invalid`.

### Cancel a branch

```http
POST /agent_api/v1/workspaces/{workspace_id}/runs/{run_id}/tasks/{task_key}/cancel
```

The person-side branch cancel: it ends work a MODEL started, by the key the
model saw — the `delegate_task` call's key (`r3t1`), or any node of the branch
hanging off it — walking the branch's descendants and stopping at every
mainline round and barrier without touching them. Every cancelled row
settles `canceled` with `failure_resolution: canceled` and
`error.key: task_canceled`: the one cancel that RESOLVES, so a blocking
consumer runs and reads `<task_result … status="canceled">(task canceled
by the person)</task_result>`, and a background answer is delivered
canceled — by an in-run wake for turn-lifetime work, or by mail after
the reply is final for conversation-lifetime background work. Queued and parked
rows settle now; a running round terminalizes after commit and the converger
applies it. 200 with the task
projection; 409 `not_a_branch` for a mainline round or a mainline fan member
(the mainline's verb is `stop`), 409 `already_terminal` once the branch has
settled, 409 `not_adjudicable` on a terminal run, 404 for an unknown key.

### The seam's veto

On a conversation-hosted Run, retry, abandon and the
hold-releasing append answer 409 `not_adjudicable` once the run's
variant is no longer what its turn shows — a person edited the
hold-settled turn and answered for the run. The hold then stands, the
turn never reopens behind the edit, and the next input on the
conversation stops the run `replaced`.

## Steps

See [Run steps](run-steps.md) for the step grammar and its four verbs,
how `after` and `results` read earlier work, `lifetime` and `wake`, the
round driver that expands a round of tool calls, and the task kinds a
step compiles into.

## Orchestration

See [Run orchestration](run-orchestration.md) for the seven kernel
orchestration tools — `delegate_task`, `wait`, `ask`, `spawn`, `send`,
`status` and `cancel` — and for the agent-side code path that authors the
same work through the task operation API.

## Compaction

See [Run compaction](run-compaction.md) for the in-turn repair of a round
whose request will not fit: the prune arm, the kernel summarizer, a
delegate the agent answers, and the manual `compact` door.

## Statuses and failure

See [Run statuses and failure](run-statuses.md) for what each task status
names, the three failure policies and the attention hold, every typed
error key, and the run statuses and envelope caps.

## Approval and hooks

See [Run approval](run-approval.md) for the approval stage every tool
call crosses — the modes, the origin rule, the park and the rule grammar
— and for the lifecycle hooks a declaration schedules around a turn.

## Prompt caching

The continuation chain is DESIGNED around cache reuse rather than having
breakpoints added afterwards, because a tool run re-sends its entire
prefix every round — reuse is the dominant cost term, not a nicety.

### The segment order is the contract

Most-stable first: the tool list
(which every wire renders before anything else), the system field when a
lane carries one (a standalone run's `instructions`), then the list —
the slot blocks (the agent's `system_prompt`, the room's `character`, the
person's `persona`) and memory as its first items on an assembled turn,
the history — each earlier turn with the preface its request carried —
then the turn's own inline lead and tail, and last the current input
and any steers ([Conversations](conversations.md) "The default
template"). History replays each earlier turn as its request sent it —
its preface in place, the user messages a round's request carried on
their own (each delivered result, the abort marker, each steer) each its
own message, adjacent texts merged into one message never folded into
one text — so on every wire the next turn's request is the earlier one
whole plus its own tail. Caching is a PREFIX match — one changed byte invalidates
everything after it — so three laws hold the front of that prefix still:

- the tool list is canonically ordered at compile, because a set
  re-authored in a different order would otherwise move the very front
  of the prefix;
- a system block must carry no volatile bytes (a timestamp, a working
  directory, a per-request id belongs in a MESSAGE);
- everything dynamic rides the SUFFIX ZONE after the last stable
  segment — which is why steers append at the mint and never splice
  earlier.

On a wire that carries explicit breakpoints (the Anthropic family — a
narrower fact than the profile's `prompt_caching`, which is on for every
text wire since the provider caches a stable prefix on each), the kernel
is the sole placer of two markers. The
### Where the markers land

The stable marker lands on the last system block when the wire's system
field is present; else on the last item of the slots-and-memory prefix —
the leading run of system-role items plus at most one user-role item
directly after it (memory when it exists) — derived from the sealed
list's role structure, never a stored count. It caches the tool list,
the slot blocks and memory together, and everything that grows (history,
the turn's own lead and tail, the input) rides behind it — a developer-role
item after the system run (the oldest turn's replayed lead) ends the
marked run at the system items; under an `assembly` template that leads
with the per-turn text, a caller's own `user`-role lead with no memory
ahead of it is marked as that one user item and moves the prefix every
turn (the template's choice), and a round whose list opens with a
compaction summary marks the summary, once per wall. The rolling TAIL
marker rides the last input entry, which caches this round's whole
settled prefix for the next round. A thinking block can never carry a
marker, so a reasoning tail SKIPS its breakpoint rather than being
marked illegally — the one skip: the tail marker rides under replayed
reasoning, which the provider keeps in the cached prefix.

### The tier

It is chosen by the turn's host, never per request: a
conversation-hosted request — a direct reply, a regeneration, every
round of a run-backed turn, the compaction summary born behind a turn —
takes the 1-hour tier (`cache_control.ttl: 1h`) because a person paces
it; a standalone run's rounds, seconds apart, and a InferenceRequest take the
5-minute tier (`ephemeral`, no `ttl`). Both markers of one request take
its tier. Reach is the Anthropic family alone; no paid lane this round
runs one, so the 1-hour tier is pinned in unit and unobserved live.
Every other family caches implicitly on prefix stability and needs no
emission at all — the laws above are what pay there.

Round one is message-shaped from birth, so the write happens on the
first round and the second already reads. Each round's `usage` item
carries `cache_read_tokens` and `cache_creation_tokens`, so the
transcript itself shows the reuse it is paying for.

## Feeds

See [Run feeds](run-feeds.md) for the run's durable event stream and every
item it narrates, and for the ephemeral transcript and progress feeds on
its own channel. A conversation-hosted run narrates onto its
conversation's feed instead ([Conversation feeds](conversation-feeds.md)).
