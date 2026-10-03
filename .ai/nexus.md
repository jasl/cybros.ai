# Nexus Kernel Doctrines

**Applies to:** `nexus`.

This file owns kernel mechanisms. Product, trust, credential, administration, and package
boundaries live in `.ai/boundaries.md`; shared development rules live in `.ai/repository.md`.
This file states the accepted kernel requirements; `docs/agent-api/**` describes the public
contract. Keep implemented behavior distinct from accepted design intent. Preserve explicit user
decisions to defer work or leave a design choice unresolved, including their scope and constraints,
without presenting them as implemented behavior or requiring a private development record.

## Shape

- Nexus is a complete, orthogonal kernel for coding, Cowork, personal, chat, and role-play agents.
  Its three primitives are Conversation, Agent Loop, and OneShot. General mechanisms belong in
  the kernel: compaction, memory, messaging, prompt assembly, approval, scoped stores, and the
  task inbox. A capability composable from those primitives earns a direct surface only when
  it is common across agent products.
- Apply the business-neutral test: implement what agent products need from a kernel, without
  encoding one application's UX or policy. Prompt meaning, model selection/routing, tiers,
  end-user semantics, memory extraction/ranking, and retrieval-augmented knowledge belong to
  applications or tool providers. Prompt assembly and generic rule evaluation are mechanisms;
  the kernel does not interpret a tool's business arguments or learn what `bash` means.
- Account, Workspace ownership/access, conversation ACLs, executor roles, and public identifiers
  follow `.ai/boundaries.md`. First boot is gated by `Account.none?`; no default Workspace is
  seeded. Principals create their own Workspaces. A synthetic system User carries machine acts.
- A durable standing goal is an accepted kernel capability that remains unimplemented design
  intent: the application supplies the acceptance predicate; the kernel mechanism would own
  attempts, cadence/backoff, continuation, and self-clear. Do not describe an application-owned
  completion check as an implemented kernel goal or remove this capability merely because it
  has no kernel implementation.

## Conversation, Agent Loop, OneShot

### Execution And Configuration

- Conversation is the unit a person has; an Agent Loop is the engine inside a loop-backed turn.
  Its rounds, tool calls/results, and approvals appear on that conversation's transcript/feed,
  never on a second conversation record. Engine selection follows the declared tool-bearing
  configuration. Loop creation is independent of a delivery row. Standalone loops support
  workflows and background runs. OneShot accepts one input and seals one request, with one
  bounded whole-request fallback and one authoritative REST result.
- Agent configuration belongs to its Profile User: tool definitions, approval mode/rules,
  prompt mechanism/template, compaction policy, lifecycle hooks, and declared models. Resolve
  configuration at each turn's materialization and freeze the execution configuration on its
  node/variant, never once per conversation. `fallback_model` is the explicit exception: read
  it live at the switch. The Profile's `system_prompt` document may be overridden by a per-turn
  inline slot. A standalone loop's create shell carries the same execution declarations.
- A paired instance may declare named definitions through `PUT profile/agents/{name}`. The
  kernel forms `<identifier>/<name>` under the same steward. A definition has no credential
  or executor address, may answer conversations, and cannot declare further definitions.
  `instance` scope follows the parent instance's fences/removal; `steward` scope persists
  independently for that steward's agents. It is configuration of the paired program, not
  another connection ceremony.

### Inputs, Speakers, And Group Chat

- Conversation inputs are the one durable, ordered, idempotent waiting room. `queue` drains at
  a turn boundary; `steer` drains all pending steers in arrival order at the next unambiguous
  model boundary of the in-flight loop. It appends trailing messages to the request being
  sealed, never amends a sent request. The round retains those messages for later history,
  pruning, and summarization before its answer (`AgentLoops::Steers::Landed`).
- A pending steer still owed when a deliverable answers without calls causes another spine
  round. A steer with no target falls back to the queue; settlement also queues an ordinary
  unconsumed steer with `steer_target_settled`. A hold preserves bound steers. An explicit
  `expected_steering_loop_public_id` instead rejects an idle/changed target at admission and
  cancels an unconsumed steer at settlement; it cannot migrate to another candidate or turn.
  There is no separate loop-reply input kind; `/asks` is for addressed obligations.
- `deliver_at` accepts an offset-bearing absolute time or a delay, rejects more than two minutes
  in the past or ten years ahead, and is unavailable on steers, standalone-loop inputs, and
  kernel mail. A future row is outside the current queue until due. Drain rechecks the author's
  write standing and uses the ordinary input receipt/wake path.
- `origin` is closed source attribution: `person|agent|task_result|child`. Only the named
  `ConversationInput::KERNEL_ORIGINS` set confers kernel-mail behavior; origin presence or a
  sender stamp does not. A principal's input, including an agent's `send`, may steer. Kernel
  mail always queues, drains before principal inputs and then by arrival, and is immutable to
  the person (`kernel_input_immutable`). Its author is the requesting loop's creator; the child
  or task identity is a separate kernel stamp, never impersonation of the child's answerer.
- Render speaker attribution once through `Conversations::ContextAssembly::SpeakerEnvelope`
  for seeds, history, user-role message turns, steers, and summarizer material. A turn's voice
  is its fork-stable `speaker_actor`, not its control owner. Member voices identify their User;
  Actor kinds are `member|speaker|ingress|system`, with `speaker` reserved for persona consumers.
  Member envelopes use `<message from="@handle" kind="human|agent" user="<public_id>"
  conversation="<sender id>">`. Host voices are bare only when they are the creator, answerer,
  or answerer's controlling Human and carry no sender stamp. Other principal rows are wrapped;
  kernel receipts are not.
- Agent-controlled ingress actors are registered by natural key through
  `POST profile/ingress_actors` and selected with `speaker_actor_public_id`, included in the
  input receipt digest. Render them as `kind="ingress" actor="<Actor UUID>"` with escaped display
  name, never as their controlling Agent. Authoring, origin, and ACLs remain the Agent's.
  Passive `message` speech starts no model. Transport, consent, routing, and unregister are
  application policy; there is no kernel revoke. Envelope bodies, including task results, use
  the shared narrow reversible escaping for `<message `, `</message`, `<task_result `, and
  `</task_result`, replacing the opening `<` with `&lt;`.
- Group chat uses the same conversation/input mechanism. Resolve an input's explicit answerer
  (`@handle` or public id) or the conversation default, require an eligible Agent with full
  conversation standing, and freeze the answerer on the reply turn. Message and summary turns
  take the conversation default. The loop derives its answerer from its turn; runner binding,
  handoff authority, memory principal, and inbox scope remain the host's. Kernel mail carries
  its source loop's answerer.
- The idle unit is the conversation; addressing another Agent does not wake a separate agent
  process. An unnamed steer addresses the running reply's answerer; a different named answerer
  queues. A row addressed elsewhere cannot replace-kill another answerer's repairable held
  loop. Side forks copy the fork-point answerer; regeneration keeps the turn's answerer.
- Assemble history for the turn's answerer: its own turns replay rounds, another Agent's reply
  becomes one wrapped user-side segment of final text beneath its seed, never its rounds.
  Skip a peer seed the answerer itself posted and a kernel receipt already consumed. Determine
  bare voices against the current answerer so ordinary one-to-one histories retain their bytes.
- For peer-sent or differently addressed work, `Conversations::AnswerEngine` uses the addressee's
  declared `default_model`, then that Agent's last reply model here, then the conversation's
  last model, then the input's model. `spawn`/`send` carry the initiator's explicit model or its
  configured lineage model; invalid selection refuses `model_not_authorized`. `turn.model` is
  the public source for the model in use. The kernel stores declared choices, not routing policy.

### Task Graph, Reads, And Continuation

- The write surface is task-grained: every node owns its tracked execution, and external
  consumers never write edges. The graph read exposes task keys, edges, and Mermaid for
  debugging or workflow display. Execution internals such as spine marks, graph sequences,
  and detached flags do not leak through ordinary task/timeline/tool projections.
- Place tasks in written order. `parallel` names a fan; `until: any|k` and `losers` name its
  barrier. Position and `after`/`results` create waits. Reads are explicit: an authored model
  or script step reads its prompt, then its named results in order; a race reads the barrier's
  captured selection. It does not inherit a conversation merely from graph position.
- The loop's own spine is the one distinct case: its top-level model step, continuation, wake,
  planted round, or lifecycle continuation reads the kernel's current spine and paired calls
  alongside explicitly named results. A named round already in that history appears once.
  An append may name any earlier task key; an expanded task reads as its final answer, never
  its first draft or a stage manifest. Reference waits do not erase structural waits. Deduplicate
  edges with structural placement winning on identical endpoints. Cancellation follows
  structural placement; scheduling waits on every dependency.
- Results nobody reads return to the caller through its waited continuation, wake, or mail once
  the chain settles. A race barrier represents its arms, an expansion represents the row it
  replaces, and a stage hides its internals. A detached step inside a race is not an arm.
  Settled race losers hold nothing back; a turn-owned spawn's completion owns the child's
  report, so its immediate short await never reports a second time.
- The kernel drives rounds from returned calls, never provider stop reasons. Every call gets a
  paired result, including an error envelope for a tool that could not run. A tool result
  settles only its node; `outcome` records whether it ran and `is_error` is data, never a run-end
  command. The tool fan joins all members before one continuation unless an author explicitly
  chose an any/quorum join.
  A settled join's later losing failure is absorbed.
- Failure policies are `absorb|propagate|halt`. Retry budgets belong to model steps, not tools
  or asks; compiling `retry` on those kinds refuses it. Client-authored tool failure defaults
  to propagate and model failure to halt. Model-authored `task`/`ask`/`compose` work and kernel
  tool fans absorb failure into material the model reads; a model ask halts on expiry.
  `halt` has no clock and moves only by adjudication or stop.
- Deliver model-started work in one envelope: `<task_result task=… status=…>` for work,
  `<answer task=…>` for an ask, with a tool tip naming its call on a `<call>` line. Render empty
  results too. A waited `task` receives the envelope as its paired result; otherwise delivery is
  a user-role message. Branch models never receive `task` or `compose`: delegation depth is one.
- `task` and `compose` default to detached execution. Their `wait` boolean decides when the
  caller continues; the client step surface spells this through `detached`. No model-authored
  step has an independent `wait` flag. Waiting, execution lifetime, and callback wake behavior
  are separate axes.
- `lifetime: turn|conversation` is available on tasks, compose, spawn, and member-authored steps.
  Omission inherits authoring context; roots and existing rows default to conversation. An
  explicit override changes no sibling default. Dependencies/read edges never transfer lifetime.
  Expansion, wake, repair, and regeneration retain source context; regeneration creates a new
  execution. A reply becomes final only after its deliverable, foreground work, turn-owned work,
  and required result consumption settle. Final delivery joins that work rather than cancels it.
  A detached conversation-lifetime consumer cannot discharge a turn-owned reporting obligation.
  Accepted append receipts replay first; new or retried turn-owned work after `delivered_at`
  refuses `turn_already_delivered`.
- Conversation-lifetime background work remains owned by its original loop and may outlive the
  turn. Every unconsumed result uses a supplementary turn after the original final reply, even
  if the result arrived early. Mail uses the same conversation/answerer and the source loop's
  model. `wake: auto` opens a `direct_reply` and wakes an idle conversation; `wake: passive`
  materializes a `message` without model lookup or reply. This inherited axis suppresses
  neither in-loop consumption nor turn-owned obligations. A standalone loop delivers within
  itself because it has no later conversation turn. Branch `cancel` resolves a canceled result
  for its consumer; the spine's lifecycle verb is `stop`.
- `pause/resume/stop` use a virtual clock. Stop may be graceful or force; an interrupted step
  requeues rather than fails, and deadlines do not advance while paused. Lifecycle hooks reuse
  task transport/repair for turn start, pre/post compaction, and a kernel-marked Stop ToolTask
  whose closed result may request bounded continuation at quiescence. Hooks are optional per
  execution, force-stop bypasses them, and they imply no plugin registry or second scheduler.
- There are no cumulative round, node, or model-step ceilings. Concurrency belongs to admission;
  per-append byte/shape bounds remain request hygiene, never total-work caps. Entry-count bounds
  sit beyond the byte wall's reach so compaction remains byte-driven.
- The repeat brake judges novelty, not total count. A round is stale when each element it reads
  already occurred in the preceding sixteen non-poll rounds on its chain and nothing new reached
  its reader. Eight stale rounds followed by calls already made in that window refuse expansion
  as `round_expansion_refused / repeat_call_loop`: a human hold on a halting chain, a failed result
  on an absorbing branch. Calls/results, settled branch tips, background launches, and delivered
  results retain their distinct identity/content. A steer, ask answer, authored brief, or rerun
  makes a round new; a compaction mark or no-call round ends the walk. Pure `read_process`
  polling is the runner's supported wait and is excluded unless new read/delivered material
  makes the round count.
- Output-limit cuts are `finish_quality`, never loop control. Execute every call whose arguments
  parse; represent a cut call as failed data rather than rejecting the batch or salvaging partial
  JSON. A provider refusal/blocked answer has no answer body: discard partial output and withdraw
  it from followers. Its work fails `model_refused` with provider/category and actionable kernel
  explanation unless the bounded fallback below applies. Never spend ordinary retries resending
  a classifier refusal to the same model.

### Script Tasks

- A script evaluates bounded pure JavaScript against `params` and its ordered selected `results`.
  A race slot is its selected/failure envelope with `selected` alongside. Return one JSON value,
  including null, or emit a finite subgraph with one readable leaf. Mixing values and work,
  an empty return, or a bare fan is refused.
- The immutable definition lives in the input ContentBody. Evaluate outside the loop lock, then
  atomically publish children, reader rewrites, output, and terminal state under it. Existing
  generation and park clocks fence duplicate work, stops, and expired evaluation. External
  readers receive final output without generated prompts/history; internal models remain branches.
- `result_from_node_keys` names selected reads and is unaffected by compaction.
  `expansion_parent_id` records immediate origin so cancellation crosses internal joins and
  boundary reads collapse to one result. Unread results outside the script still return to the
  caller. Reads, wait-only dependencies, generation ownership, and lifetime remain separate;
  there is no workflow entity, durable JavaScript stack, or additional scheduler.

### Asks And Approval

- `ask` is a first-class addressed wait, directly or inside compose, listed and answered by a
  console. Its per-park deadline is clamped to 24 hours, not shared across the loop's parks;
  expiry holds for a human without another clock. Resolution narration records
  `resolved_by` with kind, public id, and handle so the deciding principal is visible.
- Approval is the stage every tool row crosses between ready and running, including bypass mode.
  Model rounds use admission and have no approval stage. Freeze mode (`bypass|ask|rules`) and
  rules from the Profile or standalone shell; an input may tighten `bypass → ask → rules`, never
  loosen it. A model-authored row follows those declarations; author/kernel-origin rows are
  pre-approved unless a rule names that origin. Deny rules bind under every mode. `ask` parks
  without a matching allow; `rules` refuses unmatched work as data rather than granting or
  waiting for nobody. The shared grammar is tool glob, dotted input path, anchored glob,
  verdict, optional reason/origin; precedence is deny, ask, allow.
- `needs_approval` is a real tool state addressed to the host's Agent application, shown on its
  inbox as kind `approval` with the frozen effect profile. The loop reports `approval_required`
  while the turn stays running. `approve`/`deny`, stop, or the 24-hour clock ends the park;
  expiry is `timed_out approval_expired` under the row's policy. Both decision verbs project
  expiry under the loop lock before recording any decision: at/after the cutoff they return
  `not_awaiting_approval` even if the sweep has not visited.
- The approver needs the loop's write standing, including its conversation ACL when hosted.
  No extra token, role, or second factor is required. One release site serves bypass and
  explicit approval, re-runs addressing, and re-parks if the effect profile changed. Persist
  origin (`mode|rule|human|agent|author|kernel`), actor, and time on the row and public narration.
  Denial gives the model a correctable result that names the reason and tells it not to repeat
  the unchanged action.

### Delegation And Side Conversations

- `spawn` creates a child Conversation, not a branch: `parent_conversation_id` names the parent,
  `spawn_node_id` uniquely identifies the originating call for recovery, and `spawn_label` is
  unique per parent. Copy the parent's ACL carrier, billing, and runner; anchor user memory on
  the child's answerer. The brief is the sender's ordinary input. A waited spawn parks a
  kernel-held tokened await with absorb policy; timeout detaches and notifies.
- One conversation-tool job and run owner handle spawn/send/status/cancel. Address by child label
  or visible public id; refuse unknown, side, or ancestor conversations and a child addressing
  a parent that waits for it. `send` is the sender's idempotent input through the same door,
  under its full standing, with optional queue/steer delivery. `agent:` selects the peer
  answerer while `to:` selects the conversation; omission uses its default answerer.
  `status` reports running/idle, queue depth, and answerer; `cancel` invokes the shared Stop
  path. Parent identity, originating spawn key, and label appear on child reads and listings.
- Child reply relay is level-triggered over `conversation_turns.relayed_at`; terminal kicks are
  hints beside the recurring floor. It owes a reply only for a turn the parent opened, and
  only the original spawn request may settle its await. A later send, including steer-on-idle
  fallback, owns its own reply through frozen sender loop/task, model, answerer, and tool/approval
  surface. A steer into an existing child turn keeps that turn's one reply obligation.
- A turn-owned spawn adds a kernel-only `delegation_task` detached from immediate continuation,
  independent of the finite spawn await. It has no executor inbox, token, deadline, or retry;
  it observes the original child's execution and absorbs non-success for synthesis.
  Publish it atomically with `delegated_input_public_id`, binding the child's original
  position-zero Turn execution, including concealed originals, never forks/edits/later sends
  or regeneration. The seed inherits turn lifetime unless explicitly overridden.
- Repairable child holds remain outstanding; an edited unadjudicable original is stopped exactly
  and produces non-success. Publish the completion result and original reply relay stamp
  together. Switch queued await readers to completion while retaining their wait dependency,
  so the report is consumed once. Cancellation removes the pending input or stops only that
  original execution, recursively through unsettled turn-owned delegations. Completed
  obligations release ownership. Send/steer imply no join.
- Relay and completion cleanup have separate bounded cursors. Retain source owners and original
  results until the obligation converges; hard deletion of an owed original Turn refuses
  `delegation_pending`. Never acquire a child Conversation lock while holding the parent loop;
  convergence locks the target Conversation, then loop ids in stable order.
- A side conversation is a fork at the live head's last settled turn, even while the parent runs.
  It closes inherited history at that turn, adopts nothing, and places one user-role boundary
  item before its own input. User role prevents provider system-hoisting from changing the prefix.
  It never writes the parent's transcript. Shared request entries above the boundary are
  byte-identical; provider cache reuse additionally needs the same leading tool declarations.
- Sides are hidden from ordinary lists, cannot nest, archive, spawn, or receive conversation-tool
  sends, and are tombstoned/reaped immediately on delete. Parent archive/tombstone reaps sides
  first. Side instruction text, tools, one-open-side policy, and idle TTL belong to applications.

### Turn Settlement And History

- A loop-backed turn settles with its loop: completion copies the deliverable onto the variant;
  `needs_attention` or cancellation fails the turn with its reason and opens the conversation
  gate. The loop has no separate failed status. `awaiting_human` and `approval_required` keep
  the turn running on their park clocks. Held tail loops retain adjudication; retry/answer
  reopens that turn, while later input replaces the held execution. Missing results from a
  failed turn become kernel error envelopes in later assembly so every call is closed.
- Regeneration creates a new loop/candidate and refuses `loop_needs_attention` while its origin
  awaits adjudication. Successful regeneration or changed activation permanently stops the
  replaced variant's unfinished work and undelivered derived replies. `stopped_at` is write-once
  even after completion and gates publication/materialization. Selecting an old variant never
  revives work. Conversation Stop reaches all existing owners and their exact derived child
  requests; a later independent request in a reused child survives. Natural completion and
  new user input do not stop background work. The general ownership rule is in
  `.ai/boundaries.md`, *Async Execution Ownership*.
- Compatible independent worker finals may be consumed together when requester and
  execution/memory policy match. Fence each source before consumption; afterward the receiving
  conversation owns the combined reply. Immutable `callback_sources` retain each receipt and
  exact result without borrowing the last source's sender fields. Later source Stop neither
  retracts its read result nor stops that combined reply. Single-worker replies and ordinary
  task/tool/compose mail retain source ownership. Published content and completed effects remain.
- World state is a read projection of runner `metadata.checkpoint` beside the claimant
  (`AgentLoops::World`, `Conversations::WorldAt`), never a kernel judgment or column. An edit
  on a held tail overrides its execution: retry/abandon/repairing append refuse
  `not_adjudicable`, and no reopen follows.
- Every reply variant retains its opening prompt, including kernel receipts. While execution
  details exist, later history reads spine rounds through `AgentLoops::RoundReplay`, with
  in-turn summaries replacing their history; a tool-less reply reads prompt then content.
  Retention keeps the question, delivered follow-ups, and final response after execution detail
  collection, and assembly then reads those retained bodies. The default is 90 days after
  completion, configurable or disabled per Account. `details_pruned_at` records collection;
  expired world/checkpoint evidence is unavailable. Public variants expose loop ids and round
  summaries, not graph internals (`docs/agent-api/v1/execution-retention.md`).

## Executor Roles And The Gateway

- Follow `.ai/boundaries.md` for the Agent application, Runner, and tools-provider roles,
  credential planes, registration identity, management, and lifecycle. The Agent's member
  credential drives conversation work; its separate executor credential serves its inbox.
  A combined agent-plus-runner grant pairs both roles with one approval and two lineages,
  fixing the Runner private. The Agent application is never a host's Runner binding.
  Conversation-only products need not claim any task or register an executor to answer.
- Four tool sources share one provenance model: kernel, Runner, tools provider, Agent application.
  A name resolves to one authority, preserved on the row and wire. A declaration may alias a
  kernel tool and map parameters; canonical routing and reserved namespaces remain unchanged.
  Render descriptions with declared names, then execute calls under their canonical name.
  Kernel tools run through kernel jobs with the same park/deadline/settlement mechanism;
  an overridden name instead goes through the provider's inbox as ordinary tool work.
- Each conversation binds one explicitly selected Runner; an unnamed host is unbound. Validate
  a named live Runner against the host's answerer (`Executors::InitialRunner`). Handoff is the
  only value-to-value binding writer (`InputHost#bind_runner`), narrates `runner_bound`, and
  re-addresses only unclaimed work. Claimed tasks finish/expire where claimed. Model-visible
  environment/conventions stay frozen for the current turn and update on the next one.
- Tools providers use named eligible pools in the Workspace, never Runner bindings. Each
  eligible provider sees the unclaimed task until one claim wins. Workspace
  `tool_provider_overrides` is explicit and namespace-grained; reserved families cannot be
  overridden. Discovery filters eligibility, never presence, and the kernel selects no host.
- Nexus relays cross-component messages over each executor's outbound connection. A capture
  uses executor upload plus a `resource_link` in the commit and the shared upload bytes read.
  A request is an ordinary one-tool standalone loop, with the same claim/commit/sweep path;
  it has no second inbox subject or transport. The executor's own in-process UI may read its
  local surface, as specified in `.ai/boundaries.md`, *The Human Console And The Gateway*.
- Tool progress uses the executor progress door and host progress feed, fenced by the claim or
  binding. One transcript presenter serves the page, a branch's `?prefix=` expansion, settled
  round snapshots, and timeline rows. It derives rounds, calls, branches, and reading order
  from stored keys/marks/reading lists, never graph edges, and writes nothing. The graph route
  remains the graph reader.
  `node_key` uses `C` collation so key ranges mean bytes on every platform.

## The Task Inbox

- One distributed asynchronous task queue serves every executor role and every delegated kind,
  including tools and compaction. HTTP is authoritative, the inbox is level-triggered and
  complete, and Action Cable is an executor-keyed wake hint. Sleep, restart, or missed frames
  lose no task; correctness depends on no socket, presence, or heartbeat.
- A claim rotates its token and is exclusive until the task's own deadline: one clock, no
  renewable lease. Only its claimant may extend it, within the announced park bound or the
  kernel's hour, narrating `task_deadline_extended`. Commit is a write-once result and a stale
  token settles nothing. A late commit remains expiry unless the claimant extended in time.
- Inbox rows are their owner's tasks, not another delivery lifecycle. Subordinate payload/body
  rows do not duplicate mutable task metadata. A retry creates a lineage-linked task.
  A model's ask is listed on the Agent application's inbox but never claimed: its address may
  answer without a claim token, or a person may use the member resolution door; both share
  one settle. Awareness notifications never become this obligation queue.
- Runner calls address the host's bound Runner; only provider calls may address a Workspace
  role pool. An announced capability guides delivery. A declared but unserved tool fails at
  start as `tool_not_served`, material the model reads, rather than parking indefinitely.
  Human managed-executor shutdown fails unclaimed addressed work as `executor_revoked`,
  applying its failure policy; claimed work retains the independent shutdown/claim protocol.
  Agent Profile removal's different credential cut and asynchronous force-stop follow
  `.ai/boundaries.md`, *Administration Boundary*.
- The declared tools and delivery capabilities are distinct facts. Executor announcements
  never reshape tool-schema bytes in the cached prefix's name-canonicalized list. The sole
  omission is `skill` when the merged kernel/announced skill catalog is empty, decided at the
  provider-bound site. The catalog itself belongs in the assembly `skills` block.
- An executing claimant recovers missed cancellation by GET on its exact claim with the
  original `Claim-Token`. Verify claimant/token before projecting persisted dispatched state.
  This lock-free, non-cacheable read grants/renews nothing and ignores new-admission,
  inbox-membership, and current-binding gates. Pause, needs-attention, and graceful cancellation
  can preserve an existing claim. GET and POST have separate caller budgets. Executor handling
  of unknown read failures and bounded control-call delays follows `.ai/boundaries.md`.
- Deadline settlement follows the effect profile: replayable work times out for an explicit
  re-issue/retry, never automatic requeue; a possibly escaped effect becomes `uncertain` for
  adjudication, never a fabricated timeout or blind replay. A result accepted strictly before
  the absolute deadline wins over delayed expiry projection; at/after the cutoff expiry wins.
  Effect profiles are required declarations, not security authority.
- Park deadlines use the loop's virtual clock, frozen while paused. SQL timeout frontiers are
  advisory: `DatabaseClock` reads PostgreSQL `clock_timestamp()` for candidates, then the owner
  re-derives expiry under the loop lock. Strict temporal winners use that database clock.
  Coarse replay/retention TTLs may use persisted application timestamps only where the contract
  accepts ordinary clock skew without an integrity or irreversible-effect consequence.

## State, Events, Liveness

- Rows are truth. Project derived gauges at read time rather than persisting another authority;
  related status vocabularies share one closed algebra, including `timed_out`.
- Credential readiness, presence, and lifecycle are separate displayed facts, never one fused
  availability word. Presence is never an admission or dispatch gate. Lifecycle, credential,
  and ACL checks still apply at their owning boundaries; none chooses a Runner implicitly.
- Durable events narrate public facts; Cable is a droppable wake, including its final frame.
  REST replay suffices for event correctness. OneShot's terminal result event is bounded;
  REST owns the complete result. A consumer needing bounded terminal detection owns polling.
- Level-triggered, idempotent reconcilers and per-state sweeps own liveness. Jobs and socket
  wakes only reduce latency; models never require a job to have run. Unclosed work has a named
  holder and clock: invocation attempt, tool park, or await. Delegation completion observes its
  original execution without adding a deadline. A human halt and an idle conversation have no clock.
- A re-readable fact needs its row and persisted event. Archive/delete narrate
  `conversation_ended` with reason and member public id in the mutation transaction. A
  tombstone's final feed item precedes REST concealment and later collection. Runner processes
  follow their conversation's lifecycle; inbox `conversation_public_id` supplies that ownership,
  null for standalone loops, without a runner-side lookup.
- Workspace lifecycle is `active → archiving → archived → restoring → active` or
  `active|archived → deleting → deleted`. Transition states cut current authority immediately;
  bounded convergence advances them after descendants settle. `archived_at`/`deleted_at` are
  capture/retention clocks, not another status. Physical collection is FK-safe and leaves-first;
  usage/audit survive through their public-id snapshots. Human/Profile removal and their
  generation/epoch distinctions remain owned by `.ai/boundaries.md`.

## Model Plane, Billing, Context

### Catalog And Request Ownership

- The repository ships no model selector. Selection/routing is deployment policy; an undefined
  declared selector refuses `unknown_model_selector` at acceptance, before provider IO.
- Provider/model fragments plus flat `config.d` overlays form the strict file base: generic
  files, then `<name>.<env>.yml`; subdirectories refuse compilation. Boot validates the whole
  candidate before readiness. A live-reload implementation must publish a complete candidate
  atomically and preserve the prior snapshot on rejection.
- Read each enumerated file once into that candidate. A stable, valid intermediate edit is a
  valid base. No cross-file transaction, digest, capture manifest, generation marker, atomic
  directory protocol, or publisher check is required. Use registered provider defaults or a
  custom endpoint with an adapted protocol, never declarations of executable adapters or new
  OAuth ceremonies. Trust/portability and development-tool rules live in `.ai/boundaries.md`
  and `.ai/repository.md`.
- `ModelProviderPolicy` is the only database catalog overlay. `provider_definition` is an
  optional complete replacement, parsed by the file-base grammar before composing models.
  Subsequent consumers read saved changes without a restart/reload latch. Its bounded
  `model_overrides` mapping has at most 256 exact refs and 2 MiB canonical JSON: whole `upsert`
  entries or `remove` tombstones. Removing an operation restores file inheritance. No recursive
  merge, fuzzy family keys, or cross-provider batch.
- Optional `hidden_models` holds Account-wide exact-ref restrictions separately from definitions.
  Visibility writes preserve definitions/prices/inheritance and use the Policy's version.
  Hidden models remain in the admin catalog, leave Agent discovery, and refuse selection,
  admission, and provider start; already-started calls finish and settle normally.
- Well-shaped future-name upserts, flags, or tombstones may be stored inertly until composition
  makes them applicable. Warn and ignore an uncomposable provider Policy while retaining it.
  Database entries cannot define executable code, signing, transport, redirects, selectors, or
  new protocol behavior. A new model/capability must use an adapted `api_format`; price/metadata,
  narrowing, enablement, hiding, removal, and reset cannot create adaptation authority.
- Policy writes require optimistic `lock_version` and bounded validation before SQL. Interactive
  authoring also validates the resulting lane and selector references; internal inert-document
  writes retain their storage contract. Commit on the Policy alone, without CatalogState,
  generation, digest echo, or separate health gate. Invalid input and same-value replay change
  nothing. The compiler applies file then database layers and validates final composition.
- Warn-ignore an invalid top-level stored document as a whole while preserving its separate
  enabled flag; warn-ignore invalid/inapplicable entries independently so valid siblings and
  file models survive. An inapplicable tombstone hides nothing. These failures do not poison the
  strict file base. Warnings identify only safe public identity/reason. Database unavailability
  fails composition rather than masquerading as an empty overlay.
- Acceptance freezes provider/model choice and semantic options. Admission may price one
  effective catalog composition per Account/pass. Sending reads the immutable Invocation request
  plus one current process-local Catalog snapshot; derive adapter profile, endpoint, model pin,
  media rules, and wire facts once for request build and ProviderStart. No acceptance-time
  execution profile, persisted revision, or remote-version proof participates.
- Business input, assembled request, and sending have separate owners. Conversation/OneShot
  holds accepted input; assembly combines it with tools/system/history; ModelInvocation seals
  the executable request and semantic options for every retry. Do not reassemble mutable
  context at send or duplicate that snapshot on the business record. Provider limits are
  ordinary reviewed configuration: validate final consistency and enforce at the request
  boundary; unknown optional limits remain absent, without qualification records.
- ProviderStart resolves current credentials and applies expiry sufficiency before IO. Provider
  refresh is proactive, bounded, and single-winner before admission/provider start. Provider
  authorization, secret handling, and the narrow development seed exception are owned by
  `.ai/security.md`; single-use exchange/refresh coordination follows `.ai/database.md` and
  public settings behavior follows `.ai/api.md`. No diagnostic is serving authority.
- A provider's `Retry-After` is a lane admission floor stored per Account/provider, read by the
  candidate query, projected as `unavailable_until`, and expired by time. Never invent its value
  or confuse it with a cumulative-work ceiling. Operational enablement belongs to live Policy
  state; an adapted wire permits that implementation, not a remote-version guarantee.

### Bounded Model Fallback

- `AgentLoops::ModelFallback` has two explicit triggers, never catalog search. Unavailable
  result-mail work may switch once per loop to that recipient's current different
  `default_model`, using `mail_model_fallback_used`. It applies to the main reply path, not
  explicitly selected branches. Mail replies always use a loop, even for tool-less profiles,
  preserving answerer/prompt for node-level repair and the source approval mode without adding tools.
- A classifier refusal, or provider overload on every attempt of a step's spent budget, may
  switch that step once to the answerer's live declared `fallback_model`. Content blocks are
  not classifier refusals; rate limits wait on their lane floor and are not overload.
  `provider_overloaded` requires every attempt's matching receipt. This applies to all model
  steps, including named/branch/compose work. Recheck the fallback against the actual request,
  including replay requirements, then requeue with a fresh generation and narrated
  `task_status.model_change {from, to, reason, category}` plus `output_summary.model_change`.
- The switch budget is the step's invocation history, not another column/counter that retry or
  redeclaration renews. Never pick a model that refused or overloaded for that step. A switch
  that cannot proceed may fall through to the mail-unavailable rule. Exhaustion holds at
  `needs_attention`; explicit failed-model retry can name a replacement without renewing the
  automatic allowance or replaying finished tools/children.
- A switched spine continues on fallback for the rest of its turn. New branches/delegates and
  spawn/send defaults use their configured lineage model (`AgentLoops::ConfiguredModel`),
  derived from the oldest causal round on the reading chain across compaction cuts. Across
  turns use `turn.model`; keep no routing state. Invocation identity and sealed request remain
  immutable; the variant keeps initial selection while the loop exposes current main-path
  selection, and reasoning retains its producing invocation's identity.
- Tool-less direct replies use one kernel regeneration candidate (`source: fallback`), decided
  under the conversation lock before settling. Keep the turn running, its steers and lane intact,
  and act as the declined/overloaded sample's poster. A fallback candidate never falls back;
  Stop wins without a switch. OneShot makes the same bounded decision under its aggregate and
  Create authority locks, rechecks admission and sealed input for the creator's fallback,
  and creates at most one second execution. It reads its latest execution, without changing
  accepted input or resending the same failed model.

### Metering

- Usage is an append-only receipt ledger in optional, opaque, configure-once `Account.cost_unit`.
  Exact canonical amounts use `numeric(38,18)` already authored in that unit. Nexus defines no
  currency registry, exchange rate, or runtime conversion. Native amounts remain capture unless
  unit and source policy permit them. Missing money stays unknown; every started attempt's known
  cost remains in statistics regardless of product disposition. Rollups are rebuildable projections.
- A Human pays; an Agent is the consumer and derives its payer from its current steward. The
  per-payer concurrency brake (`ModelInvocations::RunningCapacity::USER_ACTIVE_LIMIT`) counts
  Agents in that steward's capacity. Admission checks the usable budget head softly and unlocked,
  with no reservation, hold, frozen pricing, or two-level winner. Settlement appends actual
  charges when a budget is usable; absent budget is uncapped. Bounded in-flight/settlement-lag
  overspend is accepted.
- Pricing is optional. Unpriced/unknown-cost models remain usable and usage quantities still
  become receipts. A complete `catalog_only` schedule with every referenced rate explicitly
  zero is known-free, produces an exact-zero receipt, and has no budget effect; file and database
  definitions may both author it. Validate completeness, unit consistency, precision, and
  non-negativity, never commercial reasonableness. `billing_subject` is opaque application
  attribution, never another payer, balance, quota, or enforcement tier.
- UsageRecord is immutable; exact replay returns its receipt. Read effective Account pricing
  at settlement and snapshot `unit_pricing` there. Cost arithmetic is an estimate; no start-time
  schedule remains to compare. First-owner browser setup defaults to opaque `USD`, with an
  explicit Advanced alternative; factory/schema/kernel still provide no default unit.
- Shipped foreign-unit rates are normalized only during manual reviewed authoring, with the
  supplied conversion convention recorded beside them. No fetched/chosen FX factor, validity
  window, scraper, periodic price refresh, or runtime sourcing. Users may author their own overlays.
  Generic source-policy/settlement coverage uses fake providers; local real-provider diagnostics
  can check wire behavior but are no second ledger or maintained billing proof pack.

### Prompt Assembly

- `raw` takes the whole caller request. `assembly` compiles the Profile's ordered
  `prompt_template`; `default` uses the same compiler with `PromptTemplate::DEFAULT`. The closed
  block vocabulary is `slot|inline|memory|skills|lead|tail|history|input`, plus declared variables.
  Text substitution uses one macro pass over built-in sources and variables, no Liquid or
  separate template engine. Kernel assembly stops at this grammar; product texts, lorebooks,
  richer personas, depth injection, and custom turn order remain application compositions.
- Persona, character, and system prompt are durable documents on the controlling Human,
  Workspace, and Profile. Default order is
  `[system_prompt][character][persona][memory][skills][history][inline lead][inline tail][input]`.
  Slots use the closed macro registry, are funded before history, and form leading system-role
  entries in the sealed list, not a second wire-system channel. Per-turn inline slot entries
  override them; raw instead uses input `instructions` in the wire system field.
- One `BudgetAllocator` pass funds required block floors with history as the optional child.
  Without a window, history is unbounded and no allocator runs. An authored turn/template share
  is flat with the prompt on top; overflow arms compaction instead of silently trimming.
- `POST …/context_estimate` with `render: true` is the preview, not a second GET surface. Use the
  same resolved addressee, caller-author, `Conversations::TurnPrincipals`, and seal measure
  (`ContentBodies::Measure`) as sending. Expose the would-be entries, storage bytes, and
  `selected|empty|floor_unmet` evidence, never excluded blocks: the request sends whole or the
  window gate refuses. A trial template is estimate-only, never stored on an input.
- A standalone default/assembly loop compiles its seed once at creation through the same
  `ContextAssembly::Source`, with no timeline, no turn Profile, and no limits. It uses Workspace
  and creator memory under the conversation-less header; the creator's template supplies
  assembly, or `prompt_template_missing` refuses it. Reject `instructions`, seal the compiled
  seed, and retain the creator's words as readable text. Later rounds replay that seed;
  scheduler-time memory reads and a second assembly path are forbidden.

### Prefix Stability And Reasoning

- Kernel-serialized context grows at the tail. Each message's wire bytes depend on its own
  immutable fragment, so appending cannot rewrite the prefix. Content is create-and-seal;
  edits create variants. This is also the SDK runtime's deferred-append default; an application
  explicitly authoring its own context retains that policy freedom.
- `simple_inference` carries cache-control mechanism; the kernel chooses breakpoints. Dynamic
  material resolved per turn belongs after the stable breakpoint. Slots, memory, and skill
  catalog may lead only while their values are stable until a write; a per-poster persona or
  date macro belongs in the suffix rather than changing the paid cached prefix.
- Seal per-turn text between history and input as the variant's preface at every seed path
  (input drain, mail, regenerate, edit), and replay it in position for the answerer's own turns,
  never peers'. An identical lead already in the newest in-window own preface is carried once,
  including its sealed dependency fact, not laid/replayed repeatedly; re-asking after it leaves
  the window lays it again. Merge adjacent same-role items as distinct text parts, never fold
  their text. Never merge a segment carrying reasoning; delivered results, steers, and abort
  messages retain the individual message boundaries their first request used.
- Wire submission order and character-identical input prefixes require direct regression pins
  in `ModelRequests::BuildTest`; correct answers alone cannot detect cache-cost regressions.
  The prefix is the unit, not the whole payload: jsonb request-option key ordering has no
  compiled-payload digest contract. The stable marker follows the sealed leading-system and
  memory structure.
- Request kind stamps Anthropic cache policy in `request_options.prompt_cache`: conversation
  spine/direct reply/regeneration gets one hour plus tail; branches, subagent conversations,
  standalone loops, and OneShots get five minutes plus tail; summarizers get no marker.
  `Nexus::PromptCache::RequestKind` owns that choice. Provider observations are optional
  diagnostics, not regression authority.
- Reasoning is history. Default replay is `all`: retain every trace the target wire can read in
  the form and position first carried. Protocol format determines representation; unreadable
  origins contribute nothing, not a content fence. Fit traces with their turn using captured
  token counts and sealed bytes. Remove them only with that turn through compaction or an
  author's narrower/off mode, never by trace-only trimming or a retry without required traces.
- A hard/shared window reserves answer room `min(32k, 12.5%)`; advisory planning bounds already
  include it. Explicit one-turn replay/history limits and model-effort changes may omit material;
  a later default turn can include it again. Do not silently convert these intents into sticky
  conversation policy. `reasoning_replay_downgraded_at` records a native-reasoning shape fault
  from a non-transient provider 4xx, read at seed creation. Loop tool rounds keep required traces;
  window overflow belongs to compaction on every lane.
- Displayed context occupancy comes from the last provider usage record, never token recounting.
  Assembly planning and fit checks remain separate from that observed occupancy.

## Content And Memory

- Freeze each turn's declared tools narrowed by input `tool_names`: absent means all; `[]`
  means none. That declaration is the execution gate, including for kernel tools; undeclared
  calls are unknown and never run. A no-tool continuation on the same model/provider retains
  its preceding round's wire `tools` by value under `tool_choice: none` while its declared set
  stays empty. This preserves cached prefix and replayed reasoning without granting execution.
- ContentBody holds ordered entries backed by immutable digest-addressed Fragments for sharing
  and copy-on-write. Compute a unique payload's canonical address once at its writer boundary.
  Input and output are sealed; an edit makes a variant.
- Attachments reuse OneShot's part model: compose one role/parts entry with words then attachments
  in order, bind its uploads, and supply words as `readable_text` (empty for file-only input).
  Read pictures through `ContentBody#upload_parts` in entry order with the join deciding liveness.
  Assembly places each part against that turn's resolved model: supported media is native,
  otherwise its index line occupies the same position. Seal exactly the placed uploads.
- Ordinary files use `nexus://uploads/{public_id}` index lines, never native model parts. The
  active claimant may read input-bound files and visible prior history through attachment
  descriptor/bytes doors with transport credential plus Claim-Token. Nexus owns durable bytes;
  the Runner builds a working copy and its tools parse it. Steers accept no attachments.
  Presentation shows the stored attachment fact irrespective of wire placement.
- Summaries retain pointers, not image contents: use the same index line with the summary's
  `not carried past the summary` reason and instruct the summarizer to name what to reread,
  never describe an unseen image. File references survive compaction within live history scope.
  Model-facing index text follows its measured contract, not unmeasured wording changes.
- One `UploadIngest` serves authenticated member, Human-session, and executor upload doors.
  Executor captures use an executor creator anchor; member/session uploads use a User.
  Anonymous framework direct-upload routes remain disabled. Unbound staged bytes are outside
  claimant scope. Output bytes stream through ranged `ActiveStorage::Streaming`, never a
  Disk-only service.
- ContentUpload owns one immutable Active Storage blob; the unique body-upload join owns body
  liveness, and blob metadata supplies filename, size, and type. Do not add attachment proxies,
  mirrored blob facts, reference counts, release stamps, copy lineage, or another public
  attachment identity without a reachable writer. Fragment/unattached-blob reapers cover real
  orphan windows; staged-upload collection queries join existence, never a second truth.
- Memory is one family of neutral immutable text versions shared by pointer at User, Workspace,
  and Conversation scope. `user/` belongs to the turn principal's controlling Human and is
  readable by that Human and their Agents across Workspaces. Scope-specific doors never reach
  a row through an unrelated host. Support bounded literal lookup, per-anchor clear, and
  fork copy-on-write restricted to the inherited prefix. Extraction, consolidation, semantic
  retrieval, ranking, vector stores, and provider dependence are outside this kernel family.
- `memory_context.bindings` maps logical paths to existing database anchors: null keeps defaults,
  an empty list disables memory, explicit roots declare read/read-write, and aliases may select
  visible conversations in the same Workspace. Content remains in the database, with no memory
  filesystem or synchronization. Reply variants freeze bindings for injection, tools, preview,
  management, and inherited work.
- A Workspace may override the memory tool family through `tool_provider_overrides`, one provider
  per family, never a reserved namespace. Its six verbs then go to that provider with kernel
  scope stamps; kernel memory injection/member doors are silent for that Workspace and provider
  results are ordinary tool output. Memory is text the model reads.
- Stores are opaque namespaced KV at User, Workspace, and Conversation scopes, using the shared
  write-size and idempotency contracts. The model does not read stores as memory text. User
  store scope belongs to the acting principal itself, unlike memory's controlling-Human scope.

## Compaction

- One kernel-scheduled repair serves mid-turn loop rounds and between-turn conversation history.
  Arm it because a request will not fit, never an arbitrary kernel threshold: last provider
  usage plus appended material (`usage`, checked first), lane fit counter (`wall`), provider
  overflow after send (`overflow`), or an explicit manual request.
- Once per wall, prune older consumed tool results or run one summarizer whose output replaces
  the corresponding history. Pruning marks rows without deleting their calls or creating a new
  row. Prune only while results outside the keep-recent tail cover overshoot net of replacement
  placeholders; otherwise summarize. Manual compaction always summarizes.
- A summary carries pointers, not values. Serialize tool results as the call and returned amount;
  instruct the model what to reread, and frame every summary with the fixed no-data-values
  sentence. The kernel ships a default summarizer; an Agent override receives an inbox task on
  its own address. A missed delegated response expires at its park and invokes the kernel
  summarizer once with narration; a second failure is an honest size failure.
- The default summarizer uses the Profile's optional content-only `summarizer` prompt document
  or shipped text. It is separate from the three assembly slots: no macros, role, or template
  placement. Under raw, the kernel owns no history and refuses its own summarizer as
  `compaction_unavailable_under_raw`; only delegated repair is available.
- The conversation timeline is the only history substrate. A mid-turn summary is inside the
  repaired turn, never another turn. Repair replaces only timeline history: current read slots
  still deliver first-read tool results, waited child results, and ask answers after it, once,
  with pairing and attachments intact. Pruning neither counts nor clears that current fan.
  Compaction is the deliberate prompt-cache reset, including when manually requested.

## Discipline

- Reuse one explicit request/snapshot size contract and one idempotency mechanism per boundary
  kind, including create receipts and result replay. Do not add inconsistent layered byte caps
  or feature-local replay schemes.
- Rails ownership/style follows `.ai/backend-rails.md` and `.ai/patterns.md`; schema, validation,
  locks, and reset posture follow `.ai/database.md`; HTTP contracts follow `.ai/api.md`.
  Keep cross-cutting rules in those owners rather than duplicating them here.
