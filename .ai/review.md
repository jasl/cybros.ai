# Code Review Principles

**Applies to:** every project. Findings about a project must cite that project's own rules.

## Review Scope And Process

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
  blocker. For Nexus, review business-owned Ruby unions and Hash shapes against
  `.ai/backend-rails.md`, preserving its opaque-payload exception.
- Review Ruby against the shared idiom rules (`.ai/repository.md` §Global Ruby Style;
  `.ai/backend-rails.md` §Layering, §Scopes, Callbacks, Control Flow, §Logging) and the ONE
  IMPLEMENTATION PER MECHANISM rule (`.ai/boundaries.md`): a comment banner carrying doctrine, a
  hand-rolled status vocabulary, a `Model.lock.find_by` re-fetch, a class probe on a value the
  code produced, a second Result type in a namespace, or a second copy of a mechanism with no
  recorded semantic difference is an improvement finding in an untouched file and a blocker in a
  file the change touches.
- A source file over 800 lines is an improvement finding in an untouched file and a blocker in a
  file the change touches — split by concern under the owning namespace
  (model files target ~200 lines, `.ai/backend-rails.md` §Layering), never a numbered twin.
- Security findings use `.ai/boundaries.md`'s Threat-Model And Portability Gate and
  `.ai/security.md`'s implementation rules and supported-threat exclusions. Do not turn trusted
  local software, intended Runner file access, copied credentials or isolated synthetic test
  secrets into undeclared security boundaries.
- Apply `.ai/boundaries.md`'s Rejected Design Shapes during design and cleanup review.
  Reintroducing one of those shapes is blocking unless the same change identifies reachable product
  behavior that Rails or an existing authority cannot provide and pins that distinction in a test.
- A fix changes only what the verified finding condemns. Do not restyle correct code or replace
  a banned construct with an equivalent spelling. Never delete a guard, regression test or
  explicit obligation merely to make the fix coherent; weakening its pinning test is a blocker.
  Follow the current authority rules in `.ai/README.md`; do not invent or misrepresent a user
  decision. Development diagnostics cannot confer production Catalog capabilities or vendored
  wire defaults: optional facts stay absent rather than false.
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
- Legal/compliance effort is capped at popular-open-source parity.
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
- When a bug resists a fix attempt or two, stop speculating: inspect runtime state (logs, console,
  queries, focused repro). Loop: reproduce, fix, widen adjacent regression coverage. Research
  historical behavior or external implementations only when the task needs it; identify the
  source/version and reproducible observation. Such evidence informs a decision, not a mandatory
  baseline; state an adopted requirement in the current contract and pin its behavior in tests.
- Extra review triggers: migrations/expensive queries → database review; auth, tokens, credentials,
  outbound requests, file paths, shell, LLM/tool execution, webhooks → security review;
  user-facing UI → UX review; E2E harness plus product changes → both layers; new dependencies →
  license, security, size, maintenance; stable JSONB contracts → consider StoreModel (never for
  intentionally open agent/provider payloads).

## Reachability And Materiality

- A deliberately constructed malformed or unsupported request is not material reachability by
  itself. Do not report a misleading empty state or unfriendly response when the request fully
  rolls back and creates no concrete security or durable data-integrity risk. Review and fix
  malformed-input behavior only for those risks; client-side input hygiene and friendly handling
  of unsupported shapes are not Nexus obligations.
- Apply the documented structured-number range as a supported-input boundary. Do not report an
  unsupported out-of-range JSON numeric literal such as `1e400` being rejected or normalized by
  the ordinary Rails/PostgreSQL JSON path as data corruption, and do not request raw-token capture
  or a recursive pre-cast validator solely to preserve it. Report a supported value whose
  round-trip changes its numeric meaning, a public boundary that promises broader numeric support,
  or a separate reachable security, availability, or durable-integrity failure.
- Ordinary dynamic-language value semantics are not findings by themselves. In Ruby/Python,
  freezing an outer value object need not recursively freeze member
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
- For defensive guards, verify reachability first: which current or planned business flow, public
  boundary, job, race, or framework behavior triggers the condition? Production reachability is
  necessary but not sufficient: an exceptional collision that fully rolls back and preserves all
  durable invariants does not require a friendly response and is not a correctness finding merely
  because it can return `500` (`.ai/boundaries.md`). No reachable material failure means remove the
  guard or downgrade the finding. Manual `Child.create!(owner: ...)` in normal business
  paths is a style smell when an owning association exists — but escalate only when a real API,
  job, import path, or race can bypass the owning aggregate, never because a test or console can
  assemble an invalid graph.
- Report correctness and security findings only when the failure is reachable in production code
  or a production deployment. Test, development, and CI-only output of synthetic or locally
  generated values is not a production secret exposure; committing or printing a real credential
  remains a finding in every environment (`.ai/security.md`; the shared local test account follows
  `.ai/repository.md`). Review those paths only for their intended test/CI correctness or
  maintainability, not as hypothetical production behavior.
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

## Concurrency And Authority

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
  not a cross-principal concurrency primitive. Review overlapping
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
- **Concurrency materiality gate.** A schedule being forceable with a
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
  confirmation; apply the serial-order test above and the owning contract.
- For ancestor archive/delete races, identify the written temporal contract before requesting
  locks; escalate only for post-commit mutation, new descendant work, or structural allocation.
  Verify protected controller families get authentication by default from the namespace base.

## Boundary-Specific Checks

- Review identity, administration, removal/restore and credential-plane changes against
  `.ai/boundaries.md` and `.ai/security.md`. An address retained after credential fencing does
  not retain authority. Independent Runners do not inherit an Agent Profile's removal. Human
  shutdown must survive restore through its remove-only and applied generations; do not demand
  status-only sweeps, extra removal markers or a restore barrier.
- Registration review uses `docs/oauth/device-flow.md`: preserve Connect's reject-only stale-page
  precondition, the locked manager-bound key recheck and Consume's persisted pairing marker.
  `registration_changed` leaves the grant pending and requires reload. The echoed public id or
  `absent` value never grants authority, names another key or changes assignment scope. Agent
  identifiers remain opaque, bounded program input; do not add a browser comparison or user
  identifier-entry flow. A winning reconnect restores the same removed Profile under its key;
  a future erase must have its own terminal-history/key-release contract before implementation.
- Lineage revoke, lapse, Runner `revoke_credentials` and re-pair fence credentials while retaining
  the address. Agent `revoke_connection` and explicit terminal Runner revoke end that logical
  address. Report missing fencing, a lineage-only operation destroying the address, terminal
  revoke leaving it live, duplicate live addresses, resolver ambiguity or old-epoch authority.
  No address means un-askable, not a resolver error. Do not reintroduce a serving-address selector
  or a second Profile to reach one identity; explicit runner handoff remains required.
- Executor control HTTP and credential refresh may outlast a task's remaining deadline while
  retaining finite timeouts. Verify return to the existing cancellation/deadline path, no renewal
  from a failed read and no early release of a live worker's ticket. Recovery reads prove the
  original claim and context: pause/inbox absence is not cancellation, a late read must not stop
  a replacement, and Cable/read overlap cancels once. GET does not spend POST claim's caller
  budget; 429 schedules a later read without sleeping inside the control path. Late results must
  not overwrite settled kernel state; no aggregate probe deadline or extra concurrency is owed
  solely to prevent accepted timeout overlap.
- E2E database isolation is judged under committed defaults and documented supported launch
  configuration. A developer deliberately overriding it with a global `DATABASE_URL` or a
  repository dotenv override is outside that path. Report any supported configuration or target-
  validation failure that can select, mutate, drop or clean a non-E2E database.

## Finding Capture Protocol

A finding that fails these capture rules is not reportable yet.

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
- An explicitly approved behavior change is reviewed against its current contract and pinning
  tests, rather than relitigating the superseded behavior as a regression.
- A finding about agent identity, executors, credentials, or task authority names the exact
  layer(s) it concerns — Agent Profile (agent User), TaskExecutor (kind and ownership),
  credential plane (member/data vs executor transport), Task execution principal, and the
  lifecycle owner — plus the reachable consequence in those terms. A finding that blends the
  program, the Profile, an executor, and a credential into one "Agent" is not reportable as written.
- Sweep a replaced design by claim, not only by keywords. Enumerate the propositions made false,
  search their paraphrases, and read the current guidance and top-of-file rationale of affected
  owners. Check the target set required by `.ai/boundaries.md`'s Contract Propagation: stale
  explanations can contradict correct code even when no retired vocabulary remains.
- Work explicitly deferred by the user or a current self-contained rule is not reportable as
  missing merely because it remains unbuilt. Preserve the accepted scope, shape, and standing
  constraints. Report code that half-builds it ahead of the authorized work, contradicts that
  shape, or breaks an applicable constraint. Cite the decision or rule that establishes the
  deferral; no particular register or private development file is required.
- A design question explicitly left unresolved by the user or a current self-contained rule is
  not a missing-feature or incompleteness defect. Preserve its stated framing; report code that
  contradicts it or silently adopts a candidate answer without the decision having been made.
  Silence, missing callers, or missing implementation alone establishes neither a deferral nor
  an unresolved decision and does not erase an accepted capability obligation.
