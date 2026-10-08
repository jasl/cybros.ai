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
GET  /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/events
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

- `POST /agent_api/v1/workspaces/{ws}/runs` creates a Run with
  `{run: {steps: […], billing_subject?, prompt_mechanism?, approval_mode,
  approval_rules?, default_runner_executor_public_id?}}`.
  The nullable default selects an omitted target on an authored Runner step.
  A named default must be a live, eligible Runner for the creator. Model tool
  declarations carry their concrete target; a Run can contain tasks on several
  Runners. Acceptance freezes each target, independently of delivery and claim.
  The full Run document exposes nullable `default_runner` and `runner_effects`.
- `PUT …/runs/{id}/default_runner` replaces a standalone Run's default using
  `{default_runner: {executor_public_id: UUID | null}}`. It returns the Run
  document and emits `default_runner_changed` when the value changes. A missing
  Runner is `404 runner_not_found`; an ineligible Runner is `409 runner_not_eligible`;
  a caller without standing receives `403 not_authorized`. Repeating the value
  succeeds without another event. Accepted tasks, approvals, deadlines, retries,
  and claims retain their existing targets. Hosted Runs return
  `409 conversation_hosted`; their preference belongs to the Conversation.
  NOTHING NAMES A DELIVERABLE: the run's answer is the envelope's end
  by construction (the last step placed, or the follower of a fan), moved
  by the engine round over round, and the receipt's `deliverable_task_key`
  says which key that is. `tasks`, `deliverable`, `tools` and
  `compaction_policy` on the shell refuse 422 `edge_authoring_refused`
  with `path` naming the word — a step's `tools` and `compaction` ride the
  seed's `model` step. `billing_subject` is verified at create
  (created-or-verified in the account, owned by the caller — a key
  owned by someone else refuses `billing_subject_not_owned`) and the
  frozen pair rides every step's usage receipt.
  THE SHELL: a standalone run is created
  with the configuration a conversation's turn would have frozen.
  `prompt_mechanism` is one of the three words — `raw` (the default when
  unnamed): the seed task's own `prompt`, `instructions` and `tools` ARE
  the request; `default` / `assembly`: THE SEED IS COMPILED ONCE AT CREATE
  by the one assembler — the creator profile's `system_prompt`, the
  workspace's `character`, the creator's controlling Human's `persona`,
  the workspace's and that Human's `user/` memory (no conversation rows,
  no history), then the words — with no model resolved (no window sizes
  it; the exact window gate is the scheduler's) and sealed in place of the
  first step's authored body, so every round replays it as the prefix and
  memory is FROZEN at create for the run's life. The template is the
  CREATOR's under the SHELL's word (the shell is the run's declaration):
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
  Under `raw` — the default — the seed may be a SINGLE `tool` step: the
  run's answer is that step's result, read on `GET …/tasks/{key}` when
  the task is terminal; no round runs, no model is called, no receipt is
  delivered. This is how a member REQUESTS something only a runner can
  answer (`executor.md`, "Requests"): create with `{steps: [{tool: {name,
  input, route: {kind: "runner", runner_executor_public_id: UUID}, timeout_ms?}}],
  approval_mode, prompt_mechanism: raw}`, then `start`. The row is granted by its
  origin (`author`) unless a rule NAMING that origin denies it or says
  `ask` — a rule with no `origin` addresses the model's rows alone. A
  tool deliverable that does not complete holds the run
  `needs_attention deliverable_unresolved` like any other.
  `approval_mode` is REQUIRED — `bypass | ask | rules` — and
  NOTHING IS DEFAULTED: nil or a word outside the vocabulary is 422
  `invalid_approval_mode`. `approval_rules` is optional — the rule list
  ("Approval" below), frozen onto the run row beside the mode; a
  malformed list is 422 `invalid_approval_rules`. All three ride the
  create digest: a different shell under one `Idempotency-Key` is a 409
  mismatch. `tools` and `compaction` ride the seed step as before. A run
  backing a turn carries the turn's own
  `prompt_mechanism` (`raw` under `context_mode: raw` or a raw profile),
  which the compaction arm reads (the raw rule, below).
  A run is born with its graph or not at all
  (compile failures answer positionally:
  `{ error: { code: invalid_steps, steps: [{code, path}] } }`, the path in
  the request's own tree — `steps[0].model.depends_on`). A tool step's
  `input` is bounded where its row is, at 64 KiB of canonical JSON:
  over it is `tool_input_too_large` at that step's `input`, while the
  whole envelope's 1 MB bound stays `steps_payload_too_large`.
  Honors `Idempotency-Key` (≤36 bytes, else 400): a retried create
  returns `200` with the standing run, `replayed: true`, and the original
  seed `receipt`, including its `resolution_tokens`. Later appends do not
  replace this receipt. The retry cannot know the id the lost response minted,
  so the workspace-scoped receipt finds it; a different envelope under the
  same key is a 409. The key is scoped to the caller within the workspace
  and reserved for 24 hours from run creation. After expiry,
  the same key is treated as a new create; the original run is unaffected.
- `POST …/runs/{id}/tasks` — the ONE append door:
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
- `GET …/runs/{id}` — the trace: run status,
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
- `GET …/runs/{id}/transcript?before=&limit=&prefix=` — THE
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
- `GET …/runs/{id}/graph` — THE PICTURE: `{nodes, edges,
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
- `GET …/runs?status=&attention=&order=&after=&limit=` — the list,
  and the two questions a person asks of one. Each row is
  `{public_id, status, failure_reason?, attention?: {reason},
  created_at}` — a listing loads no tasks, which is why the attention
  ROLLUP earns its place here where it would be a second answer on the
  trace. `status` takes a comma-separated set of run statuses and refuses
  a word it does not know rather than matching nothing; `attention=any` is
  "needs a person", whatever the status, because a reason stands on a
  `running` run too. Ordering follows the family's keyset grammar
  (`order=desc` for most-recent-first; the cursor carries its direction).
- `POST …/runs/{id}/start` — `pending → running`; creation
  authors the graph, starting it spends money — two intents. Wrong
  state is a 409 (`not_startable`).
- `POST …/runs/{id}/pause` / `…/resume` — `{force?: bool}`,
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
- `POST …/runs/{id}/stop` — `{force?: bool}`, default TRUE (stop
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
- `DELETE …/runs/{id}` — soft delete: the run leaves every
  product surface now and its rows are reclaimed after 30 days. A LIVE
  run refuses 409 `run_busy` — stopping a run is `stop`'s
  decision, never a side effect of hiding it.
- `GET …/runs/{id}/phases` — HOW FAR ALONG, derived
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
  another model (the answerer's declared fallback after a refusal, a
  result-mail switch) says whose spend was whose without anyone re-pricing
  a receipt. Receipts age out
  after 24 hours; a phase whose receipt has gone is not rendered.
- `GET …/runs/{id}/events?after=&limit=` — the replay window
  (`limit` 1..200, default 100). Answers
  `{ events: [...], pagination: { next_after, watermark } }`. Cursors are
  opaque and must be stored with the host identity. A malformed cursor or
  one from another event plane is a 400; the prefix does not bind it to an
  individual host. A blank `after` starts at the oldest retained item;
  `watermark` is the committed allocation head and survives item expiry.
  An empty page with a watermark beyond the consumed sequence requires a
  durable-state refresh; its `next_after` remains null. See the event
  vocabulary below.
- `GET|POST …/runs/{id}/inputs`, `PATCH|DELETE …/inputs/{public_id}`,
  `POST …/inputs/reorder` — THE RUN DOOR: the conversation's waiting room
  (conversations.md, "Inputs"), hosted by a standalone run at its own
  address, same verbs, same `Idempotency-Key` contract, same 202
  `{input}` and `input_queue {limit, held}`. The run admits `kind:
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
- `GET …/tasks/{task_key}` — the single-task read: the trace row plus the
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
- `GET …/tasks/{task_key}/request` — THE DEBUG DOOR: the bytes this
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
- `POST …/tasks/{task_key}/resolution` — answer a parked `await_task`:
  `{ resolution_token?, content?, outcome?: completed|failed }`. THE
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
  A model's `ask` on an AGENT-created run is ALSO that agent's
  inbox row, listed with its `prompt` and committed on the executor plane
  without a token ([Executor](executor.md)) — two doors, one settle: the
  second answer is `200` with the task as it stands (`idle`). On a run a
  person created the ask is addressed to nobody, and this is its only
  door. A wrong token, or any token on an await that was issued one
  and did not get this one, is 409 `stale_claim`; a task that has not
  been dispatched yet is 409 `task_not_running` (completing it early
  would release successors out of order); an outcome outside the
  pair is 422 `invalid_outcome`; a body over 1 MB is 422
  `result_too_large` and leaves the park standing. THE DEADLINE WINS: an
  answer arriving after the park expired settles the task `timed_out`
  (`error.key: await_timeout`) and its content is discarded — it never
  quietly succeeds late.
- The runner's claim and commit are the EXECUTOR plane's
  ([Executor](executor.md)): a member bearer holds neither door, and a
  runner holds no member bearer.
## The kernel tool catalog and imports

`GET /agent_api/v1/tools` publishes every kernel tool this deployment
runs, as `{canonical_name, name, effect_profile, definition, template}`.
An author may select exact canonical names through `kernel_tools` and let Nexus
import their plain definitions, or splice an entry's `definition` into an
explicit `tools` array. The same import grammar is available on Agent profiles.
The read-only [tool assembly projection](tool-assembly.md) resolves a proposed
declaration and Runner selection before authoring work.

An explicit plain kernel declaration must use the catalog's exact schema:
the registry stores wire names rather than computing them, and the tools block
is the front of every cached prefix. A paraphrase is refused
`kernel_tool_redefined`. Compact aliases remain the supported way to choose
another spelling or parameter presentation.

The store retains the full authorized declaration. Provider projection omits
schemas marked `defer_loading: true` when eager search/call tools are declared
([Profile](profile.md)), and omits a skill callable with an empty frozen catalog.
The annotation does not alter kernel schema equality. Eager skill catalogs appear
in the turn's `skills` block; deferred ones remain available through tool search.
The sealed request records the schemas actually offered to the provider.

The catalog publishes the UN-ALIASED render: every description with its
tool-name macros spelled as the kernel's own wire names. A profile that
declares an ALIAS of a kernel tool ([Profile](profile.md), the
`tool_definitions` row) — its own spelling, with a parameter map — is the
sanctioned way to declare a kernel tool in other bytes: the kernel renders
the texts with the profile's names at declaration, and a call under the
alias runs under the canonical.

`template` is the description's macro-bearing SOURCE — the text with its
`{{delegate_task}}`-style tool-name macros unrendered, which the plain `definition`
renders as the kernel's own wire names. It exists for one reader: an
adaptation pack (the SDK's `CybrosAgent::ModelAdaptations`) whose alias
entry carries a `recut: {anchor, replacement}` — ONE anchored edit
rendered against this text at declaration, so no kernel prose is ever
copied into a pack and a paragraph the kernel re-cuts fails the pack's
anchor loudly instead of drifting. A client that only declares the plain
tool never reads it. The contract pack (`contracts/nexus/v1/tools.json`)
carries ONE entry as the route serves it — `nexus.graph.delegate_task`, the
template the gem's `claude` recut anchors on — so a re-cut of any other
description regenerates nothing.

`effect_profile` is trusted metadata for the HOST — kind, destructive,
effect_scope, idempotency, reconciliation — and never rides the model's wire.
It is what the approval gate reads: the effect profile frozen on the held
row, rendered on the agent application's inbox row for the approver.

Declaring a kernel tool is the whole gesture by which an agent turns it
on, and doing it from a conversation's FIRST round matters: adding an eager
schema midway rewrites the front of the cached prefix and invalidates
everything after it.

`kernel_tools` selects additional plain definitions by exact canonical name;
null or `[]` adds none. It does not override explicit kernel definitions or
aliases. To omit a capability, omit it from both sources. Nexus composes and
renders the final declaration once when accepting the work.

### Runner environment discovery

`nexus.runners.list` (wire `runners_list`) is an optional reserved kernel tool.
It accepts `{}` and returns `{current_runner_executor_public_id, runners}`.
Each Runner entry contains `runner_executor_public_id`, `display_name` and its
announced `environment`. The list follows the Agent's declared candidate order
and freezes eligible candidates at acceptance, independently of imported tools.
The current UUID can be null even when candidates exist.

This is the accepted environment context, not a live connection probe. It reads
no later profile or announcement and never derives candidates from tool routes.
Use a candidate UUID as `spawn.default_runner_executor_public_id` to create work
in that environment. Omission inherits the spawning execution's frozen default;
explicit null chooses no Runner. Delegate tasks and child operations keep their
frozen inherited environment. No model-facing Runner change tool is provided.

### Tool search and deferred calls

`nexus.tools.search` (wire `tool_search`) and `nexus.tools.call` (wire
`tool_call`) are reserved kernel tools. Declare their catalog definitions from
the first round to provide stable entry points for deferred schemas. They work
across providers without a provider-specific loaded-tool state.

`tool_search` accepts `{query: string, limit?: integer}` (nonempty query, limit
1–20, default 5).
It searches the calling execution's frozen callable names, descriptions, Runner
UUIDs and served names, and skill names/descriptions. An exact callable query
returns that entry; otherwise matches contain all query terms. The result is
`{tools: [{name, definition, route?, skills}], truncated: boolean}`. `definition`
is the complete function schema, including the same `strict` default as provider
projection; `route`, when present, contains the declared public Runner target.
`skills` contains source-qualified frozen catalog entries. Results keep whole
schemas within the output bound; `truncated` reports omitted matches. Search
never adds a tool or reads a later executor announcement.

`tool_call` accepts `{name: string, input: object}`. `name` must be an exact
callable in that frozen declaration, not a served name guessed from another
Runner. It expands one ordinary child tool through the existing task-operation
lowering and task append path. Alias mapping, concrete target acceptance,
approval and deadlines apply normally to the child; the wrapper is not an
approval bypass. Its paired result preserves the child's error and capture
semantics. An application's code bridge may call the same discovered name
directly. An empty or narrowed declaration never gains authority through search
or call.

### Tool results

- THE RESULT ENVELOPE, shared by the await resolution above and the
  executor's commit ([Executor](executor.md)):

  **THE RESULT GRAMMAR, and both park doors share it** — one wire field,
  one engine, one meaning. `content` is MCP's `CallToolResult.content`:
  either a plain **String** or a list of **content blocks** of two kinds —
  `{"type": "text", "text": "…"}` and `{"type": "resource_link", "uri":
  "nexus://uploads/<public_id>", "name": "…", "mimeType"?, "size"?,
  "title"?, "description"?}`. A bare String is the identity case and
  stays valid forever — it and a single text block write the same bytes,
  which matters because the tool-result entry is the prompt-cache
  breakpoint. A BLANK result (empty, or only whitespace) writes no body at
  all and the model reads nothing, which is what it has always done. A
  `resource_link` NAMES A CAPTURE the committing executor staged as its
  own (`executor.md`, "Captures"): `uri` is the one scheme the kernel
  resolves, `name` is required (MCP `BaseMetadata`), the rest are typed
  and stored verbatim; the body binds the upload so the capture lives as
  long as the result, and its bytes are read on `GET
  /agent_api/v1/uploads/{public_id}/bytes` (uploads.md) by the result's
  reader. What the MODEL reads of it: a link to a bound image or PDF upload
  (the upload's detected type, not the link's optional `mimeType`)
  rides as ONE attachment-only message after the round's last result when the
  current model accepts that media type, else as an attachment index line.
  Later conversation turns carry these attachments with the retained round,
  applying their own model selection and history budget. A non-media link
  renders nothing — the tool's sentence names the path. An id that is not
  the committer's own capture refuses 422 `unknown_result_upload`, whole
  or nothing, with the park standing. An operation-owning tool final may additionally retain
  captures already bound to that parent's sealed operation observations.

  The vocabulary is CLOSED to those two kinds. A well-formed block of any
  other kind refuses 422 `unsupported_content_kind`; a shape outside the
  grammar (a link of another scheme, a missing `name`, a mistyped field)
  refuses 422 `invalid_content`; more blocks than a body can hold refuses
  422 `too_many_content_blocks`; and bytes that cannot be stored at all
  refuse 422 `result_unstorable`. The grammar refusals leave the park
  standing. `result_unstorable` on a TOOL CALL does not: the runner's
  report is refused (the 422), and the park is closed at once — the task
  settles `failed` with `error.key: result_unstorable` and `error.detail`
  naming the storage guard's word (`unsupported_text: the result's bytes
  cannot be stored`), so the next round reads the failure instead of
  waiting out the claim deadline (an outcome that cannot be stored is a
  failed outcome, not an open park; a typed refusal is final for the
  runner, which never resubmits it). On an AWAIT the same refusal leaves
  the park standing: its resolver is a person at an interactive door.
  (`content` used to accept anything and flatten it into the model's tool
  result — a wrong transcript rather than an error.)

  **`structured_content`** is MCP's `structuredContent` — any JSON value.
  Explicit null and false are retained; omission means no structured value.
  It rides beside the text and never inside it, and WHO SEES IT is worth
  stating exactly: it is always served back on the task read, where a
  client or a UI picks it up, and it NEVER reaches the model — this wire's
  tool result is a string, the same division MCP itself draws, where
  `content` is what the LLM reads and `structuredContent` is result data
  for the client. The kernel serializes nothing into the text position: a
  result carrying structure and no text hands the model `""` (its `output`
  reads `""`, never the storage envelope's JSON). MCP's "a tool that
  returns structured content SHOULD also return the serialized JSON in a
  TextContent block" is the RUNNER's to honour — a tool that wants the
  model to read its structure puts the words in `content` beside it, and
  the model reads the prose while the client reads the structure.

  **`result_type`** is accepted, validated and not stored. Absent reads as
  `"complete"` (the spec's own rule) and anything else refuses 422
  `invalid_result_type`: its only other value belongs to MRTR, which this
  system does not implement, so accepting it would be a lie.

  A settled task reads back through `GET …/tasks/{task_key}`, which
  carries `output` (the text projection, unchanged) alongside `content`
  (the blocks) and `structured_content`. TWO MORE FIELDS ARE UI-ONLY: `title` (the one-line
  header a collapsed transcript row shows — the file it read, the
  command it ran) and `metadata` (the model-invisible carrier: structured
  material for a per-tool renderer, one reserved key `checkpoint` — the
  runner's own record of its environment before the call, verbatim —
  [Executor](executor.md)). Both
  are served on that same read, only when the executor sent them. Neither
  is EVER spliced into a model request; the model sees the output and
  nothing else. Without them every tool renders as "Called X" over a raw
  blob.

  Where a runner finds this work, claims it and commits its answer is
  the executor plane's inbox ([Executor](executor.md)) — per executor,
  across every live run of its account, with `work_available` pushed on
  the executor's own channel; nothing of it is reachable with a member
  bearer.

- `POST …/tasks/{task_key}/retry` — adjudicate an unresolved failure by
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
  retry does not replenish a result-mail run's automatic fallback allowance,
  and does not re-arm a declined or overloaded step's once-only re-run on
  the answerer's `fallback_model`.
- `POST …/tasks/{task_key}/abandon` — adjudicate by giving up: the task
  settles `abandoned`, plain dependents proceed without it, joins
  recount by their own modes, and quiescence judges the deliverable
  honestly. The run's next state is judged in the same commit: an
  abandoned sole deliverable leaves the run `needs_attention
  deliverable_unresolved` at once (never a transient `running` a
  converger could reopen the turn on); with work remaining the run
  returns to `running`. 409 `not_abandonable` on the same terms as retry.
- `POST …/tasks/{task_key}/approve` — THE APPROVER'S GRANT ("Approval"
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
- `POST …/tasks/{task_key}/deny {reason?}` — THE APPROVER'S REFUSAL: the
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
- `POST …/tasks/{task_key}/cancel` — THE PERSON-SIDE BRANCH CANCEL: ends work a MODEL started, by the key the
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
- THE SEAM'S VETO: on a conversation-hosted Run, retry, abandon and the
  hold-releasing append answer 409 `not_adjudicable` once the run's
  variant is no longer what its turn shows — a person edited the
  hold-settled turn and answered for the run. The hold then stands, the
  turn never reopens behind the edit, and the next input on the
  conversation stops the run `replaced`.

## The step grammar

An envelope is `{steps: [...]}` and a step is an object with ONE verb key:

    { "tool":  { "name", "input"?, "route"?, "key"?, "timeout_ms"?, "model_defaults"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "after"? } }
    { "model": { "prompt", "key"?, "model", "tools"?, "instructions"?, "configuration"?, "compaction"?,
                 "fan_on_failure"?, "detached"?, "lifetime"?, "wake"?, "retry"?, "on_failure"?, "visibility"?, "attachments"?, "after"?, "results"?,
                 "kernel_tools"?, "runner_executor_public_ids"?, "runner_tool_names"? } }
    { "ask":   { "prompt", "options"?, "multi"?, "key"?, "timeout_ms"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "after"? } }
    { "wait":  { "task", "run_public_id"?, "key"?, "timeout_ms"?, "detached"?, "lifetime"?, "wake"?, "on_failure"?, "visibility"?, "after"? } }
    { "parallel": [ step | [step, ...], ... ], "until"?: "all" | "any" | k, "losers"?: "cancel" | "run_out",
      "key"?, "on_failure"?, "lifetime"?, "wake"? }

WRITTEN ORDER IS THE GRAPH OF WAITS. Every step waits on the step before
it (the tips of everything placed so far); a `parallel` runs its members
at once and the step after it waits on all of them; a member that is an
Array is a sequence run one after another inside the fan. READS never
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
on a step — the node column's word — says THIS ENVELOPE DOES NOT WAIT FOR
IT: the next step is placed as if it were not there, a detached `model`
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
reference naming a race's MEMBER instead waits on that member and reads its
own envelope: a live consumer, so the race spares it as shared
work rather than canceling it — name the race to read the race's answer. A
reference follows the producer's logical completion through model tool rounds,
an operation-owning tool, or a graph-authored `ask` / `spawn(wait: true)` waiting for
its answer. A nonwaiting spawn still returns its launch acknowledgement.
It adds to written-order dependencies; it never replaces
them or gives the consumer ownership of the producer.

A named model answer is result material, never a replacement conversation
history: the reader gets the producer's final answer after its tool rounds,
not its request. A race reaches a reader only by
name: `results: [race]` reads the selection captured when the race settled,
or a failed race's partial winners followed by its failure, and never a
member the race did not select; a step after a race that names nothing reads
its prompt alone (a top-level `model` step, the mainline it continues). Across
appends the rule is the same: a later envelope reads an earlier one's rows by
key, never by position.

Every step accepts `lifetime?: "turn" | "conversation"`. Omission inherits
its enclosing authoring context; ordinary roots default to `conversation`.
An explicit value overrides that context for the step's work and descendants,
without changing later siblings. A parallel group's value supplies its members'
default. Dependencies do not transfer lifetime. `turn` adds a final-delivery
obligation even on detached work: its result must be consumed before this
AgentRun's reply becomes final. Unconsumed `conversation` background results
arrive in a separate supplementary turn after the original reply is final, even
if the result finishes early. This removes no foreground dependency or failure
hold. Standalone runs still wait
for all work. Append and retry refuse new turn-owned work after final delivery
with `turn_already_delivered`; a replayed successful append receipt is unchanged.
See [orchestration](../../orchestration.md) for examples and cancellation scope.

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

Every step: `key` (`[A-Za-z0-9][A-Za-z0-9_-]{0,63}`, unique per run;
minted `s{revision}-{verb}-{n}` when absent),
`visibility` defaults per kind (model `visible`, tool `collapsed`,
ask/wait/barrier `hidden`); `on_failure?: absorb|propagate|halt` (defaults:
model `halt` — a failed execution asks for repair via the attention hold; retry/abandon are the
answers; wait `absorb`; tool/ask/barrier `propagate` — an authored pipeline step
that could not run skips its dependents). `retry?: 0..5` applies to
MODEL steps only — the budget is the round converger's; a tool call or an
ask parks on its holder and has nothing to re-run by budget, and `retry`
on either refuses `unknown_step_option` (a budgeted requeue on a tool's
failed commit is the recorded alternative, if a consumer ever asks).
Kernel-driven tool fans differ at
S5: a tool that RAN and errored is a COMPLETED task whose result
carries the error envelope the model reads — and a could-not-run
failure there is authored `absorb`, so the continuation always hears
what happened.

What a task READS BACK as, on the trace and the single-task read: `key`,
`kind` (`model_task | tool_task | await_task`, `join_task` for a kernel
barrier, or `delegation_task` for a turn-owned child's report), `lifetime`
(`turn | conversation`, the resolved selection), `wake` (`auto | passive`), `status` (the engine's `queued` is the
product's `waiting`), `after?` — its current dependency keys, at every
status, absent for a root. The kernel can update them when a model task
expands into more work; settlement alone does not remove them. `waiting_on?` — the
keys of the tasks it still waits for, present only while the task has
spent nothing (`waiting`, or a tool call's `needs_approval`) and only for upstream tasks
not yet settled; once started, its status says what it waits on (the
kernel, a machine, a person), and once settled the question is moot — a
racing barrier completes with sources still running, and a live list
would contradict the status `after` does not — `on_failure`,
`failure_resolution?` — THE ADJUDICATION AXIS, a person's stamp:
`abandoned`, or `canceled` for a person's branch cancel; an `absorb`
policy resolves its failure by derivation and stamps nothing, so a
client reads `on_failure` beside it — `retry?: {budget}` (a model step's),
`model?`, `tool_name?`, `tool_alias?`,
`target?: {executor_public_id, display_name?}` — the immutable accepted Runner
destination, present before delivery and retained after withdrawal; distinct from
`addressed_to?` — who a started tool call or ask is for, `{role,
executor_public_id}` for an addressed row and the role alone, `{role:
tool_provider}`, for a pool row; absent on a kernel-executed or model task
([Executor](executor.md) "Where a tool call goes") — `claimed_by?:
{executor_public_id}` — the executor that took the call, a snapshot kept
after the executor is gone; absent until a claim — `approval?: {origin,
decided_by?, decided_at}` — the stage's fact on a tool call, absent until
it was decided: `origin` is `mode` (bypass), `rule` (an allow rule),
`author` or `kernel` (pre-approved by the row's writer), `human` or
`agent` (an approve or a DENY by a principal — the status and `error.key`
say which), `decided_by` the deciding principal's public id on the last
two — `result?`, `error?`,
`visibility`, the stamps, and `result_delivered_at?` — present
only on a background answer that outlived its turn and was delivered to the
conversation as the kernel's own input. A barrier's `until`
and `losers` draw on the graph route, where the picture needs them.
Nothing else: not whether a round is the mainline's continuation or a
composed branch, not that a step was placed in the background.

- `model` — `model: {model: "provider/ref", reasoning_enabled?, reasoning_effort?}`
  (required on this API; task operations can inherit their frozen model defaults),
  with independent enablement and effort as described in
  [Models](models.md#reasoning-selection),
  `prompt` (required on this door and in task model operations; the kernel's own
  rounds carry none), `attachments?: [upload_public_id, …]` (the
  files beside the prompt — the caller's own staged uploads,
  resolved against the door's member — the run's creator on create,
  the acting member on append — bound for liveness, composed as one
  message with the prompt's words; `invalid_attachments` positionally for a malformed or empty
  list; never authorable by the kernel or by a model-origin task operation. The
  round reads them as an input door's does: natively on an engine whose
  row takes images, as the `[Attachment: …]` line in place otherwise.
  Ordinary files carry their `nexus://uploads/<public_id>` reference in that
  line and are available to the run's active claimant through the executor
  attachment resources. Later rounds re-read the index through the sealed prefix),
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
- `tool` — `name` is the served execution name. A kernel name refuses
  `reserved_tool_name`, except an explicitly Runner-routed source skill.
  `route?: {kind: "runner", runner_executor_public_id?: UUID}` selects Runner
  delivery. An omitted UUID resolves the host's nullable default once at
  acceptance; no default refuses `runner_target_required`, explicit null is
  `invalid_tool_route`, and an unserved selected tool is `tool_not_served`.
  An absent route never infers a Runner by name. An accepted call can wait for
  an offline target until its own deadline. Task-scoped child calls resolve declared
  callable names against their frozen context and refuse `unknown_tool_name`
  or `tool_route_mismatch` when they try to expand that authority.
  `input` is a JSON object (`{}` when absent); `timeout_ms?` sets its clock.
  An eligible executor may also consume explicit `model_defaults` on a standalone tool:
  `model`, `configuration`, `tools`, `instructions`, `compaction`, `on_failure`,
  `fan_on_failure`, `retry`, `kernel_tools`, `runner_executor_public_ids` and
  `runner_tool_names`. Import intent uses the same grammar and acceptance-time
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

### Model tool imports

Member-authored model steps and standalone tool `model_defaults` may use
`kernel_tools`, `runner_executor_public_ids` and `runner_tool_names` with the
[Profile](profile.md) grammar. `kernel_tools` adds selected plain canonical
definitions; explicit `tools` remain independent declarations. The ordered Runner
UUID list declares candidates. The Run's selected default must be among them
when importing from that Runner. With no selected Runner, candidates remain
available through `runners_list` but contribute no tools. `runner_tool_names: null`
imports all model schemas from the selected Runner and `[]` imports none.

Only acceptance reads current announcements. The task stores the resulting
definitions, selected environment, candidate facts and skill catalog. Import
intent is consumed there; it is not a second persisted source that later rounds
resolve again. The original explicit-tools form, without import fields, retains
its direct Runner route semantics and does not automatically import announcements.

A tool's own explicit execution route is independent of these model defaults:
the executor running that tool does not become the target of its child tools.
Children inherit the frozen context. A child model operation may narrow `tools`
by callable name, but any import field is refused as `context_not_authorable`.

## The round driver

A model round that answers with TOOL CALLS is the middle of a turn, not
its end. The kernel expands it in the same transaction that applied the
answer, through the same door and grammar a client uses: it places
`parallel` (one `tool_task` per call — carrying the provider's own
`tool_call_id` as the pairing key, the parsed arguments as `tool_input`,
and the fan policy) and then one continuation `model_task`, which by
position waits on the whole fan and reads the round and every result.
The continuation inherits the source round's COMPLETE
request surface (model, effort, configuration, tools, instructions), and
if the source was the run's deliverable the deliverable MOVES to it —
a run must not complete on a round that only asked for tools. Every
queued consumer the round had — a step placed after it, a branch
continuation — is handed to the continuation in the round's place
(attachment forwarding), so nothing ever reads a round's tool-call
chatter as its answer.

NO CUMULATIVE CEILING, ONE REPEAT BRAKE. A run's size is a function of
MODEL BEHAVIOUR — one tool row per call, one continuation per round —
and the kernel puts no round, task or model-step ceiling on it:
long-horizon work is the norm, concurrency is the only capacity control
and the admission plane owns it. The per-request envelope bounds below are request
hygiene, never totals. What the kernel does bound is REPETITION WITHOUT
NOVELTY. Each round's calls are read with their results: the call as its
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
round. A fan is a SET: reordering or regrouping calls already brought is
not new. A round of nothing but `read_process` polls is the runner's
designed wait: never refused, never stale, and outside the count — unless
one of the above reached the model with it, or material was delivered
beside it, which keeps it in the count. The brake reads at most
twenty-four rounds back, whatever the run's length.

These rows are KERNEL-materialized: `revision` does not tick (the
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

The continuation is the engine's main-thread mark: the chain of marked
model tasks IS the mainline, structural, never inferred from a key
convention. The trace does not render the mark. A client follows the
conversation through the TRANSCRIPT, whose rounds carry `mainline`
(`true` for the mainline, `false` for composed work), and a client that
must splice onto the mainline's latest round reads `deliverable_task_key`:
the kernel moves the deliverable from a round to its continuation and to
the waking round, so it names the main thread's tip whenever the author
designated a mainline round as the answer.

## Agent-side code orchestration

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

## `delegate_task`, `wait`, `ask`, `spawn`, `send`, `status`, `cancel` — kernel orchestration tools

Seven kernel tools an Agent may select for its declaration, published
as `Nexus::Tools::DELEGATE_TASK`, `::WAIT`, `::ASK`, `::SPAWN`, `::SEND`, `::STATUS` and
`::CANCEL` (`nexus.graph.{delegate_task,wait}`, `nexus.human.ask`, `nexus.conversation.
{spawn,send,status,cancel}`; wire names `delegate_task`, `wait`, `ask`, `spawn`, `send`,
`status`, `cancel`). Each is a small adapter over a door that exists
anyway — the shared append door (a lowering, a splice), the
conversation create, the one input door, the conversation's stop. The
published texts are the un-aliased render;
a profile's aliases (`Agent`, `spawn_agent`, `AskUserQuestion` —
[profile.md](profile.md)) re-spell the tool names these texts mention,
and a call made under an alias becomes a row under the wire name below
with the alias beside it (`tool_alias`).

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
call's result; it never silently inherits another model. The existing declared
fallback for classifier refusal or exhausted provider overload still applies.
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
and at assembly the branch's last word is rendered AS THE CALL'S PAIRED
RESULT (the stored result says only `Task r3t1 started.`). Several
waited calls in one message run at once and answer in call order. The
id the model reads back is the CALL's key (`r3t1`); the branch is
namespaced under it. Refusals are error envelopes of the call, never a
failed round: `prompt is empty. …`, `wait must be true or false.`,
`tools: "browse" is not one of your tools. You have: …`. The
continuation reads the mainline, every call and every waited branch, and
that list is bounded (`too_many_reads` past 256 waited calls in one
message — 257 reads including the mainline, `Tasks::Compile`'s kernel bound
— request hygiene, not a ceiling).

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

`spawn({prompt, agent?, label?, wait?, lifetime?, wake?, model?})` — a conversation with another agent
that PERSISTS. The kernel creates a CHILD conversation off
the run's own conversation (its `parent` block — archive/delete follow the
subagent tree; Stop follows each request's originating execution,
[conversations.md](conversations.md)), answered by the profile `agent`
names (`@handle` or public id — WHO; `to` is WHERE, a conversation, on
every conversation verb; omitted, the caller's own profile — a
fresh copy with an empty context, a subagent; named, that agent's own
engine, tools and memory, a peer — both use the same answerer selection) and briefed with `prompt` as its first turn: the SPAWNER's own
row, origin `agent`, stamped `sender_conversation_public_id` = the
parent's, riding THE INITIATOR'S MODEL (the call's
`model` — a catalog ref `provider/model` at the model's own reasoning
default, refused at the call `model_not_authorized: model: "…" is not a
model you may run here (<the resolver's word>).` when this account may
not run it — else the spawning run's current main reply selection; the wire always
carries one) and NONE of its tool narrowing or approval word — the child
runs under its answerer's whole declaration, `spawn` included: no depth
or fan-out ceiling. The answerer reads that model only when it has no
`default_model` of its own ([Profile](profile.md)) and no reply here
yet: the addressee's engine order ([conversations.md](conversations.md)). The
child copies the parent's access carrier (entries plus the parent's
derived-full pair materialized, minus the child's own creator/answerer
pair), its billing pair, and the caller's frozen default Runner. Supplying
`default_runner_executor_public_id` explicitly replaces that default; null clears
it. A selected Runner must be eligible for the child's answerer or spawn refuses; its `user/` memory rung is the ANSWERER's controlling Human's
whoever posts the turn. The child hangs off the conversation, never a
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
its own job (`AgentRuns::ConversationToolJob`, one job for the
conversation verbs) in three idempotent transactions — the child (its
unique `spawn_node_id` is the recovery key: a twin run reads the
winner), the await, then the brief, whose commit wakes the child — so a
retried job resumes where it stopped and never mints a second child.

With `lifetime: "turn"`, spawn also creates a detached `delegation_task`
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

With conversation lifetime, THE CHILD'S REPLY comes back once, whichever way the call was made
(the relay, `AgentRuns::Spawn::Relay`, level-triggered over the child
turn's `relayed_at` marker with a recurring sweep — a lost kick loses
nothing): the reply to a waited spawn's initial request settles its parked
await TRUSTED by the kernel with the reply's text (its `task_status` item carries
`resolved_by: {kind: "conversation", public_id: <child>}`; a canceled or
failed child turn fails the await with the words, and `absorb` runs the
continuation), and every other owed reply — no await, an expired or
canceled one — is kernel mail on the parent through `Mail.child_reply`:
`origin: child`, the child's id as the sender stamp, the spawn envelope
as the text with the originating `spawn` or `send` call's task key,
authored as task mail is (the originating request run's creator and
request surface). The originating request's `wake` selects an automatic
reply or passive history message. The recipient is that run's answerer;
automatic mail uses its selected model, approval tightening and the intersection
of its seed's tools with the current declaration, including an explicit empty
set. Kernel aliases match by canonical identity; executor tools match by name. For a
later queued `send`, these belong to the execution that sent that request;
they are not selected from the parent's active turn at delivery time.
When that model is unavailable, automatic result mail has one alternative:
the same recipient's current `default_model`, if different — and never a
model that already declined that step. The mail turn
uses a run even for a tool-less profile. The allowance covers the whole
mail run's main reply path, not independently selected model branches.
Exhaustion holds the run at `needs_attention`, preserving its received
prompt and failed task for an explicit task retry. See
[result delivery](../../orchestration.md#how-results-reach-the-conversation)
for the recovery and ownership rules.
If the seed could not be prepared until retry, an implicit history-window
overflow holds with `history_exceeds_fit` rather than silently discarding
history. Retry with a larger-window model or an explicit template history
budget; this delayed preparation does not start a conversation summary. The
200-turn candidate window's end is no overflow there — no retry changes a
turn count — so that request sends the newest window, narrated as a
`context_trimmed` event.
Owed means the PARENT opened the turn (the brief, a parent `send`) and the
run that sent that particular request was
not stopped. The source may be stopped even after its own reply was delivered.
Stopping the original spawning execution does not silence replies to later
independent `send` requests. Stopping a later sending execution suppresses that
request's undelivered reply, even when the original spawning turn completed.
A person's own exchange in the child is never relayed.
Only the initial request's reply may settle the spawn await; a later
`send` cannot consume it, even when both calls came from the same run.
Each queued `send` may select its own `wake`; omission inherits the sending
task's policy, not the original spawn's. A steer that joins an already-running
child request keeps that request's return-mail policy. Passive mail carries no
model selection and does not attempt model fallback.
An await appended but not yet parked defers the initial reply's relay to the
next pass rather than mailing a reply the await would then time out
against. If the reply arrives after the await's deadline but before the
timeout sweep, the relay expires the await and still delivers the reply as
mail. An expiry is not a reply delivery. A reply already delivered through
the await is never also delivered by another relay attempt.

`send({to, agent?, message, steer?, deliver_in?, deliver_at?, model?, wake?})`, `status({to})`, `cancel({to})` —
the three verbs on a conversation another agent answers,
ONE executor keyed by the wire word, the same job. `to` is WHERE:
the LABEL `spawn` gave a
child of the run's own conversation, or any conversation's public id,
resolved through the member plane's one read funnel
(`Conversation.visible_to`): what the sender may not read is
`unknown_conversation`, a side is `side_conversation`, and a conversation
ABOVE the sender in its own subagent tree is `ancestor_conversation` for
`send` and `cancel` (a subagent's steer or stop there would interrupt or
stop the turn it answers to; `status` reads an ancestor freely). `agent`
on `send` alone is WHO: a principal inside that
conversation by `@handle` or public id, the door's one member
`answering_user_public_id` — the row and the reply turn it opens are
that agent's, on the engine that answered for it there (the addressee's
engine order, [conversations.md](conversations.md)); absent, the
conversation's own answerer. A name that is nobody's is `agent: "…"
names no member of this account. The agents are: …` (the door word
`principal_unknown`, `spawn`'s sentence); a Human or a profile without
standing there is `agent: … cannot answer in <id>: it is not an agent with write standing there.` (the door's
`answerer_not_eligible`); the settle names it — "Sent to `<id>`, for
`@handle` (queued)". `deliver_in` / `deliver_at` on `send` schedule the row
(the door's fields, the door's rules: not with `steer`); `to` may be the
sender's own conversation, so a model wakes itself at a time with its own
words. A retried `send` keeps its first accepted deadline: the receipt
digests the relative delay before resolving the clock and retains the
accepted deadline for the tool result, even after the input is consumed. `send`
posts the SENDER's own row on the addressee through the one input door
(`Command.sent`: the author is the profile whose engine made the call,
`origin: agent`, `sender_conversation_public_id` = the sender's
conversation, a `direct_reply` head riding the initiator's model as the
spawn brief does — the call's `model`, judged by the same check and
refused with the same sentence, else the sending turn's selection; read
by the addressee only when it has no preset and no reply there — the
kernel impersonates nobody),
queued by default; `steer: true` binds it to the reply running there
and lands at that reply's next model boundary (nothing running: the
door's queue fallback). A steer joins that existing turn without changing
which request opened it or creating a separate reply obligation. A queued
send, including that fallback, opens its own reply turn. Standing is the sender's `full` on the addressee
as the door judges it — a `read`-level addressee answers
`not_authorized: you may read <id> but not write in it.`; the door's
other words (`input_queue_full`, `conversation_archived`, …) are relayed
by name. A child whose parent is BLOCKING on it (`wait: true`, the
`<call>-spawn-1` await parked) is told `parent_waiting: your parent is
waiting for your reply; end your turn with the answer instead of
sending.` — before the ancestor refusal. One's own conversation is
a lawful addressee: the row queues like any row. The call settles "Sent
to `<id>` (queued|steering)". A queued send to the sender's own child,
including a scheduled execution child,
promises a later `<task_result task="<send call>" conversation="<id>">`
message, addressed to the sending execution's answerer and request
surface. A steer joining an existing child turn shares that turn's original
reply; it promises no separate result for the steer call. A peer send is
a queue row without an automatic reply obligation. Idempotent under a
retried job by a hosted receipt keyed on the call (`send:<run>:<call>`), so
the row is posted once. The receipt retains the accepted delivery state;
replaying a consumed steer still describes the existing reply, without
promising a new one. `status` answers three facts — "conversation `<id>`
— running|idle; queue: N waiting; answered by `@handle`." — and a fourth
only when messages from that conversation wait in the caller's own
queue, where a running turn keeps them: "1 message from it waits for
you, delivered when you end your turn." ("N messages … wait …"). Every
field is a model-facing name to measure. `cancel`
stops all existing execution owners in the addressee, including historical
background work, then cancels derived requests by source run/task. It does
not cancel an independent request merely because it occupies the same reusable
child conversation. Authorization is the sender's `full` on the addressee.
A reply the addressee owed the still-active sender can arrive marked canceled;
a reply whose sender was also stopped is suppressed. An idle addressee can
still have background work to stop. Only an addressee with no remaining source
cut or active cancellation answers that nothing remains to cancel. A standalone
run refuses all three (`send needs a conversation: this run has none.`).

THE ENVELOPE (one renderer, `AgentRuns::TaskResultEnvelope`). Every
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
AN OPERATION OWNER'S BOUNDARY instead names the parent tool's own key and
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

## `skill` — loading one skill's instructions

One more KERNEL TOOL an agent declares from the first round, published as
`Nexus::Tools::SKILL` (`nexus.skill.load`, wire name `skill`; a profile
may alias it — Claude Code's `Skill({skill})` maps `skill` onto `name`).
`skill({name})` loads a document from the turn's frozen skill catalog, exposed
through the `skills` block or `tool_search` according to schema visibility.
Runner documents use declared callables such as `mac_skill` and `build_skill`,
each carrying a concrete Runner route to the served `skill` tool. Equal document
names remain separate because each entry names its callable and source UUID.
The assembly renders `- callable / name [executor UUID]: description`; kernel
memory entries omit the UUID. The result is the document body as ordinary tool
result content, with no additional task kind or graph edge.

For a non-Runner skill callable, the Agent application's announced document has
precedence, then the workspace's `skills/` row, then the controlling Human's.
Acceptance freezes that source as well. A call reads its selected source, never
the host's current default or another same-named document. A source no longer
serving the selected skill fails delivery with `tool_not_served`; a document
missing at load returns `skill_unknown` as ordinary tool-result data. Later
catalog changes apply only to later acceptance.
`nexus.skill` cannot be a Workspace provider override.

## Compaction — the repair, not a policy

A round whose request WILL NOT GO is not a failure to report; it is a
round to make fit. The kernel never picks a threshold at which someone's
context gets shrunk — that stays the app's policy — but it does refuse
to let a round die for size when it could be repaired, because the typed
refusal was otherwise a dead end with nothing on the far side consuming
it.

ONE ARM, TWO HOSTS. The same repair serves a ROUND of a run — standalone
or backing a turn; this section — and, between turns, a conversation's
timeline (conversations.md, "Compaction — a context that will not fit"):
one summarizer task, one rendering, one set of instructions, one
`context_compacted` item. A mid-turn summary is an entry INSIDE the turn
it repairs, never a second turn.

FOUR TRIGGERS, named on the event as `trigger`:

- `usage` — THE PROVIDER'S OWN COUNT, checked first on every lane. The
  last usage record the provider reported for this context (the mainline
  source's `input_tokens` — the request this round's prefix replays)
  plus the cost of what was appended since it (the tail: the round's
  answer, its results, any steer) over the model's window arms the
  repair BEFORE any counter runs. Occupancy derives from the last
  reported record, never from re-counting; a round with no record behind
  it — round one, or a lane that reports no usage — falls to the counter.
- `wall` — the composer's byte bound (`context_overflow`) or the model's
  window by the lane's own counter (`estimated_input_exceeds_model_limit`).
  ONLY AN EXACT COUNT MAY FAIL A ROUND — estimates advise and bytes
  enforce — but an estimate from a real tokenizer is enough to ARM,
  because compacting a little early costs a summary while not compacting
  costs the round. A lane declaring no counter is measured
  bytes-as-tokens, a bound that overstates, so it never arms before the
  send; on such a lane the usage trigger is the pre-send gate.
- `overflow` — the provider's own length rejection, AFTER the send. It is
  classified as `provider_context_overflow` and repairs instead of
  retrying: the round is requeued WITHOUT charging its retry budget (a
  repair is not a failed attempt) and the summarizer is armed. The
  classification reads typed provider codes or narrow error sentences.
  Responses can answer 200 and fail inside the stream with
  `context_length_exceeded`. HTTP 400/413 errors can carry that code or
  llama.cpp's `exceed_context_size_error`; the same status gate also
  recognizes the specific length-rejection sentences from Anthropic,
  Gemini, OpenRouter, llama.cpp and Strata. Only structured error fields
  and the parsed error message are read, never an echoed raw request.
- `manual` — somebody asked: COMPACT NOW below, or the conversation's
  `POST .../compaction` reaching a running run-backed turn's next queued
  round.

A REFUSAL IS THE GOOD CASE. Some endpoints answer 200 having silently
discarded most of an oversized input — observed live on two OpenRouter
models, unaffected by `transforms: []`. The kernel narrates the
suspicion and never acts on it: a round that reports FEWER input tokens
than its source did, by more than its own tail could explain, settles
with `input_truncation_suspected: true` on its `round_result`; evidence
for a watcher, not a trigger.

A caller can set `configuration.max_output_tokens` when the selected
model declares that control in its `generation_parameters`; an undeclared
parameter is refused. The caller chooses the cap, and the kernel validates
and forwards it through the model's declared protocol. Shared-window
planning bounds the input without reserving the requested output tokens,
so the provider can still reject a request whose combined input and output
budget exceeds its window. Recognized context-overflow errors use the
overflow trigger.

The configured window must match the provider's actual loaded context. An
overflow repair does not discover or rewrite it. If that configuration is too
large, the summarizer may also be rejected; if the requested output budget alone
is too large, removing history cannot repair it. Repeated rejection of the same
round does not trigger another summary. Correct the model's context and output
configuration, and shorten the input when its fixed content cannot fit. Once
the repair is unavailable or exhausted, a context-length rejection fails the
step without spending its ordinary retry budget on the unchanged request. This
also applies to a summary request that is itself rejected for context length;
transient provider failures keep their normal retry behavior.

THE CHOICE, ONCE PER WALL — `mode` on the event:

- `prune` — preferred, and chosen when already-consumed tool results of the rounds
  OUTSIDE the keep-recent tail cover the overshoot, after charging the
  replacement placeholders. Byte limits use stored result sizes; token
  limits also require the selected model's counter to confirm enough
  token savings. Without a usable counter, a token-triggered repair
  summarizes. Nothing is appended:
  the round is marked `pruned_before: <the first retained round>`: the earlier
  of the ordinary tail and the current fan's round (its own key when neither
  retains a round). The current fan's first read never contributes savings or
  clears, even when it exceeds the tail budget. The round is re-scheduled in the same pass and
  composes from ROWS — every result of a round before the mark renders
  as the kernel's placeholder `[Older tool result cleared to fit the
  context window; call the tool again if you need it]`, calls and words
  verbatim, and the recent results stay EXACTLY what they were. A call
  that settled without a result keeps its error envelope: clearing it
  frees nothing, and the placeholder would read as a result that
  existed, so the arm never counts it as freed either. A
  trigger with no number behind it (`overflow`, `manual`) never prunes.
- `kernel` (the default) — the kernel's own summarizer runs as a
  tool-less model task on the round's model, with no tools; pass
  `model`, `reasoning_enabled` or `reasoning_effort` on the policy to override.
- `delegate` (`{"mode": "delegate", "tool_name": "…"}`) — the same text
  is handed to the AGENT's own tool as a `tool_task`, which is how an
  agent supplies its own implementation: an inbox row addressed to the
  run's declaring profile's address ([Executor](executor.md)). Its
  `tool_input` carries `history`, `retained_tail` and the address of what
  it summarizes: on a run-backed turn `conversation`, `turn` and the
  round's `task`; on a standalone run `run_public_id` and `task`; between
  turns `conversation` and `turn`. The two texts are clamped so the WHOLE
  `tool_input` fits the 64 KiB envelope bound once encoded, address
  included — the oldest material yields first, and the tail yields only
  after the history is gone. It settles into the same slot, and the
  composer cannot tell the two apart. A delegate nobody answers expires
  at its park and the kernel's own summarizer runs ONCE in its place,
  narrated `context_compacted{trigger: fallback, fallback_from,
  fallback_reason}`; a second failure is the honest size failure. A run
  with no declaring agent — a person's own standalone run — has
  no address to delegate to: `compaction: {mode: delegate}` on any of its
  model steps is refused at the append door, `invalid_steps` with
  `{code: delegate_requires_agent, path: steps[i].compaction}`.
- `{"mode": "off"}` — keep the typed refusal. A client driving its own
  run needs the signal, not a repair it did not ask for.

`compaction` is authored on a model task and inherited by every round
that continues it — a continuation that could not carry it would lose
the policy at round two. The repair's MARKS are not inherited: a
continuation of a pruned or summarized round replays that round's sealed
request byte for byte and carries no mark of its own.

ARMED, THE ROUND WAITS. One summarizing task is appended, the round
gains a dependency on it, and when it runs again it reads that summary
IN PLACE OF the history it replaced — a deliberate chain break. The
summary is spliced as MATERIAL, never as a mainline: replaying the
summarizer's own request would put the whole history back, which is the
one thing compaction exists to avoid.

The repaired round still reads its current tool fan, waited child results,
ask answers and named results after the summary. These have their first
consumption at this boundary: calls retain their original pairing and required
native replay, and current captures retain their bindings. A source named in
both ordinary and explicit result slots is delivered once. Later history and
row reconstruction keep that consumption position; they do not restore the
replaced history or an older launch acknowledgement.

WHAT THE SUMMARIZER READS is led by THE NAMES THE MODEL SAW — the
repaired round's declared tools under one header (`The tools the agent
has:`), an alias by its alias, so the summary's next steps can only name
a tool the run declared (a summarizer told none once wrote
`execute_command` to a run that had `bash`) — then a rendering of the
chain back to the last cut: each round's words verbatim, and EVERY TOOL
RESULT AS A POINTER — `Tool <name> (<status>, <outcome>): <the call's
arguments, head> → N bytes, not carried; re-read it if needed`, `<name>`
being the spelling the model called (an alias, never the kernel's wire
name behind it), the outcome being `ok` or
`error` on a completed row (its envelope's `is_error`), `no result` on
any other settled one and `no result yet` while it runs — never its
body, in the older rounds and in the recent ones alike. A `no result`
pointer is followed on its next line by the error envelope the model
read for that call (`<tool_use_error>…</tool_use_error>`, its typed
failure in the kernel's words), because the summary is read in its
place: without it a call failed as `tool_input_too_large` reads
`{} → 0 bytes`, and the repaired round learns that something failed
but never why. A summariser
handed a result's bytes can
only pass them on as its paraphrase, and a paraphrased value is a wrong
value: the fifty-two invented first lines of the long-session lane were
paraphrased two-kilobyte heads. Its instructions ask for the same shape
back — WHAT TO RE-READ as paths and calls, never contents, values,
lines or numbers, and which results the summary does not carry — and
the KERNEL, not the model, frames every summary a round reads with one
fixed sentence ahead of it: "This summary replaces earlier history and
carries no data values: re-read any file, output or result it mentions
before you use it." Recent results stay verbatim through the prune arm,
which keeps the rows.

EVERY DROP IS ANNOUNCED, and cut on a boundary. The newest work rides
under its own header and is carried whole — the tail is bounded both by
bytes and as a FRACTION of the history, because an absolute cap alone
would keep a small history entirely verbatim and shrink nothing, and
the oldest round is always summarized; the cut falls on round
boundaries, so a call and the result answering it are never separated.
When the rendering does not fit, whole ROUNDS are dropped oldest first
and the text leads with `[... N earlier round(s) elided to fit ...]` —
the count is honest only because the cut is on a round boundary. On a
lane that counts, the older section shrinks the same way until the
summarizer's request counts under ITS reader's window: a history that
walled is by construction larger than the window that walled it.

THE RAW RULE. `prompt_mechanism` rides the run (`raw` when the turn's
input said `context_mode: raw` or its profile declares it): the kernel
assembles no history under raw, so `kernel` mode refuses
`compaction_unavailable_under_raw` — the round fails on size with that
key — while `delegate` arms, because the agent's own tool is the one
reader of a raw request.

COMPACT NOW: `POST .../tasks/{task_key}/compact`. The kernel picks no
threshold, and this does not change that — it is a CALLER asking, which
the wall-only trigger never left room for. Task-grained like every other
verb here: the caller names the ROUND, because a run can hold many in
flight and "compact the run" would have no referent. Answers `202` with
the task and the `summary_task_key` it authored (a manual repair always
summarizes), so the repair can be followed without diffing the graph. A
QUEUED model task only — `task_not_queued` otherwise — and that is what
the repair means rather than a restriction: the summary is spliced AHEAD
of the round that reads it, and a started round's request is already
sealed and on the wire. Refusals name which precondition failed
(`compaction_disabled`, `already_compacted`, `nothing_to_compact`,
`compaction_unavailable_under_raw`), because the automatic caller has
one answer to all of them and a person who asked is owed which.

A ROUND IS REPAIRED AT MOST ONCE, by either arm. Compacting a compaction
is a run, not a repair: if a pruned or summarized round still will not
fit, the refusal is the honest answer. And a first round with no history
behind it is simply too big — there is nothing to summarize.

THE CUT MARKER is not a row. The transcript's round row carries
`compacted_before: <its own key>` when the round read a summary in place
of everything before it, and `pruned_before: <key>` when it read the
rounds before that key with their results cleared — absent otherwise —
and a reader draws the line from those; on a conversation's timeline the
line is a `compaction_summary` turn's own kind.

COMPACTION IS THE ONE LICENSED PROMPT-CACHE BUST. Every other rule here
protects the prefix; this one spends it, consciously, for a context that
fits — once per wall, not per round.

## The kernel's tool registry

Every tool the KERNEL executes has a three-segment canonical name,
`source.category.name`, where the source is the authority that EXECUTES
it: `nexus.*` runs in the server, `rho.*` in the agent's own process.
Providers receive a short WIRE name instead (`nexus.graph.delegate_task` →
`delegate_task`), because short names protect tool-call success. The wire
name is STORED, never derived, so a name already sitting on a cached
prefix can never be moved by a rule change; a call resolves back to its
canonical intent through the alias index. The descriptions name a kernel
tool through a MACRO (`{{delegate_task}}`, `{{ask}}`,
`{{memory_write}}`) rendered plain here and with a profile's own spellings
when that profile aliases the tool; a runner's tool name the texts quote
(`read`, `grep`, `start_process`) is literal, pinned to what rho declares.

Every live entry declares one complete EFFECT PROFILE —
`{kind, destructive, effect_scope, idempotency, reconciliation}` — trusted
registry metadata that drives recovery classification and, later,
approval routing. It is never a security boundary, and it never rides
the provider wire: the schema a provider sees is exactly
name/description/parameters.

DECLARING A KERNEL TOOL IS THE GESTURE THAT ENABLES IT — an agent puts
`delegate_task` in a model task's `tools` and the model can call it. One
declaration is refused, because it could not work:

- a LIVE kernel name declared with anything but the published bytes:
  `kernel_tool_redefined`. The model would be told one thing while the
  KERNEL's executor did another, and the paraphrase would buy a second
  cached prefix describing a tool that does not behave that way.

An ALIAS entry (`{name, canonical, params?, omit?, description?}`, [Profile](profile.md))
is the third declaration shape — the agent's own spelling of a live
kernel tool, rendered by the kernel with the profile's names — and adds
its own refusals: `alias_canonical_unknown`, `alias_name_reserved`,
`duplicate_tool_name`, `alias_param_unknown`, `alias_invert_needs_boolean`,
`alias_param_description_required`. A round's `tools` admits the same
three shapes and stores the same render; a call the model makes under an
alias becomes a row under the kernel's wire name (`tool_name`), its input
mapped, with the alias beside it (`tool_alias`).

Every registered kernel name is LIVE and executable: the registry holds no
name ahead of its executor, so no client tool (a runner's included) can
take a kernel word and no transitional spelling ever ships. The
`nexus.conversation.*` family — `spawn`, `send`, `status`, `cancel` — is
reserved under these wire names, and all four tools are live; the memory
family is LIVE and executable under `memory_ls` and `memory_delete`, and
what it lacks is a client that declares it. (A RESERVED NAMESPACE is a
different fact — `nexus.graph`, `nexus.human`, `nexus.conversation`, `nexus.tools`, `nexus.runners`, the
families no executor may serve in the kernel's place; it governs the
announcement door, [executor.md](executor.md), never this one.)

TWO CONSEQUENCES A CLIENT SEES:

- The append door refuses a `tool_task` whose `tool_name` is any
  registered kernel name, in either spelling: `reserved_tool_name`. The
  model reaches these through its own tool calls; a client has the whole
  task grammar for everything else.
- A model call the round never DECLARED fails at birth with
  `unknown_tool` instead of parking until its deadline — a kernel tool
  included: the round's declaration is the ONLY gate, so a turn whose
  tools withhold `delegate_task` (a conversation input's `tool_names`, a
  branch's inherited set) refuses a guessed `delegate_task` exactly as it
  refuses a name nobody serves. The task is still authored — the pairing
  law owes every call a result — and the continuation hears why. One bad
  name among good calls never fails the round.

`delegate_task`, `wait`, and `ask` are KERNEL TOOLS — Nexus is their runner. None
appears in any executor's inbox: a kernel tool carries no addressee, and the
executor claim answers `not_addressed_here`, because a runner that could
claim it could forge a graph mutation nobody authored. It parks like every other tool task, on the same clock
and the same deadline, so a lost evaluation returns through the timeout
sweep exactly as a crashed runner's task does.

THE MAINLINE SHARPENS THE STEER BOUNDARY. Without one, "next" is
ambiguous the moment two model tasks are ready or one is mid-flight,
and a steer waits. With one, "next" means the next CONTINUATION: a
background branch being ready — or even talking to a provider — no
longer holds the conversation's own directive back, and only a mainline
round in flight does.

THE DISCRIMINATED ABORT MARKER. A round a forced pause cut short and
resume re-minted carries a marker in its fresh request saying it was
interrupted on purpose and that started tool calls may have partially
executed — an interrupted round must not read to the model like one
that produced nothing. It is SUPPRESSED when the user's own directive
drains into that same request: the message that follows explains the
interruption better than any sentence the kernel could synthesize. The
discrimination is "does the message follow in THIS request", so a
steer that cannot land at an ambiguous boundary still gets the marker.
- `tool_task` — a `tool` step's `name` and `input`, `timeout_ms?` (≤7 days;
  when absent the park's deadline is the executor's announced `timeout_ms`
  for that tool, else the kernel's 10-minute default — [Executor](executor.md)
  "the park's deadline"); tool steps that must run one after another are
  written one after another. A tool task PARKS on its
  runner exactly as an await parks on its holder — same derived
  deadline from its own authored timeout, same sweep, same settle
  engine — and its answer arrives through the executor plane's commit
  ([Executor](executor.md)), never through a member door.
- `await_task` — shared by human questions, finite waits for existing work,
  and a waited spawn's original reply. Human questions carry `prompt?`
  (THE QUESTION: an await that cannot say what
  it is waiting for hands a human a task key), `timeout_ms?` (≤7 days;
  default 1 hour). The park's EFFECTIVE deadline is
  `min(timeout_ms, 24 hours)` — a clamp each park carries on its own,
  never a budget the run's parks share: a run may park as many times
  as its work needs (there is no cumulative park-time ceiling). The authored timeout is never rewritten — what
  moves is the derived deadline. An attention hold is not a park and has
  no clock at all.

  WHO MAY ANSWER DEPENDS ON WHO ASKED. An AUTHORED ask — appended
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

  A KERNEL-AUTHORED await — the one a model requests through a task operation, or plants with the one-call `ask` tool (`nexus.human.ask`,
  "`delegate_task` and `ask`" above; the model's two ways to ask a human anything,
  both kernel-planted) — is minted NO token,
  because the kernel's command carries no `Idempotency-Key`, persists no
  receipt, and so has nobody to hand one to. It answers to the
  resolution door's own authorization alone: write standing on the
  workspace, the same standing that could have authored the await by
  hand. `resolution_token` is absent from its trace projection, and
  `POST .../resolution` omits the field.

- the BARRIER — never authored; the kernel places one hidden `join_task`
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
  k. A starved barrier never hangs. THE RACE RULE: a race reaches a reader
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

## Statuses and failure

Task statuses: `waiting | needs_approval | running | dispatched |
awaiting_input | completed | failed | canceled | timed_out | uncertain |
skipped`.

A STATUS NAMES WHO IS BEING WAITED ON, and the task's KIND names what the
wait is; neither derives from the other. `waiting` is a dependency (the
engine's own word for it is `queued`). `needs_approval` is an approver:
the stage is the TOOL CALL's alone — the one
kind whose effect reaches the person's own files and shell; a model round
is admitted by the admission plane and has no stage. Under `bypass` the
stage is crossed and granted in one transaction and never observed at
rest; under `ask` or `rules` a model-composed call the rules do not
decide RESTS there, ADDRESSED to the host's agent application, listed on
its inbox as kind `approval`, announced on the run as
`approval_required` while the turn stays `running`, and ended by
`approve`, `deny`, the 24 h park clock (`timed_out approval_expired`
under its own `on_failure`) or a stop, which cancels it with the rest of
the unstarted work (`error.key: run_canceled`). `running` is the
KERNEL doing it — a round driving a provider call, or a kernel tool
executing in one of our own jobs. `dispatched` is a holder outside the
kernel that was handed a bearer proof: a tool call advertised to a
runner, or an await whose `resolution_token` rode out in an append
receipt. `awaiting_input` is a person nobody handed anything to: the
tokenless await a model requests through a task operation. `uncertain` is the sweep's
word for a claimed, non-replayable tool call whose executor expired with
no result: its effect may have happened, so nothing re-runs it blind — a
person's `retry` or `abandon` decides ([Executor](executor.md) "Expiry").

EACH KIND DECLARES ITS OWN MACHINE, so this list is a union rather than a
menu — a join is never `running`, and an unknown
status must be treated as live rather than finished by any client that
predates it.

A `propagate` failure SKIPS its not-yet-started
descendants (transitively); joins treat a skipped source as a settled
non-success. `absorb` satisfies dependents and resolves in the failing
write; `halt` is the adjudication hold: the run finishes what can
still run, and at quiescence with an unresolved failure it becomes
`needs_attention` (`attention.reason: halt_failure`) until someone
adjudicates — and THE ASK HAS NO CLOCK, so a run resting there stands
until a person decides. The deciding verbs are `retry` (run the failed
task again under its own lineage), `abandon` (settle the failure as
resolved so the run moves past it) and `compact` (repair a round by
authoring a summarizer for it). A client computes the candidates from the
trace by the kernel's own rule — `status ∈ {failed, timed_out, uncertain}`
with no `failure_resolution` AND `on_failure` not `absorb` (an absorbed
failure is settled the moment it is written and neither verb accepts it) —
rather than from `attention.blocked_task_keys`,
with the one edge exception the barrier paragraph states: a `halt`
loser whose every consumer is a settled `any|quorum` barrier or a task
canceled by that race (`join_loser_canceled`) is absorbed and never a
candidate. A failure earlier in a canceled branch therefore cannot hold
the run after the race has its answer. A `run_out` branch with an
unfinished consumer still follows its own failure policy. The person then
retries, abandons, or appends the repair — an applied append RELEASES
the hold back to `running` (the scheduler judges the repair; if the
rest still cannot resolve, the run re-holds). A
resolved graph whose deliverable did not complete holds as
`deliverable_unresolved` — the kernel never synthesizes an answer. THE
ASK HAS NO CLOCK: a hold stands until a
human answers it — the references all idle indefinitely, and a user
away at dinner must not return to a dead run whose fix was one retry
click. Abandonment is the retention/tombstone story, never a sweep.
A MODEL'S QUESTION announces from `running`, as `awaiting_human`: the
task itself sits in `awaiting_input`, and the run STAYS `running`, so a
run holding an ask is not quiescent and the reason is what tells a
person apart from a run busy doing the work.
(`awaiting_human` is the RUN's attention reason; `awaiting_input` is the
TASK's status. Two axes, deliberately two words.) Only the asks nobody holds a key to — an
ask a CLIENT authored was handed its `resolution_token` in a receipt,
so somebody already arranged to answer it, and announcing it would nag
an operator about a rendezvous they set up on purpose. The
`attention_required` item's `blocked_task_keys` names the QUESTION for
this reason, and the pending failures for `halt_failure`; a stamp
already standing is never replaced, so a halt failure outranks an ask. A failed task carries
`error: {key, detail?}` (typed keys — e.g. `provider_http_error`;
`provider_model_unavailable` for a provider HTTP 401, 403 or 404;
`provider_context_overflow` — the PROVIDER refused the request for
length, which arms a compaction repair rather than a retry and only
reaches a client as a failure once the round is already repaired or has
no history to summarize;
`missing_input` — a task with nothing to ask, including a splice
whose last word would be the assistant's own; `context_overflow` — the
composed request exceeds the storage bound, the signal a client's
compaction consumes; `input_source_unavailable`;
`round_expansion_refused` — the model's calls could not be authored
into a fan, so the round failed rather than vanishing;
`provider_error` with `finish_quality: error` — the provider completed its
exchange but reported an abnormal generation finish. The step fails, the
reported usage remains billed, and partial answer, reasoning, and tool calls
are discarded. No round expands, no automatic retry is spent, and no
declared fallback runs. The error detail names the provider's finish word;
`model_refused` — the provider DECLINED the step: its classifier refused
the request or the answer (`finish_quality: refused`), or a
content-protection stop blocked the content (`blocked`). The call
completed and was billed, but the step has no answer. A classifier's
refusal first re-runs the step ONCE on the answering profile's declared
`fallback_model` ([Profile](profile.md)) — the task goes back to `waiting`
under the fallback's trio, its `result` carrying `model_change {from,
reason: model_refused, category?}`, what this execution replaced; a
content block, a step nobody waits for any more, and a step with no
fallback to go to (none declared, the declared one is the model that
declined, or it cannot take the request) fail at once, and so does a
second refusal of the same step — the step's own history is the bound,
which neither a retry nor a new declaration renews. It fails over a
`completed` invocation, the round's own narration saying so, with the
quality and the provider's `refusal_category` on its `result` (beside
`model_change` when it was the fallback that declined) and the kernel's
sentence as `error.detail` — which names who declined, the category
(with a short meaning beside a word that does not say it plainly) and
why nothing re-ran it, for the model that reads it; the envelope adds one
line saying what the model can do next. A switched step that fails at its
next start there (a smaller window, fewer modalities, a credential gone)
keeps the start gate's key and carries the same sentence as its detail. It never spends the step's
`retry` budget (re-sending the same request to the same model usually
earns another refusal); a person's retry may name another model, and
clears the row's `result` with its error;
`provider_overloaded` — the provider said it was overloaded (HTTP 503 or
529, or Anthropic's streamed `overloaded_error`) on EVERY attempt the step's
budget spent; a budget spent on any other transient answer among them is
`attempt_budget_spent`, and a rate limit (429) is never overload — it waits
out the lane's `Retry-After` floor and retries within the budget. Like a
refusal it first re-runs the step ONCE on the answering profile's declared
`fallback_model`, `model_change {from, reason: provider_overloaded}` on its
`result`; it stands — the kernel's sentence naming why as `error.detail`,
"… was overloaded on every attempt of this step, so it failed with no
output; …" — with no declaration, on a fallback that is the model that
failed or cannot take the request (one that needs the tool run's
reasoning back stands on a tool round after the last user message that it
did not produce, `foreign_tool_history`), or on a second overload; a result-mail round then
takes its own `default_model` rung, and after that the step's `retry` budget
applies as for any failure. The switched step stays on the fallback for the
rest of its turn, but work it starts — a composed member, a `delegate_task` delegate,
the model a spawn or send names by default — begins on the model its
lineage was configured with;
`model_capability_unavailable` — the model does not offer something
the request asks for, e.g. declared tools on a lane without
`tool_calls`; `tool_failed`/`tool_timeout`/`tool_uncertain` and
`await_failed`/`await_timeout` for the two parked kinds; `executor_revoked`
— the executor an unclaimed call was addressed to was removed first, a
`failed` row under its own `on_failure` like `tool_not_served`; `run_canceled`
on every row a stop took before it started). `retry: {budget}` model steps re-run
automatically that many times before the policy dispatches. Run statuses:
`pending | running | paused | needs_attention | canceling | completed |
canceled` — no `failed`: a reasoned cancel IS the run failing, and the
turn shape derives its `failed` from a hold or that cancel. Envelope caps:
64 steps per request, 32 members per fan and per follower's wait
(`too_wide_a_fan`), 33 reads per model step (`too_many_reads`), 1 MiB
payload — request hygiene, not totals (there are deliberately no
per-run size limits; concurrency is the admission plane's business);
a stored body's entry count is a storage sanity bound (32,768, above
what 1 MiB of the smallest entries can hold), so a composed round under
the byte wall is never refused for its count — `content_items_too_many`
is corruption protection, never a wall.
Values the row store cannot hold (NUL bytes, exponent-form numbers)
refuse typed at compile. Both write doors
(create and append) require write standing on the workspace — the same
gate as every other write surface.

## Lifecycle hooks

An Agent may declare `lifecycle_hooks` through its
[configuration](profile.md#declare-the-configuration). Nexus freezes the
declaration onto each execution and schedules its named executor tools as
ordinary tasks at `turn_start`, `pre_compact`, `post_compact`, and `stop`.
Hooks are independent of the model's declared tool list. Turn-start and
compaction hooks acknowledge their event; a Stop hook can accept the candidate
final answer or request a bounded model continuation with feedback. Hook
failure follows the existing attention, retry, and abandon flow. Explicit
force-stop cancels hook work and never asks it for permission.

See [Lifecycle hooks](../../lifecycle-hooks.md) for event ordering and
[Executor](executor.md#lifecycle-hook-tasks) for the input and result protocol.

## Approval — the modes, the origin, the rules

APPROVAL IS A KERNEL STAGE between "ready" and "runs": every tool call crosses it, under every mode,
never skipped. What decides the crossing is the MODE and the RULE LIST
frozen on the run row — from the create shell on a standalone run, from
the declaring profile's `configuration` (or the input's tightening,
[Conversations](conversations.md)) on a run-backed turn — and the row's
own ORIGIN: who wrote it.

THE ORIGIN RULE. A row a model composed (a round's fan, a task operation or
`delegate_task` graph) is a `model` row: the mode and the rules govern it. A row
appended through the tasks door is an `author` row and a row the kernel
planted (a continuation, a summarizer, the `ask` await) a `kernel` row:
both are PRE-APPROVED by their origin — the appender is a principal who
could approve, the kernel asks nobody — unless a rule that names their
`origin` opts them back in. This is what every reference does (a person's
own command line is never re-prompted), and it is why a person's `rho
append` or `--until` check never parks.

THE MODES, for a model-composed tool call:

| mode | deny rule matches | allow rule matches | ask rule matches | unmatched |
| --- | --- | --- | --- | --- |
| `bypass` | `failed approval_denied` + the rule's reason | granted, `origin: mode` | granted, `origin: mode` | granted, `origin: mode` |
| `ask` | `failed approval_denied` | granted, `origin: rule` | PARKS | PARKS |
| `rules` | `failed approval_denied` | granted, `origin: rule` | PARKS | `failed approval_denied` — "no approval rule allows NAME" |

Deny binds everywhere, for every origin. `ask` parks every model call
unless an allow rule names it (the rules are an allowlist refinement);
`rules` is the policy itself, and what it does not name is refused AS
DATA — a typo in a tool name is a refusal the model reads, never a grant
and never a 24 h park for nobody; an agent wanting "unmatched allow"
authors `{"tool": "*", "verdict": "allow"}` last, explicitly. An `author`
or `kernel` row is granted by its origin under every mode, parks only on
an `ask` rule naming its origin, and is refused by a deny rule naming it.

THE PARK. A parked row rests at `needs_approval` addressed to the host's
agent application (nobody on a Human's own standalone run — the member
door alone), with the effect profile the approver reads frozen on it and
the 24 h park clock armed; it lists on that inbox as kind `approval`
([Executor](executor.md)), the run announces `approval_required` naming
it and stays `running`, and the addressee is nudged `work_available`
(kind `approval`). It ends by `approve` or `deny` (the routes above), by
the clock — `timed_out approval_expired` under the row's own
`on_failure`, the next round reading "Nobody approved this tool call
before it expired." — or by a stop. Explicit executor revocation clears a
held row's addressee (`task_readdressed` with its own detail) instead of failing
it: the person's door still answers. Agent removal separately fences
that application's credentials and asynchronously force-stops related runs;
their held rows are canceled through the ordinary stop path.

THE RULE GRAMMAR, exactly. `approval_rules` is a JSON array; each rule
is an object of at most these six keys:

```json
[{"tool": "bash|start_process", "path": "command", "match": "*git push*--force*",
  "verdict": "deny", "reason": "force push rewrites history others may hold; a person can run it"},
 {"tool": "write|edit", "path": "path", "match": "*.env", "verdict": "deny"},
 {"tool": "memory_*|ask|delegate_task|code|skill", "verdict": "allow"},
 {"tool": "bash|start_process", "path": "command", "match": "ls*", "verdict": "allow"},
 {"tool": "bash", "verdict": "ask", "origin": "author"}]
```

- `tool` (required): `|`-separated globs over the wire `tool_name`, each
  ANCHORED — `bash` names `bash` alone, `memory_*` every memory tool.
  Matching uses the resolved execution name and input keys after kernel-alias
  and Runner-route resolution. A callable such as `bash__0123456789ab` is
  checked as the served `bash` while retaining its concrete Runner target;
  the rule does not need an alternative for each qualified callable.
- `verdict` (required): `allow | ask | deny`.
- `path` (optional): a dotted key path into `tool_input` — `command`,
  `edits.0.path` — an object walked by key, an array by integer index;
  anything else walks nowhere. Absent, the rule matches the tool as a
  whole; present without `match`, the rule matches when there is text at
  the path.
- `match` (optional, needs `path`): an ANCHORED glob over the text at the
  path — only `*` (anything, newlines included) and `?` (one byte) are
  special, every other byte is literal; so a fragment needs a leading
  `*`. The text at the path: a string as-is; an array of scalars joined
  by ONE space (`["rm", "-rf", "/"]` reads `rm -rf /`); anything else —
  absent, an object, a nested array, a number alone — NEVER matches, and
  under `bypass` a non-match is a grant.
- `reason` (optional, text): the denial's `error.detail`, the first 256 bytes.
- `origin` (optional, `model | author | kernel`, default `model`): whose
  rows the rule addresses.

Evaluation collects every matching rule: deny wins, then ask, then allow
(codex/claude-code strictness — an agent's deny is never overturned by a
later allow), the first deny's `reason` riding; unmatched is the mode's
word. Glob only, no regex. The kernel interprets no tool argument: the
path is the agent's, and the evaluator reads `tool_input` as opaque JSON
through it. The list is validated at declaration — a seventh key, a
missing tool, a verdict outside the three, an origin outside the three, a
`match` without a `path`, an empty path segment, a glob that does not
compile — under the 64 KiB envelope bound and with no length limits.

## Prompt caching

The continuation chain is DESIGNED around cache reuse rather than having
breakpoints added afterwards, because a tool run re-sends its entire
prefix every round — reuse is the dominant cost term, not a nicety.

THE SEGMENT ORDER IS THE CONTRACT, most-stable first: the tool list
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
STABLE marker lands on the last system block when the wire's system
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

THE TIER is chosen by the turn's HOST, never per request: a
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

## The event stream

ONE HOSTED EVENT PLANE: a run narrates onto its HOST's
feed. A standalone run is its own host, so `GET …/runs/{id}/events`
and `RunEventsChannel` serve its narration under `resource: {type:
"run", public_id}`; a conversation-hosted Run narrates onto its
conversation's feed (conversations.md, "Events"), under `resource: {type:
"conversation"}` with `run_public_id`, `turn_public_id`, and
`variant_public_id` on every item. These are the originating run's
identities, including for background work after a successor turn or
regeneration starts; they do not follow the displayed variant. Standalone
items carry `run_public_id` without turn or variant keys. A
conversation-backed run's own address refuses 409 `conversation_hosted` (the channel
rejects the same way) — serving the conversation's whole stream under a
run id would hand a follower other turns' items. One vocabulary, one
`cvei` cursor prefix, one 30-day age-out, on both hosts. Sequences are
allocated contiguously from 1 within each host and are never reused after
items expire. A replay gap can therefore mean expired history, even while
the run is running. A follower that outlived the window refreshes from
durable tasks and outputs; replay cannot recover expired items. Items render
identically over REST and over the cable, so one reconnect algorithm
serves both.

The run's item types, in the one closed vocabulary conversations.md lists
(`input_*` and `context_compacted` are shared; the rest of that list never
appears on a run host):

- `turn_status` — WHERE THE RUN IS, written under the run lock at every
  run status write, including the ones nobody asked for (a hold, an
  authority cut, a drain escalation): `{run_public_id, run_status,
  failure_reason?, attention_reason?}` — `run_status` is the run row's
  own word (`pending | running | paused | needs_attention | canceling |
  completed | canceled`). On a STANDALONE run the same write also
  carries the turn shape, `status` and `failure_reason_key?` (the `turn`
  block above, as an item), because its rows are the truth and nothing
  can contradict them; on a CONVERSATION host it carries `turn_public_id`
  and `turn_kind` (the turn row's own `kind`: `direct_reply` on an
  answer, `compaction_summary` on the kernel's between-turn summary —
  what a follower waiting on a person's turn reads to tell the
  summarizer's run from the answer's) and NO `status` — the turn's row
  is the converger's to narrate, under the conversation lock, in its own
  `turn_status`. The reader rule:
  `status` present ⇒ the TURN moved; absent ⇒ a run-state note, no turn
  transition. A turn-shaped `failed` is a LEVEL: a `needs_attention` run
  renders it, and a retry or an answer narrates `running` again.
- `task_readdressed` — `{task_key, role, executor_public_id?, deadline_at, detail?}`:
  records withdrawal of an unavailable agent delivery address from a held
  approval, preserving the Human's decision door. It does not move the task's
  Runner target. Host preference changes emit `default_runner_changed` separately.
- `task_deadline_extended` — `{task_key, deadline_at, by, timeout_ms}`: the
  row's claimant extended its own park ([Executor](executor.md) "Extend"),
  the one clock moved to `deadline_at`; `by` is the claimant's public id
  and `timeout_ms` what it asked for, so a watcher can say "the runner
  asked for N more minutes".
- `task_status` — `{task_key, kind, lifetime, wake, status, after?, on_failure, error_key?,
  failure_resolution?, approval?, model_change?}` (`on_failure` so a follower computes the candidate
  rule without the trace: an `absorb` failure stamps nothing; `approval`
  is the task read's own `{origin, decided_by?, decided_at}` block, present
  from the crossing that decided the call — a denial narrates the failure
  first and the fact on the next item). Every task transition, birth included — a
  follower reading only the stream learns about newly appended tasks
  here. `after` is the authored list the task hangs from (the trace row's
  `after`; a root carries none) and rides every item; a queued round is
  narrated again when a branch forwards onto it, `after` grown. The
  trace's `waiting_on` is live and derived — a follower computes it from
  `after` and the statuses it holds, never reads it off an item.
  An automatic model switch carries `model_change: {from, to, reason,
  category?}` with the provider/model references and the trigger: a
  result-mail run's unavailable model moving to the recipient's
  `default_model` (`reason` the failure key), or a step a provider's
  classifier declined, or the provider was overloaded for on every
  attempt, re-running on the answerer's `fallback_model` (`reason:
  model_refused` with `category` the provider's own word when it named
  one, or `reason: provider_overloaded`). It changes the next execution,
  and the task's `result` keeps the same fact without `to` (the row's own
  `model` says it); previous `round_result` items retain the model that
  actually made those calls. The row holds ONE switch, not the history: a
  refusal or overload the fallback served stays on it through a later unavailable switch of the
  same step (a mail run's fallback whose credential is gone), whose own
  `model_change` rides this item alone — the items are the whole record.
- `round_result` — `{task_key, status, model, finish_quality?, refusal_category?,
  error_key?, error_detail?, input_truncation_suspected?}` when a model step settles;
  `error_detail` is what the provider answered (its HTTP status and
  sentence, then its code and type when named — never a raw body), the
  same text the failed task carries as `error.detail`. An abnormal generation
  finish carries `status: failed`, `finish_quality: error`,
  `error_key: provider_error`, and a diagnostic naming its finish word.
  On a DECLINED
  finish (`finish_quality: refused | blocked`) the round reads what the
  provider said and the task what the work came to: `error_key` is
  absent (the call did not fail), `refusal_category` is the provider's own
  word (absent when it named none), `error_detail` the provider's
  explanation for people, and `status` the task's `failed` beside it —
  whose `error.detail` is the kernel's sentence for a reading model
  instead — or `waiting` when the answerer's `fallback_model` re-runs it;
  the same request is never re-sent to the same model automatically, and a
  person may retry it on another. The last is
  present, and `true`, only when the round reported fewer input tokens
  than its source by more than its own tail explains (the compaction
  section's silent-truncation note).
- `usage` — `{task_key, input_tokens, output_tokens, reasoning_tokens?,
  total_tokens, cache_read_tokens?, cache_creation_tokens?}`, appended
  with the round it paid for. The cache counters are the round's own
  reuse: a tool run re-sends its whole prefix every round, so a
  transcript that cannot show them cannot be tuned.
- `attention_required` — `{reason, blocked_task_keys,
  blocked_task_overflow?}`: the call to act — `reason` one of
  `halt_failure | deliverable_unresolved | awaiting_human |
  approval_required` — carrying the tasks an adjudicator can retry or
  abandon, the question to answer, or the calls to approve or deny (no
  deadline rides it — a hold has no clock; an ask's or a held call's
  `deadline_at` is on its task). The key list is capped at 32 with the
  remainder counted in `blocked_task_overflow`; the trace answers "all of
  them".
An AWAIT serves the question it was authored with. `GET .../tasks/{key}`
carries `prompt` for any kind that was authored with one — the text the
kernel sealed as that node's input: an `await_task`'s question (a model
composing `ask` authors it, and until it was served the one task kind
that exists to be answered by a person could not be read by one — it
parked to its deadline), a model step's prompt, authored or
client-appended. A spliced continuation has no authored input and
carries none; a tool task's authored side is `tool_input`. The resolution
token is not there and never will be: it travels only in the creator's
receipt.

- `input_materialized` — `{input_public_id, queue_position, task_key,
  run_public_id}` when a bound input landed in a round's sealed
  request (on a conversation host, `turn_public_id` too); a steer the
  run ended without landing — by stop, cancel, completion or being
  replaced — is released as `input_edited{state: pending, reason:
  steer_target_settled}` instead, never dropped, and a HOLD releases
  nothing: a steer typed before it stays bound and lands with the retry.
  A queued word found at quiescence binds the follow-up head first,
  `input_edited{state: steering, reason: follow_up_bound}`, and the
  kernel plants one more mainline round for it to land in — so a queued
  input lands BEFORE the turn-shaped `completed`, never after.
- `context_compacted` — `{turn_public_id?, run_public_id,
  task_key, summary_task_key?, mode, trigger}` when a round was repaired
  for size: `task_key` the round made to fit, `summary_task_key` the
  summarizer it waits on (absent on a prune, which appends nothing),
  `mode` `prune` | `kernel` | `delegate`, `trigger` `usage` | `wall` |
  `overflow` | `manual` | `fallback`, and on a conversation-hosted Run the turn.
  A `fallback` item is the kernel's summarizer appended once in place of
  a delegate nobody answered, and carries `fallback_from` (the expired
  delegate's key) and `fallback_reason` (`tool_timeout` |
  `tool_uncertain`). It is the
  one repair a watcher cannot infer: the round pauses, a task nobody
  authored appears, and the next round answers from a summary — or from
  cleared results — instead of the history it had. The same item, with
  `summary_turn_public_id` in place of the task keys, is what a
  conversation narrates for a repair between turns (conversations.md).

Realtime: subscribe to `AgentAPI::V1::RunEventsChannel` with
`{workspace_id, run_id, items?: "events"|"lifecycle"|
"transcript"|"progress"}` — a standalone run only; a conversation-hosted Run's channel is
its conversation's, and this one rejects `conversation_hosted`. `events`
carries every item; `lifecycle` carries only `turn_status` and
`attention_required` — where the turn stands and when it needs a human,
the same narrowing on both hosts — so a console holding many runs is not
handed every task transition to decode and discard. `items: progress`
subscribes the run's ephemeral progress feed — what is happening RIGHT
NOW. The executor's frames ride it (executor.md, "Progress": a `bash` tail
under its current claim, a process's output under its retained source claim), and the
kernel's own frames ride it beside them: `round_started {task_key, mainline,
attempt, model, request_bytes}` when a model attempt is dialled,
`step_started {task_key, tool_name, status}` when a tool row is
dispatched, run or held (an approval-gated call says so twice — held, then
released — and a reader upserts the call's live status), `step_claimed
{task_key, tool_name, executor_public_id}` when an executor takes it —
three facts no row or settled item carries at that instant; a round's or a
call's END is the settled `round` / `call` snapshot on `transcript`, whose
`started_at` / `completed_at` are the timing. Every frame carries the
host's keys (`run_public_id`, `task_key`; on a conversation host
`turn_public_id` and `variant_public_id` beside them) and `at`
(milliseconds); the envelope is `{frame}`, never `{event}`: nothing on it
is durable, nothing replays, and a subscriber sees what follows its
subscription. A `hidden` task reaches this feed exactly as it reaches the
transcript: not at all. The pack lists the feed's five words once
(`conversations.json#/progress_frame_types`).

`transcript` is the HUMAN feed — ONE stream over the host, in
the vocabulary conversations.md's "The transcript feed" section owns: a
STANDALONE run's rides its own channel; a conversation-hosted Run's rides its
CONVERSATION's, where a run address no channel serves would otherwise
have swallowed it. While a round runs it carries `text_delta`,
`reasoning_delta`, `tool_call_started` and `tool_call_arguments_delta`
(a call announces itself on its FIRST fragment, so a collapsed row can
name its target before the arguments finish); when a task settles it
carries the `round` or `call` SNAPSHOT — the same row the paginated read
would have served, under the same task key — and on a conversation host
the settled `turn` follows. A settled `round` is the thread row the
transcript page serves — `mainline`, its `calls` and `branches` included — so
a client upserts the thread by `task_key`. Every item carries `run_public_id` and
`task_key`, which is how a client upserts it in place; on a conversation
host `turn_public_id` and `variant_public_id` ride beside them (the seam's
turn), and on a run host those are the absent ones.

Five laws govern it. Nothing on this feed is DURABLE: a saturated
transport must not be able to truncate a transcript, which is only true
when the deltas were never the record. A delta may not CREATE a row — a
delta for a task the subscriber has not seen is dropped, and the
paginated read repairs it. COMPLETION WINS: the snapshot replaces
whatever the deltas accumulated. A provider retry emits `stream_reset`,
voiding what that attempt streamed, so a follower never splices two
attempts into one answer (an attempt that streamed nothing public emits
no marker); its `reason` is `retry`, `refused` when the attempt ended
in an answer the provider declined — the kernel stores none of a declined
answer, so a follower drops what streamed of it, an announced call
included — and `failed` when the attempt failed with nothing retrying it
(a budget spent mid-stream), which the kernel stores none of either. And the feed is a TAIL, not a log: a subscriber joining a
running run receives what happens from then on and is never backfilled
— history comes from the window. A task whose `visibility` is `hidden`
reaches NEITHER half of the feed, exactly as it reaches neither the
window; on a conversation host a `hidden` or concealed TURN silences its
run's items the same way.

The reference implementation of those laws ships in the Ruby SDK as
`CybrosAgent::Api::TranscriptAccumulator` — a client that re-implements it
owes the same three answers (append, discard, replace-on-settle) and the
same arithmetic: a bounded preview is a TAIL, so the settle comparison
counts what was accumulated rather than testing the buffer as a prefix.

Narration is written ONCE per transaction, so one logical change (a
cancel is a run status plus every task it settled) arrives as one
envelope with contiguous sequences.

Items are replay EVIDENCE, not the record: the tasks and their outputs are
the durable truth, and items age out after 30 days while the run lives.
