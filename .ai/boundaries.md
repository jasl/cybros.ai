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
  Humans resolve through owner-or-account-wide coverage; Agents have no independent Workspace
  data-access ACL and derive data access only through their current live Human steward.
  Dedication grants no access: after that ordinary relation is applied, an Agent Workspace list with
  `dedicated_to_current_agent` omitted or false exposes only rows whose `agent_identifier` is
  null, while true exposes only rows matching the current Agent's identifier. A Human list with
  the filter omitted or false retains every ordinarily accessible row, while true is empty.
  Dedicated rows additionally fence writes from an Agent whose identifier differs; reads and
  Humans pass that fence. Every Agent-created Workspace is create-frozen under the authenticated
  Agent's identifier, while every Human-created Workspace has a null tag; creation exposes no
  dedication selector. Tags are repeatable, and the only `agent_identifier` uniqueness is one
  Agent/User per
  `(account_id, agent_identifier)`. An instance already stewarded by another Human refuses
  authorization; signing in never transfers ownership or creates another Agent for that key.
  Public Workspace surfaces expose only the boolean
  non-identifying dedication marker and current-Agent predicate, never the exact product-code
  tag. Only the active Human owner manages, and an Agent never inherits management. Authorization
  resolves current membership/steward/Workspace state at request time; scoped finders are the
  default enforcement (`.ai/api.md`). A future Human-only WorkspaceAccess sharing row is additive
  and must not replace the non-tombstoned owner's current management authority.
- Workspace messaging policy belongs to each recipient Agent, separate from data access.
  An Agent is `public` by default and accepts contact from every otherwise eligible Agent.
  A `private` Agent accepts contact only from its allowed senders and itself; self-contact is
  always allowed. An explicit `public` setting retains its saved sender list but ignores it
  for admission. For A to contact B, only B's setting applies; A's setting controls who may
  contact A. Paired and named Agents retain their own public identities even when one program's
  bearer serves them. Only the active Human Workspace owner replaces this policy, using the
  Workspace's `lock_version`; members with
  Workspace data access may read it. The policy governs new `send` and `spawn` requests from a
  run's answering Agent to the resolved recipient. It does not change ordinary Human/member
  inputs, Conversation standing, `status`, `cancel`, or history access. Previously accepted inputs
  continue, and kernel result mail requires no reverse permission. It is collaboration control,
  not data isolation, and grants no authority that the existing access predicates deny.
- Conversation access: under the Workspace's access, every conversation carries one default
  level for every principal its entries
  do not name — `full | read | none`, born `full` — and one entry per named principal, of either
  kind, no groups. The creator and the answerer are `full` BY DERIVATION, never rows; there is no
  owner carve-out and no system-user carve-out (the workspace's owner is nobody special on a
  conversation it is not listed on). `none` CONCEALS: to that principal the conversation is absent
  on every member-plane door — the lists, the document, its turns, events and cable, its inputs,
  store, memory, forks, the replay of its receipts, and every route of a run one of its turns
  hosts — exactly as a tombstone is, never a 403 that admits the row exists. `read` READS: every
  read answers and every write is refused `not_authorized` by name; `full` is what write standing
  has always meant, conjoined with the workspace's. One read funnel (`Conversation.readable_by`)
  and one write predicate (`writable_by?` on Workspace, Conversation and Run) carry the rule;
  a door finds the row through the funnel and then judges standing, so concealment always comes
  before refusal. The carrier is set at create and REPLACED WHOLE by `PUT …/access` under the
  Windows rule — full control includes changing permissions: `full` on the row with workspace
  write standing, a `read` principal can never escalate itself — with the actor's KIND recorded on
  the narrated fact; a fork and a side copy the rows at the fork instant and materialize the
  source's derived-full principals. The rule is the MEMBER PLANE's alone: the kernel's own acts
  never consult it — the answerer's engine writes its turns and a task's receipt lands as kernel
  mail whatever the run's creator holds, and a spawned child's reply is relayed the same way,
  AUTHORED AS THAT MAIL IS (the originating request run's creator, `origin: child`, the child's
  identity a stamp beside the text — never the child's answerer: the kernel relays its own receipt and
  impersonates nobody) — and "kernel" is the kernel's own act, named by
  `Input::KERNEL_ORIGINS`, never a property of `origin` presence. The principals a
  carrier may name are the members with access to the workspace, listed by
  `GET …/workspaces/{id}/principals` — the member plane's one user listing, which prints a USER's
  own non-secret registration identifier beside its steward, never a workspace's
  dedication tag.
- Executor binding is a correctness boundary: an executor (the `Executor` row) lists, claims,
  and reports only the inbox tasks addressed to it — a Runner receives calls accepted for its
  concrete target UUID; a tool provider may also claim calls addressed to its role within
  a workspace. This isolation exists to prevent work stealing and double
  execution, and survives regardless of trust-domain shape. The executor is a delivery address,
  not a principal: each inbox task names its own execution principal (the Agent the
  work runs as) and the executor credential proves only the address. A named Agent may use
  its declarer's application transport while both remain active under the same Human steward;
  this shares no identity, memory or announced skill documents. Its removal or steward transfer
  ends new shared serving without revoking that declarer's credential. Agent removal
  synchronously fences member access and its agent transport, retaining the address,
  then asynchronously force-stops related work (Administration Boundary below). Its independent
  Runner is unaffected. Human removal additionally owns the existing
  managed-resource shutdown generation protocol; becoming a removed Agent also applies
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
  executor-transport credential is bound to one executor — an agent, a runner, or a
  tool provider — and reaches only that executor's transport and execution resources
  (inbox, claims, commits, captures, progress and Cable)
  and nothing on the member plane; none of the three roles gains member or Platform authority
  from that binding. An application may also announce the runner role on its existing
  agent address, sharing that address's transport credential and inbox while
  retaining role-qualified task dispatch. Its member bearer never reaches the inbox.
  A client-side generic HTTP primitive
  can never widen these server-owned planes.

## Threat-Model And Portability Gate

These rules apply to design, implementation and review in every project:

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

## Rejected Design Shapes

These shapes require correction at their owning boundary:

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
- **Speculative state machines:** no table, status, lock rank, wake, sweep, recovery run, or reader
  abstraction lands without a reachable writer, a reachable product/operator consumer, a concrete
  failure it recovers, and tests for that behavior in the same change.
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

- Agent business data persists through Nexus wherever possible. File-style memory tools address
  database rows; opaque recovery, routing and delivery state uses scoped stores; artifacts use
  uploads. Local filesystem work belongs to the Runner, including rho's Local environment.
  Bootstrap credentials/configuration and disposable caches are distinct from durable business
  state. Repair storage gaps at their existing owner rather than adding an Agent-local store.
  Agent program source, extension packages, installed versions and assembly configuration remain
  local to the agent installation; the operator chooses how to back them up. Nexus persists user
  documents, conversation/execution records and business data, not the composition of rho or
  another agent. Do not add package-retention or installation state to scoped stores.
- Automatic work derived from restricted content must not silently widen its audience. Choose
  an existing carrier with the required source ownership and access before copying the content;
  check persisted prompts, results and their read surfaces, not only the final displayed value.
  A title, summary or background helper has no authority to publish a broader copy merely because
  its caller can read the source. Intentional sharing follows its owning product contract;
  existing fork/Side snapshot access semantics remain unchanged.
- Nexus is a complete, orthogonal kernel for coding, Cowork, personal, chat and role-play agents.
  Its primitives are Conversation, the standalone Run, and InferenceRequest. Conversation is the
  person's unit; a run drives a turn or runs standalone for workflows/background work.
  Capabilities composed from these primitives need a direct kernel surface only when common.
  The kernel owns general mechanisms: compaction with an overridable default summarizer, memory,
  messaging, prompt assembly, approval, scoped stores, task delivery, orchestration, persistence,
  catalog resolution, usage, audit and recovery. Kernel details live in `nexus.md`.
- Agents own prompt meaning, model selection/routing, tiers, UI semantics,
  orchestration strategy, approval policy, memory extraction/ranking and commercial policy.
  The kernel resolves a declared model reference to a provider lane; it ships no model selector.
  It compiles raw/assembly/default prompts and durable prompt documents without interpreting
  persona meaning or owning product features such as lorebooks or depth injection. Approval
  reads opaque `tool_input` through agent-authored rules; the kernel never learns what `bash`
  means. Cross-conversation messaging uses conversation inputs (`delivery_mode: queue|steer|steer_now`),
  and delegation spawns child conversations. `origin` is testimony (`person|agent|task_result|child`),
  not authority; only `task_result` and `child` identify kernel-owned mail acts. Side conversations
  use the kernel's fork/boundary/shared-prefix mechanism; one-open-side limits, idle TTL and
  instruction text are application policy.
- Three executor roles are agent, runner, and tool provider. An application address
  may serve both agent and runner roles through one transport credential and inbox.
  Independent runners and tool providers have their own addresses. A runner supplies environment-bound tools and may run
  separately in a container or the cloud. A tool provider supplies external tools and may
  override kernel tools by name under the Workspace's explicit opt-in. An Agent playing the
  runner role announces that service on its application address; it never lends its member bearer to transport.
  A runner may serve multiple Agents within its assignment scope because each task freezes
  its own execution principal separately from its destination. Tool processes, files and working
  directories are executor-local state.
- Any Agent application may implement its own Runner service through the public executor
  protocol, in any language. Neither rho nor `rho-env` is a Nexus dependency or required
  implementation. `Rho::Env` and `Daemon#mount_runner` are rho's library and composition
  choices. `Rho::Env` is the library namespace and `Rho::Env::Executor` owns execution.
  rho is one complete application with no runtime mode selector or independent Runner identity.
  There is no separately deployable first-party Runner application. Keep protocol capability,
  library reuse and deployment entry points distinct when documenting or explaining them.
- Nexus is the gateway. Components poll its HTTP API over outbound connections; Action Cable
  and presence are latency hints, never correctness dependencies. Live lifecycle, credentials
  and ACLs still gate admission. Every role uses the same asynchronous task inbox: exclusive
  claim with a rotated token, the task's deadline as its clock, bounded/narrated extension by
  its claimant, and a write-once committed result. Tools and delegated kernel work such as
  compaction use this same protocol. Runner tasks use their accepted target; tool-provider
  tasks may address a role within a Workspace when no executor is named. Cable is executor-keyed.
  Announcements let the kernel address work and, at acceptance, import the selected Runner's
  exact model tools through the Agent's declared sources. Accepted declarations stay frozen;
  later announcements do not reshape them (the empty skill-catalog exception is defined in
  `nexus.md`).
- Executor surfaces use the same outbound topology. A capture is published through
  `POST /agent_api/v1/executor/uploads`, named by `resource_link` in a committed result and bound
  by that result. Member and executor upload doors share `UploadIngest`; a creator is
  exactly one member or executor. The member bytes route (`GET /agent_api/v1/uploads/{id}/bytes`)
  uses `ContentUpload#readable_by?`: creator access or access through a readable referring row.
  An addressed operator call is a one-task standalone Run seeded with an explicitly routed
  tool step and uses ordinary claim,
  extension, commit and recovery. Task-attached realtime signaling may exchange bounded WebRTC
  descriptions and project current interaction permission for that exact claim; it grants no work.
  A handler owns its direct/TURN data transport under the original Task, deadline and Stop path.
  Authorization-window expiry pauses input/media without canceling, extending or releasing execution.
  A connected viewer may observe the Runner's remaining window over that same bound peer;
  it anchors expiry before its probe, so relaying cannot extend authority. The Runner still
  checks both original credentials and the existing execution owners through Nexus.
  Nexus never dials into the Runner or carries continuous input/media through Rails/Cable.
  Runner capabilities such as `files_bytes`/`process_log` are announced as tools without model
  descriptions/schemas and hidden by name from model declarations. File bytes are always a
  capture, with HTTP Range for partial reads. Human process-log reads and model owner-gated
  `read_process` have distinct semantics. Announcements carry environment metadata; progress
  uses the executor progress door and host feed. No separate `environment` relay tool.
- Missed cancellation is recovered by reading the exact existing claim with its original
  `Claim-Token` (`guides/reference/agent-api/executor-inbox.md`). The read proves the claimant/token and projects
  dispatched state; it neither grants nor renews work. Inbox absence, pause, current default
  and new-admission eligibility do not revoke existing claims. The Runner checks on its
  existing control wait, cancelling only the original context on inactive, missing or
  `not_claimant`. Unknown failures preserve the live execution and original deadline;
  startup admission is returned only by the actual worker yielding or exiting, independently
  of a control request's outcome. No additional lease, cancellation marker or second
  claim registry is needed.
- Executor-local deadline handling is best effort while finite-timeout control HTTP or
  credential refresh is in flight. The request timeout may exceed remaining task time; after
  it returns or times out, resume the existing cancellation/deadline path without extending
  the task. Do not add a whole-probe deadline, watchdog, worker pool or interruption of
  credential wire-and-persist to align independent budgets. Nexus claim fencing, expiry and
  result integrity remain authoritative.
- Five tool sources share one provenance model: Nexus, runner, tool provider, agent and MCP connection. Each
  tool resolves to one authority whose provider identity survives on the wire. An Agent may
  declare an alias and parameter map for a kernel tool; canonical names, reserved namespaces
  and routing stay unchanged. The call arrives under the alias and runs under the canonical.
- An MCP connection is a Human-owned external account, never an Executor or model Provider.
  Only its owner manages it; administrator status grants no takeover. Its owner's active
  Agents use the connection through their current steward relationship, without per-Agent
  grants or a connection-level tool allowlist. The execution's frozen declaration selects tools.
  The connection UUID and remote tool name bind every call; an unavailable connection never
  falls back to another source. Nexus holds write-only encrypted credentials and performs
  bounded HTTP IO through the existing ToolTask approval, deadline and settlement owners.
  Owner removal disables connections; restore does not enable them. Agent steward changes
  change its directory and block new starts on the previous owner's captured connections;
  shared application transports do not substitute for that ownership relationship.
  Native remote OAuth belongs to this same connection: Nexus owns browser callback state,
  exchange and refresh; the Human authorizes it through personal settings. It never issues
  a Nexus principal or copies the remote grant into an SDK, Runner or Agent declaration.
- A Run can target multiple Runners. Runner tool declarations carry a concrete Runner UUID
  and served tool name separately from the callable name/schema. An authored Runner step may
  omit its target and resolve the host's nullable default once at acceptance. The target then
  remains fixed across waits, approval, retry and claim generations.
- `InputHost#set_default_runner` changes `default_runner_executor_id` for future acceptance
  and narrates `default_runner_changed`; it never moves accepted tasks or external state.
  Runner effects preserve each Runner's earliest claimed write independently. Restore requests
  target those original Runners and report partial results. Process progress uses the source
  task's claimant/token, never the current host default.
- No layer interprets another layer's business payload beyond an explicitly versioned generic
  contract. Public APIs expose task/timeline/capture projections, not scheduler lanes, STI names,
  countdowns or generations. Only tasks write the run graph; clients may read its nodes and
  edges as task keys/Mermaid for debugging and UI projection.
- Workspace is the mandatory container for conversations, runs and InferenceRequests. Ownership, access
  and dedication are defined in Trust Domain above.

## Administration Boundary

- Nexus deployment administration covers Nexus and its own worker processes only.
  Agent releases, installation state and lifecycle remain owned by each
  application's installer or the enclosing deployment tools. A combined installation
  does not authorize Nexus to manage those applications; generic image lists or a private
  IPC bridge do not change that ownership. Joint upgrades belong to the installation layer.
- Administrators operate the Account; they do not act as custodians of how members use Nexus.
  Administrative scope is account-global settings, Human user management, aggregate statistics
  and operational monitoring, and any current or future executor kind whose owning contract
  explicitly makes it account-global. One narrow billing-policy exception is explicit: owner/admin
  Humans may issue and adjust any Human's virtual Account-unit usage balance, including their own,
  and inspect its amount-only ledger/headroom. That authority exposes no content, Workspace, provider trace, or
  per-Agent activity, and it does not authorize an administrator to manage the Human's Agent
  allowances. If resolving/reversing one Human charge must mechanically correct the paired Agent
  allowance entry, the billing service derives and applies that hidden second effect atomically;
  the administrator supplies no Agent selector and receives no Agent identity or detail, so this is
  not an independent Agent-allowance command.
- `executor_kind` is registration identity; `services` is a whole-address map of announced
  roles. An `agent` address always provides `agent` and may also provide
  `runner`. A `runner` registration provides only `runner`; a `tool_provider` provides only
  `tool_provider`. Each role owns its tools, documents and environment, so the same tool name
  may have different schemas and effect profiles under different roles. Dispatch and claim
  resolve `(executor, role, tool_name)`; a role's tools never satisfy another role's claim.
- An application's Runner capability uses its existing UUID, epoch, transport credentials,
  inbox, presence and lifecycle. Its owning Agent and eligible named Agents use it through
  `application_owner` while retaining their own execution principals. Another application under
  the same Human is ineligible. Local is product policy resolved to a concrete application UUID
  before acceptance, never a kernel address kind or a magic target. Withdrawing `services.runner`
  closes new admission without rotating credentials or preventing an already claimed task from
  settling on its original transport. Re-pair, removal, revocation and shutdown retain their
  existing epoch and authority semantics for the whole address.
- Every independent Runner or Tool provider has one Human manager. Its logical registration key
  is `(account_id, manager_id, registration_identifier)` and is kind-blind across the two machine
  kinds. `assignment_scope` is `user_private | account_wide`, frozen at creation and separate
  from registration identity. `user_private` admits the manager and Agents they steward;
  `account_wide` admits eligible Account principals. An ordinary Human gets `user_private`;
  an owner/admin may choose `account_wide` on a fresh registration through a default-unchecked
  browser control. Re-pair preserves the stored scope and kind, advances the epoch and keeps
  the address. A different requested kind is refused. Terminal revocation permits a later
  fresh registration with a new UUID. Only the current manager controls the machine; administrator
  status supplies no takeover or emergency bypass. No scope-change or manager-transfer command
  exists. A copied bearer identifies authority, not a distinguishable physical process.
- Agent and machine connection claims are disjoint. There is no combined registration or
  application-assigned private machine. Old private registrations are terminally revoked during
  the cutover, retaining UUIDs and task/effect history; they are never widened to shared scope.
  Old combined or assignment-selecting pending grants are invalidated. Independent machine
  registrations and named-Agent `application_owner` relationships remain unchanged.
- Human managed-resource shutdown is a durable generation protocol, not a status-only sweep.
  Human Users advance `managed_resource_shutdown_generation` only when removal is accepted.
  Stewarded Agents record `applied_steward_shutdown_generation`, and Executors record
  `applied_human_shutdown_generation` for their controlling steward/manager. A mismatch is a
  level-triggered pending shutdown that survives Human restore. Agent convergence removes and
  authority-fences the Agent before acknowledging its generation, applying the Agent removal
  consequence below. Other managed executors retain exact bound transport for safe task/result/
  capture reconciliation, then fence the epoch before acknowledging. Human restore changes none
  of these applied generations; the Agent consequence does not replace this Human protocol.
- Administrator commands for a specific Agent User are limited to steward reassignment and the
  remove/restore lifecycle. Removal synchronously fences member/data access through status and
  `authority_generation`, and revokes the Agent's credentials through its existing
  executor credential epoch. The address stays active and is not rebound; an independent Runner's
  address and lineage are untouched. Related Conversations and live runs are force-stopped
  asynchronously; status lag and eventual task timeout are accepted.
  Related work includes the Agent as creator, the Conversation's default answerer, its current
  turn's initiator or answerer, the related spawned descendants, and its still-live
  historical/background runs. Historical participation alone
  does not authorize stopping somebody else's current turn. Cleanup reads current removed state,
  skips restored Agents, and has a bounded recurring floor for lost wakes. Restore does not wait
  for cleanup or revive old credentials. Do not add a task-withdrawal marker, removal episode,
  generation counter or restore barrier to delay this immediate authority cut.
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

## Contract Propagation

- A change to principal selection, assignment scope, defaults or lifecycle ownership reaches its
  executable consumers in the same change. Trace ordinary entry points, including creation with
  and without an initial input, later inputs, delegation and background continuation. Inspect
  implicit defaults and preflight work as well as the final request: the submitting principal's
  discovery scope is not necessarily the execution principal's authority. Reuse the owning
  selection and authorization mechanisms rather than reproducing them in each adapter.
- Replacing or retiring a mechanism updates its current normative consumers in the same change:
  public documentation, `.ai/**`, `AGENTS.md`, tests and checked-in contract data. Code alone is
  insufficient when another current document still requires the old mechanism.
- Record the affected files and rationale in the change so later searches can find the complete
  target set. Instructions retain the resulting rules and their reasons, with no dependency on
  a separate development history or private record.

## Design Expansion Gate

- Use the smallest set of domain entities and boundaries already present in or explicitly required
  by the accepted design that can satisfy written, reachable product behavior. A distinct fact,
  state, or code path does not by itself justify another entity.
- Prefer existing owners and framework mechanisms, then conventional mechanisms from mature
  products designated as references for the task. Verify their actual behavior and applicability
  boundaries from relevant source or authoritative documentation before adopting them; do not
  infer their internals from an API shape or mechanically copy that API.
- Before adding a mechanism, argue against its necessity: explain why omitting it, reusing an
  existing mechanism, or using a mature conventional implementation still cannot satisfy the
  concrete, reachable requirement. Name the necessary semantic difference, its actual or explicitly
  required product/operator consumer, and a distinguishing test; compare the smallest alternatives
  and their runtime, persistence and maintenance costs. Without a supported semantic difference,
  do not introduce the mechanism; merge or remove redundancy while preserving accepted behavior.
- Do not invent stronger requirements such as automatic recovery or future extensibility to prove
  a mechanism necessary. A problem introduced by a proposed mechanism does not justify adding
  another mechanism to repair it; reconsider the originating design first. Keep this reasoning
  within this gate and the owning change, without a new workflow, ledger or CI requirement.
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
- One implementation per mechanism: two implementations of one mechanism
  — a map, a queue, a serializer, a result type, a guard — are unified whenever they can be; a
  second copy survives only on a recorded, explicit semantic difference, never on lane, history,
  or convenience.

## Breaking Changes to In-Flight and Historical State

Rails migrations own schema and data shape; do not build
state-machine migration machinery on top of them. When a code change breaks the meaning of
durable orchestration or execution state, the handling lives in business logic as graceful
degradation:

- **Unfinished work is regenerated, not migrated.** An in-flight task, run, or invocation whose
  durable state no longer matches the current machine is failed closed and re-created/retried
  under the new shape through its ordinary retry lineage or run re-planning —
  never patched in place to "resume" across the break.
- **Historical records are rendered tolerantly, never crashed on.** Display and read surfaces
  skip or degrade unknown/incompatible content in old rows (a placeholder, an omitted section)
  instead of raising; history is capture, and capture stays readable across versions.
- Keeping this cheap is a design constraint, not an accident: orchestration state stays small,
  short-lived, and enumerable, so "fail closed and regenerate" is always affordable; the durable
  conversation/capture stratum stays structurally boring so it never needs rewriting.

## No Compatibility Before Release, And What Is Not Dead Code

- **Before the product ships, compatibility is never a reason to keep anything.** No shims, no
  transitional vocabularies, no "accept both spellings for one release", no version gates between
  our own components. A refactor lands whole: writers, readers, clients, tests, docs and the
  removal of whatever the old shape needed. Schema changes follow the same reset policy in
  `database.md`. Where a rolling step is genuinely unavoidable inside one change, it
  is a step within that change and never a committed resting state.
- **An UNWIRED PUBLIC CAPABILITY is not dead code, and must not be swept as one.** A service,
  route, command or declared field that is complete and reachable by design but has no caller yet
  is owed a caller, not a deletion — the kernel deliberately ships ahead of its clients, so
  "nothing calls it" is the normal early state of a public surface rather than evidence against
  it. A public capability may precede its UI or SDK consumer. Dead code is internal:
  a predicate, constant, branch or helper with no reader that no public surface promises.
  When in doubt, ask whether anything outside this repository could reasonably be expected to
  reach it; if yes, it is unwired, and the finding is a missing caller.

## The Human Console And The Gateway

`/agent_api/v1` serves Agent work, including model discovery and execution. `/api/v1` serves
Human personal and system settings; `/api/v1/admin` additionally requires a live Human
owner/admin. Personal settings do not require that role. Nexus's Rails UI owns Account and
member-resource management and the Human work console. Its work pages browse readable
Conversations and Runs, inspect execution, export diagnostics, and invoke existing authorized
Run/Task commands. They use the Human's browser Session and CSRF protection and share the
member plane's domain queries, readers and commands; they never borrow an Agent credential or
put content operations into the settings API. Agents retain their conversation
product experience, prompt meaning and configuration policy. The Human console inspects
Agent declarations. Applications own configuration editors, Presets and standing
declaration writes; Nexus validates generic declarations and captures execution values.
An application's inline execution declaration remains separate from the Agent's standing
default. `cmctl` consumes the Human settings capabilities. These responsibilities do not
alter the credential planes defined in Trust Domain.

The four primary entries are Overview, Connect an Agent, Agents and Workspaces. Work lists
are Workspace-scoped; details keep their canonical URLs. Agents and Runners share management
layout conventions while retaining their distinct identity, credential and lifecycle owners.
Independent Runner connection guidance uses Device Flow and the machine registration scope selector.
Runner-related Runs live under `/runners/:public_id/runs`, fixed to the managed address and
filtered by current content visibility and retained Task targets/claimants. `/attention/runs`
fixes the existing non-null attention-reason query. There is no global HTML `/runs` collection;
canonical Run details and the Agent API global query remain available. Session work
commands cover resource management and recovery: cancellation, cost limits, Run lifecycle,
Task decisions/retries/compaction, and Schedule pause/resume/cancel/run-now. Conversation
creation, ordinary input and steer authoring, regeneration, candidate activation, branching,
Schedule authoring and upload staging belong to application/SDK clients of the Agent API.
Session attachment downloads and previews remain available.

Overview uses one exact rolling seven-day receipt window for readable Conversation usage,
with known costs and incomplete cost evidence preserved. Its short attention list uses the
existing actionable Task query. Resource counts do not claim connection or execution success.

Workspace work views and retained secondary reports use the same current Workspace and Conversation
read permissions. Administrator, steward and Workspace-owner roles grant no content bypass.
Work statistics count only that readable set; conversation-attributed usage additionally
requires a currently readable, retained Conversation. Permanent receipts never restore lost
content access, and conversation usage is not a person's bill or a total for standalone Runs.
Current state counts remain distinct from time-windowed historical activity. Work and Agent reports
and the administration usage page show fixed rolling seven-day summaries. Download
parameters select the file only; programmatic report and analysis APIs retain their filters.
Content-scoped downloads export readable Conversation receipts and retained Run diagnostics;
administration downloads expose only Account aggregates. Workspace data exports preserve
ordinary Memory override and scope rules. Exports stream existing retained records with
explicit missing-material and completion markers, without another persistence lifecycle. Administration
usage reports provide Account aggregates and provider/model/workload/status filters, never
member, payer, billing-subject or Workspace activity selectors.

Agents may use long-lived API keys issued by their Human steward through personal
settings. Keys retain the existing member or executor-transport plane, User authority generation
and executor epoch. Each key is independently revocable, has no refresh lineage or expiry, and
fails authentication on the next request after revocation. An Agent can hold member authority
without an application address; issuing its first application transport key creates that address.
Named Agents never obtain their own key or address. Local runner capability uses the
application address and its transport keys; independent machines keep their own registration. Whole-connection revocation and OAuth replacement
also fence existing static member keys; ordinary single-key revocation does not replace the
connection or revoke its other keys.

rho uses Nexus application OAuth for Human login. Initial application connection may use OAuth
or explicitly imported API keys. Imported member and executor keys are checked
against the existing profile and executor self-descriptions before installation. Their opaque
registration identifiers stay with the connection so later Human login selects that same Agent
without re-pairing its runtime. Static keys use the existing credential stores and connection
publication order and do not schedule refresh. The daemon
keeps each browser's Human platform credential and refresh lineage separate from the Agent member
and executor vaults. Its settings proxy presents that browser's Human credential; Nexus evaluates
current Human status and administrator authority. Conversation work still uses the Agent plane.
GUI and CLI settings share their owner and take effect immediately where live replacement is
supported. An extension with exclusive process-wide state explicitly requires a restart for
replacement or removal; a refused preparation retains the running instance. Existing run snapshots stay
captured; incompatible later tool calls use ordinary tool failure without run migration
or compatibility copies. Local configuration format/schema versions are separate from
run snapshots: plugin-owned migration hooks update their versioned configuration, while
the core settings reader accepts only its current format. Old pre-release core settings
and identity state are rebuilt explicitly, without compatibility readers or automatic conversion. Core and plugin settings share
`<RHO_HOME>/settings.json` and its existing serialized writer; new plugin private runtime
data uses `<RHO_HOME>/plugins/<id>/`, while existing credential stores retain their
owned directories within the same home. Static descriptors expose disabled plugins
without executing them. Every non-core contribution can be disabled while authenticated
management and CLI recovery remain available. Forms save explicit field changes,
preserve untouched overrides and secret values, and report saved versus active state.

Personal joint installations start at rho's public Connect page. Nexus first boot creates and
signs in the owner, then resumes the original validated authorization request. Approval binds the
Agent and its application Executor and returns to rho. Optional Local runner capability is
announced on that same address. Device Flow provides the equivalent
headless/browser-code path. Pairing does not wait for model configuration. The installer supplies
no first-boot secret by default: a visitor who can reach the uninitialized deployment may create
the first owner directly. An operator may explicitly configure `NEXUS_SETUP_SECRET` to require
that secret for first-owner creation; it stays private and never reaches the public rho page.
There is no deployment helper automatically approving a connection. Pairing is one thing and the
page's gate is another: once rho is paired, `webui_access` decides what a browser needs before it
may use rho — `open` (nothing), `password` (rho's own unlock password, a salted digest in
`<RHO_HOME>/webui_password.json`) or `nexus` (a Nexus sign-in); unset, the gate is open on a
loopback bind and asks for Nexus elsewhere. The gate admits a browser to rho's Agent plane only;
a Nexus sign-in is accepted in every mode and is what the Human plane needs (How A Browser Gets
rho's Bearer, below). rho stays a single-owner application: an unlock is the owner's.
Setup progress is projected from saved configuration and live credentials, never a second
onboarding lifecycle. Later login to an already connected instance issues only Human authority
and must not rotate the running Agent or Runner's credential epoch. Logging out does not transfer
instance ownership or disconnect its independently running Agent.

Agent model discovery returns the Account's configured, usable models with no per-Agent model
ACL. Human/admin Platform discovery includes unavailable definitions and diagnostic reasons.
Hiding a model preserves definition/pricing while removing it from Agent discovery and refusing
new calls. Model choice remains application policy.

An executor's own process may read its local surface directly. rho's file-bytes route and
`Processes.list` / `Processes.log` choose a local read for its own runner and a Nexus request for
a remote runner. Explicit `Ops.call_tool` always uses Nexus, including for its own runner, so the
kernel's approval stage judges every relayed command. Remote `files_bytes` returns a capture
fetched on the member plane. `rho call_tool`, `fetch`, `ps` and `logs` expose these operations;
operator-facing tools hidden from model declarations do not require a Human credential.

`agents/rho/rho-webui/webui/` ships plain ES modules/CSS through `register_webui(root:)`.
Only committed extensions contribute a page; two page owners refuse startup. rho owns generic
static serving and authentication. `Config#webui_root` (`settings.json` / `RHO_WEBUI_ROOT`) is
the override seam for alternative bundles. Non-fingerprinted files stay at the root; only
fingerprinted assets belong under the year-long immutable `assets/` cache prefix. Any other
running extension may contribute one browser module through `register_webui_module(root:)`: the
page's static server mounts that directory under the reserved `modules/<id>/<key>/` prefix with
`no-cache` only while the extension runs and a page is served, and its `/extensions` row names
the entry as `capabilities.webui`. The key is derived from the installed directory, so another
installed version is another URL. Module code is trusted installed code running same-origin with
the page's bearer; there is no sandbox, and the module list stays behind the bearer like the rest
of `/extensions`.

### How A Browser Gets rho's Bearer

`GET /` contains no credential and is public to every process that can reach the port. A
browser obtains its distinct opaque local bearer in one of two ways. A Nexus sign-in: the
browser starts Nexus OAuth with a per-attempt state, PKCE S256 challenge and local completion
secret; only the browser that started the login can finish its callback; Device Flow uses the
same Human authorization and local session owner; the resulting session is a Human's, verified
against Nexus on every request. Or the gate (`POST /auth/unlock`): under `webui_access: open`
by itself, under `password` with rho's unlock password, never under `nexus` and never before
rho is paired; the resulting unlock session holds no Human credential and is admitted while its
access mode and password generation match the current gate. An authenticated browser that changes
the gate to `open` or `password` keeps its bearer under the newly published mode; other unlock
sessions remain bound to their previous mode. Changing the gate to `nexus` requires every unlock
session, including the browser making the change, to sign in with Nexus. An unlock is refused on
the Platform proxy with `human_login_required`. The daemon's private announcement remains the operator CLI's
local control authority, never a public browser login credential.

- The page stores its local bearer and pending login state in `sessionStorage`, never
  `localStorage`, cookies or a `window` property. Nexus credentials stay in rho's private state
  files, not served HTML or resource URLs. Callback query material is removed before ordinary
  rendering. Streaming uses `fetch` and `ReadableStream` to carry Authorization.
- Browser control requests on a Human session verify live Human authority through Nexus; on an
  unlock session they verify the gate as it stands now. The Platform proxy uses a Human session's
  platform credential; neither the Agent credential, the local operator bearer nor an unlock
  alone grants Human administration. An operator CLI uses its independently saved Human
  OAuth login through the same proxy; a local announcement alone never supplies that login. Logout revokes that Human lineage without revoking the runtime's
  separate Agent or Runner lineage.
- Default OAuth callbacks trust loopback, `localhost`, private IPv4 and IPv6 unique-local addresses:
  HTTP/HTTPS `/auth/callback` on any valid port, without userinfo, query or fragment. An explicit
  deployment callback list replaces that default; other HTTP destinations require an explicit
  transport exception. Preserve PKCE, state and exact authorization-to-exchange callback binding.
  LAN HTTP provides no transport encryption. Internal Nexus service URLs and browser-visible
  Nexus/rho origins are separately configured.
- Do not add CORS or an OPTIONS handler. Browser requests use rho's same-origin control API;
  Nexus browser authorization uses navigation, not a cross-origin credential proxy.

## Async Execution Ownership

Application-launched helper work also has an explicit existing lifecycle owner. Follow its
accepted input or task through execution, publication and the cleanup promised by its contract,
including failure, cancellation and application shutdown. Keep the original source and recipient
when the visible conversation or current Bot changes. Reuse existing input, receipt, Stop and
discard paths; do not infer cancellation from archive, selection changes or natural completion,
or add a parallel lifecycle merely to coordinate a helper.

An execution belongs to its original run/variant/turn, even when its result starts
a supplementary reply. Conversation-lifetime background results use the existing
mail/input queue after the original reply is final, including fast results;
launch-time waits and turn-lifetime obligations keep their current-turn synthesis.
Conversation Stop cuts all its existing execution owners. Changed activation or
successful regeneration cuts the replaced variant's owner. The cut includes
undelivered callbacks and already-started supplementary replies, follows exact
sender run/task ownership into child requests, and does not stop later
independent requests merely because they reuse that child conversation. A
write-once `Run.stopped_at` preserves this existing Stop fact after terminal
completion. Viewing or reselecting an old candidate never revives work. Published
content and completed external effects remain; natural completion and new user
input do not cancel background work.

Already-arrived independent worker finals may be
consumed together when their original requester and execution/memory policy
match. The receiving conversation owns that combined reply after consumption;
stopping one source afterward neither retracts its read result nor stops the
combined reply. Before consumption, every source retains its Stop fence. The
turn retains immutable per-receipt result pointers rather than assigning the
whole reply to its last source. A reply to one worker result and ordinary
task/tool receipts retain the preceding ownership rules. A combined
report stays in its receiving conversation; each worker's explicit external
delivery exports only its own fixed formal result and changes only that
worker's future destination.

## Awareness Versus Obligation

Two signal primitives, never conflated:

- Awareness: Notification rows fanned out to subscribed/mentioned principals (mutable read state,
  mutable subscriptions, server-side filtering before any agent wake). An agent may ignore
  awareness; the notification inbox is never a second delivery queue.
- Obligation: an inbox task addressed to an executor, with a claim, a deadline, and a write-once
  result. Only obligation carries execution semantics. Product policy may escalate awareness into
  obligation (a direct ask becomes an addressed task); the kernel does not do this implicitly.

## Mutation Topology

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
   future-work-only rule. Steward transfer follows the existing authority lane: lock the Agent first, then the source and target Humans in deterministic order, then its dependent
   Executor address. A future Runner-manager transfer follows the Human-before-Executor
   credential lane because the Runner is itself the managed Executor. If source removal won
   first and either the Agent or executor still has an unapplied shutdown generation, transfer
   returns `shutdown_pending` without rebinding; transfer that wins first freezes the target
   Human's current generation on each rebound resource.

A new model earns a place in shape 2 or 3 only with a written reason; the default is shape 1.

**Lifecycle verbs are rare, and their cost is paid at the authority edge plus convergence.**
Connect, disconnect, revoke, remove, restore,
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
  report a safe terminal fact except when an Agent becomes removed: Agent removal
  immediately fences that application's credentials and force-stops its related work
  asynchronously.
- **The rest is asynchronous convergence, in bounded batches.** Marker propagation, reaping, and
  cascade cleanup run as recurring jobs over bounded continuations — restartable, never a
  full-table drain, never blocking an API response, never interfering with other users or other
  business. Human remove/erase first stops admission, then cancels queued inbox tasks and asks
  running work to stop at data-safe checkpoints, then fences dependent transports only after
  every inbox task has reached a truthful terminal/capture state, with the Agent removal
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
- All `public_id` columns use PostgreSQL `uuid` with sortable UUIDv7 values: PostgreSQL 18+
  `uuidv7()` defaults, PostgreSQL 17 `pg_uuidv7` extension `uuid_generate_v7()` defaults,
  or Ruby `SecureRandom.uuid_v7`. Migrations and schema loads enable the extension only on
  PostgreSQL 17; primary schema dumps remain loadable on either server version.
- Use `attr_readonly` for persisted identity fields that are mutable during creation but immutable
  afterward: owner FKs, stable external keys, STI scope keys, `public_id`, short technical tags.

## Package Boundaries

- Top-level projects are independently buildable/testable unless a change crosses them. Bundled
  projects own toolchain files and explicit root CI jobs.
- Shared protocol changes reach every affected owner: kernel, SDK, operator tooling and E2E.
  `nexus/app/**` never depends on concrete agent constants.
- Development/test placement and the one-way dependency from tests into production are defined
  in `repository.md`, Development And Test Placement. A test consumer does not make production
  behavior test-only, and deployment conveniences remain product capabilities.
- Remove declarations, wire revisions, source pins and capture fingerprints that serve only
  development-work bookkeeping. A runtime protocol version needs independently deployed product
  consumers choosing/refusing behavior and an executable compatibility test at that boundary.
- The Ruby SDK's synchronous client (httpx, resources, credentials) loads without the framework reactor;
  realtime error types load without `async-websocket`.
- TypeScript HTTP imports do not load the optional realtime adapter; Rust HTTP works without
  its realtime feature. All SDKs retain the same Member, Executor and Platform authority planes,
  while using their language's native async, typing and resource ownership conventions.
- Credential ceremonies mask interrupts across wire-and-persist and reopen delivery at blocking
  waits. A kill lands before spending authority or after persisting the answer, never between.

## E2E Boundaries

- E2E may inspect kernel/agent databases or processes for internal observability only — to explain
  what happened, never to create the success condition. Control/use actions and externally visible
  assertions go through public APIs, not direct service calls or synthetic result injection.


Protocol E2E under `e2e/protocol` uses the SDK and deterministic fake Agent/Runner
fixtures, with its own dependency closure. It must run without `agents/rho/**`.
Product E2E under `e2e/products` owns real rho/rho-env integration, filesystem,
process and checkpoint behavior. Shared `e2e/support` remains independent of rho.
