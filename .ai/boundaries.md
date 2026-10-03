# Boundary Rules

**Applies to:** every project. Product architecture, trust domain, and package boundaries do not vary by language.

## Trust Domain

- One `Account` is the single trust domain: users (human and agent members), workspaces,
  conversations, executors, credentials, and usage all live under it. There is no tenant-isolation
  layer and no cross-tenant concealment semantics.
- Workspace access control is a product feature among trusted members, not tenancy. Each
  Workspace has one required same-Account Human owner and
  `access_mode ∈ { account_wide, private }`. Every non-tombstoned Workspace requires that owner to
  remain un-removed: suspend is never blocked by ownership (a suspended owner's private Workspaces
  are simply inaccessible and unmanaged until reactivation), while remove requires each such
  ownership to be transferred or tombstoned first. `deleting|deleted` retains the non-null owner
  only as a durable ownership/attribution anchor until physical collection and does not block that
  Human's suspension or removal.
  Humans resolve through owner-or-account-wide coverage; Agents have no independent ACL and derive
  data access only through their current live Human steward. Dedication grants no access: after
  that ordinary relation is applied, an Agent Workspace list with
  `dedicated_to_current_agent` omitted or false exposes only rows whose `agent_identifier` is
  null, while true exposes only rows matching the current Agent's identifier. A Human list with
  the filter omitted or false retains every ordinarily accessible row, while true is empty.
  Dedicated rows additionally fence writes from an Agent whose identifier differs; reads and
  Humans pass that fence. Every Agent-created Workspace is create-frozen under the authenticated
  Agent's identifier, while every Human-created Workspace has a null tag; creation exposes no
  dedication selector. Tags are repeatable, and the only `agent_identifier` uniqueness is one
  Agent Profile/User per
  `(steward_id, agent_identifier)`. Public Workspace surfaces expose only the boolean
  non-identifying dedication marker and current-Agent predicate, never the exact product-code
  tag. Only the active Human owner manages, and an Agent never inherits management. Authorization
  resolves current membership/steward/Workspace state at request time; scoped finders are the
  default enforcement (`.ai/api.md`). A future Human-only WorkspaceAccess sharing row is additive
  and must not replace the non-tombstoned owner's current management authority.
- CONVERSATION ACCESS (S-A2; the Windows rule without groups, mandate 2026-09-08): under the
  workspace's access, every conversation carries ONE default level for every principal its entries
  do not name — `full | read | none`, born `full` — and one entry per named principal, of either
  kind, no groups. The creator and the answerer are `full` BY DERIVATION, never rows; there is no
  owner carve-out and no system-user carve-out (the workspace's owner is nobody special on a
  conversation it is not listed on). `none` CONCEALS: to that principal the conversation is absent
  on every member-plane door — the lists, the document, its turns, events and cable, its inputs,
  store, memory, forks, the replay of its receipts, and every route of a loop one of its turns
  hosts — exactly as a tombstone is, never a 403 that admits the row exists. `read` READS: every
  read answers and every write is refused `not_authorized` by name; `full` is what write standing
  has always meant, conjoined with the workspace's. One read funnel (`Conversation.readable_by`)
  and one write predicate (`writable_by?` on Workspace, Conversation and AgentLoop) carry the rule;
  a door finds the row through the funnel and then judges standing, so concealment always comes
  before refusal. The carrier is set at create and REPLACED WHOLE by `PUT …/access` under the
  Windows rule — full control includes changing permissions: `full` on the row with workspace
  write standing, a `read` principal can never escalate itself — with the actor's KIND recorded on
  the narrated fact; a fork and a side copy the rows at the fork instant and materialize the
  source's derived-full principals. The rule is the MEMBER PLANE's alone: the kernel's own acts
  never consult it — the answerer's engine writes its turns and a task's receipt lands as kernel
  mail whatever the loop's creator holds, and a spawned child's reply is relayed the same way,
  AUTHORED AS THAT MAIL IS (the originating request loop's creator, `origin: child`, the child's
  identity a stamp beside the text — never the child's answerer: the kernel relays its own receipt and
  impersonates nobody, S-I step 2) — and "kernel" is the kernel's own act, named by
  `ConversationInput::KERNEL_ORIGINS`, never a property of `origin` presence. The principals a
  carrier may name are the members with access to the workspace, listed by
  `GET …/workspaces/{id}/principals` — the member plane's one user listing, which prints a USER's
  own non-secret registration identifier (spec 01 D14) beside its steward, never a workspace's
  dedication tag.
- Executor binding is a correctness boundary: an executor (the `TaskExecutor` row) lists, claims,
  and reports only the inbox tasks addressed to it — a runner receives the calls of the
  conversations bound to it; a tools provider may also claim calls addressed to its role within
  a workspace. This isolation exists to prevent work stealing and double
  execution, and survives regardless of trust-domain shape. The executor is a delivery address,
  not a principal: each inbox task names its own execution principal (the Agent Profile the
  work runs as) and the executor credential proves only the address (the law of spec 03 D23,
  carried unchanged into the inbox protocol — owner ruling R1, 2026-09-05). Agent Profile removal
  synchronously fences member access and its agent-application transport, retaining the address,
  then asynchronously force-stops related work (owner ruling 2026-09-19, Administration Boundary
  below). Its independent Runner is unaffected. Human removal additionally owns the existing
  managed-resource shutdown generation protocol; becoming a removed Agent Profile also applies
  the Agent removal consequence.
- What is untrusted: content, not connectors. LLM output, tool effects, external ingress payloads,
  and user-supplied data are untrusted regardless of which trusted principal relayed them
  (`.ai/security.md`).
- API authority is enforced by Nexus from the authenticated principal kind plus the
  mint-frozen credential plane, never by which client library sent the request. Human cookies,
  API Sessions, and Human platform credentials reach the ordinary website/Platform surfaces;
  administration additionally requires the live Human owner/admin role. Member-plane credentials
  reach only the documented member/data resources for their User kind — the current Workspace
  family explicitly permits a Human owner's member credential as well as Agent data access, while
  keeping management Human-owner-only. Agent Users never gain Platform authority. An
  executor-transport credential is bound to one executor — an agent application, a runner, or a
  tools provider — and reaches only that executor's inbox transport (inbox, claim, commit, cable)
  and nothing on the member plane; none of the three roles gains member or Platform authority
  from that binding. An agent that plays the runner role does so on a SECOND executor row of
  kind `runner` — a transport-only credential paired beside its agent-application address (S-D
  step 2, cb415c44; the shape *Product Boundaries* states below) — never by lending its member
  bearer to the inbox. A client-side generic HTTP primitive
  can never widen these server-owned planes.

## Threat-Model And Portability Gate

Owner ruling (2026-08-13, confirmed in review). These rules apply to development, design,
implementation, and review in every project:

- Do not add a security mechanism or report a security finding without first writing the concrete
  asset, attacker, attacker capability, trust boundary, and a test that would distinguish the
  claimed failure from supported behavior. A vague hostile-environment possibility is not a threat
  model.
- The user's own environment and an implementation package the user deliberately installs are
  trusted. Do not model that package as a hostile same-process actor, the operator as an attacker
  against their own deployment, or ordinary user edits and
  stable intermediate configuration as adversarial publication. Untrusted content and explicitly
  declared external boundaries remain untrusted under their owning contracts. A documented
  OS/language/framework mechanism may still create a correctness problem, but review it as that
  concrete mechanism with a reachable test rather than inventing an attacker.
- A content digest proves integrity or names a fixed version of bytes. It does not by itself prove
  publisher identity, confer authority, or create a trust boundary.
- Host identity, absolute filesystem paths, hardware serial numbers, MAC addresses, and transient
  package inventories must not become compatibility, admission, or capture-validity conditions.
- A probe may collect only the typed capabilities the task or owning contract explicitly permits.
  It must not inventory adjacent host, package, process, or identity facts for possible future use.
- Supply-chain protection belongs at the distribution boundary: reviewed source and dependencies,
  ordinary signatures/checksums where the release process owns them, and package installation. It
  must not add attestation, sourcing, identity, or inventory checks to the model-execution hot
  path.

## Negative Archetypes From The 2026-08-25 Cleanup

Owner ruling (2026-08-25). These are rejected design shapes, not reusable hardening recipes:

- **Runtime proof theater:** local SHA values, generations, revisions, latches, fingerprints, or
  capture-currentness records cannot prove a remote Provider's version or that a trusted operator
  has not changed local files. A send reads the Catalog currently loaded by its process; distribution
  integrity stays at the release/install boundary.
- **Framework shadow state:** do not mirror facts Rails, Active Storage, Active Record, or database
  constraints already own. `ImmutableFile`, attachment reference counters/timestamps, reconciliation
  scans, and parallel attachment models are the negative example: use immutable blobs, attachment
  foreign keys, framework purge, and the smallest domain join actually read by product behavior.
- **Boundary echo validation:** normalize and validate external input once at its owning boundary.
  Inner layers trust the closed value they receive; they do not repeat type probes, canonicalization,
  integrity checks, or defensive copies, especially on a hot path.
- **Speculative state machines:** no table, status, lock rank, wake, sweep, recovery loop, or reader
  abstraction lands without a reachable writer, a reachable product/operator consumer, a concrete
  failure it recovers, and tests for that behavior in the same slice.
- **Development-tool productization:** E2E, replay, mocks, probes, and manual provider smokes exist to
  shorten development feedback. Do not add promotion workflows, qualification databases, source
  pins, environment/hardware attestations, dependency matrices, portable capture formats, or result
  fingerprints unless a current product contract consumes them. Real Provider IO is an explicit
  local-development diagnostic and never a CI or release authority.
- **Trusted-host adversaries:** the deployment operator, deliberately installed packages, sibling
  processes excluded by an existing daemon-lifetime lock, and ordinary local file replacement are
  not attackers. Do not add per-operation sidecar locks, inode/path revalidation, or self-integrity
  proofs against them.
- **Coordination beyond the contract:** prefer one indexed set update for an immediate authority cut,
  Rails-native lifecycle/parameter mechanisms, and database constraints. Add multi-phase protocols
  only when the product promises an observable distinction those mechanisms cannot make.

An exception must name the reachable behavior, the single authority that owns it, why the existing
framework mechanism is insufficient, and a test that fails without the added design.

## Product Boundaries

- Agent business data persists through Nexus wherever possible (owner clarification,
  2026-10-01). Memory remains database-backed even when tools expose file-style paths and
  read/write/edit/list/grep/delete verbs. Opaque recovery, routing and delivery state uses
  Nexus stores; artifacts use Nexus uploads. Local filesystem work belongs to the Runner
  role for coding/Cowork, including when an Agent such as rho full combines both roles.
  Bootstrap credentials/configuration and disposable runtime caches do not become a second
  durable business store. A storage-infrastructure gap is repaired at its existing owner,
  not hidden behind a new Agent-local persistence system.

- `Nexus` (kernel) is a fat, complete, orthogonal kernel for building every kind of agent —
  coding/Cowork, personal, chat, role-play (owner mandate, 2026-09-04). An agent plugs in to get
  an agent's general capabilities. Three primitives: Conversation, the bare-metal Agent loop, and
  OneShot; capabilities composable from them are not provided directly unless common (owner
  ruling Q1, 2026-09-05). Conversation is the unit a person has; the Agent loop is the engine
  inside a turn, and standalone loops remain a kernel mechanism for workflow and background runs.
  Mandatory kernel mechanisms: compaction (a kernel-shipped default summarizer an agent may
  override through the inbox — Q3), memory, cross-conversation messaging, prompt assembly (raw |
  assembly | default built-in templates, with persona, character and system prompt as durable
  entities on Workspace and User — R3), approval (a stage with modes bypass|ask|rules,
  approve/deny verbs, a park with an attention reason, and a rule model agents author instances
  of — R5), stores at User/Workspace/Conversation scope as simple KV (R4), and the task inbox
  (R1). Of these, compaction, memory, the stores, the inbox's tool half and the approval stage
  with its park, verbs and rule model are landed (S-F step 1), and so are prompt assembly's
  entities — the three `prompt_documents` slots with `default`'s fixed order (S-F step 3) and
  `assembly`'s own grammar on the profile's `prompt_template` column (S-G-B), the standalone
  loop's shell taking all three words — its seed compiled once at create over a standalone
  `Source`, never a reader in the scheduler (S-G-B B.5). The kernel interprets no tool argument: the approval evaluator reads `tool_input` as
  opaque JSON through the agent's own rule path and never learns what `bash` is. The kernel also
  owns orchestration, persistence, public identifiers, catalog
  resolution of a declared model ref to a provider lane (never the choice of model),
  workspace/conversation state, usage accounting, host-owned policy,
  audit, and recovery. What stays out: prompt MEANING (what a product says — and, over
  `assembly`, the template-tier features a product composes from the block list: lorebooks,
  depth injection, a turn order beyond the blocks, personas beyond the three documents; the
  kernel ships the compiler, the preview and the grammar, never those), model routing and
  selection (deployment policy; the repository ships no selector), product tiers, real-user
  semantics, memory extraction/consolidation/ranking policy, and commercial concerns.
- Agent applications own product experience: prompt meaning — what the product says and which
  persona, character and templates it binds through assembly, or the whole request under raw —
  model selection, UI semantics, orchestration strategy (which conversations to drive, when to
  delegate), the approval mode it declares and the rules it authors, memory extraction and
  ranking policy, and business-facing configuration. Cross-conversation messaging and delegation
  are kernel capabilities with one front door — conversation inputs with `delivery_mode:
  queue|steer`, the sender kernel-stamped; delegation spawns a child conversation
  (`.ai/nexus.md`). Input sourcing (`origin`) is neutral testimony closed at four words
  (`person|agent|task_result|child`); the kernel interprets only its own two. A SIDE conversation
  (S-Q) is the kernel's fork with a boundary item and a shared prefix; the one-open-side-per-
  parent rule, its idle TTL and its instruction text are the agent application's bookkeeping
  (rho's `btw`/`side`) — the kernel keeps no such rule (the business-neutral cut, 2026-09-10).
- Three executor roles stand beside the kernel, each a separate abstraction with its own
  credential plane that reaches its own inbox transport (owner mandate 2026-09-04; R2,
  2026-09-05): the **agent application**; the **runner**, a special tools provider for
  environment-bound tools (filesystem, processes) that is expected to run separately, in a
  container or the cloud; and the **tools provider**, an external role providing tools, which may
  OVERRIDE a kernel tool by name (memory is the ruled example) — `tools_provider` landed S-C step
  5, 2026-09-07: the enum value, the machine ownership shape (a manager Human, an identifier, an
  assignment scope, one live address per `(account_id, manager_id, runner_identifier)` key across
  BOTH machine kinds), a branch-B connection naming its kind, and pool addressing by name;
  provenance on the wire (the row's provider segment) and the per-workspace override opt-in
  landed S-E (step 3, 927b9f38); the executor relay landed S-E2 (2026-09-13) as two halves of
  the ONE inbox protocol — a CAPTURE the executor publishes on its own upload door and names by
  a `resource_link` in its commit, and a REQUEST addressed to it as a one-task standalone loop
  whose seed is the tool step (`docs/agent-api/v1/executor.md` "Captures" / "Requests"). An agent MAY play
  the runner role: rho — an agent application, the Cowork agent (`.ai/repository.md`) — plays
  it through the runner abstraction: `rho connect` pairs a SECOND executor row of kind `runner`
  (branch B, a transport-only credential, S-D step 2) that announces rho's environment tools,
  and rho names that row on every host it opens; the agent-application address announces only
  the agent's own tools (the delegate summarizer) and is never a binding — its claims are on the
  executor plane, never by its member bearer. A runner may serve multiple
  Agent Profiles within its assignment scope because every task carries the frozen principal of
  the loop that authored it (`agent_loops.creating_user_id`), separately from the executor it is
  addressed to; a runner is never exclusively bound to one Profile. Executor-local semantics —
  tool processes, file mutation, working directories — belong to the executor, never kernel
  state.
- Nexus is the gateway: every message among agent, runner and tools provider is relayed by Nexus.
  Nexus deploys on the public internet or a LAN; every other component defaults to the intranet
  and needs no inbound route, because components POLL Nexus (HTTP is the authority) and the
  Action Cable channel is push notification and latency optimisation — nothing in the
  correctness path depends on the cable, on presence, or on a heartbeat. The task inbox is the
  one protocol (owner ruling R1, 2026-09-05): a distributed asynchronous task queue between Nexus
  and every executor role — claim (a token rotated per claim, exclusive until the task's own
  deadline, one clock, which the claimant alone may extend, bounded and narrated) then commit a
  write-once result. Its
  kinds are not only tool calls: Nexus-level business an executor takes over — a compaction
  delegated to the agent (Q3), and whatever else the kernel delegates — rides the same queue. A
  task is addressed to an executor — a runner-kind call to the conversation's bound runner (one
  runner per conversation at a time; the handoff verb rewrites the binding) — or, for tools
  providers only, to the role within the workspace when the caller names none;
  the cable stream is keyed by executor; an executor announces what it serves so the kernel can
  address it, and that server-side record never shapes the per-round tools list, which is the
  front of the cached prefix — with ONE bounded exception: the `skill` entry is OMITTED from
  the wire when the merged skill catalog (kernel `skills/` rows and announced documents) is
  empty (owner 2026-09-10: absent, not disabled), decided at the one provider-bound site from
  the stored set; no entry's bytes are ever shaped by any executor record, and the catalog
  itself rides the assembly's `skills` block, not the tool list. A runner's own surface — a file's bytes, a process's log, a
  screenshot — is reached through Nexus and never directly, and the relay keeps the topology:
  it is served over that executor's own outbound connection, never by Nexus dialling in (S-E2,
  2026-09-13). An executor surface is either a CAPTURE the executor publishes — `POST
  /agent_api/v1/executor/uploads` into the one ingest (the `UploadIngest` concern behind the
  session, member and executor doors; the row's creator anchor-shaped, exactly one of a member
  or an executor), named by a `resource_link` block in the commit's `content` and bound by the
  result body, read back by the ONE bytes read `GET /agent_api/v1/uploads/{id}/bytes` under the
  upload's own rule (`ContentUpload#readable_by?`: the creator, or a reader of a row that names
  it — the same read serves an input's attachment) — or a REQUEST addressed to it as a task: a
  one-task standalone loop created and started on the task-grained surface, its seed the tool
  step, claimed / extended / committed / swept as any tool call, no second subject and no second
  door. The runner's capabilities are TOOLS it announces without a description or a schema
  (rho-runner's `files_bytes` — always a capture, the chunk is HTTP `Range` — and rho's
  `process_log`, the person's read beside the model's owner-gated `read_process`, a recorded
  semantic difference), hidden by name from every model on the agent side
  (`LoopRequest#undeclared`). The announcement IS the environment (re-announced on a re-point;
  no `environment` relay tool). Progress — the ephemeral frames — is the executor progress door
  and the host's `progress` feed, landed in S-E2's S5 (`nexus/app/services/executors/progress.rb`).
  The transcript route is the THREAD (2026-09-14, §3.2 S1): one presenter for the page, a branch's
  `?prefix=` expansion, the settled `round` snapshot and the timeline's rows, reading keys, the
  spine mark and the round's own reading-list column — a display projection reads no edge and
  writes nothing; `node_key` is collated `C` so its ranges mean bytes on every platform.
- An executor recovers a missed cancellation by reading its exact existing claim (`GET` on the
  claim resource, original `Claim-Token` header; `docs/agent-api/v1/executor.md`). This projects
  the existing node's dispatched state and proves its claimant/token; it neither grants nor
  renews work. Inbox absence, pause, current binding and new-admission eligibility do not revoke
  an existing claim. The Runner reads on its existing control wait and cancels only the original
  context on inactive, missing, or `not_claimant`; unknown read failures preserve the worker,
  admission ticket and original deadline. No lease, cancellation marker or second claim registry.
- Executor-local deadline handling is best effort while bounded control HTTP or credential
  refresh is in flight (owner ruling 2026-09-19;
  `docs/plans/2026-09-19-executor-cancellation-recovery-design.md`). Each HTTP request retains a
  finite timeout, which may exceed the task's remaining time. After that control call returns
  or times out, resume the existing deadline/cancellation path; do not extend the task merely
  because the call ran late. No whole-probe deadline, watchdog, extra worker pool, or interruption
  of credential wire-and-persist is required to align these independent budgets. Nexus's claim
  fencing, expiry and terminal-result integrity remain authoritative.
- Four tool sources, one provenance model (R2): Nexus (memory, subagent, background tasks — the
  tools tied to the kernel's authority over Conversation and loop), the runner (environment
  tools), the tools provider (external; may override), and the agent itself. A tool name resolves
  to one providing authority and the provider survives on the wire. An agent may declare its own
  SPELLING of a kernel tool (an alias on its declaration, with a parameter map); the canonical, the
  routing and the reserved namespaces are untouched, and a call arrives under the alias and runs
  under the canonical.
- Switching the runner within a conversation — between the agent's own runner address and a
  separate one, or between runners — is an explicit handoff: the host's answering profile or a
  Human with write standing invokes it, the kernel records it (`runner_bound`), and the ONLY
  value→value rebinding of `runner_executor_id` is `InputHost#bind_runner` (the create doors
  write it once, a fork copies it). Nexus never retargets STARTED work on its own; an explicit
  handoff re-addresses what nobody has claimed — through the one addressing site, the park
  clock re-armed — and a claimed task finishes or expires where it was claimed. The host
  filesystem is implicit state, which is why the switch is never implicit.
- No layer may normalize, classify, validate, or silently reinterpret another layer's
  business-specific payloads beyond an explicitly versioned generic contract.
- Kernel execution substrates are internals: public APIs expose task/timeline/capture
  projections, never raw mechanism (countdowns, generations, STI class names, scheduler lanes).
  The loop's graph is WRITTEN only through tasks — no client authors an edge, which keeps it
  sound — and READ whole on the member graph route (nodes and edges as task keys, Mermaid) for
  debugging, e2e evidence and a UI drawing the workflow (owner ruling 2026-09-05).
- Workspace remains the mandatory container for execution/content resources (conversations, loops,
  one-shots). Ownership, access-mode, and `agent_identifier` dedication rules are stated in
  the Trust Domain section above (provenance: archived specs 01/02, a historical citation).

## Administration Boundary

- Administrators operate the Account; they do not act as custodians of how members use Nexus.
  Administrative scope is account-global settings, Human user management, aggregate statistics
  and operational monitoring, and any current or future executor kind whose owning contract
  explicitly makes it account-global. One narrow billing-policy exception is explicit: owner/admin
  Humans may issue and adjust any Human's virtual Account-unit usage balance, including their own,
  and inspect its amount-only ledger/headroom. That authority exposes no content, Workspace, provider trace, or
  per-Agent activity, and it does not authorize an administrator to manage the Human's Agent
  allowances. If resolving/reversing one Human charge must mechanically correct the paired Agent
  allowance entry, the spec-20 service derives and applies that hidden second effect atomically;
  the administrator supplies no Agent selector and receives no Agent identity or detail, so this is
  not an independent Agent-allowance command.
- Every Runner has one Human manager regardless of assignment scope. Its logical registration key
  is `(account_id, manager_id, runner_identifier)`; `assignment_scope ∈ { user_private,
  account_wide }` is pure ACL and never part of identity, address, credential lifecycle, or task
  history. `user_private` admits Profiles managed by that Human; `account_wide` admits eligible
  Profiles across the Account. That broader ACL grants no lifecycle or credential authority:
  the manager is the sole current manager through their member-owned `/runners` surface, and an
  administrator has no takeover, offboarding, or removal-time emergency bypass for another
  Human's Runner. Each logical registration has at most one non-revoked address/current pairing;
  re-pair advances its epoch rather than creating a sibling address. A tools provider is an
  executor under the same identity model — the same registration key (so one manager cannot hold
  a runner and a provider under one identifier: the kind is the registration's, frozen at
  creation like its scope, and a re-pair naming the other kind is refused at Consume), at most
  one non-revoked address, an epoch that re-pair advances, a transport-only credential — and its
  manager is the connecting Human and its admission scope the browser's choice, exactly as a
  Runner's (S-C step 5, 2026-09-07).
  Browser Connect selects scope only when it creates a fresh logical registration: an ordinary
  member is fixed to `user_private`, while an owner/admin connecting a Runner as its manager may
  opt into `account_wide` through one default-unchecked control. A live registration instead
  renders its stored scope without a selector, and re-pair preserves it; after terminal
  revocation, a later fresh registration may select again. The machine cannot self-assert scope.
  No scope-change or manager-transfer command exists. A later scope change affects only
  discovery/admission/publication begun after it commits; existing inbox tasks retain their frozen principal, executor, and
  authority facts. A future manager transfer requires its own explicit authorization and route contract;
  pure ACL never implies one. None of this claims that Nexus can identify the physical process
  holding a copied bearer.
- Human managed-resource shutdown is a durable generation protocol, not a status-only sweep.
  Human Users advance `managed_resource_shutdown_generation` only when removal is accepted.
  Stewarded Agent Profiles record `applied_steward_shutdown_generation`, and TaskExecutors record
  `applied_human_shutdown_generation` for their controlling steward/manager. A mismatch is a
  level-triggered pending shutdown that survives Human restore. Profile convergence removes and
  authority-fences the Profile before acknowledging its generation, applying the Agent removal
  consequence below. Other managed executors retain exact bound transport for safe task/result/
  capture reconciliation, then fence the epoch before acknowledging. Human restore changes none
  of these applied generations; the Agent consequence does not replace this Human protocol.
- Administrator commands for a specific Agent User are limited to steward reassignment and the
  remove/restore lifecycle. Removal synchronously fences member/data access through status and
  `authority_generation`, and revokes the Agent application's credentials through its existing
  executor credential epoch. The address stays active and is not rebound; an independent Runner's
  address and lineage are untouched. Related Conversations and live loops are force-stopped
  asynchronously; status lag and eventual task timeout are accepted (owner ruling 2026-09-19).
  Related work includes the Agent as creator, the Conversation's default answerer, its current
  turn's initiator or answerer, the related spawned descendants, and its still-live
  historical/background loops. Historical participation alone
  does not authorize stopping somebody else's current turn. Cleanup reads current removed state,
  skips restored Profiles, and has a bounded recurring floor for lost wakes. Restore does not wait
  for cleanup or revive old credentials. Do not add a task-withdrawal marker, removal episode,
  generation counter or restore barrier to preserve the superseded graceful-removal contract.
  Agents have remove/restore, not a new suspension API. This lifecycle consequence creates no
  administrator credential/executor inspection or independent revocation surface; connection and
  credential management otherwise remain member-owned.
- Administrators do not inspect or mutate a specific Agent User's activity, credentials,
  user-bound executors, conversations, or other product data. Per-user and per-Agent facts may
  contribute to aggregate global statistics and monitoring without becoming a per-member
  management surface. A future sensitive-operation feed would be a separate, explicitly accepted
  scope and would not imply general content, credential, or usage review.
- A Human steward alone manages the exact Account-unit cost allowance of their current Agent Users.
  The Agent may read its own allowance/headroom but cannot grant, raise, adjust, or reverse it, and
  it never reads the steward's balance. Steward reassignment transfers authority over later Agent
  allowance commands but never moves an existing debit or immutable usage receipt.
  `billing_subject` ownership grants no balance or allowance authority. These amount-only controls
  do not weaken the ban on administrator inspection of a specific Agent's activity or usage detail.

## Ruling Propagation

- A ruling that RETIRES or REPLACES a mechanism is not landed until its target set is swept in the
  same change: `docs/agent-api/**` (the living contract a future implementer builds from), `.ai/**`,
  `AGENTS.md`, the owning plan register(s), and any checked-in data or contract text that names
  the retired mechanism. Code alone is never enough — a spec still mandating a retired mechanism
  will be rebuilt by whoever implements that spec next.
- The ruling's dated record names the files it swept. A later sweep starts from that list rather
  than from whatever the author happens to remember, because "patch the sites I recall" is how the
  same retirement goes stale twice.
- Dated historical records (round records, entry-gate records, review adjudications) keep their
  original wording: they describe what was true when written. Only NORMATIVE-NOW statements are
  swept. When a record would read as current guidance, mark it with its date and the ruling that
  superseded it rather than rewriting history.

## Design Expansion Gate

- Use the smallest set of domain entities and boundaries already present in or explicitly required
  by the accepted design that can satisfy written, reachable product behavior. A distinct fact,
  state, or code path does not by itself justify another entity.
- Do not add a domain entity, table, independently persisted lifecycle, coordination mechanism,
  state machine, protocol boundary, or general-purpose abstraction for future extensibility,
  implementation convenience, or a theoretical race or invalid state with no reachable product
  path.
- If a written contract cannot be implemented without an expansion not already present in the
  accepted design, stop before implementing it or changing the schema or public/domain boundaries
  and obtain explicit user approval. Present the exact invariant, a reachable scenario, why
  existing owners, fields, or associations cannot express it, the smallest alternatives and their
  tradeoffs, and the precise added surface.
- Routine code decomposition that gives already-specified behavior or a closed value shape a home
  is not an expansion when it introduces no new independent identity, lifecycle, persistence
  owner, coordination semantics, or protocol surface. When uncertain whether a change crosses
  this boundary, stop and ask.
- Data integrity is universal; a friendly or typed losing response is required only when a written
  contract promises one. Flows whose normal operation admits multiple writers — transport
  retries, duplicate jobs, claim/deadline/reaper interactions, multi-actor commands — must have
  and retain a written convergence contract. Any other collision is exceptional: it may surface
  as an ordinary `500` when the failed request is fully rolled back, durable invariants remain
  intact, and no irreversible effect or partial state results.
- Do not add a lock, retry, rescue branch, persisted state, recovery path, coordination mechanism,
  or entity solely to make such an exceptional failure friendly.
- Do not turn an observable interleaving into a coordination contract by itself. Independent
  commands are already convergent when every reachable result is equivalent to an allowed serial
  ordering, the final authoritative state still gates later authorization/effects, and no durable
  invariant, irreversible effect, or atomicity boundary is violated. A stale observation or a
  difference between acceptance and commit order alone is not divergence; a stricter winner
  requires an explicit product contract and a distinct unsafe final state.
- ONE IMPLEMENTATION PER MECHANISM (owner ruling 2026-09-05): two implementations of one mechanism
  — a map, a queue, a serializer, a result type, a guard — are unified whenever they can be; a
  second copy survives only on a recorded, explicit semantic difference, never on lane, history,
  or convenience.

## Breaking Changes to In-Flight and Historical State

Owner ruling (2026-08-12). Rails migrations own schema and data shape; do NOT build
state-machine migration machinery on top of them. When a code change breaks the meaning of
durable orchestration or execution state, the handling lives in business logic as graceful
degradation:

- **Unfinished work is regenerated, not migrated.** An in-flight task, loop, or invocation whose
  durable state no longer matches the current machine is failed closed and re-created/retried
  under the new shape through its ordinary lineage (spec 03 retry lineage, loop re-planning) —
  never patched in place to "resume" across the break.
- **Historical records are rendered tolerantly, never crashed on.** Display and read surfaces
  skip or degrade unknown/incompatible content in old rows (a placeholder, an omitted section)
  instead of raising; history is capture, and capture stays readable across versions.
- Keeping this cheap is a design constraint, not an accident: orchestration state stays small,
  short-lived, and enumerable, so "fail closed and regenerate" is always affordable; the durable
  conversation/capture stratum stays structurally boring so it never needs rewriting.

## No Compatibility Before Release, And What Is Not Dead Code

Owner ruling (2026-09-04). Two halves, and the second is the guard on the first.

- **Before the product ships, compatibility is never a reason to keep anything.** No shims, no
  transitional vocabularies, no "accept both spellings for one release", no version gates between
  our own components. A refactor lands whole: writers, readers, clients, tests, docs and the
  removal of whatever the old shape needed. This is the same rule the reset-era schema policy
  states for the database (`.ai/database.md`) and the no-progressive-versions ruling states for
  features, applied to code. Where a rolling step is genuinely unavoidable inside one change, it
  is a step within that change and never a committed resting state.
- **An UNWIRED PUBLIC CAPABILITY is not dead code, and must not be swept as one.** A service,
  route, command or declared field that is complete and reachable by design but has no caller yet
  is owed a caller, not a deletion — the kernel deliberately ships ahead of its clients, so
  "nothing calls it" is the normal early state of a public surface rather than evidence against
  it. Examples of the class, all real: a routed task adjudication verb no client calls yet, a
  provider-key installer with no HTTP caller, a memory family the daemon does not declare, an
  effect profile published on every tool and consumed by nobody. What IS dead code is internal:
  a predicate, constant, branch or helper with no reader that no public surface promises.
  When in doubt, ask whether anything outside this repository could reasonably be expected to
  reach it; if yes, it is unwired, and the finding is a missing caller.

## The Human Console And The Gateway

API responsibility follows the user's activity (owner clarification 2026-09-29).
`/agent_api/v1` serves Agent work, including model discovery and conversation execution.
`/api/v1` serves Human personal settings and system settings; the latter live under
`/api/v1/admin` and are visible and usable only by a live Human owner/admin. Personal
settings do not require that role. A conversation/work WebUI reaches Agent work through
its Agent application, while browser use of the Platform API is confined to settings
pages. `cmctl` consumes the same settings capabilities as a CLI. These responsibilities
do not change the credential-plane or authentication rules.

The console is split (owner ruling 2026-09-05). Nexus's own Rails UI owns ACCOUNT ADMINISTRATION —
LLM providers, credentials and models first (the biggest gap), runners, workspaces' management —
under the ordinary Human session; conversation and workspace CONTENT pages on Nexus are deferred
(the management pages ship). An agent
may ship its own UI for conversation-level work — rho's webui, an extension in the pi-agent shape —
served by the agent daemon and reaching the kernel through the agent's own credential; that daemon
proxies no account administration (model/provider configuration and provider keys belong on Nexus).
For terminal onboarding, `rho setup` may consume the Platform settings API through cmctl's
operator library with a separately authenticated Human owner/admin (owner OOBE request,
2026-09-29). This setup-only session is revoked on exit and is never written into the member
vault or carried into the daemon. Nexus provider/model and Account cost-unit browser
settings use the existing Human admin Session and the same domain commands (owner
follow-up, 2026-09-29); rho's browser settings remain deferred to its WebUI redesign.
This adds no Agent tool or daemon route for administration.
Read-only model discovery stays on the Agent API for every authenticated member-plane Agent,
returning only the Account's configured, currently usable models, with no per-Agent model ACL.
Model choice and routing remain the Agent application's policy. The Human/admin Platform API
also reads the complete catalog, including unavailable models and their diagnostic reasons;
provider mutation and Account-wide model visibility use that API and its
operator consumer, `cmctl`. Hiding a model retains its definition and pricing,
removes it from Agent discovery and refuses new calls; it is not a per-Agent ACL.
An
executor's surface — a runner's file bytes, process logs and environment, a tools provider's
API — is read locally by the executor's own UI while an agent plays the runner role in-process
(rho's webui → the daemon's `/files/bytes`, `/processes*`, `/environment`, the local
short-circuit on `own_runner?`), and through Nexus's relay from anything that is not the
executor's own process (S-E2, 2026-09-13): the daemon's `Ops.relay` / `Processes.list` /
`Processes.log` dispatch on `own_runner?` — the local table, or ONE SDK request as a one-task
loop on the bound runner (`files_bytes` answers a capture the daemon fetches on the member
plane and streams back; `list_processes` / `process_log` the rows) — and `rho relay`, `rho
fetch`, `rho ps` / `rho logs` are the verbs a person drives.

- **The page is wired and shipped** (rho's webui, kept by owner ruling 2026-09-05). `agents/rho/rho-webui/webui/` holds it: plain ES modules and plain
  CSS with no build step, so what the gem ships is what a person reads. The owner-authorized
  extraction (2026-09-28, `docs/plans/2026-09-28-rho-plugin-packaging.md`) places resources in
  the `rho-webui` gem: `register_webui(root:)` registers a page through the existing extension
  loader, while rho owns generic static serving and the console-code exchange. Only committed
  extensions contribute a page; two committed page owners refuse startup. Full/agent defaults
  select `rho/webui`; runner stays headless and `api_only` disables serving. `Config#webui_root`
  (settings.json / `RHO_WEBUI_ROOT`) points the mount somewhere else — a dev build, an operator's
  own, or a bundle another gem ships — and is the seam every alternative shape needs.
  Non-fingerprinted files live at the ROOT, never under `assets/`: that prefix earns a year of
  `immutable` and only a fingerprinted name deserves one.

### How A Browser Gets rho's Bearer

The served document carries NO credential. `GET /` is unauthenticated by necessity, so anything in
it is public to every process that can open the port — which is a different local uid on a shared
host, and any container or FS-restricted tool with host networking, including ones rho itself
starts. A same-uid process reads the 0600 announcement regardless and is out of scope.

The bearer travels as a **console code**: `rho console` reads the announcement (which is what
proves it may), calls the bearer-guarded `POST /console/code`, and prints a single-use link valid
for 90 seconds; the page redeems it once at `POST /console/session`. The code never GRANTS a
capability — it moves one the caller already held into a browser, which cannot read files.

Three rules follow, and the round that ships the bundle owes all of them:

- **Nothing is printed at boot.** Not the bearer, not a code. Under a process supervisor this
  stream is merged with every other process's and tee'd to a file whose mode the daemon does not
  own; that is the same read the design closes. `rho server` prints only where to look.
- **The page keeps the bearer in `sessionStorage`, never `localStorage`, never a cookie, never a
  `window` property.** Web storage is keyed by origin, so a rebound origin gets different storage;
  `localStorage` would make the bearer outlive the tab that earned it, which is strictly worse
  than the injection this replaced. Cookies are ambient authority on a surface whose every route
  runs shell commands, and are port-blind across all of `127.0.0.1`.
- **The page never auto-retries a failed exchange**, checks `/healthz`'s `control_version` BEFORE
  spending its code, and renders the connect screen — a designed state, not an error branch — for
  a bare `GET /`, a restart, a stale link or a wrong-daemon code. `code_spent` is a warning naming
  the consequence, not "invalid": it is the only theft signal this design has. Streaming uses
  `fetch` + `ReadableStream`, never `EventSource`, which cannot set `Authorization`.

Deliberately absent, so they are not re-proposed: CORS, an `OPTIONS` handler, an origin allowlist
(the dev story is a proxy in the page's own workspace, and `http://localhost:5173` is not a trust
boundary — that port belongs to whichever uid bound it first); any throttle on the code (256 bits
have no searchable keyspace, and a limiter is a lockout lever); a code in the announcement; and a
fixed port, which the page slice owes when a bookmark first has to mean something.

## Async Execution Ownership

Owner ruling 2026-09-29 (`docs/plans/2026-09-29-async-result-ownership.md`): an
execution belongs to its original loop/variant/turn, even when its result starts
a supplementary reply. Conversation-lifetime background results use the existing
mail/input queue after the original reply is final, including fast results;
launch-time waits and turn-lifetime obligations keep their current-turn synthesis.
Conversation Stop cuts all its existing execution owners. Changed activation or
successful regeneration cuts the replaced variant's owner. The cut includes
undelivered callbacks and already-started supplementary replies, follows exact
sender loop/task ownership into child requests, and does not stop later
independent requests merely because they reuse that child conversation. A
write-once `AgentLoop.stopped_at` preserves this existing Stop fact after terminal
completion. Viewing or reselecting an old candidate never revives work. Published
content and completed external effects remain; natural completion and new user
input do not cancel background work.

Owner refinement 2026-10-02: already-arrived independent worker finals may be
consumed together when their original requester and execution/memory policy
match. The receiving conversation owns that combined reply after consumption;
stopping one source afterward neither retracts its read result nor stops the
combined reply. Before consumption, every source retains its Stop fence. The
turn retains immutable per-receipt result pointers rather than assigning the
whole reply to its last source. A reply to one worker result and ordinary
task/tool/compose receipts retain the preceding ownership rules. A combined
report stays in its receiving conversation; each worker's explicit external
delivery exports only its own fixed formal result and changes only that
worker's future destination. See the 2026-10-02 refinement in
`docs/plans/2026-09-29-async-result-ownership.md`.

## Awareness Versus Obligation

Two signal primitives, never conflated:

- Awareness: Notification rows fanned out to subscribed/mentioned principals (mutable read state,
  mutable subscriptions, server-side filtering before any agent wake). An agent may ignore
  awareness; the notification inbox is never a second delivery queue.
- Obligation: an inbox task addressed to an executor, with a claim, a deadline, and a write-once
  result. Only obligation carries execution semantics. Product policy may escalate awareness into
  obligation (a direct ask becomes an addressed task); the kernel does not do this implicitly.

## Mutation Topology

Owner ruling, 2026-07-26, generalizing the steward decision in spec 01. Two rules, and the
performance posture that follows from them:

**Bindings are immutable by default.** An association column that names WHO a row belongs to — its
account, its member, its executor, its family, its creator — is ordinarily written at most once and
never changes from one value to another. Rebinding is normally snapshot → delete → recreate. The
enforcement is `attr_readonly` on every such column; the taxonomy has exactly three shapes:

1. **Creation-frozen** — the default. Every binding is in the model's `attr_readonly` list.
2. **Transition-written capture** — nil → value exactly once at a chartered transition, never
   value → value: DeviceAuthorization's consume capture pointers and the `user` /
   `connected_by` pointers Connect writes, RefreshToken's `superseded_by_id` at rotation. These
   are state-machine facts wearing FK types. One of them un-writes: Cancel returns Connect's two
   pointers to nil (`device_authorizations/cancel.rb`), which is inside the shape rather than an
   exception to it — the row is terminal by then and `Connect` requires `pending?`, so no writer
   can ever re-bind it, and the value → value form stays unreachable.
3. **Sanctioned management escape hatches** — `users.steward_id`, a Runner's `manager_id`, and
   `workspaces.owner_id`. Steward reassignment and Workspace ownership transfer are current rare
   management commands. Runner manager transfer is a future rare command that earns a separate
   authorization and route contract before that column becomes writable.

   Workspace transfer locks the Workspace, then source/target Humans in deterministic order,
   requires a same-Account active Human target, and changes no creator attribution. Human remove
   is refused while any non-tombstoned Workspace ownership remains; suspend is never blocked by
   ownership. Tombstoned ownership stays attached for ownership/attribution until physical
   collection but is ignored by that remove guard. Agent steward reassignment never follows
   through to Workspace ownership.

   Runner manager transfer changes management and the private-ACL subject for future admission
   only; it never changes the Runner's public identity, credential epoch, or an existing inbox task. A
   future `assignment_scope` mutation is ACL, not a WHO binding, and follows the same
   future-work-only rule. Steward transfer follows the existing authority lane: lock the Agent
   Profile first, then the source and target Humans in deterministic order, then its dependent
   TaskExecutor address. A future Runner-manager transfer follows the Human-before-TaskExecutor
   credential lane because the Runner is itself the managed TaskExecutor. If source removal won
   first and either the Profile or executor still has an unapplied shutdown generation, transfer
   returns `shutdown_pending` without rebinding; transfer that wins first freezes the target
   Human's current generation on each rebound resource.

A new model earns a place in shape 2 or 3 only with a written reason; the default is shape 1.

**Lifecycle verbs are rare, and their cost is paid at the authority edge plus convergence**
(owner refinements, 2026-07-26 and 2026-07-28). connect, disconnect, revoke, remove, restore,
steward reassignment, and one day erase/incineration are administrative-frequency operations:

- **The synchronous half cuts authority in one atomic transaction; O(1) is the default, not a
  doctrine.** Usually that transaction is short: the API call locks the owning row, flips the
  appropriate fence — status, generation, epoch, revoked_at — commits, and answers fast. A rare
  ACL/lifecycle command may instead use one indexed, set-based `UPDATE`/`DELETE` statement over real
  authority rows when that is the simplest correct accepted-order boundary. ModelInvocation bulk
  cancellation is the negative-example repair: one guarded update terminalizes nonterminal parent
  rows immediately, while Attempt and event convergence happen later. Do not split that statement
  into keyset cohorts, collect winners in `pg_temp`, add a progress ledger, or synchronously walk
  dependent rows merely to demonstrate bounded work. If one statement is materially too large,
  preserve the immediate indexed authority cut and move collateral cleanup to bounded recurring
  convergence. Such a bulk cut must have an explicit cardinality/query-plan argument and explicit
  handling for every callback or projection it bypasses. A Human removal therefore blocks that Human's
  member/data access and all new dependent-resource admission immediately; it does not pretend
  already-running work has stopped. The managed-resource protocol retains transport needed to
  report a safe terminal fact except when an Agent Profile becomes removed: the 2026-09-19 Agent
  rule immediately fences that application's credentials and force-stops its related work
  asynchronously.
- **The rest is asynchronous convergence, in bounded batches.** Marker propagation, reaping, and
  cascade cleanup run as recurring jobs over bounded continuations — restartable, never a
  full-table drain, never blocking an API response, never interfering with other users or other
  business. Human remove/erase first stops admission, then cancels queued inbox tasks and asks
  running work to stop at data-safe checkpoints, then fences dependent transports only after
  every inbox task has reached a truthful terminal/capture state, with the Agent Profile removal
  exception above. Convergence itself never grows an unbounded
  transaction: N is paid in batch-sized installments or not at all. The ordinary mechanism is
  `.ai/database.md`'s two-phase idiom (flip and commit the owning row first; apply to other
  aggregates after commit). A chartered accepted-order bulk cut may mark actual affected rows in
  the authority transaction; handlers still stop and settle asynchronously.

Within that shape there is no optimization pressure — do not report a rare verb's end-to-end
convergence latency, or set-based O(N) alone, as a finding, and do not complicate one to make it
converge faster. The single-statement authority exception above does not relax recurring or
asynchronous convergence: those still commit batch-sized installments. What IS reportable:
Ruby/per-record synchronous writes or unbounded candidate/winner materialization where bounded set
DML expresses the domain transition, an unexplained or unindexed bulk mutation at representative
scale, callbacks/projections silently skipped by `delete_all`/`update_all`, holding hot-path locks
longer than the accepted-order cut requires, or a convergence job growing an unbounded transaction.

## Public Identifiers

- Do not expose internal `bigint` IDs at external, executor-facing, or durable audit boundaries;
  use public identifiers there.
- Named degradation: when Rails or an adopted gem's record-referencing mechanism —
  `generates_token_for` signed tokens, GlobalID/`deliver_later` job arguments, and similar
  framework plumbing — cannot carry `public_id` without reimplementing the mechanism, the internal
  id may ride inside that mechanism's opaque signed or serialized payload. The id is transport
  plumbing there, not a public identifier: routes, response bodies, logs, and durable audit fields
  still use `public_id`.
- Do not add `public_id` to every model by default — only where the model crosses one of those
  boundaries.
- All `public_id` columns use PostgreSQL `uuid` with sortable UUIDv7 values: PostgreSQL 18
  `uuidv7()` defaults or Ruby `SecureRandom.uuid_v7`.
- Use `attr_readonly` for persisted identity fields that are mutable during creation but immutable
  afterward: owner FKs, stable external keys, STI scope keys, `public_id`, short technical tags.

## Package Boundaries

- Each top-level project is independently buildable and testable unless a change explicitly
  crosses projects; new bundled projects get their own toolchain files and explicit root CI jobs.
- Shared protocol changes must be reflected at every owning boundary: kernel service,
  `cybros_agent` gem, operator tooling, and E2E harness where applicable.
- `nexus/app/**` must not depend on concrete agent application constants.
- Minimize development/test/E2E/diagnostic code in Nexus and prefer the owning non-deployable tree;
  location alone is not a prohibition (owner clarification 2026-09-22; `repository.md`, Development
  And Test Placement). Genuine deployment conveniences, including environment-variable import
  of provider API keys, remain product capabilities. Production mechanisms stay in their owning
  layers when tests exercise them; placement follows runtime responsibility and consumers.
- The executable dependency is one-way from `e2e/**` and project tests into Nexus. Nexus production
  boot/runtime must not require, discover, load, or read either tree. No production configuration
  is generated from, admitted by, or kept current by real-call artifacts — what ships is ordinary
  reviewed registry/catalog data authored by the development process.
- A declaration with no product consumer is not preserved merely to prove that development work
  happened. Delete wire revisions, source pins, capture-currentness records, and equivalent
  fingerprints when they only coordinate a test/qualification workflow. A real runtime protocol
  version remains only when two independently deployed product components use it to choose or
  reject behavior, with an executable compatibility test at that boundary.
- Within `cybros_agent`, the client plane (synchronous httpx transport, resources, credentials)
  must stay loadable without the agent-framework plane's reactor; realtime error types stay
  loadable without `async-websocket`.
- KILLS ABANDON WAITS AND NEVER SPLIT AN ANSWER FROM ITS PERSIST: a credential ceremony (the
  device-flow poll, a refresh rotation) masks interrupts across wire-and-commit and re-opens
  delivery only at its blocking waits, so a kill lands where nothing was spent or after the
  answer is durable — never between the two.

## E2E Boundaries

- E2E may inspect kernel/agent databases or processes for internal observability only — to explain
  what happened, never to create the success condition. Control/use actions and externally visible
  assertions go through public APIs, not direct service calls or synthetic result injection.
