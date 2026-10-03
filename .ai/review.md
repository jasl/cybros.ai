# Code Review Principles

**Applies to:** every project. Findings about a project must cite that project's own rules.

- Review in layers: scope/intent, architecture fit, blockers (regressions, security, missing error
  handling, missing durable tests, boundary breaks), improvements, then nitpicks labeled as
  nitpicks. Any blocker means request changes; nitpicks only means approve while noting them;
  answer merge-readiness with a direct yes/no backed by fresh capture.
- Prefer the smallest correct change; flag scope creep; split unrelated work; preserve unrelated
  dirty changes.
- When the owner asks whether an uncommitted worktree is ready to commit, assemble the review
  candidate from every in-scope staged, unstaged, and untracked file; a requested merge-base diff
  is comparison capture, not a staged-only boundary. Git index membership, or an intended file's
  absence from `git diff <base>`, is packaging state rather than a finding: inspect the file
  directly and review its contents. Report a missing dependency only when it is absent from the
  assembled candidate, relies on local or generated state that is not intended to ship, or the
  owner explicitly limits review to an index, patch, or commit that omits it.
- Treat an unapproved expansion covered by `.ai/boundaries.md`'s Design Expansion Gate as a
  blocker. Review business-owned Ruby unions and Hash shapes against `.ai/backend-rails.md`;
  preserve its opaque-payload exception.
- Review Ruby against the idiom rules of 2026-09-05 (`.ai/repository.md` §Global Ruby Style;
  `.ai/backend-rails.md` §Layering, §Scopes, Callbacks, Control Flow, §Logging) and the ONE
  IMPLEMENTATION PER MECHANISM rule (`.ai/boundaries.md`): a comment banner carrying doctrine, a
  hand-rolled status vocabulary, a `Model.lock.find_by` re-fetch, a class probe on a value the
  code produced, a second Result type in a namespace, or a second copy of a mechanism with no
  recorded semantic difference is an improvement finding in an untouched file and a blocker in a
  file the change touches.
- (delta audit 2026-09-16) A source file over 800 lines is an improvement finding in an untouched
  file and a blocker in a file the change touches — split by concern under the owning namespace
  (model files target ~200 lines, `.ai/backend-rails.md` §Layering), never a numbered twin.
- Before reporting a security finding or requesting a security mechanism, apply
  `.ai/boundaries.md`'s Threat-Model And Portability Gate and state the asset, attacker, capability,
  boundary, and distinguishing test. Reject findings that treat the trusted user environment, a
  deliberately installed implementation package, ordinary stable user edits, a content digest,
  host fingerprints, or transient inventories as security authority. Probes remain limited to the
  task's explicit typed capabilities, and supply-chain controls remain at distribution boundaries.
- Apply `.ai/boundaries.md`'s 2026-08-25 negative-archetype gate during design and cleanup review.
  Reintroducing one of those shapes is blocking unless the same slice identifies reachable product
  behavior that Rails or an existing authority cannot provide and pins that distinction in a test.
- **Fix-application conduct** (owner ruling 2026-08-13, after a review-agent fix round): a fix
  changes only what the verified finding condemns. Behavior-preserving restyles of correct lines
  are reportable noise, and a banned construct is never laundered through an equivalent spelling —
  if the fix wants `case x when String`, the answer is to normalize (`to_s`) or delete the gate
  (`.ai/backend-rails.md`, case-costume rule). A fix may not delete a guard, a regression test, or
  an owner-recorded obligation to make itself coherent; deleting the test that pins the invariant
  being weakened is itself a blocking finding. No agent authors, re-dates, or paraphrases an owner
  ruling into new authority: normative text in `.ai/**` (the founding `docs/specs/**` were retired 2026-08-17 and are historical citations only — owner ruling 2026-09-05), a closed register
  policy, or a dated decision changes only with a ruling that exists in the dated records —
  citing one that is not there is fabrication and reverts on sight. Production Catalog data and
  vendored wire defaults never infer capabilities from a development diagnostic; optional facts
  stay absent rather than false.
- Verify findings before fixing or reporting; do not infer state from diff context when the source
  is cheap to inspect. Framework behavior reviews use the current Rails version, gem source, or
  docs — never memory. Rails-covered behavior is the default contract: redundant defensive code
  around verified framework semantics is a deletion candidate; do not request custom parsing,
  headers, or stricter wrappers without a written contract.
- A documented Rails default practice is not a finding merely because a hand-written route,
  callback, validation, or wrapper could enforce a stricter generic convention. This includes the
  standard verbs recognized by Rails resource routing. Escalate only a concrete production
  failure or a violation of an explicit product, security, or data-integrity contract; framework
  defaults do not need application code solely to make them narrower.
- Legal/compliance effort is capped at popular-open-source parity (owner rule, 2026-08-11).
  Concretely: referenced code obeys its license the way popular projects do (a LICENSE/NOTICE
  file, a short header where customary); code whose license is commercially incompatible is
  clean-room reimplemented rather than imported; the dependency checklist's one-line license
  criterion is the whole gate. Never invent compliance concepts, records, or machinery —
  no sourcing ledgers for code origin, no license-scanning pipelines or SBOM generation,
  no compliance capture in specs, registers, or CI — and never raise a review finding that
  asks for one. Specialized legal work belongs to professionals, not this repository.
- Any change under `nexus/vendor/simple_inference/lib/simple_inference/protocols/**` must identify
  whether the real wire behavior moved: request shape, headers, streaming semantics, parsing, or
  usage rules. Update the focused prepared-request/response golden and protocol behavior tests when
  it did. Do not add or bump a `WIRE_REVISION`, source pin, or capture-currentness record; those
  declarations have no product consumer and cannot prove a remote Provider's version.
- Review closeable IO objects by their ownership contract, not merely by observing that they
  remain open. A low-level API that returns a response, stream, cursor, file, socket, or derived
  session ordinarily transfers lifecycle responsibility to its caller when that ownership is
  documented or idiomatic; the producer is not leaking the resource merely because it does not
  close an object the caller still owns. Escalate the concrete layer that violates the contract:
  a caller that fails to close its owned object, a wrapper that consumes or hides the low-level
  object without closing it or exposing a lifecycle, or an abstraction that lets a
  transport/provider-specific resource cross a boundary that promises to hide it. When a wrapper
  elects to own the whole operation, a block API with `yield` plus `ensure` is the preferred
  structural lifetime contract, but do not require that style from an intentionally low-level
  caller-owned API and do not ask a library to enumerate every possible downstream use.
- A caller voluntarily weakening its own request construction is not a Nexus security finding when
  verified Rails-native semantics cause no cross-principal influence or application-created secret
  exposure. In particular, Rails merges query and body parameters; a caller can put its own
  sensitive value in the query string or submit conflicting copies. Do not request body-only
  parsing or custom precedence solely to protect that caller from itself. Escalate when another
  principal can influence the request, application code creates or propagates the exposure, or an
  explicit endpoint contract requires transport-source separation.
- Caller-controlled opaque JSON and metadata are not secret-bearing merely because a caller could
  choose to place a secret inside them (owner ruling, 2026-07-30). Nexus cannot infer
  confidentiality by enumerating arbitrary container names, nested keys, or values, and its
  ordinary Rails request-parameter logging does not become a security finding on that possibility.
  A downstream application that needs Nexus to persist confidential opaque content encrypts it
  before upload and owns its key handling. Do not request filtering `metadata`, `value`, task
  input, tool payload, or another generic opaque container solely because it might contain a
  caller-supplied secret. Escalate only when Nexus itself creates or accepts a field whose explicit
  contract identifies it as a credential/raw secret and then exposes it outside that contract, or
  when a written privacy contract covers the opaque payload itself.
- A browser-owned page flow may carry its local authorization context through login,
  reauthentication, or switching the signed-in user explicitly performed by the person operating
  that same browser. Do not report the current principal's ability to continue, retry, or act on
  that flow as cross-principal influence or a correctness failure solely because another principal
  began or advanced it, when continuation requires the local operator's deliberate authentication
  or action, the current principal is authorized for the resulting operation, and durable
  integrity is preserved. This includes an authorization or device-confirmation page where the
  browser operator deliberately logs out, reauthenticates, or switches accounts before continuing.
  Escalate only when an uninvolved principal can exercise the capability without the browser
  operator, the operation exceeds the current principal's authority, or a durable invariant
  breaks.
- An installed agent program is owner-selected software inside the Account trust domain. In v1,
  which deliberately has no Profile selector, one exact `(steward_id, agent_identifier)` key maps
  to one Agent Profile. That is the current product constraint, not a claim that identifier
  equality must define every future multi-Profile design. `agent_identifier` and
  `runner_identifier` are the program's release-stable, non-secret constant plus a per-home
  instance part derived at first boot (owner ruling 2026-09-09; rho: `rho.<instance_id>`,
  `agents/rho/rho/lib/rho/connection.rb:287-291`) — never a value a user imports, exports,
  copies, types or chooses; Nexus accepts the whole as opaque product input, stays kernel-blind
  to the part's shape (length only, `device_authorization.rb:51-54`), and never renders it for
  browser comparison. Under the current schema, active and removed
  Profiles occupy the same key slot, and a winning reconnect to a removed Profile restores that
  exact row. Escalate a reconnect that leaves a removed Profile unusable or creates a duplicate.
  Future `erase` instead leaves terminal attribution history that never restores or reconnects,
  while releasing the current resolver key so the same product constant may create a new
  Profile/public identity; do not request that future schema ahead of its owning slice.
  Program-provided identity and display-name claims are product input rather than an adversarial
  impersonation boundary. Do not report phishing by an installed program, deceptive
  same-identifier claims, or software supply-chain compromise as Nexus findings. Escalate only a
  normal-operation mapping/fencing invariant failure or authority beyond the protocol-validated
  connection and its credential plane; installation trust and software sourcing remain outside
  Nexus.
- A deliberately constructed malformed or unsupported request is not material reachability by
  itself. Do not report a misleading empty state or unfriendly response when the request fully
  rolls back and creates no concrete security or durable data-integrity risk. Review and fix
  malformed-input behavior only for those risks; client-side input hygiene and friendly handling
  of unsupported shapes are not Nexus obligations.
- Apply spec 21 D3's structured-number limitation as a supported-input boundary. Do not report an
  unsupported out-of-range JSON numeric literal such as `1e400` being rejected or normalized by
  the ordinary Rails/PostgreSQL JSON path as data corruption, and do not request raw-token capture
  or a recursive pre-cast validator solely to preserve it. Report a supported value whose
  round-trip changes its numeric meaning, a public boundary that promises broader numeric support,
  or a separate reachable security, availability, or durable-integrity failure.
- Ordinary dynamic-language value semantics are not findings by themselves (owner ruling,
  2026-07-31). In Ruby/Python, freezing an outer value object need not recursively freeze member
  strings or collections, and a nullable reader may ordinarily collapse a missing member with
  explicit `null`/`nil`. Do not request deep freezing or required-nullable presence checks without
  a concrete supported-flow business failure, security impact, durable data-integrity failure, or
  breach of a promised isolation boundary. This exclusion does not excuse an explicit deep-freeze,
  security, or isolation contract when its violation has such a reachable effect; a frozen outer
  object, a `required` schema label, or theoretical caller mutation alone is not enough.
- An unhandled server or reverse-proxy `5xx` may be non-JSON or empty and does not need to preserve
  an API family's error envelope or media type. That response shape is never a server finding; do
  not request a catch-all application rescue solely to make it uniform. Clients must never assume
  that a `5xx` response is JSON. A client that parses before exposing the status is reportable only
  when that behavior breaks a documented supported flow and creates a concrete product, security,
  or durable data-integrity problem; a parser exception or lost diagnostic by itself is not enough.
  This does not relax expected business, validation, or other controller-handled errors. Review the
  underlying failure only when it creates one of those concrete problems.
- Missing administrator inspection, audit, or management of an Agent User's credentials or
  user-bound executors is not a missing control. The administration boundary deliberately leaves
  those surfaces member-owned; administrators may only reassign the Agent User's steward or run
  its remove/restore lifecycle (`.ai/boundaries.md`). Escalate an implementation that exceeds that
  administrative authority, or a concrete security or durable-integrity failure in the
  member-owned lifecycle, but do not request an administrator surface merely to make those records
  inspectable.
- Agent User removal synchronously fences its member and Agent-application credentials, retains
  the active TaskExecutor address, and asynchronously force-stops related work (owner ruling
  2026-09-19; `.ai/boundaries.md`). An independent Runner is unaffected. Review current-state
  cleanup for restore-safe targeting and a bounded lost-wake floor, not exact removal episodes:
  status lag and eventual timeout are accepted. Do not demand continued use of the removed
  Agent's old transport, a task-withdrawal marker, another generation, or a restore wait. Do not
  mistake the retained address for retained credential authority. Already persisted results stay
  intact; a result arriving after force-stop cannot overwrite its terminal state.
- Executor-local deadline handling is best effort during bounded control HTTP and credential
  refresh (owner ruling 2026-09-19; `.ai/boundaries.md`). A finite HTTP timeout extending beyond
  the task deadline is accepted, not by itself a finding. Verify that control returns to the
  existing cancellation/deadline path, that read failure neither renews the task nor releases a
  live worker's ticket early, and that late results cannot overwrite settled kernel state.
  Do not require an aggregate probe deadline or additional concurrency solely to prevent this
  accepted overlap. For cancellation recovery, verify the exact original claim proof and context:
  pause/inbox absence is not cancellation, a late read cannot stop a replacement execution, and
  Cable/read overlap counts one cancellation. GET must not spend POST claim's caller budget;
  429 schedules a later read without sleeping inside the control path.
- Human removal is deliberately broader and two-phase. The Human's member/data authority and new
  admission are fenced immediately; every managed Agent/Runner/future provider then converges
  asynchronously by canceling queued Tasks, stopping running work at data-safe checkpoints, and
  fencing transport after truthful terminal/capture state is durable. The explicit exception is
  an Agent Profile becoming removed: its credential cut and asynchronous force-stop apply then.
  Do not generalize that exception into a synchronous managed-resource scan or an immediate epoch
  bump for independent Runners/providers. Escalate a path that admits new work after
  removal, drops/overwrites an accepted result, crosses a new effect boundary after cancellation,
  or leaves managed transport authorized after its Task set has converged. The accepted episode
  must survive Human restore through the Human's remove-only generation and the independent
  applied generations on Agent Profiles and TaskExecutors. Escalate a status-only sweep, a Profile
  that becomes usable merely because its steward was restored, a reconnect/re-pair that clears a
  mismatch, or a remove-first manager/steward transfer that rebinds instead of returning
  `shutdown_pending`.
- Device-code `interval` and `slow_down` are cooperative client pacing plus a best-effort abuse
  guard, not a serialized ownership or correctness boundary. Concurrent pollers presenting the
  same short-lived `device_code` during one authorization ceremony are ordinary protocol
  retries/cooperation; that tolerance does **not** make sharing the minted access/refresh
  credential bundle across devices or independent stores a supported topology. Do not request row
  locks, CAS, or exact additive interval increments merely because concurrent polls can all observe
  `authorization_pending` or coalesce a bump. Escalate a double mint, terminal-state bypass,
  credential-family corruption, unbounded application work, or a concrete supported-load resource
  failure; rate limiting need not replace deployment-layer WAF/proxy controls.
- rho's renewal cadence is deliberately independent of the kernel's credential constants (owner
  ruling, 2026-07-26). The kernel decides when a lineage lapses and derives its inactivity window
  from the access-token lifetime; rho picks its own renewal lead and only has to stay comfortably
  inside that window. Do not report the two as duplicated constants that should be coupled, and do
  not request that rho import, fetch, or derive the kernel's numbers — a client whose behaviour
  depends on a constant it cannot read is worse than one that renews early. Escalate a cadence
  that could actually reach the lapse (a renewal interval longer than the lead, or a lead longer
  than the window rho assumes), or a comment that states a server rule as fact rather than as an
  assumption.
- Rho's daemon-lifetime boot lock is the single-writer boundary for one local `RHO_HOME`; do not
  treat the operator, sibling processes excluded by that lock, copied homes, or inode/path changes
  as hostile actors. `StateFile` keeps private modes, atomic publish, persist-before-use ordering,
  ambiguous-publish no-retry behavior, secret redaction, and in-process synchronization. Do not
  request per-operation sidecar locks, inode revalidation, pid files, NFS protocols, or
  cross-process sibling adoption. Escalate a first-party daemon path that bypasses the lifetime
  lock, a non-atomic credential write, secret exposure, or a retry after an ambiguous publish.
- Post-publish durability failures in `StateFile` are labeled, not prevented. `PublishedError`
  marks the window where `rename(2)`/`link(2)` succeeded and the directory `fsync` did not: the
  document IS on disk and the caller must not retry, because a retried credential rotation presents
  a token the server already spent. Do not report that `write`/`create_once` can raise
  after publishing, and do not request the directory fd be opened before the publish step —
  measured, fd exhaustion lands pre-publish, and hoisting the fd raises the operation's peak fd
  need. `create_once` losing a race at the same moment as an `fsync` failure surfaces
  `PublishedError` rather than `false`; that label is accurate (a document is published, by the
  winner) and is deliberately not special-cased. Escalate only a post-publish failure a caller
  cannot distinguish from a pre-publish one.
- Private-mode checks on state files test the security property — no group or other access — not an
  exact mode. A file that has *become* readable by others is refused rather than repaired, on write
  as well as read: a repair hides an exposure that already happened, and on the write path it would
  rotate the exposed token away before anyone was told. A *stricter* mode leaks to nobody and is
  accepted, because a narrowing umask or `chmod -R 700` must not brick a daemon's only credential
  store. Do not request exact-mode equality, and do not request a `chmod` that repairs a widened
  file. Escalate a mode granting group or other access that is accepted, or a skipped owner check.
- **Executor single-instance means one logical registration, address, and current credential
  epoch — not proof of one physical process** (owner refinement, 2026-07-27). One Agent Profile
  has at most one non-revoked `agent_application` address; the current product maps exactly one
  Profile for `(steward_id, agent_identifier)`. Each Runner key
  `(account_id, manager_id, runner_identifier)` likewise has at most one non-revoked address,
  independent of its `user_private | account_wide` ACL. A tools provider shares the Runner key
  `(account_id, manager_id, runner_identifier)` — one live address per key across BOTH machine
  kinds (S-C step 5, 2026-09-07). The identifier branch is the request discriminator; a branch-B
  request may name its machine kind — `executor_kind: runner (default) | tools_provider` — and a
  kind on branch A, or a value outside the vocabulary, is `invalid_request`; the kind is frozen on
  the registration like its scope, and a re-pair naming the other kind for a live key is
  invalidated at Consume (`access_denied`). `assignment_scope` is absent from the machine-request schema and
  cannot be expressed by the first-party SDK. An extra raw parameter cannot affect the grant.
  An ordinary browser member is fixed to `user_private`, while an owner/admin connecting their
  own Runner may select a default-unchecked account-wide checkbox. Connect freezes the chosen
  scope as `selected_assignment_scope` for Consume only when a fresh logical registration is
  created. A live registration renders its stored scope without a selector and re-pair preserves
  it, while a fresh registration after terminal revocation may select again. The Runner form also
  echoes the live registration public id observed by GET, or `absent`, as a reject-only
  precondition. POST must lock and re-resolve that manager-bound key; mismatch returns
  `registration_changed`, leaves the grant pending, and requires a reload. Escalate deletion of
  this stale-page CAS, or any use of the echoed value to grant authority, name another key, or
  mutate scope. Connect's persisted pairing marker separately protects Consume from changes after
  POST. A Runner
  may execute Tasks for multiple Agent Profiles inside that scope because the execution principal
  is frozen per Task, not on the Runner.
  Browser Connect freezes the replacement consequence and expected address/epoch without taking
  authority away; the requesting device's winning Consume re-pairs a matching non-revoked address
  in place and advances its credential epoch, fencing the old device's authority, or creates an
  address when none exists. The former Agent *serving*
  designation, its hand-off verb, `/profile`'s `serving_executor` block, duplicate Profile/Runner
  resolution, and multi-device selectors are deleted, not deferred. Do not report their absence or
  request a second Profile merely to reach the same identity from another place; identity carries
  permissions and data. That deleted hand-off was only a serving-address designation. It does not
  retire the explicit runner handoff — invoked by the agent application, recorded by the kernel —
  required before future work switches between runners, the agent's own runner address
  included: host filesystem state is implicit, and Nexus must neither migrate nor retarget
  existing work.
  Escalate two durable non-revoked addresses for one logical key, a resolver ambiguity, old-epoch
  authorization, a resolution that treats "no address" as an error rather than as un-askable, or
  an execution-site switch that skips its application workflow or mutates existing work.
- **Runner assignment scope is ACL, never administrative ownership.** One Human manager is the
  sole current lifecycle and credential manager through `/runners`, regardless of
  `user_private | account_wide`. An owner/admin may select `account_wide` only while connecting a
  Runner as its manager; that ACL never grants administrators a management surface over another
  Human's Runner or an emergency bypass after manager removal. V1 has no scope-change or
  manager-transfer command. Escalate an administrator list/revoke/takeover path, a re-pair that
  silently changes the stored scope, or a future transfer added without its own explicit
  authorization and route contract.
- **Copied current credentials and multiple independent holders are an accepted Nexus
  limitation, not a future finding.** If an operator copies a minted bearer/state directory to
  another device, or non-first-party code starts independent processes outside the same local
  store/boot-lock domain, those holders present the same logical address and current epoch. Nexus
  cannot reliably distinguish them, and IP binding would reject legitimate NAT/shared-address
  users while still not proving device identity. Do not request IP or User-Agent binding, device
  fingerprints, heartbeats, remote process registries, parallel-session detectors, or another
  coordination entity to prove physical cardinality. Presence may say that at least one
  current-epoch subscription exists; it is not a single-instance fence. This exclusion does not
  excuse the logical-key, epoch-fencing, or first-party local-lock failures named above.
- **Credential-lineage fencing does not revoke its durable address, and that asymmetry is the
  design** (spec 03 D1/D2). `RefreshTokenFamily#revoke`, credential lapse, Runner
  `revoke_credentials`, and re-pair make the affected lineage/epoch unusable; re-pair also installs
  a new current epoch on the same address. None deletes the address. By contrast, an Agent
  steward's `revoke_connection` is a terminal TaskExecutor revoke despite the product's
  credential-oriented copy, and a Runner's explicit terminal revoke likewise ends that logical
  registration's live address. A person returning after a lapse therefore re-pairs the address
  they had, while a terminally revoked registration requires a new address. Do not report the
  missing lineage-to-address cascade or lapse-reaper as a leak; escalate a credential that survives
  its authority fence, an address destroyed by lineage-only fencing, or a terminal revoke that
  leaves the same address live.
- **`uses_transaction` keys on the test method name, and a stale name fails silently.** A renamed
  test that the class still lists under the old name runs inside the wrapping transaction again,
  which deadlocks any test using `RowLockTestHelper` (the row-lock holder pins the connection) and
  surfaces as an unrelated `Timeout::Error` in `start_database_call`. When reviewing a renamed test
  in a class with `uses_transaction`, check the list was renamed with it.
- What `Credentials::OAuth` deliberately does not do. After terminal loss it keeps the persisted
  document for capture and operator visibility instead of deleting credentials or logging out; the
  latch is in memory, so a restarted process makes exactly one attempt, which is what "exits to
  reconnection" requires — do not request a persisted latch. A rotation that succeeded and could
  not be persisted keeps the new pair in memory and raises `NotDurable`: the previous token is
  already spent, so falling back to it is the one unsafe answer, and the pre-raise mutation is not
  a defect. Persisted expiry is wall-clock because monotonic time cannot survive a restart, and a
  clock jump is absorbed by the expiry skew plus the reactive retry. `Credentials::Static` (spec 40
  D5) is unbuilt because nothing consumes it. Escalate a refresh token presented after a latched
  loss, a durability failure reported as a rotation failure, or a plane served out of a document
  the class never verified.
- For defensive guards, verify reachability first: which current or planned business flow, public
  boundary, job, race, or framework behavior triggers the condition? Production reachability is
  necessary but not sufficient: an exceptional collision that fully rolls back and preserves all
  durable invariants does not require a friendly response and is not a correctness finding merely
  because it can return `500` (`.ai/boundaries.md`). No reachable material failure means remove the
  guard or downgrade the finding. Manual `Child.create!(owner: ...)` in normal business
  paths is a style smell when an owning association exists — but escalate only when a real API,
  job, import path, or race can bypass the owning aggregate, never because a test or console can
  assemble an invalid graph.
- Do not manufacture a stale-authority finding from an already-started synchronous request merely
  because another request suspends or removes a Human/Agent User, changes an Agent's steward,
  transfers Workspace ownership, or rotates/revokes the actor's credential before commit. Review
  these low-frequency authority changes by their **final durable state**, not by commit timestamps.
  When the actor held every required authority at request start, could have completed the exact
  same durable mutation immediately, the command produces no broader or irreversible effect than
  that already-authorized mutation, the result matches the mutation-first serial order, and the
  **applicable dominant final authority fence** gates later calls, request-start authorization is
  sufficient. Name that fence for the concrete flow: current status for ordinary lifecycle
  liveness; `authority_generation` after every accepted transition away from `active`, so neither
  suspend→reactivate nor remove→restore revives stale authority; current steward/owner for
  relationship cuts; and, when Human removal owns a managed-resource shutdown episode, the
  Human's `managed_resource_shutdown_generation` together with each affected Profile or
  TaskExecutor's matching applied generation. Current credential epoch plus
  AccessToken/RefreshTokenFamily liveness separately governs rotate, revoke, lapse, and re-pair.
  Status alone is not the dominant fence when later reactivation or restore is allowed. A short
  local reload or row lock inside an already-required aggregate transaction is acceptable
  hardening, but its absence is not a finding by itself. Escalate only when the
  interleaving leaves invalid ownership or binding, admits work begun after the applicable final
  authority cut, revives stale authority, duplicates an irreversible effect, partially commits,
  or bypasses a written recovery winner that protects one of those outcomes.
- Caller-scoped create idempotency keys coordinate retries from the same logical client; they are
  not a cross-principal concurrency primitive (owner ruling, 2026-08-02). Review overlapping
  duplicate submissions by durable convergence, not by whether every in-flight request returns the
  winner's friendly response. If one request atomically commits the unique receipt and effect,
  another request that observed no receipt may independently refuse or abort before it contests
  receipt uniqueness; do not require a final receipt lookup solely to turn that transient result
  into replay/mismatch. A typed refusal or `5xx` is acceptable when the loser leaves no loser-owned
  durable row, partial state, or irreversible effect and a later same-key retry reliably observes
  the winner.
  Escalate duplicate durable effects, partial state, a changed digest being accepted as replay,
  cross-principal scope collision, or a later retry that cannot replay/mismatch. A boundary may
  promise a stronger loser response explicitly, but the presence of an idempotency key alone does
  not create that contract.
- **Concurrency materiality gate** (owner ruling 2026-08-14). A schedule being forceable with a
  barrier, second connection, query-cache probe, stale object, or private-service/console
  composition does not make it a production finding. Before reporting any concurrency or
  stale-read finding, establish all three: (1) a current first-party supported workflow naturally
  overlaps the operations; (2) their real cadence and overlap window make the collision plausible
  in representative operation, rather than merely possible at one hand-picked instant; and (3)
  the result leaves a material product failure, unsafe final durable state, or irreversible effect
  that cannot be explained as an accepted request-start/serial boundary. A deterministic test can
  prove an interleaving, but it cannot supply the missing workflow or operational likelihood.
  Low-frequency administration and configuration — including catalog/provider policy, pricing,
  and Account cost-unit maintenance — have no instantaneous-cutover or linearizability contract:
  an already-started request may complete from its request-start view, while later ordinary
  requests observe the committed setting. Busy ordinary read traffic does not turn these rare
  commands into a normal multi-writer workflow. Request-local query-cache state, a momentarily
  stale Active Record object, or immediate reuse of the same object after a set-based
  administrative write is not a finding unless a current first-party caller deliberately and
  repeatedly exercises that exact topology or an owning product contract explicitly promises the
  immediate winner. Do not request locks, cache bypasses, retries, CAS, final rereads, reloads, or
  mutation-matrix tests solely to close such a theoretical window. A plan's implementation
  recipe (`lock`, `stable read`, `recheck`) likewise does not turn an operationally negligible
  collision into a code finding; raise over-prescribed mechanics as a
  spec-cleanup discussion unless the owning product contract explicitly makes the temporal winner
  user-visible and the realistic workflow clears this gate. This does not excuse ordinary
  multi-writer flows, routine retries/leases/reapers, duplicate irreversible effects under normal
  load, or an explicitly accepted immediate authority cut whose supported traffic makes overlap
  plausible.
- Report correctness and security findings only when the failure is reachable in production code
  or a production deployment. Test, development, and CI-only output of synthetic or locally
  generated values is not a production secret exposure; committing or printing a real credential
  remains a finding in every environment (`.ai/security.md`; the shared local test account follows
  `.ai/repository.md`). Review those paths only for their intended test/CI correctness or
  maintainability, not as hypothetical production behavior.
- E2E and development-only passwords, tokens, and credentials generated for the repository's
  isolated test world are public test inputs, not security secrets (owner ruling, 2026-07-30).
  Their presence in local logs, exception output, screenshots, or retained test artifacts causes
  no security harm and is not a correctness or maintainability finding. Diagnostic redaction and
  screenshot suppression may remain as best-effort noise reduction, but missing one such wrapper
  is never reportable. This exception does not cover a real external credential, production data,
  or a test harness that can address a non-test environment.
- Do not report E2E database isolation as unsafe solely because a developer could deliberately put
  a globally exported `DATABASE_URL`, or an equivalent developer-authored override in this
  repository's dotenv files, in front of the harness. Those broad overrides are not a supported
  local-development path. This exception is narrow: report any concrete path under committed
  defaults or documented, ordinarily supported launch configuration that can select, mutate,
  drop, or clean up a non-E2E database, and report any target-validation failure that makes such
  a path reachable.
- Ractor readiness is reviewed only for first-party code paths whose owning docs or tests promise
  it. Directory placement does not decide ownership: repository-maintained vendored code remains
  first-party, while Rails, HTTPX, injected adapters, and other upstream dependencies gain no
  implied Ractor contract. Do not turn a first-party path's compatibility promise into an
  application-wide or dependency-wide requirement.
- A maintainability finding names a concrete cost in the current change — duplicated ownership,
  conflicting state, an existing modification path made materially harder, or measurable query or
  write amplification. Extra branches or theoretical future growth alone are not findings.
- An intentionally captured, bounded statistic, request-metadata value, or diagnostic fact does
  not need a current reader to justify its existence. The absence of a UI or query consumer is not
  a finding by itself; report only a separate concrete failure such as an explicit retention or
  privacy-contract violation, unbounded growth, or material write amplification.
- For any diff that takes a row lock, opens a transaction around writes, or adds an INSERT inside
  an existing transaction, ask two questions: (1) after acquiring its lock, what other tables does
  this transaction touch — including the FK target rows of every INSERT, which take share locks
  invisible in the diff; (2) does the acquisition order match the global order in
  `.ai/database.md`? Enumerate those hidden edges even when the diff works locally — deadlock
  potential is a property of code-path pairs and may not reproduce in fast single-threaded runs.
  An order violation or held-lock cross-aggregate apply is a blocker when the paths belong to a
  flow whose normal operation admits multiple writers, a written convergence or typed-loser
  contract applies, or the collision can leave an unsafe durable state, irreversible effect,
  partial commit, or broken atomicity boundary. Do not report one solely because a rare overlap
  between low-frequency administrative or registration commands can deadlock and return an
  unhandled `5xx` when database abort fully rolls back every write, durable invariants remain
  intact, and no irreversible or partial effect occurs; `.ai/boundaries.md` forbids adding
  coordination solely to make that exceptional collision friendly. Apply this directly to rare
  overlaps among User suspension/removal, steward reassignment, Workspace ownership transfer,
  executor registration, and lifecycle commands: absent an unsafe durable result or irreversible
  effect, their possible stale observation, serial-order-equivalent commit, or rollback is not a
  finding.
- Credential writes that prepare a new digest apply `.ai/database.md`'s prepare-then-commit rule.
  Never request BCrypt or another KDF inside a transaction or row lock merely to close a post-
  verification window; require only the mutable-authority rechecks whose stale state could violate
  the owning winner rule or leave usable authority after the write should lose. Do not generalize
  that recheck to every status gate or every command that uses a password only as request-start
  confirmation; apply the serial-order test above and the owning spec.
- For ancestor archive/delete races, identify the written temporal contract before requesting
  locks; escalate only for post-commit mutation, new descendant work, or structural allocation.
  Verify protected controller families get authentication by default from the namespace base.
- Do not report ordinary NTP-scale skew merely because a coarse replay, cleanup, or retention TTL
  compares an application-written persisted timestamp with the database clock. Escalate only when
  the owning contract requires one exact database-time winner, the plausible skew can cross a
  materially shorter safety window, or reuse can violate data integrity, duplicate an
  irreversible effect, or expose authority. A small shift in a 24-hour replay reservation is not
  such a failure by itself.
- Bounded inline metadata and opaque JSON values follow `.ai/database.md`'s full-row snapshot
  posture. Do not report a collection loading those columns merely from the theoretical maximum
  bytes. Require a representative measured bottleneck; if one exists, review whether the value
  should become structured columns or a subordinate table before requesting scattered `select`
  projections.
- When a bug resists a fix attempt or two, stop speculating: inspect runtime state (logs, console,
  queries, focused repro). Loop: reproduce, fix, widen adjacent regression coverage. Unported
  old-repo surfaces use mature references as reachability capture, not final truth.
- Extra review triggers: migrations/expensive queries → database review; auth, tokens, credentials,
  outbound requests, file paths, shell, LLM/tool execution, webhooks → security review;
  user-facing UI → UX review; E2E harness plus product changes → both layers; new dependencies →
  license, security, size, maintenance; stable JSONB contracts → consider StoreModel (never for
  intentionally open agent/provider payloads).

## Finding Capture Protocol

Mechanical rules every reviewer follows regardless of judgment or capability; a finding that fails
one of them is not reportable yet.

- Every finding cites capture gathered from this checkout — file:line plus the reachable behavior
  path — never model memory, diff-only inference, or another review's summary. A suspicion that
  survived no verification attempt is a question, not a blocker.
- State each finding as a concrete failure scenario: which inputs or state produce which wrong
  outcome. Severity follows the scenario, not reviewer confidence; no scenario means nitpick at
  most. A concurrency scenario must also name the current first-party overlap path and explain why
  its cadence/window is plausible in representative operation; a forced barrier or stale-object
  reproduction alone is not reportable capture.
- A request to delete or weaken a guard, lock, validation, or test quotes the written rule or
  contract that justifies it (`.ai` module and section, or the endpoint doc). A request to add
  defensive code names the reachable path per the reachability rule above.
- Green guard tests and full suites outrank reviewer style opinion. Overruling a
  `nexus/test/code_style/` guard requires citing a written contract and changing the guard in the
  same change — never a hand-waved exception.
- Comments marked `Deliberate contract flip (WP-…)` record an approved behavior change and point at
  the tests pinning the new contract; verify the pins exist instead of relitigating the old
  behavior as a regression.
- A finding about agent identity, executors, credentials, or task authority names the exact
  layer(s) it concerns — Agent Profile (agent User), TaskExecutor (kind and ownership),
  credential plane (member/data vs executor transport), Task execution principal, and the
  lifecycle owner — plus the reachable consequence in those terms (spec 01 Vocabulary,
  spec 03 D2/D23). A finding that blends the program, the Profile, an executor, and a
  credential into one "Agent" is not reportable as written.
- Sweeping a retired design is **not** a keyword grep. A word-keyed pass over the deleted
  vocabulary (`serving`, `handoff`, `designate`) reaches the sentences that name the mechanism and
  misses the ones that merely assume it — and the sentences that merely assume it are the
  dangerous kind, because they read as ordinary description. The single-instance round's sweep ran
  clean at code level and still left spec 41 D5 stating the inverse of the ruling, as a normative
  decision, three paragraphs above the D12 the same round had rewritten correctly; not one of the
  swept words appears in it. Sweep by **claim** instead: enumerate the propositions the change
  made false ("an agent reconnect creates a new address", "a lineage revocation takes its address
  with it"), then search for each proposition's paraphrases, and read every normative decision in
  the specs the change names — a spec that contradicts itself is worse than one that is merely
  stale, because a reader cannot tell which half is current.
- The retired design also hides in **rationale**: a comment or spec sentence explaining *why*
  something is the way it is outlives the fact it explains. `task_executor.rb`'s file header still
  taught "an address belongs to one connection session and dies with it" while `address_for` forty
  lines below stated the opposite — and the header is what a reader consults before deciding
  whether a revocation should cascade. Check the top-of-file authority comments of every model the
  change touched, not just the lines the change edited.
- Local filesystem read/write by rho or a runner is **in scope by design** and is not reportable
  as a sandbox-escape, arbitrary-file-write, or privilege class of finding (`.ai/security.md`,
  Trust Model). The isolation boundary is the runner role and container deployment, not an
  in-process sandbox. A finding here must instead name one of the fences that IS declared —
  rho's own secret files, the local control surface's auth, a traversal escaping rho's own tree,
  or an effect reaching the disk without the approval its profile requires.
- `docs/plans/DEFERRALS.md` is the deferral ledger: work that is decided and deliberately not
  built yet, each entry naming its owning round. An absence recorded there is not reportable;
  reportable is DRIFT — code that half-builds an entry ahead of its round, contradicts the
  recorded shape, or breaks one of the ledger's standing constraints on future code (those are
  written to be enforced).
- `docs/plans/OPEN-QUESTIONS.md` lists design questions the owner has parked deliberately. A
  finding that reports one of them as missing, incomplete, or a defect is not reportable — the
  absence IS the recorded state, and the file gives the reason. What remains reportable is code
  that contradicts a parked question's framing, in particular code that silently adopts one of the
  candidate answers without the decision having been made.
