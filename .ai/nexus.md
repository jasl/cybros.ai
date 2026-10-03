# Nexus Kernel Doctrines

**Applies to:** `nexus`.

Project-local rules for `nexus/`: the kernel doctrine under the product mandate of 2026-09-04
(`docs/plans/2026-09-04-product-mandate.md`, including its rulings of 2026-09-05 and of
2026-09-08/09), with the
capability set distilled from the references (`docs/plans/2026-09-05-capability-basis.md`) as the
design basis. The mandate is the yardstick: when code contradicts it, the code drifted. This file
is the index of things that must stay true, stated in the present tense; a mandate word not yet
built may stand here only as intent carrying a `(planned: S-x)` marker (orchestrator ruling Q8,
2026-09-10) — never in the present tense — and everything else unbuilt is the ledger's business
(`docs/plans/DEFERRALS.md`), never this file's. THE BUSINESS-NEUTRAL TEST (owner principle
2026-09-09): Nexus implements the essential capabilities every agent product needs —
conversations, loops, tools, memory, approval, presence, delegation, group chat — and nothing
shaped by one product's UX; an earlier plan item is not a commitment, and when a slice reaches
one the test is "would every agent product need this from the kernel, or is it one
application's?" — an application's goes to the SDK side or is dropped (S-H's re-scoping was the
first application of the test).

## Shape

- Nexus is a fat, complete, orthogonal kernel for building every kind of agent — coding/Cowork,
  personal, chat, role-play (owner mandate 2026-09-04). An agent plugs in to get an agent's general
  capabilities; chat and role-play agents are Nexus consumers in their own right, not a degenerate
  case of the coding one. Three primitives: Conversation, the bare-metal Agent loop, OneShot.
  Mandatory kernel mechanisms: compaction, memory, cross-conversation messaging (Q1), prompt
  assembly `raw | assembly | default` (R3), approval — stage, modes, verbs, park, rule model (R5),
  stores at User/Workspace/Conversation scope (R4), and the task inbox (R1) — owner rulings
  2026-09-05. A capability composable from the primitives is not provided directly unless it is
  common. What stays OUT:
  prompt MEANING (what a product says), model routing and selection (deployment policy; the
  repository ships no selector), product tiers, real-user semantics, memory
  extraction/consolidation/ranking policy, retrieval-augmented knowledge (a tools provider's or the
  agent's, never a kernel block — owner ruling 2026-09-05), in-place rewriting of history (an edit is
  a variant; the agent may build more), and commercial concerns. Fat means every general
  mechanism an agent needs lives here; it never means product policy does.
- One `Account` (Fizzy-shaped) is the container root and single trust domain; Identity/User split
  per `.ai/patterns.md`; a synthetic `system` user carries machine-initiated actions. First boot is
  gated by `Account.none?` signup.
- Workspace is the mandatory container for execution/content resources. It has one required
  same-Account Human owner, immutable creator attribution, and `account_wide | private` data
  access. The owner must remain un-removed while the Workspace is non-tombstoned: suspend is never
  blocked by ownership, remove requires transfer or tombstone first, and `deleting|deleted`
  retains that owner only as a durable ownership/attribution anchor until physical collection. No
  default Workspace exists — founding seeds nothing, principals create their own, and the
  create-frozen `agent_identifier` tag is null for Human creation and automatically set to the
  authenticated Agent's own identifier for Agent creation. It grants no access while fencing
  mismatched Agent writes (reads and Humans pass), and creation exposes no dedication selector.
  Workspace tags are never unique; the sole `agent_identifier` uniqueness
  boundary is one Agent Profile/User per `(steward_id, agent_identifier)`. Agents derive data access
  only from their current live steward and never manage. After that ordinary access scope, Agent
  lists default to undedicated (`agent_identifier IS NULL`) rows and may instead request only rows
  dedicated to their current identifier; Human lists default to every accessible row and the
  current-Agent predicate is empty for them. The exact identifier never crosses the wire, and
  dedication has no mutation surface. Only the active Human owner of a browsable Workspace manages
  (`.ai/boundaries.md`, spec 02).

## Conversation, Agent Loop, OneShot

- Conversation is the unit a person has. The Agent loop is the engine inside a turn: a turn's
  reply may be produced by a loop — the loop-backed turn — and that loop's tool calls, tool results
  and approvals land on the conversation's own transcript and feed, never on a second record.
  Which engine answers a turn is the kernel's choice from the agent's tool-bearing configuration;
  loop creation is decoupled from any driving delivery row (owner mandate 2026-09-04 corollaries;
  owner ruling 2026-08-30 R15). Standalone loops remain a kernel mechanism for workflow and
  background runs. OneShot is one accepted input, one sealed request (asked once more, whole, on
  the creator's declared fallback when a classifier declined it), one authoritative REST
  result.
- One input door: conversation inputs with delivery mode `queue|steer`, durable, ordered and
  idempotent, and no second waiting room anywhere. A queued input lands at the turn boundary; a
  steer lands at the next unambiguous model boundary of the loop backing the in-flight turn,
  spliced as its own trailing message into the request that boundary seals — the sealed request
  is the record of landing (the round keeps the landed messages as its own `steers` body,
  `AgentLoops::Steers::Landed`, so later history, a pruned round's composition and the summarizer
  render them before that round's answer — B43); nothing amends a request already sent. Every
  pending steer drains together at that boundary, in arrival order; a steer that finds no
  boundary falls back to the queue unless it carries `expected_steering_loop_public_id`:
  that exact-loop delivery intent rejects an idle or changed target at admission and cancels
  an unconsumed steer when the bound loop settles, rather than creating a later request.
  There is no reply input kind for a loop-backed turn — the reply is the turn — and `/asks`
  is reserved for addressed obligations, never a reply door (owner corollary 2026-09-04, Q2).
  A row may carry `deliver_at` (the door's one clock, taken as an absolute time with an offset or a delay;
  a time more than two minutes past or ten years ahead is refused; never on a steer, never on the loop
  door, never on the kernel's mail): before its time it is not in the room; when due the drain re-reads
  the author's write standing and it drains and wakes through the receipt's own path (owner 2026-09-15,
  item 12).
- THE KERNEL DRIVES ROUNDS. A round continues iff calls arrived — never on the provider's stop
  reason; every call is paired with a result, and a tool that could not run reaches the model as
  an error envelope so its failure resolves the continuation rather than skipping it (owner ruling
  2026-08-30 R9, second batch: the kernel's own tool fans are authored `absorb`). An ordinary tool
  cannot declare the run done: `outcome` says whether it ran and `is_error` is data. Quiescence
  owns final delivery. Lifecycle hooks add a narrow seam there — the one the owner's ruling of
  2026-09-06 had deferred to S-P's first seam, reversed for this surface alone by the ruling of
  2026-09-20/21 (the mandate's entry of 2026-09-22; the rest of S-P's seams stay deferred):
  only a kernel-marked Stop ToolTask can request bounded continuation through its closed
  structured result. The same task-backed mechanism acknowledges turn start and pre/post
  compaction. It is optional per execution, uses existing task transport and repair, and force
  stop bypasses it. No general plugin registry or second scheduler is implied. After a
  crash an unclosed unit is waiting on a
  named party with a clock — never "still running", never abandoned — because level-triggered
  sweeps terminalize started work. A `halt` at rest has no clock and only a person or `stop`
  moves it. A kernel delegation completion observes a concrete child execution without adding
  another clock; that execution retains its own deadlines and repair holds. A conversation
  between turns is idle, not waiting.
- The loop's WRITE surface is task-grained: tools and API author work items, every node is its
  own tracked, retried, parallel state machine, and no agent or external consumer ever writes an
  edge — the edges are the kernel's, which is what keeps the graph sound. The graph is READABLE:
  a task's `after` on the trace, the member graph route (nodes, edges, Mermaid) for debugging,
  e2e evidence and a UI drawing the workflow. Engine mechanism still never renders — no detached
  flag, spine mark or graph sequence on a public route or in a tool result (owner rulings
  2026-08-30 and 2026-09-05, the latter clarifying that the picture may be exposed). Work is
  placed in WRITTEN ORDER; `parallel` names a fan; a barrier is named (`until: any | k`, `losers`),
  never drawn — the kernel places it. Waits come from position and from `after`/`results`; READS
  never come from position: an authored model or script step — every compose step, every
  `parallel` member, a stage's steps, the `task` tool's delegate, a door step — reads its prompt
  and the results it names, in that order, a race by its barrier as the selection it captured,
  and continues no one's conversation. The loop's own conversation is the one recorded
  difference: a model step on the loop's own path — the door's top level, a round after its tool
  fan, the wake, the plant, the lifecycle-hook continuation — continues the spine the kernel's tip
  hands it and reads the round's paired calls beside what it names; a spined reader naming the
  round it continues receives it once, as history (Q10), never as a second envelope. A door
  envelope's `results:` may name any earlier row of the loop by key — the one way a value crosses
  appends — and reads what stands for that row now: a row an expansion replaced is read as the
  expansion's final answer, never its first draft or a stage's manifest. Every result no step
  reads comes back to the caller (the waited continuation reads it; the wake or the mail delivers
  it once its chain has settled), one set for both modes; a race's barrier stands for every row in
  its arms (a step its author detached there is no arm's), and a settled race's arms hold nothing
  back; an expansion stands for the row it replaced; a stage's insides stay behind its boundary;
  and a turn-owned spawn's delegation owns the child's one report, so the short await beside it
  never comes back. References wait as well as read and never remove a written-order wait. The
  kernel deduplicates edges; structural placement wins over a reference on the same endpoints.
  Cancellation follows structural placement, while scheduling waits on every dependency. (Owner
  ruling 2026-09-26, the familiarity bar, recorded in
  `docs/plans/2026-09-26-explicit-reads-design.md`; supersedes the additive `results` of
  2026-09-21 §1 and the positional read of 2026-09-06 §2.2.) Failure containment
  `absorb|propagate|halt` with a per-MODEL-STEP retry budget (a tool call or an ask parks on its
  holder and has nothing to re-run by budget — `retry` on either is refused at compile, node review
  2026-09-08 change 6; a failed tool call propagates, a failed model call halts, the kernel's own
  tool fans are authored `absorb`), `halt` as a human ask with no clock, `pause/resume/stop` on a
  virtual clock (two-phase stop, graceful or force; an interrupted step is a requeue, never a
  failure; no deadline moves while paused), and the repeat brake (it judges NOVELTY, never count:
  a round is what its reader newly read — each call as its row stores it with its result as the
  row, or the branch tip it answered with, settled; a background launch as the launch alone; a
  delivered result by what it came from and what it said — and a round is stale when the sixteen
  non-poll rounds before it on the same chain already brought each of its elements and nothing new
  reached its reader; when the eight rounds up to the one the model just read are all stale and it
  asks only for calls those sixteen made, its expansion is refused `round_expansion_refused /
  repeat_call_loop`: a halt to a human on a halting chain, a failed round its consumer reads on an
  absorbing branch; a landed steer, an ask's answer, an authored brief and a re-run make a round
  new; a compaction mark and a round that made no call end the walk; a round of nothing but
  `read_process` polls is the runner's designed wait — never stale, never refused, outside the
  count unless a fresh reader or delivered material keeps it in — owner rulings 2026-09-12 Q3 and
  2026-09-24, the exemption retired by a process-exit wake)
  are kernel mechanism. A task a MODEL authors — through `task`, `ask` or `compose` — is `absorb`: its
  failure reaches the model as an envelope, never a skip that strands the deliverable; the
  kernel's own fans are `absorb`; a client-authored task keeps the compile
  defaults (a failed tool call propagates, a failed model call halts); a model's `ask` is `halt`
  on expiry (loop authoring design 2026-09-06 §4, §14 item 2). What a model started is DELIVERED
  to it in one envelope — `<task_result task=… status=…>` for work, a tool's tip naming its call
  on a `<call>` line on every read, `<answer task=…>` for a
  question — as a waited `task` call's paired result (`wait: true`), else as a user-role message,
  rendered for every tip a round reads, an empty one included; a branch never receives `task` or
  `compose` (depth one). `task` and `compose` run DETACHED by default — the WHEN word is `wait` on
  the call, one boolean on both, and no step carries one (S-N decision 3, 2026-09-08; the door's
  per-step `detached` is the client's word for the same mechanism). Waiting is independent from
  lifetime: `task`, `compose`, `spawn`, and member-authored steps accept `lifetime: turn|conversation`.
  Omission inherits the authoring context; roots and existing rows default to `conversation`.
  An explicit override may select either value without changing a sibling's default. Dependencies
  and read edges never transfer lifetime. Expansion, wake, repair and regeneration retain their
  source context; regeneration creates a new execution. A loop-backed reply becomes final only
  when its deliverable answers, foreground work and turn-owned work are settled, and results
  have been consumed through the existing wake/continuation path. Normal final delivery joins
  rather than cancels that work. A conversation-lifetime detached consumer does not discharge
  a turn-owned result's reporting obligation; its final-responsible consumer must still read
  the result, without changing either consumer's declared lifetime. An accepted append receipt replays first; newly appended or
  retried turn-owned work after `delivered_at` refuses `turn_already_delivered`. Existing
  placement, join and explicit-stop semantics remain. A BACKGROUND TASK WITH CONVERSATION
  LIFETIME MAY OUTLIVE ITS TURN (`delivered_at`, the turn settles on it);
  background work stays the loop's, and every unconsumed conversation-lifetime background
  result uses a supplementary turn even if it finishes early (owner ruling 2026-09-29,
  `docs/plans/2026-09-29-async-result-ownership.md`). After the original reply is final,
  its answer reaches the model as kernel mail through the input door — a kernel-stamped input created `queue` always (never a steer: a
  running turn finishes first) that drains FIRST — kernel-origin inputs read before the person's,
  then arrival. `wake: auto` (default) uses `direct_reply` and wakes an idle conversation;
  `wake: passive` uses `message` and materializes history without a model lookup or reply.
  This inherited axis is independent of waiting and lifetime; it does not suppress in-loop
  consumption or turn-owned obligations. Automatic mail opens a new turn on the same conversation and its
  answering profile, on the mailing loop's model, bounded by what bounds a turn (S-N decision 1, 2026-09-08). A
  kernel-origin input is immutable to the person (`kernel_input_immutable`) and visible by the
  product's choice. Result-mail replies use a loop, including for a tool-less profile, so a
  model failure retains its intended answerer and prompt for node-level recovery. Owner
  direction, 2026-09-20: when the captured model is unavailable, permit one switch per mail
  loop to that same recipient's current different `default_model`; never search the catalog
  or borrow another Agent's model. This applies to the main reply path, not explicitly selected
  model branches. Exhaustion holds at `needs_attention`; explicit model-task retry may name a
  replacement without resetting the automatic allowance or replaying completed tools/children.
  ONE MECHANISM, TWO TRIGGERS (owner ruling 2026-09-26,
  `docs/plans/2026-09-26-refusal-fallback-design.md`; `AgentLoops::ModelFallback`): that
  mail rule is the `unavailable` trigger, untouched in letter; the `switch` trigger re-runs
  EVERY model step of every loop — spine, composed member, `task` branch, named model or not —
  ONCE on the answering profile's declared `fallback_model` when a provider's classifier
  declined it (never a content block) OR the provider was overloaded on EVERY attempt the
  step's budget spent (503, 529, the streamed `overloaded_error` — one per-attempt receipt word,
  the work's key `provider_overloaded` only when every attempt said it; a rate limit waits out
  the lane's floor and is never overload, owner 2026-09-28), resolved against the step's own
  request at the switch — a fallback that needs every tool round's reasoning back stands on a
  history of tool rounds it did not produce — read live from the profile, requeued under a fresh
  generation with the row fact `output_summary.model_change` and the narrated
  `task_status.model_change {from, to, reason, category}`. The budget units differ on purpose:
  the mail rule spends the loop's `mail_model_fallback_used`; the switch is bounded by the
  STEP'S OWN INVOCATION HISTORY (it fires only on the step's first refusal or overload, and
  neither trigger ever picks a model that refused the step or was overloaded for it) — no
  counter, no column, nothing a retry or a re-declaration renews; a switch that stands falls to
  the mail rung. A switched spine round's continuations inherit the fallback for the rest of the
  turn, but work a round STARTS — a composed member, a `task` delegate, a spawn's or send's
  default model — begins on the model its lineage was configured with
  (`AgentLoops::ConfiguredModel`: the first cause's trio of the OLDEST round on its reading chain,
  walked past every compaction cut, whose row carries the switch's fact — a cause that stood moved
  nothing — else its own); across turns the caller reads `turn.model`, and the kernel keeps no routing state. A TOOL-LESS
  direct reply has no step to requeue: the reply converger decides once, under the
  conversation lock, before the sample reads as settled, and re-asks it as the kernel's own
  regeneration (`Turns::Regenerate.fallback`, a `source: fallback` candidate) as the declined
  or overloaded sample's poster, the turn held `running` with its steers and lane; a fallback
  candidate never falls back, no model that declined or was overloaded for the turn is picked,
  and a stop in that window settles the sample with no switch. A ONE-SHOT is the same decision on its own aggregate
  (`OneShots::Fallback`): the terminal converger decides once, under the aggregate's lock and
  Create's authority locks, while the run reads `running`, and mints its second execution on
  the CREATOR's declared `fallback_model` (`one_shot_attempt:<id>:2`) behind Create's gates
  re-read and the sealed input re-judged for the fallback; the run reads its latest execution,
  switches once — on a refusal or an overload — and a stop in the window settles it with no switch.
  A tool-less profile retains the originating loop's approval mode as the loop's declaration;
  no tool is added by that inheritance. A standalone loop has no later turn; its wake delivers within it. The
  person cancels one branch by the key the model saw (`cancel`, `rho stop ID TASK`) — the one
  cancel that resolves, so the consumer reads `status="canceled"`; the spine's verb stays `stop`
  (loop authoring design 2026-09-06 §6.4, §14 items 3 and 5).
- A script task evaluates bounded pure JavaScript against `params` and only its ordered selected
  `results` — a race's slot envelope-shaped: its first selected envelope, or its failure, with
  `selected` beside it. It either returns a JSON value (including null) or emits a finite subgraph ending in
  one readable leaf. Mixing a value with work, an empty return, and a bare fan are refused. The
  immutable definition lives in its input ContentBody; evaluation runs outside the loop lock;
  publication of children, reader rewrites, output and terminal state is atomic under that lock.
  The existing generation and park clock fence duplicate work, stops and expired evaluation.
  An external reader receives only the final output, without generated prompts or model history.
  Internal models remain branch models. `result_from_node_keys` carries the results a step names;
  compaction does not replace them. `expansion_parent_id` records each generated node's immediate
  source, so cancellation crosses internal joins, a read across the boundary is rendered as one,
  and the stage's insides never come back on their own. A result outside the script that no step
  names comes back to the caller. Selected results,
  wait-only dependencies, generation ownership and lifetime are independent facts; no workflow
  entity, durable JavaScript stack, or separate scheduler is introduced.

- A turn-owned spawn records a kernel-only `delegation_task` on its caller's existing graph,
  detached from the immediate continuation. It observes completion independently of the finite
  spawn await. It has no executor inbox, token, deadline or retry, and absorbs a non-success
  result as material for synthesis. Publication and its write-once `delegated_input_public_id`
  commit together. The child link and source loop/task pair bind the original local Turn's
  position-zero execution, including concealed originals, never a fork, edit, later send or
  regeneration. That child's seed inherits `turn`; an explicit conversation-lifetime override
  may escape its report obligation. `send` and `steer` remain messages without an implicit join.
  A repairable child hold remains outstanding; an edited, unadjudicable original is stopped
  precisely and yields a non-success result. Result publication and the original reply's relay
  stamp commit together; an open await's queued readers switch to the completion result while
  retaining the wait dependency, so the report is consumed once. Canceling an unfinished
  completion removes its pending input or stops only its original execution, recursively through
  unsettled turn-owned delegations. Completed obligations release ownership. The existing relay
  floor has independent bounded cursors for child replies and completion cleanup. Source owners
  and original results remain unreapable until their obligation converges; hard deletion of an
  owed original Turn refuses `delegation_pending`. No parent-loop lock may acquire a child
  Conversation lock; target-first convergence takes Conversation, then loop ids in stable order.
- NO CUMULATIVE CEILINGS. The kernel carries no round, node or model-step ceiling; concurrency is
  the only capacity control and the admission plane already owns it; long-horizon work is the
  norm (owner rulings 2026-08-30 R4 and 2026-09-05 Q2). Per-append envelope bounds survive as
  request hygiene, never as totals — the request body's entry count included, which is sized above
  the byte wall's reach (Gate 3, 2026-09-10) so compaction stays byte-driven. A ceiling bounds cost
  by count and the repeat brake bounds
  latency by pattern; only the second is a kernel mechanism.
- A provider's `Retry-After` on an overloaded answer is a FLOOR on the lane's admission — one
  `model_provider_runtime_states` row per (account, provider), written from the header and never
  computed, read by the candidate query, rendered as `unavailable_until`, cleared by the clock
  (owner 2026-09-15, item 11; R4 bars ceilings, not a floor the provider states).
- THE APPROVER is any principal with write standing on the workspace — the agent application
  acting for its person included; the fact records who decided and of what kind (`human|agent`),
  so a transcript tells a delegate's grant from the person's. No token, no second factor, no role.
- The model asks a human with one call (`ask`), and with compose where the ask is one node of an
  authored graph; the wait is a first-class state a console lists and answers, parked on its own deadline
  (clamped per park to 24 hours, never a budget the loop's parks share); when it expires the
  loop holds for a human with no clock. Delegation
  spawns a child Conversation — parent linkage, lifecycle following, the child's reply delivered
  back as kernel-stamped mail — and `send` is one verb with `mode: queue|steer` (owner ruling
  2026-08-30 R11): S-I step 2 LANDED `spawn` — `Conversations::Create`'s parent arm is the
  first writer of `parent_conversation_id` (the child hangs off the CONVERSATION, never a
  branch; `spawn_node_id` unique per call is the recovery key, `spawn_label` unique per parent),
  the child copies the parent's carrier/billing/runner and anchors `user/` on its ANSWERER,
  the brief is the spawner's own `Command.sent` row on the child, a waited spawn parks a
  KERNEL-HELD await (`holder: :kernel`, tokened `dispatched`, `absorb` — expiry is detach +
  notify) that the child's reply settles trusted, and `AgentLoops::ConversationToolJob` is the
  one job for the conversation verbs; THE RELAY is `AgentLoops::Spawn::Relay` — level-triggered
  over `conversation_turns.relayed_at` (a guarded stamp after either path, a recurring sweep
  `relay_spawned_replies` every minute, the turn converger's kick at both terminals a hint),
  owed only for a turn the PARENT opened (the seed's sender stamp), the await path settling
  trusted only for the original spawn request, with `resolved_by: {kind, public_id}` narrated,
  the mail path ONE kernel-mail writer
  (`Mail.child_reply`: `origin: child`, authored as task mail is — the requesting loop's creator,
  the kernel impersonates nobody); conversation Stop cuts all existing execution owners in
  that room and recursively cancels their derived requests by sender loop/task, not by the
  reusable child's container membership (owner ruling 2026-09-29). A later independent
  request in that child survives. `SubagentTree.ancestor?` remains the door's refusal
  predicate for a subagent addressing its ancestor; the presenter says `parent:
  {public_id, spawn_node_key, label} | null` on both shapes and `/children` lists the
  followers; `send|status|cancel` are LIVE (S-I step 3 LANDED): ONE
  `AgentLoops::ConversationTool::Run` keyed by verb behind the same job, addressing through
  `Conversations::ConversationAddress` (a child's label or a public id over `Conversation.visible_to`
  — `unknown_conversation`, `side_conversation`, `ancestor_conversation`; `parent_waiting` for a
  child whose parent blocks on it); `send` is the SENDER's row through the one door
  (`Command.sent`, origin `agent`, the sender stamp, `steer` when the agent chose it and a reply
  runs there; the door judges the sender's `full`), idempotent by a hosted receipt on the call;
  `status` = running|idle, queue depth, answered-by; `cancel` = `Turns::Cancel.stop_tree`;
  `input_accepted` carries `authored_by {kind, handle, display_name}` and the sender stamp; the
  resolutions door narrates `resolved_by {kind: human|agent, public_id}`; THE SPEAKER ENVELOPE
  (`Conversations::ContextAssembly::SpeakerEnvelope`, r1 §8 Q4 a / Q5 b): ONE renderer at the
  five sites a model reads a user-side row — the wire seed (`ApplyNext`), the history seed and a
  user-role `message` turn (`ChatHistory`), the steer tail (`InputComposition`, rows in), the
  summarizer (`Compaction::Serialize`) — `<message from="@handle" kind="human|agent" user=
  "<public_id>" conversation="<sender id>">` line-structured, rendered at assembly never stored, a
  turn's voice = its `speaker_actor` (fork-stable, never `control_owner_user`);
  member voices name their User. An Actor's kind is `member|speaker|ingress|system`.
  Agent-controlled ingress voices are registered/resolved by natural key through
  `POST profile/ingress_actors` and selected on conversation user inputs by
  `speaker_actor_public_id`, included in the existing receipt digest. They always
  render as `kind="ingress" actor="<Actor UUID>"` with an escaped display name,
  never as their controlling Agent; authoring, origin and ACLs stay the Agent's.
  Passive speech uses `message` and starts no model. Transport, external consent,
  chat routing and unregister remain application policy; there is no kernel revoke.
  `speaker` remains reserved for a persona consumer;
  BARE = a row posted directly by the host's own voices (its creator, its answerer, the answerer's
  controlling Human); WRAPPED = every other principal and every stamped row whoever sent it;
  kernel origins never; the NARROW escaper (`</task_result`, `</message`, `<task_result `,
  `<message ` → `&lt;`, reversible) guards every envelope body, `TaskResultEnvelope`'s included
  (step 0 LANDED: the family, `origin ∈ person|agent|task_result|child`
  on every input, `Command.sent`) (S-I step 1 LANDED: the answering profile is a stored fact —
  `answering_user_id`, chosen at create, copied by forks; `spawn`/`send` and the rest of S-I
  follow; CONVERSATION ACCESS, S-A2 step 1 LANDED: the carrier — `access_default` on the
  row (`full | read | none`, born `full`) plus `conversation_access_entries`, one level per named
  principal; the creator and the answerer are full by derivation, `Conversation#access_level_for`
  is the one derivation, a fork copies the rows and materializes the source's derived principals;
  step 2 LANDED: `Conversation.visible_to(user, workspace:)` — `readable_by`, the derivation in
  SQL, composed under `listable` — is the ONE read funnel on every member-plane door and the
  events channel, `AgentLoop.readable_by` the loop door onto the same rows, `writable_by?` on
  Workspace, Conversation and AgentLoop the ONE write predicate behind every service conjunct
  and controller gate (find, then authorize: `none` is 404, `read` is 403), kernel mail exempt
  BY NAME through `ConversationInput::KERNEL_ORIGINS` — never origin presence; step 3 LANDED:
  the writers and surfaces — `access` on the create envelope (digested in the request's entry
  order; a principal refused by ONE name, `principal_not_eligible`, through
  `Conversations::AccessPrincipals`), `PUT …/conversations/{id}/access` = `Conversations::SetAccess`,
  a whole replacement under the row's lock and the Windows rule (`writable_by?`: full on the row
  ∧ workspace write — an amendment of the plan's handoff clause), narrated `access_changed` with
  the actor's kind; `GET …/workspaces/{id}/principals`, the member plane's one user listing;
  the SDK's `create(access:)`, `set_access`, `Conversation#access`, `workspace.principals`;
  rho's `rho do --restricted` (none + the steward at full, rho's entry) and
  `rho conversation participants` over one daemon PUT; R-32 pinned over HTTP with its deny twin;
  the exit lane `e2e/test/conversation_acl_test.rb` in GROUP 3). GROUP CHAT is the kernel's
  (owner ruling 2026-09-09,
  S-H re-scoped): several principals — humans and agents — speaking in one conversation, each
  input carrying its author (`origin`/`authored_by`, landed), history rendered with speaker
  attribution (the speaker envelope, S-I step 3), a way to address which agent answers a turn,
  and the wake/turn-taking rule for agents in a group (S-I step 5, the columns and the door
  LANDED 2026-09-12: ONE addressee column on the input — `answering_user_public_id`, `@handle`
  or a public id resolved at the door, the conversation's stored answerer by default, eligibility
  = an agent member with `full` on the row, the kernel's mail carrying its loop's answerer and
  never judged — frozen onto the reply turn (`conversation_turns.answering_user_id`, NOT NULL on
  every kind; a message and the summary turn take the conversation's answerer at creation); the
  loop DERIVES its answerer from its turn, so every executor judgment follows the turn while the
  runner binding, the handoff, `memory_principal` and the inbox scope stay the host's; the WAKE
  rule is no state — the idle unit stays the conversation, an agent is addressed never woken,
  an unnamed steer addresses the RUNNING reply's answerer and a named other addressee queues, a
  post-hold row addressed elsewhere is held so a `to: B` never REPLACE-kills A's repairable
  loop; a side fork copies the fork-point turn's answerer, regenerate keeps the turn's; the
  RENDERER (landed 2026-09-12): history is assembled FOR the turn's answerer — its own reply
  turns as rounds, another agent's reply as ONE wrapped user-side segment of its final text
  under its seed (never its rounds; a seed the answerer itself posted or a kernel receipt
  skipped), the bare voice judged against the turn's answerer so B's turn bares B's person and
  every 1:1 lane keeps its bytes; the ADDRESSEE'S ENGINE (F-3 ruled 2026-09-15: the agent's
  OWN preset first, else the initiator's; the kernel stores the fact and carries the model, it
  chooses nothing) — a row addressed away from the default, and every row a peer SENT (`send`,
  the spawn brief), runs on the addressee's `default_model` (the seventh profile column, a
  catalog ref the agent's application declares — rho writes its settings' `default_model` —
  judged at declaration by `ModelSelection.ref_refusal`, the drain's own check), else the
  addressee's last reply turn's trio here, else the conversation's last, else the row's own —
  THE INITIATOR'S on `spawn`/`send`: the call's optional `model` (a catalog ref, refused at the
  call `model_not_authorized` with the resolver's word), else the round's, carried by
  `KernelTool.initiator_model` so the wire always carries a model; ONE ladder at the door
  (`Conversations::AnswerEngine`, `Inputs::Create#answer_engine`), and the loop projection's
  `turn.model` is the STATED PLACE a follower reads the model in use (rho's `say` on a row it
  only attached: its own `default_model`, else that field, else a refusal); the relay addresses the
  execution that opened this child turn (owner ruling 2026-09-20): the original `spawn` or a later
  queued `send`, including steer-on-idle fallback. Its frozen sender loop and task key own reply
  correlation, cancellation, answerer, model and inherited tool/approval surface; only the original
  spawn request may settle its await. A steer joining a running child turn keeps that turn's one
  reply obligation. A cascade cancel owes nothing below the canceller;
  `resolved_by` carries `handle`; the presenter's `speaker` + `answering_user_public_id` on
  every input and turn; the SDK's `inputs.create(to:)`; rho's `rho say --to @handle|<id>`
  (LANDED 2026-09-12: the bare rule keyed on the ADDRESSEE per call, the addressee printed
  back, a loop refusing the word); the exit lanes —
  `e2e/test/group_chat_test.rb` in GROUP 4 (rho A + a differently-declared SDK peer B in one
  room; the two-instant "B not woken" `turns.list` read) and `live_spawn`'s GROUP variant (the
  S-V pair's second half); the `send` verb names the peer by `agent:` (`@handle` or public id)
  and the conversation by `to:` — without `agent:` the conversation's own agent replies;
  agent↔agent messaging is one instance of it). SIDE CONVERSATIONS are the kernel's (owner
  ruling 2026-09-09; Claude Code `/btw`, Codex `/side`; S-Q LANDED 2026-09-10): `POST …/forks`
  with `side: true` takes a fork at the live head from the last settled turn while the parent
  runs, the child flagged `side` (hidden from the working list, `?side=1`), its closure bounded
  at that turn inclusive with nothing adopted, so assembly renders the inherited history behind
  ONE boundary item — a USER-role message stating the turns above are inherited reference (user
  role because the Anthropic protocol hoists every system-role entry into the top system block,
  which would move the first bytes and break the shared prefix) — never writing into the
  parent's transcript, its first sealed request equal to the parent's running request above the
  boundary byte for byte (the pinned cache property; `cache_read_tokens` on the conversation read
  is the provider's confirmation — the shared bytes are the kernel's, and a provider cache HIT
  also needs the turn's tool block to be the parent's, since OpenAI-shaped wires render the
  declarations ahead of the messages: a narrowed side shares the entries and misses the cache). The kernel's lifecycle: `side_of_side` refused, no archive
  (`side_conversation`), never a `spawn` spawner or answerer under the same word (S-I step 2;
  `send`'s addressee follows in step 3), DELETE = tombstone
  and reap at once, the parent's archive/tombstone reaping its sides first. The instruction text
  and the tool posture of a side are the caller's per-turn words (rho's `btw`/`side`); one open
  side per parent and an idle TTL are the agent application's bookkeeping, never kernel rules.
  A standing goal — an
  acceptance predicate the model cannot argue with, with its attempts, cadence, backoff and
  self-clear — is rho's today: rho's `--until` plants the check as a `bash` tool step the kernel
  addresses to the host's bound runner (S-D step 4) and the hold that keeps the loop open is
  rho's own await (`extensions/until.rb`); the kernel object any agent gets — the agent supplies
  the check, the kernel keeps the goal — is intent (planned: put to the owner, S-D/S-E design
  §14 item 9; kept as a plan by orchestrator ruling Q12, 2026-09-10).
- Approval is a kernel stage between "ready" and "runs" (owner ruling 2026-09-05 R5; S-F step 1,
  2026-09-08): the stage is every TOOL row's — the one kind whose effect reaches the person's own
  files and shell — crossed under every mode, exercised, never skipped; a round is admitted by the
  admission plane and has no stage (node review 2026-09-08 Q1). The MODE (`bypass|ask|rules`) and
  the RULE LIST are frozen per turn onto the loop row — from the declaring profile (or the reply
  input's tightening, `bypass → ask → rules`, never looser) or the standalone create shell, nothing
  defaulted — and the row's ORIGIN decides with them: a model-composed row is governed by mode and
  rules; a row the append door or the kernel wrote is pre-approved by its origin unless a rule
  names that origin. Deny rules bind under every mode; `ask` parks a model row unless an allow rule
  names it; `rules` decides alone and what it does not name is refused as data — a typo never
  grants and never parks for nobody. THE PARK: `needs_approval` is a real rest state of the tool
  row, addressed to the host's agent application, listed on its inbox as kind `approval` with the
  effect profile the approver reads, announced on the loop as `approval_required` while the turn
  stays `running`, on the ask's 24 h clock (`timed_out approval_expired` under the row's own
  policy), ended by the `approve`/`deny` verbs on the member plane or by a stop. Both decision
  verbs first let the park's settle owner project any expiry under the loop lock: at or after the
  virtual deadline they return `not_awaiting_approval`, with no decision fact, even before the
  sweep has visited the row. ONE grant site:
  the bypass path and a person's approve release through the same body, which re-runs addressing
  and re-parks when the effect profile changed under the park. The fact — origin `mode|rule|human
  |agent|author|kernel`, who, when — rides the row, the task read and the stream. A denial reaches
  the model as correctable material: "declined by the approver; do not run it again unchanged." plus
  the reason. THE RULE MODEL is one grammar: a tool glob, a dotted path into `tool_input`, an
  anchored glob, a verdict, an optional reason and origin; deny > ask > allow. rho declares `bypass`
  and ships its guard list as deny rules (landed S-F step 2: `Rho::LoopRequest::APPROVAL_RULES`,
  twenty-nine deny rules and two allow rules; `rho do --approval ask|rules` tightens one turn, `rho approve|deny` decide).

- SIX SEMANTICS, cross-checked against codex, claude-code, opencode and pi
  (docs/plans/2026-09-05-loop-semantics-cross-check.md, owner questions 2026-09-04/05). (1) A
  response without a call ends the round; the round ends the run only when it is the deliverable
  and the quiescence site finds nothing started or ready — the references end the turn on the same
  signal; what keeps a run going past that is a person (steer, queue), an authored graph, or a
  standing goal firing on the completed transition as a new spine round. The deletion of
  cumulative ceilings follows the owner's ruling (Q2), not reference agreement — opencode and
  claude-code carry step caps. (2) After a tool fan the kernel mints one continuation and the
  model speaks again; a run ends on a tool result only when an author designated that task the
  deliverable — pi's per-result `terminate` is declined, three references continue
  unconditionally. (3) A steer lands at the next unambiguous model boundary of the in-flight turn;
  a steer still pending when the deliverable round answers without a call is never stranded — the
  kernel plants one more spine round and the steer drains into it (codex, opencode and pi re-
  sample; claude-code queues); a steer bound to a loop that ended by stop, cancel, completion or
  `replaced` falls back to the queue as `input_edited{reason: steer_target_settled}`, and a hold
  keeps steers bound (S-B §4.3, §4.5). An exact-loop guarded steer instead cancels on settlement;
  it cannot migrate to another candidate or a later turn.
  (4) An output-limit cut is `finish_quality`, never control: every call whose arguments parse
  executes, the cut call is authored and failed as data the model reads with the cut named, the
  batch is never refused — pi's whole-batch refusal is declined because pi salvages partial JSON
  and we do not. A provider's DECLINE is a finish too, but it fails the work: the invocation
  completes `finish_quality: refused | blocked` with the provider's `refusal_category` and NO
  answer body (a declined answer's partial output is discarded and withdrawn from followers), and
  the step, the direct reply or the one-shot it was for fails `model_refused` — its reader gets
  the kernel's sentence naming who declined, the category and why nothing re-ran it, then one
  line saying what it can do next (the model is that sentence's audience); no retry
  budget re-sends it to the same model — a loop step, a tool-less reply or a one-shot a
  classifier refused re-runs once on the declared `fallback_model` of its answerer (a one-shot's:
  its creator) first (`ModelFallback`, above). (5) A tool result settles its own node and nothing else; a round's fan is joined
  `all` and the continuation waits for the last member; early settlement exists only as an
  authored any|quorum join, and a loser of a join that already settled cannot hold the loop — its
  later failure is absorbed. (6) After a crash an unclosed unit waits on a named party with a
  clock — a running round on its invocation attempt's deadline, a tool park on its authored
  timeout, an await on its own timeout clamped per park to 24 hours. A delegation completion
  observes its original execution and inherits that execution's liveness, without another deadline
  — where the references repair
  at read time; the difference is recorded: their process is the driver, ours has runners and
  provider calls outside it.
- A LOOP-BACKED TURN SETTLES WITH ITS LOOP (owner ruling 2026-09-05; docs/plans/2026-09-05-halted-
  turn-and-agent-configuration.md). Loop `completed` → turn completed with the deliverable's
  output on the variant. Loop `needs_attention` — a model call out of retries, the repeat brake,
  an expired ask, an unresolved deliverable — → turn `failed` with the reason, and the
  conversation gate opens: the failed turn stays in history as context, so the next turn continues
  the work or pivots (codex `TurnComplete{error}`, claude-code's error assistant message,
  opencode's `assistant.error`). Loop `canceled` likewise (the loop has no `failed`: a reasoned
  cancel IS the loop failing, node review 2026-09-08 change 7). `awaiting_human` and
  `approval_required` are waiting, not halting: the turn stays `running` on the park's own clock.
  The held loop keeps its adjudication verbs while its turn is the tail — retry or answer reopens
  the same turn — and a later input stops it as `replaced`. A tool call of a failed turn with no
  result reaches the next turn as a kernel-authored error envelope at assembly, so the model sees
  a closed conversation. Regenerate on a loop-backed turn births a new loop behind a new candidate
  (refused `loop_needs_attention` while the origin's loop awaits adjudication). Successful
  regeneration and changed activation permanently stop the replaced variant's unfinished
  work and undelivered derived replies. A loop's write-once `stopped_at` preserves that
  fact even after a completed reply; publication and input materialization check it.
  Returning to an old variant never revives canceled work. Conversation Stop includes
  older loops and unconsumed callbacks; ordinary completion and the next user input do
  not stop background work. The 2026-10-02 owner refinement permits compatible
  independent worker finals to be read together: each source is fenced before
  consumption, then the receiving conversation owns the combined reply. A later
  individual source Stop does not retract already-read results or stop that
  reply. Its immutable `callback_sources` retain each receipt and exact worker
  result; the combined turn does not borrow the last source's sender fields.
  Ordinary task/tool/compose mail and single-worker replies retain their source
  ownership. Published bodies and completed effects remain. The world the old
  loop changed is a DERIVED fact on the reads (`world` — the runner's `metadata.checkpoint` record
  beside its claimant; `AgentLoops::World`, `Conversations::WorldAt` for a fork point), never a
  kernel judgment or column; edit and swipe are allowed, and an edit
  on a hold-settled tail is the person answering for the loop — `AgentLoop#overridden?` makes
  retry, abandon and the repairing append answer `not_adjudicable`, and no reopen follows. A
  loop-backed turn's opening words (the input that materialized it, kept as the variant's `prompt`
  body at `land_reply` — every reply turn has one, the kernel's receipt included) and its rounds
  render into later turns' history from rows (`AgentLoops::RoundReplay` per spine round, the
  in-turn summary cutting what it replaced, the seed included; a tool-less reply renders its seed
  then its content); while execution details remain, its `content` body is the presenter's
  projection and assembly reads the rounds. The owner-approved retention exception
  (2026-09-29, `docs/plans/2026-09-29-history-search-and-retention.md`) keeps the question,
  landed user follow-ups and final response after expired execution details are collected;
  assembly then reads those retained bodies. The default is 90 days after completion,
  configurable or disabled on Account. `details_pruned_at` records collection, not a world
  judgment: world/checkpoint reads report unavailable when their evidence has expired.
  On the wire the variant carries
  `agent_loop_public_id` and `rounds` (the loop transcript's summary rows, never a DAG word).
- THE AGENT'S CONFIGURATION lives on the Agent Profile User row — `tool_definitions`,
  `approval_mode`, `approval_rules`, `prompt_mechanism`, `prompt_template` (jsonb, S-G-B),
  `compaction_policy`, `lifecycle_hooks`, `default_model` (F-3, 2026-09-15: the profile's own model, step 0 of the
  answer engine's ladder; the agent's application writes it, the kernel stores a fact and chooses
  nothing), `fallback_model` (the ninth, 2026-09-26, `2026-09-26-refusal-fallback-design.md`: the model a step this profile answers — or a
  one-shot it creates — re-runs on once when a classifier declined it or the provider was
  overloaded on every attempt of its budget, judged at declaration like
  `default_model` and read LIVE at the switch, never frozen onto a turn) (on `users`,
  `db/schema.rb`) — read at each turn's
  materialization and frozen onto that turn's node and variant rows, never snapshotted per
  conversation; the agent's own system prompt
  is its `system_prompt` prompt document on its profile, overridable per turn by an inline slot
  entry (S-F step 3); a standalone loop's create request carries the same shell.

## Executor Roles And The Gateway

- Three executor roles stand beside the kernel, each a separate abstraction with an EXECUTOR
  credential that reaches only its own inbox transport (inbox, claim, commit, cable) and never a
  member resource (owner mandate 2026-09-04): the AGENT APPLICATION — additionally a member
  principal through its Agent User's own bearer, which is what lets it drive conversations; the
  RUNNER — a special tools provider for environment-bound tools (filesystem, processes, the coding
  essentials), expected to run separately in a container or the cloud; and the TOOLS PROVIDER —
  the external role that provides tools and may OVERRIDE a kernel tool by name (memory is the
  owner's example; owner ruling 2026-09-05 R2). The agent application holds both planes — a member
  credential for its data and an executor credential for its address; the inbox doors
  authenticate the executor plane for every role, so an agent's claim is by its address, never by
  its member bearer. A tools provider speaks the inbox protocol; it is not an MCP connector. A
  tools provider is a machine registration shaped like a runner's — a manager Human, an
  identifier, an assignment scope, a transport-only credential — connected on the device flow's
  branch B naming its kind (`executor_kind: tools_provider`; S-C step 5, 2026-09-07). An agent that
  also plays the runner role pairs both in ONE grant — the combined shape A+B of the device flow:
  both claim sets on one request, one approval, two lineages, the runner fixed private (r-modes M2,
  2026-09-07; rho in full mode). THE IDENTIFIER IS THE PROGRAM PLUS THE INSTANCE (owner ruling
  2026-09-09): `agent_identifier` and `runner_identifier` are the program's constant plus a
  per-home instance part derived once at first boot and never typed by a person (rho:
  `rho.<instance_id>`, `rho-runner.<instance_id>`), so several installs of one program under one
  steward pair as separate rows and a copied home fences the original; the kernel stays blind to
  the part's shape — an opaque string bounded by length. A paired instance may DECLARE NAMED
  DEFINITIONS of its own — `<identifier>/<name>`, composed by the kernel's door
  (`PUT profile/agents/{name}`, `Users::DeclareNamedDefinition`), the same steward, NO credential
  and NO address (they answer conversations, they never claim or connect), one level (no bearer,
  so never a declarer), fenced as their parent while `instance`-scoped and removed with it; a
  `steward`-scoped one persists on its own for every agent of the steward and is never fenced
  (capabilities III, 2026-09-15). Pairing stays the human's: a named definition is the paired
  program's configuration, answered for by the human who paired it. EVOLUTION BY INCUBATION, never
  self-modification (owner principle 2026-09-09): a running agent never edits its own checkout or
  home — it develops its successor as a separate registered instance, proves it, then upgrades —
  and the kernel imposes no ban: rho enforces it with its own deny rules through the kernel's
  rule mechanism (`Rho::LoopRequest.self_modification_rules`), removable by the product. An agent MAY
  play the runner role: rho plays it through the runner abstraction — its runner row (kind
  `runner`, the runner credential plane) announces rho's environment tools and is what rho names
  on every host it opens; the agent-application address announces only the agent's own tools
  (the delegate summarizer) and is never a binding, and its claims are by that address on the
  executor plane, never by its member bearer (S-D step 2). An agent application may validly claim no inbox task at all —
  a pure chat or role-play product plugs in through Conversation alone — and the kernel never
  requires an executor registration to serve a conversation.
- Four tool sources, one provenance model (owner ruling 2026-09-05 R2): Nexus (the tools tied to
  its own authority over Conversation and loop — memory, subagent, background tasks), Runner
  (environment tools), Tools provider (external, may override), and the Agent itself. A tool name
  resolves to exactly one providing authority, the provider survives on the wire and on the row,
  and two providers cannot silently claim one name. An agent may declare its own SPELLING of a
  kernel tool (an alias on its declaration, with a parameter map; S-N step 3): the canonical, the
  routing and the reserved namespaces are untouched, the kernel renders its descriptions with the
  declared names, and a call arrives under the alias and runs under the canonical. Kernel tools are executed by the kernel
  itself — dispatched to one of its own jobs, parked under the same clock, deadline and settle
  engine as a runner's tool (owner ruling 2026-08-30 R5 on locus); the moment a tools provider
  overrides that name, the same call rides the inbox to that provider and its result is ordinary
  tool output.
- NEXUS IS THE GATEWAY: every message among agent, runner and tools provider is relayed by Nexus.
  A runner's or tools provider's own surface (file bytes, process logs, a screenshot) reaches a
  browser or another agent THROUGH Nexus and never directly — the executor relay (S-E2,
  2026-09-13; `docs/agent-api/v1/executor.md` "Captures" / "Requests"): an executor surface is
  either a CAPTURE the executor publishes (`POST /agent_api/v1/executor/uploads` into the one
  ingest, named by a `resource_link` block in its commit's `content`, read back by the ONE
  member-plane bytes read `GET /agent_api/v1/uploads/{id}/bytes` under the upload's own rule) or
  a REQUEST addressed to it as a task (a one-task standalone loop on the task-grained surface
  whose seed is the tool step — `files_bytes`, `process_log` — claimed, committed and swept like
  any tool call; the SDK's `agent_loops.request` / `request_result`, rho's `rho relay` /
  `rho fetch`). No second inbox subject, no second door: the transport is the executor's own
  outbound connection, the bounds are the ingest's `upload_bound` and the row's deadline. The
  ephemeral half — progress frames a running tool posts — is the executor progress door
  (`POST /agent_api/v1/executor/progress`, token-first, fenced by the claim or the binding) and
  the host's `progress` feed (landed 2026-09-13 in S-E2's S5). What a person READS of a run is
  the transcript route's THREAD (2026-09-14, §3.2): the spine's rounds by the kernel's mark, each
  with the calls it read and the branches under them, derived from the rows' keys, marks and
  reading lists — never from the edge table, which stays the graph route's, the debugger's.
  Topology: Nexus on the public internet or a LAN, every other component on the
  intranet; components POLL Nexus — the HTTP API is the authority — and the Action Cable channel,
  keyed by executor, is the push notification and latency optimisation. Nothing in the
  correctness path depends on the cable, on presence, or on a heartbeat. What Nexus relays it
  also revokes: a stop or cancel reaches the executor holding the claim through the same inbox
  (the row changes state; the cable only says where to look), the executor kills what it spawned,
  and the model reads a marked abort, never silence.
- Registration and authority invariants: each logical registration has at most one non-revoked
  address and one current credential epoch; re-pair keeps the address and fences the previous
  pairing. Every Runner has one Human manager who alone manages its current lifecycle and
  credentials; `account_wide` is only new-work ACL and grants administrators no management
  authority over another Human's Runner. This is a durable address/authority invariant, not
  physical device or process attestation. A runner is shared capacity: it may serve every agent application its assignment scope allows — but a CONVERSATION BINDS ONE RUNNER at a time (owner ruling 2026-09-04, explicit handoff): its runner-kind calls are addressed to that bound executor, never to a pool; the binding's initial value is the runner the creator names; the kernel infers none (owner ruling 2026-09-08, r-modes M6: an unnamed host is unbound; a name binds only a live runner-kind row eligible for the host's ANSWERER — a conversation's answering profile, a standalone loop's creator (S-I step 1) — a row fact, never an announcement — `Executors::InitialRunner`), and only the handoff verb rewrites it. Addressing a ROLE within a workspace (any eligible executor may claim) exists for tools providers only: a pool is every active `tools_provider` announcing the name and eligible for the loop's principal (S-C decision 7; the per-workspace opt-in landed S-E step 3, `PUT …/workspaces/{id}/tool_provider_overrides`), the row lists for every member until the first claim wins, and a claimed row is the claimant's. A tools provider is never a binding.
- Switching runner within a conversation is an EXPLICIT HANDOFF — the host's answering profile or a
  Human with write standing invokes it (`PUT …/runner`, `InputHost#bind_runner`), the kernel
  records it (`runner_bound`) and the binding is readable on both hosts and through discovery.
  Nexus never retargets STARTED work on its own; an explicit handoff re-addresses what nobody
  has claimed — a claimed task finishes or expires where it was claimed. Nexus provides
  authorized discovery of the executors a caller may address (`GET /agent_api/v1/executors`,
  filtered by eligibility, never by presence); it never selects an execution host on its own.
- The human console is split (owner ruling 2026-09-05): Nexus's own Rails UI owns account
  administration — providers, credentials, models, runners, workspace management — and
  conversation/workspace CONTENT pages on Nexus are
  deferred; an agent may ship its own conversation-level UI (rho's webui) that reaches the kernel
  through the agent's credential and proxies no account administration. The owner-authorized
  terminal OOBE (2026-09-29) may separately consume Platform administration through a Human
  owner/admin API Session; it does not give the daemon or member credential that authority.
  An executor's surface
  is read locally by the executor's own UI when the executor is in-process, and through Nexus's
  relay — a capture, or a request as a one-task loop (S-E2) — when it is not
  (`.ai/boundaries.md`, *The Human Console And The Gateway*).
## The Task Inbox

- THE INBOX IS THE PROTOCOL, and it is general (owner ruling 2026-09-05 R1): one distributed
  asynchronous task queue between Nexus and every executor role. The HTTP API is the authority and
  the cable is the push; the inbox is level-triggered and complete, so an executor that slept,
  crashed, restarted, or never received a push recovers by reading it, and a lost frame costs
  milliseconds, never a task. An executor CLAIMS a task — the claim mints a token rotated per
  claim, exclusive until the task's own deadline: one clock, no lease, no heartbeat — a claimant
  may EXTEND its own deadline, bounded by the tool's announced park or the kernel's hour and
  narrated `task_deadline_extended` (the executor plane's `extend`, node review 2026-09-08 change
  8: an extension, never a lease; a late commit after a deadline it did not move stays an expiry)
  — and then COMMITS one write-once result; a stale token settles nothing. A claim that reaches its
  deadline settles by the tool's effect profile: replayable work settles `timed_out` for the model
  to re-issue or a person to retry — nothing re-queues itself (decision 8, 2026-09-07); a
  possibly-escaped effect becomes `uncertain` and waits for adjudication, never a re-run
  (*Ambiguity is honest*, below). Kinds are not only tool calls: Nexus-level business an
  executor takes over rides the same queue — a compaction delegated to the agent (Q3), and
  whatever else the kernel delegates — and a model's `ask` is the agent application's inbox row,
  listed with its question and never claimed, answered by the agent on its address (the executor
  commit, no token: the addressee's credential is the standing) or by a person on the member
  resolution door — two doors over one settle (S-C decision 4, landed step 4, 2026-09-07).
- The inbox row is a task of its owner — a loop's tool call, a conversation's delegated
  compaction, whatever else the kernel delegates — delivered to one executor; the loop's unit is
  `task` (owner ruling 2026-08-30 R1). Large payload and result bodies may live in subordinate
  rows for query performance, but they never own another delivery lifecycle or duplicate mutable
  metadata. A retry is a new, lineage-linked task, never another execution cycle inside the same
  one.
- Addressing: a task is addressed to one executor — a runner-kind call to the conversation's bound runner — or, for tools-provider calls only, to the role within the workspace when the caller names none; the cable stream is keyed by executor; an executor announces what it serves
  so the kernel can address it; a declared tool nobody announces fails at start with
  `tool_not_served`, an error the model reads, never a park. Human managed-executor shutdown
  fails the UNCLAIMED rows addressed to those executors (`failed`, `executor_revoked` — the
  same shape as `tool_not_served` at start, one narrated transition each, the row's own failure
  policy applied through the one failure rule: absorb resolves, propagate skips, halt holds; node
  review 2026-09-08 Q3 — so `canceled` has exactly two settlements, a stop's or a race's skip and
  the person's branch cancel, the one cancel that resolves) and
  advances an executor's epoch only once it holds no claimed row; a claimed row settles by its
  own deadline and effect profile (S-C §7, landed step 5). Agent Profile removal has a different
  consequence (owner ruling 2026-09-19): synchronous member and Agent-application credential
  fencing, retaining the active address, followed by asynchronous force-stop of related work.
  That consequence also applies when Human shutdown makes a Profile removed; an independent
  Runner is not revoked by direct Profile removal. A server-side record of executor
  capability never shapes the per-round tools list — that list is a set rendered at the front of
  the cached prefix and
  canonicalized by name; what the model is shown and what the kernel knows for delivery are two
  facts — with ONE bounded exception: the `skill` entry is OMITTED from the wire when the merged
  skill catalog (kernel `skills/` rows and announced documents) is empty (owner 2026-09-10:
  absent, not disabled), decided at the one provider-bound site from the stored set; no entry's
  bytes are ever shaped by any executor record, and the catalog itself rides the assembly's
  `skills` block, not the tool list.
- Awareness vs obligation (`.ai/boundaries.md`): notifications never form a second delivery queue.
- An executing claimant recovers a missed cancellation through the existing claim resource's
  GET, with its original token in `Claim-Token` (`docs/agent-api/v1/executor.md`, “Read an existing
  claim”). Exact claimant and token are required before projecting `active` from the task's
  persisted `dispatched` status. The lock-free, non-cacheable read never changes a deadline or
  applies new-admission, inbox-membership or current Runner-binding gates; pause, needs-attention
  and graceful cancellation preserve an existing claim. GET and POST have separate caller budgets.
- Ambiguity is honest: a possibly-escaped external effect becomes `uncertain`, never a fabricated
  timeout and never a blind replay. A result accepted strictly before the task's absolute deadline
  beats delayed deadline projection; at or after the cutoff, deadline expiry wins regardless of
  projection lag. Replayable-vs-uncertain follows the tool's effect profile. Effect profiles are
  required declarations and never a security boundary.
- Park deadlines derive from the loop's VIRTUAL clock — wall time that stands still while the
  loop is paused — and the timeout sweep's SQL frontier is advisory: it reads PostgreSQL's
  `clock_timestamp()` (`DatabaseClock`) to find candidates and re-derives each one under the loop
  lock. PostgreSQL's clock is the sole time authority for strict temporal winner decisions that
  read a window under held locks (budget admission). A coarse replay/retention TTL may instead
  anchor on an application-written persisted timestamp when its owning contract explicitly
  accepts ordinary NTP-scale skew and no data-integrity or irreversible effect boundary depends
  on the exact cutoff.

## State, Events, Liveness

- Rows are truth: derived gauges are projected at read time, never persisted as authority; status
  vocabularies are one frozen algebra (including `timed_out`) shared across related models.
- NO FUSED STATE: an executor's credential readiness, its presence and its lifecycle are three
  separate facts read side by side, never folded into one projected availability word, and none
  of them is a dispatch gate.
- Events are durable public narration; ActionCable is an opportunistic thin wake-up; REST replay is
  always sufficient for event correctness. A terminal `result` event is a bounded wake; the REST
  OneShot is the authoritative complete result. Every cable frame is droppable, including the last
  one, so a consumer that requires bounded terminal detection also owns a REST polling policy.
- Liveness is owned by level-triggered, idempotent reconcilers/sweeps with per-state reapers and
  distinct failure reasons; jobs and WebSocket events are latency optimizations only. Models never
  depend on a job having run.
- A fact that must be re-readable is a ROW plus a persisted EVENT (owner, 2026-09-10 live
  progress). A conversation's END is such a fact: archive and DELETE narrate `conversation_ended`
  (`reason`, the member's own id) on every member they stamp, in the verb's transaction; a
  tombstone's item is the last its feed carries (the cable delivers it, the next poll is the 404,
  the reap destroys later). The process lifecycle follows the conversation (owner, 2026-09-10):
  what a runner started for a conversation dies with it, and the runner learns whose a call is
  from the inbox row's `conversation_public_id` (every row; null for a standalone loop), never
  from a lookup of its own.
- Workspace lifecycle is one strict serial persisted algebra:
  `active -> archiving -> archived -> restoring -> active` and
  `active|archived -> deleting -> deleted`. Entering a transition state changes current authority
  immediately; bounded level-triggered convergence advances it after real descendants settle.
  `archived_at`/`deleted_at` are capture and retention clocks, not a second state authority.
  Physical collection is FK-safe leaves-first. Usage/audit records survive hard deletes through
  their own public-id snapshots.
- Human remove/erase uses the same two-phase discipline for managed runtime resources: the Human
  authority and new admission are fenced synchronously, while bounded asynchronous convergence
  cancels queued inbox tasks, stops running work at data-safe checkpoints, preserves truthful
  result/late-capture facts, and then fences transports. An Agent Profile becoming removed applies
  the Agent-specific credential cut and force-stop below; the independent machine protocol is
  unchanged. Cancellation may never trade data
  integrity for faster offboarding; the Agent loop's tasks prove this against the engine's
  checkpoint rules. One remove-only generation on the Human and separate applied
  generations on each Agent Profile and TaskExecutor make this level-triggered across restore:
  Profile and delivery-address shutdown are independent resource progress, not one inferred from
  the other.
- Agent removal synchronously cuts member/data access and revokes the Agent application's
  credentials through its existing epoch, without terminally revoking its address or touching an
  independent Runner. Related Conversations and live loops are force-stopped asynchronously
  (owner ruling 2026-09-19): the Agent's creator/default-answerer/current-turn initiator or answerer
  relationships, related spawned descendants, and still-live historical or background loops
  count; historical participation alone does not stop another user's current
  turn. Existing force-stop owns cancellation, narration and convergence. Cleanup scans current
  removed state with a bounded recurring floor, skips after restore, and accepts delayed status
  and eventual task timeout. Restore needs no cleanup barrier and never revives old credentials.
  There is no task-withdrawal marker, removal-episode state or new generation, and no Agent suspend
  API. The ruling and superseded proposal are recorded in
  `docs/plans/2026-09-19-agent-removal-force-stop.md`.

## Model Plane, Billing, Context

- Development-, test-, and real-call diagnostic code/config/fixtures prefer their owning test or
  E2E tree; keep any Nexus-local support minimal rather than banning it by location
  (`repository.md`, Development And Test Placement). Environment-variable API-key import is a
  supported deployment convenience. E2E may start a standalone
  fake Provider and drive ordinary provider seams; Nexus runtime never reads `e2e/**` and contains
  no mock route/parser or test-only provider runner. Serving control is operational through live
  product state such as `ModelProviderPolicy.enabled`. Presence of an `api_format` adaptation in
  the gem authorizes only that implementation path; a wrong or changed upstream wire fails through
  the ordinary request/result path. Do not add wire revisions, capture projections, or local
  qualification state as serving authority. A future circuit lands only with its real observation
  writer and operator consumer.
- The shipped provider/model fragments and operator `config.d` overlays form one
  strict file base. THE REPOSITORY SHIPS NO SELECTOR (owner ruling 2026-08-21): routing policy
  — which models to try, in what order — is a deployment decision, so a selector exists only
  where a deployment declared one, and a caller naming an undefined selector is refused
  `unknown_model_selector` at acceptance before any provider call. `config.d` is FLAT: a
  generic tier plus one `<name>.<env>.yml` tier, and a subdirectory under it refuses
  compilation rather than being silently ignored. Boot compiles and validates that whole candidate
  before serving and fails readiness for any missing, malformed, duplicate, or inconsistent fact.
  A future live-reload entry point first builds a complete candidate and then publishes it with one
  pointer swap; rejection leaves the already-published complete snapshot untouched and reports the
  configuration error. The user's filesystem and edits are trusted: any stable set of files that
  forms a valid complete candidate is a valid
  file base, including a stable intermediate state while the user edits several files. The loader
  enumerates the selected paths and reads each file once into the candidate that it parses,
  validates, and publishes. Those observed values are the in-memory configuration for consumers;
  no digest is computed or persisted. The loader does not promise a cross-file transaction and
  must not add a capture protocol, manifest, generation marker, atomic directory protocol, or
  publisher-identity check. Provider declarations may use a registered provider's defaults or
  declare a custom endpoint and an already adapted protocol. They do not define executable
  adapters or new OAuth ceremonies. `ModelProviderPolicy` is the only database catalog overlay.
  Its nullable `provider_definition` is a complete replacement declaration, validated with the
  same grammar as the file base and composed before model entries. Human administration owns
  connection and model editing; Agents retain read-only discovery. Saved changes are read by
  subsequent catalog consumers without a restart or reload latch.
  Its `model_overrides` is a bounded
  v1 document: at most 256 exact model refs and 2 MiB canonical JSON, with whole
  replacement-mapping `upsert` or `remove` tombstone entries. Its optional `hidden_models` list
  holds Account-wide exact-ref visibility restrictions independently of those entries; absence
  means no restrictions. Admin visibility writes preserve definitions, prices and file inheritance,
  sharing the same Policy version. Hidden models stay in the admin catalog, disappear from every
  Agent's available-model list, and refuse selection, admission and provider start. Already-started
  calls finish and settle normally. Removing an override operation resets that model
  to file inheritance; there is no recursive partial merge, fuzzy family key, or cross-provider
  batch. Each layer is a plain overlay. Provider/model names need not exist in an earlier layer: an
  otherwise well-formed future-name upsert, enable flag, or tombstone may remain stored and has no
  effect until the final composition makes it applicable. A Policy whose provider is not currently
  composable is warned and contributes nothing while its row remains stored. DB entries cannot
  define executable code, signing, transport, redirect, selector, or new protocol behavior.
  Connection settings choose supported credential modes and wire adapters. Pricing is optional
  spending-estimate configuration (owner ruling 2026-09-30): an unpriced or unknown-cost model
  remains usable, and an explicitly complete all-zero schedule is permitted. Unknown money
  remains absent rather than becoming zero. A
  DB-only model or expanded capability must bind an `api_format` the gem adapted —
  the adapted WIRES are the boundary now, not a shipped model list; price/metadata changes,
  narrowing, enable/disable, tombstone, and reset never manufacture adaptation authority.
  Writes require optimistic `lock_version` and validate the bounded replacement document before
  SQL. Interactive provider/model authoring also validates the resulting provider lane and its
  selector references; internal inert-document writes retain the forward-compatible storage
  contract above. No file-base digest echo or separate catalog-health gate rides the write path. A command commits
  its effective Policy change on that row alone; there is no CatalogState/generation side effect,
  and invalid input or same-value replay changes nothing. The compiler applies the file base and
  database policy in order, then validates the final composed candidate. An invalid top-level
  stored document is warned and ignored as a whole without discarding the separate enabled flag;
  each invalid or currently inapplicable entry is warn-ignored independently so valid siblings and
  the underlying file model survive. A currently inapplicable tombstone hides nothing. These
  conditions never crash the process or poison the strict file base. Warnings contain only safe
  public identities/reason, never raw overlay data or secrets. Database unavailability is not an
  empty overlay and propagates as a failed composition/read; there is no generation proof to
  establish first.
- Explicit model selection is the default: acceptance freezes the stable provider/model choice
  and semantic options. The automatic switches of `ModelFallback` above — the bounded
  result-mail fallback and the declared refusal fallback, each a model the answerer's own
  profile names (a one-shot's: its creator's) — are the owner-approved exceptions; explicit failed-model-task retry may
  also name a replacement. A model node's trio therefore
  describes its current execution selection, while each ModelInvocation's model and sealed request
  remain immutable evidence of that execution. A turn variant retains its initial selection;
  current loop selection comes from its main reply path, and reasoning traces retain their actual
  producing invocation's identity. Neither transition rewrites old requests or resets completed work.
  Admission may price that
  choice against one effective catalog composition per Account per pass. At the actual send
  boundary, one current in-memory Catalog snapshot derives the adapter profile, model pin,
  input-media rules, endpoint, and other wire facts. The same derived profile and endpoint values
  flow through request build and ProviderStart; the Catalog object itself is not runtime proof.
  No acceptance-time execution profile, persisted revision, or remote-version proof participates.
- Business input and executable request have distinct authorities. `OneShot` and Conversation
  inputs own the accepted user input; Prompt assembly combines that source with system, tools,
  history, and other sections; `ModelInvocation` owns the sealed assembled request and semantic
  options used by every retry. Sending reads only the Invocation request plus the current Catalog —
  it never rewrites the business input, reassembles from mutable source context, or stores the same
  request/selection snapshot on both the business record and Invocation. Prompt assembly has three
  mechanisms (owner ruling 2026-09-05 R3): `raw` — the agent supplies the entire request; `assembly`
  — the SAME compiler with the block ORDER read from the profile's `prompt_template` jsonb (S-G-B:
  an ordered block list from the closed vocabulary slot | inline | memory | lead | tail | history |
  input, plus root variables; the text layer is the one macro gsub over the built-in sources and the
  declared variables — no Liquid, no template engine); `default` — the built-in
  template on assembly (`PromptTemplate::DEFAULT`, the fixed order as
  data). Persona, character and system prompt are durable entities stored on
  Workspace and User and injected through assembly: `default`'s order is fixed —
  `[system_prompt][character][persona][memory][skills][history][inline lead][inline tail][input]` — the
  slots being `prompt_documents` rows on the Agent Profile User, the Workspace and the poster's
  controlling Human (S-F step 3), macro-substituted from a closed registry, funded ahead of
  history, riding the sealed list as its first system-role items (one channel — never the wire's
  system field; the merge makes them one item), an inline entry naming a slot overriding it for
  the turn; `raw` carries the input's own `instructions` in the wire's system field instead.
  The budget is one `BudgetAllocator` pass: every placed block a required floor, history the
  optional child; no window → no allocator, history unbounded; a stated share (the turn's or the
  template's) is flat with the prompt on top, so its overflow arms the timeline compaction (S-B)
  rather than trimming. THE PREVIEW is the estimate rendered (`POST …/context_estimate` with
  `render: true`, S-G-B B.4, one door, no GET): the entries the seal would write, the storage bytes
  from the seal's one measure (`ContentBodies::Measure` — the seal, the loop composer's wall and
  the preview read one formula), the per-block evidence (`selected | empty | floor_unmet`; never
  `excluded` — the request sends whole, only the window gate refuses); it compiles under the
  ADDRESSEE the input door would resolve and the caller as author, through the one principals
  rule the drain uses (`Conversations::TurnPrincipals`), so the preview's bytes are the send's; a
  trial `template` rides the estimate body only, never an input. A STANDALONE LOOP under
  `default`/`assembly` (S-G-B B.5) compiles its seed ONCE at the create shell by the same
  `assemble` over a `Conversations::ContextAssembly::Source` (the room, no timeline: history
  empty, memory the workspace's and the creator's rung under the conversation-less header) with
  no profile and no limits, sealed in place of the seed step's authored body — so every round
  replays it and memory is frozen at create; the template is the creator's under the shell's word
  (`assembly` with none → `prompt_template_missing`); `instructions` is refused by name; the
  creator's words stay the body's readable text, the summarizer's only line from the seed. No
  second assembly path — never a reader in `ScheduleReady`. The surfaces alongside (S-G-B
  B.4/B.6): the SDK's `estimate_input(render:, to:, variables:, template:)` with typed evidence
  readers and `Users::DeclareConfiguration.call(prompt_template:)`; rho's `prompt preview | show` in the Ops
  extension over the daemon's member plane (no `write`/`delete` — rho rewrites its own
  `system_prompt` at every declare edge), and the daemon's `POST /loops` author route carrying
  `prompt_mechanism` to the shell word for word (under an assembled word rho's lead rides ahead
  of the words in the seed's prompt and no system field is sent — `rho do` opens a conversation,
  so no CLI verb authors a standalone loop); the `assembly_bytes` journey pins the template's
  bytes against the preview's and the standalone seed's bytes on the sealed request. THE KERNEL COMPILES THE PROMPT and stops at the block list: what a
  product says (the texts, the personas beyond the three documents, a lorebook, depth injection,
  a turn order beyond the block list) is an application's, composed over `assembly` through
  inline blocks, variables and the per-turn `inline`/`variables` intents — never a kernel
  feature. Inline remains the text primitive and raw the total-control escape. This reverses the
  2026-08-30 ruling that clients render templates themselves.
- Provider and model limits are ordinary reviewed Catalog configuration. Validate the final
  composed values for internal consistency and enforce them at the request boundary; do not attach
  source-reference rows, paid-measurement receipts, or qualification state to make a limit usable.
  Unknown optional limits stay absent.
- ProviderStart resolves the current credential and applies the product's expiry-sufficiency rule
  before IO. A local diagnostic may reuse that product path but owns no refresh flow, ancestry,
  promotion record, source pin, or currentness proof.
- Codex provider authorization is Nexus-owned (its development sequencing lives in the aggregate
  round plan). Production Nexus owns a dedicated provider authorization lineage: it never imports,
  copies, shares, or refreshes the Codex CLI's rotating single-use refresh token, and long-lived production Codex inference
  authenticates only from the credential installed by Nexus's own device-start → token-refresh
  ceremony. The explicit development seed exception (owner ruling 2026-08-29) lives under
  `e2e/manual`, with its own tests; it imports through the existing install command only in
  development/test, refuses a pending session, and leaves subsequent rotation to Nexus rather
  than synchronizing with the CLI. Nexus boot/runtime never loads this tool. Human device-start
  may create a disabled `ModelProviderPolicy` anchor and run while disabled; successful
  credential installation enables it atomically, as does an interactive API-key save. Failures
  do not enable it. Internal refresh requires an existing enabled lane and never changes
  enablement. Disable and clear revoke pending sessions under the Policy lock, preventing a
  late callback from re-enabling the lane (owner ruling 2026-10-01). Issuer, client id,
  redirect URI, and the user-code/poll/code-exchange/refresh endpoints are release-pinned
  constants with no ENV/CLI/database/request/operator/runtime override surface. Because device
  and refresh grants are single-use, per-dispatch `ModelProviderOAuthTask`
  children are the only send authority — no wire attempt exists without its persisted claim and
  no claim authorizes more than one attempt (mechanics: spec 12 D13). Steady-state refresh is a
  bounded proactive single-winner performed before admission/provider start (P11 restored);
  refresh remains internal, while the Human Platform API exposes device start/resume,
  explicit restart and clear. Authorization secrets are
  encrypted at rest, cleared at the Session's first terminal transition, and never rendered in
  logs, errors, receipts, or serialization; the sole user-visible reveal is the bounded user
  code. Real-call diagnostics remain non-production tools; serving control is owned by the live
  Policy and authorization state above.
- Metering is an append-only receipt ledger in one optional, opaque, configure-once
  `Account.cost_unit`. Canonical amounts use exact decimal `numeric(38,18)` values already
  expressed by the user in that Account unit; Nexus defines no currency, exchange rate, or
  cross-unit conversion. Missing cost remains explicitly unknown, known cost from every started
  provider attempt remains in statistics regardless of product disposition, and native provider
  amounts stay capture unless their unit exactly matches the Account unit and the source policy
  source policy permits them. Rollups/snapshots are rebuildable projections and never receipt
  truth. For priced work, a Human User is the virtual payer; an Agent User is attributed as the
  consumer and derives its payer from its current Human steward. The per-payer concurrency brake
  (`ModelInvocations::RunningCapacity::USER_ACTIVE_LIMIT`) is keyed and counted on that same
  payer through `users.steward_id`, so an Agent's running work occupies its steward's slots
  (2026-09-05). Admission performs one soft,
  unlocked check of the payer's usable budget head and creates no reservation, hold, frozen price
  schedule, or two-level winner. Settlement later appends the actual receipt charge to the payer's
  budget when one is usable; missing budget means the lane is uncapped, and bounded in-flight or
  settlement-lag overspend is an accepted consequence of this simpler policy. A catalog
  lane with a complete `catalog_only` formula whose every referenced rate is explicit zero is
  known-free on that fact alone: it creates no budget effect and still writes an exact-zero usage
  receipt. File and database definitions may both author that schedule (owner ruling 2026-09-30,
  superseding spec 20 D24's overlay restriction). Missing prices or an unset cost unit do not
  block execution; provider usage quantities still become receipts and uncomputable money
  stays absent. Nexus validates authored formula completeness, Account-unit consistency,
  exact decimal precision, and non-negativity; it does not judge whether a supplied numeric price
  is commercially reasonable. `billing_subject` remains only an
  app-mintable opaque grouping (Tavern-style per-end-user attribution stays supported); it is never
  a payer, balance, quota, or third enforcement layer.
- A UsageRecord is immutable once inserted; exact replay returns the existing receipt. Settlement
  prices from the effective pricing READ AT SETTLEMENT from the Account's catalog (D17: nothing
  frozen at start remains to compare — the reservation/start-frozen-schedule model this line
  once described was deleted in the course correction; cost arithmetic is auxiliary and
  approximate, and the receipt snapshots the `unit_pricing` it settled under).
- Ordinary first-owner browser setup configures the Account to opaque `USD` (owner ruling
  2026-09-30). Its Advanced options allow an explicit alternative; omitted or blank input uses
  `USD`. This is initialization policy: the Account
  factory, schema and kernel still supply no default, currency registry, live FX service,
  refresh job, or request-time conversion. The configure-once command remains unchanged; see
  `docs/plans/2026-09-30-nexus-default-cost-unit.md`. A foreign-unit provider schedule is a conservative provider-cost debit,
  not a sale price, normalized only from manually supplied, owner-reviewed offline authoring
  inputs — never a fetched or chosen FX factor. The conversion is an authoring-time convention
  recorded beside the shipped rates (owner ruling 2026-08-13, e.g. the hosted DeepSeek
  `USD/CNY` factor `"0.16"`); no runtime sourcing or validity-window machinery exists, and a
  price change is a manual owner-reviewed edit. Nexus does not scrape, periodically synchronize,
  mechanically refresh, or validity-window provider prices. Reference projects are consulted only
  through explicitly requested manual review, primarily to learn provider/model adaptation
  behavior; users may also edit their own overlays directly.
- Deterministic fake-Provider coverage owns the generic source-policy and settlement matrix. A
  small local real-Provider diagnostic may confirm a concrete wire behavior when needed, but it
  does not bind catalog, Attempt, reservation, or UsageRecord facts into a maintained proof pack
  and is never a second billing authority.
- Prompt caching splits mechanism (vendored `simple_inference` carries `cache_control`) from
  policy (kernel breakpoint placement); the kernel owns byte-stable continuation prefixes.
  Kernel-rendered DYNAMIC material — anything resolved per TURN rather than per write — lives in
  the SUFFIX ZONE behind the stable breakpoint; the slots (persona included) and the memory
  block change only when written, so they lead ahead of the marker, and a block that starts
  resolving per turn (a persona resolved per poster once several people post, a date macro)
  belongs behind it — one that stays ahead moves the marked prefix, a billing regression.
  Per-turn TEXT is the same rule applied to a turn: what a request laid between history and its
  input is that turn's PREFACE (`Conversations::ContextAssembly::Preface`), sealed on the reply
  variant by every seed path (the drain, the mail seed, regenerate, edit) as it was sent and
  replayed in place by later history for the answerer's own turns — never a peer's — so the next
  turn's request is the earlier one whole plus its own tail; a caller's lead the window already
  carries — the lead run of the newest in-window preface of the answerer's own turns, role and
  text byte for byte — is laid once, not per turn (the sealed entries name their block; a carried
  lead is sealed as the lead the turn relied on, never laid or replayed, and a re-ask whose window no
  longer carries it lays it); adjacent
  same-role items merge with each text its own part, never folded, and a segment carrying replayed
  reasoning never merges; a user message a round's request carried on its own (a delivered
  result, the abort marker, a steer) stays its own message in history, as that request sent it,
  on every wire.
  A serialization-order change is a BILLING regression, invisible in functional tests because the
  answer stays correct and visible only as `cache_read_tokens` declining — so it is pinned
  directly, by `ModelRequests::BuildTest#test_the_wire_preserves_submission_order...`, which
  asserts the wire order is the submission order and that rebuilding the same sealed body yields a
  character-identical `input` prefix. The prefix is the pinned unit, not the whole payload:
  `request_options` is jsonb and PostgreSQL reorders its keys by length, which nothing depends on
  because no digest is taken over the compiled payload. The stable marker follows the sealed
  list's role structure (the leading system run — the slots — plus the memory block after it);
  the TIER AND THE TAIL are the request's KIND, stamped where it is minted into its sealed
  options (`request_options.prompt_cache`, `Nexus::PromptCache::RequestKind`, owner 2026-09-28):
  a conversation's spine — its rounds, a direct reply, a regeneration — 1 h with its tail; a
  branch (a composed member, a detached step, a `task` delegate), every request of a subagent's
  conversation, a standalone loop's rounds and a OneShot 5 min with their tails; the summarizer
  no marker at all (its instructions sit below every cacheable minimum and nobody reads its
  serialized history back). Anthropic-only. An optional local real-Provider diagnostic may
  observe current remote behavior but is not the regression authority. Replayed reasoning is
  HISTORY (owner 2026-09-27/28): the default replay mode is `all` on every row
  (`ContextAssembly::Replay::DEFAULT_MODE`) — every trace the target can read rides on every
  later request exactly as the request that first carried it did — and the row states only the
  FORMAT its wire takes back (Anthropic's blocks, the Responses items, Gemini's thought parts, the
  chat message's reasoning field, DeepSeek's plain-text item); a trace whose origin the target
  cannot read carries nothing, never a fence in content (Anthropic's own models take every
  block back and the API drops what the model cannot read). Traces are priced WITH their turn in
  the one fit — the provider's captured count in tokens, their landed bytes against the seal —
  and leave the window only with their turn: the timeline compaction (the fit wall arms it on the
  tokens, the bytes or the candidate window's end, never a trace-only cut, never a retry without
  them) or the author's own `off`-slide. The fit leaves the turn's answer room on a hard or
  shared window, `min(32k, 12.5 %)`; a row that plans to an advisory bound has it already. The
  put-backs, each the author's: an explicit narrower mode or a stated history bound for one turn,
  and the effort toggle on one model — the next default turn carries again what that turn left
  out (the ledger's open rows). The kill switch (`reasoning_replay_downgraded_at`) is a
  shape-fault switch — a provider's non-transient 4xx of a request carrying native reasoning —
  read where seeds are made; the loop lane keeps its turn's traces (a tool turn must pass them
  back), and a window overflow is compaction's on both lanes.
- CONTEXT GROWS AT THE TAIL AND NOWHERE ELSE, and this is the centre of the platform's token
  economics rather than a style preference (owner ruling 2026-08-12). It is normative on
  KERNEL-serialized machinery: a message's wire bytes are a function of its own immutable fragment
  alone, so appending cannot change a byte of the prefix — `ModelRequests::Build#responses_item` is
  where that holds, and it holds structurally rather than by anyone remembering. It is the DEFAULT
  a language SDK's turn-driving runtime implements, as deferred append. It is FREE POLICY for an
  agent billed to its own budget, which may rewrite its own context as it likes. Content is
  create-and-seal; an edit is a variant, never a patch.
- Context occupancy derives from the last provider-reported usage record, never token re-counting.
- Input sourcing (`origin`) is opaque, kernel-uninterpreted testimony rendered in events.
  Cross-conversation messaging IS a kernel capability (the 2026-08-28 messaging round reversed
  the earlier no-cross-conversation-verbs decision, with cause recorded): one front door — the
  Input queue — for local, peer, and parent↔subagent mail alike, carrying a kernel-stamped weak
  sender snapshot, with queue/steer delivery modes (a steer drains at the next model boundary of
  the loop backing the in-flight turn — the loop-backed turn, *Conversation, Agent Loop, OneShot*;
  only a person's input steers — the kernel's own mail queues and drains first).

## Content And Memory

A turn's tool set is the declaring profile's declaration narrowed by the input's `tool_names` (absent = the whole declaration, `[]` = no tools: a reply from context alone under the same engine), frozen onto the round; that declaration is the ONLY delivery gate — an undeclared tool call, kernel tools included, is refused as unknown, never executed. A step with no tools that continues a model round which sent tools on the same provider and model sends that round's `tools` by value under `tool_choice: none` (the provider's own switch; its declared set stays empty): the tool list heads the cached prefix and binds the reasoning the step replays, and dropping it would re-write both.

- User input and LLM output are create-and-seal content; an edit creates a variant. ContentBody's
  ordered entries may share digest-addressed immutable Fragments for CoW/deduplication. Compute a
  unique payload's canonical address once at the writer boundary and pass the closed value inward.
- An attachment on an input (S-G-A) is the OneShot's part model reused, never a second one: the
  door composes ONE `{role, parts}` entry (words, then attachments in the order given), binds the
  rows through the join, and hands `Replace` the words as `readable_text` (`""` for a file
  alone — the projection is the writer's, never derived over the parts). Every reader of a body's
  pictures reads `ContentBody#upload_parts` (entry order, the join for liveness). Placement is per
  PART, per TURN, at ASSEMBLY against the turn's resolved selection (`Input.media_allowed?` via
  `AttachmentLine.carries_for`): a native part on a row that takes the type, else the index line
  in the picture's position; the seal binds exactly the placed set. Ordinary files use an index
  line with their `nexus://uploads/{public_id}` reference, never a native model part. An active
  claimant can read input-bound files in its loop and visible prior conversation history through
  the executor attachment descriptor/bytes doors, using its transport credential and Claim-Token.
  The runner reconstructs a working copy; Nexus owns the durable bytes. Parsing is a workspace
  tool's responsibility. Steers take no attachments; the presenter shows the row's fact whatever the wire read. The
  summarizer's rendering shows a picture as the same line with the summary's reason (`not carried
  past the summary`) after the words, under both producers — a pointer, never a value: no image id,
  no byte — and its instructions say to name a pointer, never describe what it showed. File
  references remain usable after compaction, subject to the same live history scope. The line's
  spelling is model-facing bytes measured by the index-line bench, never tuned by hand. ONE
  ingest, two authenticated doors: the member plane's `POST /agent_api/v1/uploads` and the
  console's session-plane `POST /uploads` (a multipart post into the same `ContentUploads::Create`,
  the creator = the session's user); the framework's anonymous direct-upload endpoints stay
  undrawn (`draw_routes = false`); unbound staged bytes remain outside the executor's scope. Bytes a
  OneShot produced stream through `ActiveStorage::Streaming` (ranged), never a Disk-only server.
- A staged `ContentUpload` owns an ordinary immutable Active Storage blob. Body liveness is a
  minimal unique body-upload join; filename, byte size, and media type come from the blob. Do not
  add an attachment proxy, mirrored blob facts, reference counter, release stamp, copy lineage, or
  public attachment identity before a reachable product writer needs that behavior. Fragment and
  unattached-blob reapers remain because their orphan/crash windows are real; a future staged-upload
  reaper should query join existence instead of maintaining a second truth.
- One memory family (the old MemoryDocument/MemoryChunk split is not carried), and it is kernel
  (owner ruling 2026-09-05 R2): kernel owns neutral, immutable text versions shared by pointer on
  the user|workspace|conversation scope ladder — `user/` is the controlling Human of the turn's
  principal, read by that person and every agent they steward from any workspace — with bounded
  literal text lookup, per-anchor clear, and CoW-on-fork bounded to the inherited prefix. Each scope
  has a member door of its own (the person's `profile/memory`, the room's `workspaces/{id}/memory`,
  a conversation's over its selected bindings, defaulting to all three) — a row is never reached through a host it does not belong to. No embedding/vector sidecars, no ranking,
  and no vector-storage or model-provider dependency exist in the kernel — extraction,
  consolidation, semantic retrieval, and fusion/ranking stay Agent policy. A conversation's
  optional `memory_context.bindings` maps named logical paths to existing database anchors;
  `null` keeps the defaults, an empty list disables memory, explicit roots carry read/read-write
  access, and aliases can select visible conversations in the same workspace. Content remains
  database-backed; there is no memory filesystem or synchronization. Reply variants freeze the
  execution's bindings, shared by injection, tools, preview, management and inherited work.
 A tools provider may
  OVERRIDE the memory tools by name — a WORKSPACE opts in (`tool_provider_overrides`,
  namespace-grained, one provider per family, reserved namespaces never); while it does, the six
  verbs ride the inbox to that provider with the kernel's `scope` stamp, the kernel's block and
  member doors go silent for that workspace, and the kernel treats the provider's results as
  ordinary tool output. Memory is text the model reads.
- Stores at three scopes — User, Workspace, Conversation — are one simple KV (owner ruling
  2026-09-05 R4): namespaced keyed entries, kernel-opaque, written under the same idempotency and
  size-bound contracts as every other write (*Discipline*), and data the model never reads as
  text. A store is distinct from memory by that test — and the User scope is the acting
  principal's own row, where memory's `user/` is the controlling Human's.
- A FAT KERNEL COMPACTS. Compaction is a kernel-scheduled repair, ONE arm over two hosts — a
  loop-backed round mid-turn, the conversation timeline between turns — and the kernel never picks
  a threshold: it arms when a request will not go — the provider's last reported count plus what
  was appended since it over the model's window (`usage`, checked first on every lane), the lane's
  own counter (`wall`), or the provider's refusal after the send (`overflow`) — and a person may
  ask for it (`manual`). Once per wall the arm chooses between clearing older tool results (the
  prune arm: a mark, no new row; the call stays so the model can make it again) and one summarizer
  task the round re-reads in place of the history it replaced; a manual repair always summarizes.
  A summary carries POINTERS, never values: the summarizer reads every tool result as the call
  that produced it and how much came back, its instructions ask for what to re-read, and the
  kernel frames the summary wherever a model reads it with one fixed sentence saying it carries no
  data values. The kernel ships the default summarizer; an agent that declares its own receives
  the compaction request as an inbox task addressed to its own address and answers with the
  summary (owner ruling 2026-09-05 Q3; landed S-C step 4, 2026-09-07): the kernel default is the
  shipped implementation, the agent's is an override by policy. The kernel's own summarizer runs
  under the declaring profile's `summarizer` prompt document when one is written — a fourth
  `prompt_documents` slot on the Agent Profile User, never placed by a template (the three
  `assembly_slots` are the template's), content-only, no macros, no role — else the shipped text;
  the mid-turn arm prunes while the results outside the keep-recent tail cover the overshoot net
  of the placeholders each cleared call leaves and summarizes once they cannot; a delegate NOBODY answers expires
  at its park and the kernel appends its own summarizer once, narrated (decision 9) — a second
  failure is the honest size failure. Under `raw` the kernel owns no history, so its own mode refuses
  (`compaction_unavailable_under_raw`) and only a delegate arms. The conversation timeline is the
  only history substrate — a loop-backed turn's rounds are entries on it and a mid-turn summary is
  an entry inside the turn it repairs, never a second turn — so the summary a compaction writes
  replaces timeline history and nothing else. The repaired round's current read slots still deliver
  their first-read tool results, waited child results and ask answers after the summary, once,
  with their call pairing and attachment bindings. Pruning cannot count or clear that current fan;
  only already-consumed older results contribute savings. Compaction is the one licensed prompt-cache bust; a
  manual compaction is the same mechanism on request.

## Discipline

- Rails models own business validation, domain predicates, and useful caller feedback. Business
  value bounds, vocabularies, normalization, and cross-field/lifecycle shapes use Active Record
  validations; Nexus application migrations do not use SQL CHECK constraints. Database types and
  limits, nullability, foreign keys, unique indexes, and defaults remain structural/race backstops,
  not a second home for product policy.
- One explicit request/snapshot size-bound contract (no layered inconsistent byte caps).
- One idempotency mechanism per boundary kind, reused (create receipts, result replay) — never a
  new bespoke scheme per feature.
- Destructive schema changes stay allowed pre-release (`.ai/database.md`); no product names in
  `nexus/app/**`; nexus is licensed O'Saasy — commercial concerns go to an overlay tree, never
  into the kernel.
