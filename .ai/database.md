# Database Principles

**Applies to:** `nexus` — it is the only project with a database.

## Schema Policy

Pre-release: correctness and maintainability beat compatibility. Destructive schema cleanup is
allowed, compatibility shims for deleted names are never kept, and local/generated data may be
cleared when it blocks a clean reset. `nexus` owns `db/schema.rb`, the truth every world loads
(`db:schema:load:primary`; the e2e worlds never walk the migration path).

Migration folds are a development-only policy. Stable public releases retain the incremental
migrations needed to upgrade installed databases; browser and CLI upgrades use that normal Rails
migration path and never implicitly reset user data. Do not preserve obsolete unpublished schema
history or add a compatibility protocol for it in anticipation of those future releases.

**Migration folds:** at each fold `db/migrate` holds one schema-creating migration (`create_nexus_schema`) that produces `db/schema.rb` exactly, and every
intermediate step — renames, relaxations, backfills, every data migration — is deleted; between
folds a schema change is one migration per change. A development database from before a fold is
rebuilt, never migrated across it: run `bin/rails db:reset` before `bin/setup`.
`bin/setup --reset` runs `db:prepare` first, so a pre-fold schema can fail
before that script reaches its reset step.

Proving that the migrations reproduce the committed schema: `db:migrate` against an empty primary
loads `db/schema.rb` first when the file exists, so move the dump aside, run
`RAILS_ENV=development bin/rails db:drop:primary db:create:primary db:migrate:primary`,
and diff the fresh dump against the committed one.
Rebuild queue/cable only through their database-qualified drop, create and schema-load tasks
when that database is intentionally in scope, for example
`RAILS_ENV=development bin/rails db:drop:queue db:create:queue db:schema:load:queue`
(use the same three tasks with `cable` for that database). These commands rebuild framework
tables without running application seeds. In the current Rails version, qualified `db:reset:queue` and
`db:reset:cable` leave the default connection on that framework database and then invoke
the application seed against it. The unqualified `db:migrate:reset` drops every configured database,
migrates only the primary, and can overwrite `db/queue_schema.rb` and `db/cable_schema.rb` with
empty dumps.

## Migrations, Tables, Columns

- Domain tables, models, and independently persisted state not already required by the accepted
  design are subject to the Design Expansion Gate in `.ai/boundaries.md`; persistence convenience
  is not a domain boundary.
- Name migrations after the concrete schema change, never a plan, phase, or umbrella such as
  `foundation`; Schema Policy above defines folding and reset behavior.
- Reversible `change` or explicit `up`/`down`; non-reversible data migrations explain why rollback
  is a no-op. DDL separate from large DML. No application models/services in migrations — use a
  small local migration class. No DB access from initializers.
- Foreign keys for real ownership; index FK columns. Add query indexes for current hot or high-
  cardinality `WHERE`/`JOIN`/`ORDER BY`/`GROUP BY` paths; when a composite index is justified, match
  its filter+order and let it replace indexes it makes redundant. Define `ON DELETE` intentionally.
  Hot operational paths take no hard FKs into retained append-only ledger tables. For retained
  audit/ledger rows, choose snapshot and nullify-FK semantics deliberately so deleting
  operational owners does not erase attribution. The Usage And Content Lock Edges section defines
  the usage receipt's narrower live-FK shape.
- A self-referential parent on `users` is a nullable FK with `on_delete: :nullify` and its own
  index — `steward_id` (the Human a profile answers to) and `derived_from_id` (the paired instance
  that declared a named definition); the named definition's other two facts are
  `definition_scope` (`instance | steward`, NULL on every paired row — the marker column the door
  matches on, never a prefix read back from the identifier) and `description` (`limit: 1024`,
  the one line a spawner chooses it by). Removal is a status cascade in the model, never a
  `dependent:` on the association.
- Subordinate rows are created through `owner.children.create!`/`build` or a semantic owner
  method. The owner supplies redundant anchors; direct assignment remains appropriate for stable
  roots and invalid-state tests.
- Every domain table denormalizes `account_id`, populated by the owning creation path
  (`belongs_to :account, default: -> { parent.account }`), never public input; freeze with
  `attr_readonly`. Two shapes carry none: a pure join row (`content_body_uploads`) and an
  immutable child of an account-anchored parent (`usage_budget_entries`, which snapshots
  `account_public_id` for attribution instead).
- Status and other closed-vocabulary columns have no length limit: the program defines their
  values and model inclusion validation enforces them. Existing columns keep their limits until
  a change has a reason to touch them; new ones declare none.
- Rails models own business validation and the actionable errors returned to callers. Normalized
  values, length and numerical bounds, allowed vocabularies, and cross-field or lifecycle shapes
  use Active Record validations, not SQL CHECK constraints. Nexus application migrations do not
  use `add_check_constraint`; a future storage-level exception requires explicit user approval.
  Database types and limits, `NOT NULL`, foreign keys, unique indexes, and defaults remain
  structural and concurrency backstops. Model preconditions/validations provide the ordinary
  friendly uniqueness path and a unique index decides the final winner. Map a database loser to a
  domain result only when the written contract or an ordinary production collision requires it;
  exceptional fully rolled-back losers follow `.ai/boundaries.md`.
- **Model execution, usage/billing, and content-storage exception:** these domains enforce
  their closed owner/purpose/active shapes through owning associations, model validation, one
  semantic writer, owner-row serialization, and guarded status transitions. They do not
  add typed `(account_id, id)` composite foreign keys, owner-role/purpose/active-attempt partial
  unique indexes, or product SQL CHECK constraints. They retain ordinary foreign keys to real parents,
  nullability, query indexes, and ordinary unique indexes that are themselves an identity or a
  real concurrency winner (for example public ids, receipt keys, owner/invocation 1:1 identities,
  attempt ordinals, body positions, and Account-scoped digests). This is a named exception for
  those domains, not a weakening of the default structural-backstop rule for unrelated models.
- No persistent cache tables as primary truth; prefer observable state transitions and timestamps
  before physical deletion; `archived_at` archive state and `deleted_at` delete state hide rows
  from default queries unless the contract includes them — via explicit scopes, never
  `default_scope`.
- JSON/JSONB columns need an explicit owner, documented shape, and size expectations; stable shapes
  get a StoreModel value object; intentionally open agent/provider payloads stay generic. Ordinary
  `jsonb`, never `jsonb[]` for a JSON array; large blobs go to object storage. Bounded inline
  metadata and opaque JSON values are part of the owning row's ordinary Active Record snapshot:
  loading the full row is the default, including on a bounded collection, until representative
  measurements show a material bottleneck. Do not add per-query projection machinery merely to
  avoid loading such a bounded column. When it becomes material, first decide whether the value
  has earned structured columns or a subordinate table; large blobs still move to object storage.

## Query Design And Bounded Discovery

- Check N+1 for every collection-loading path; Pagy for pagination (posture in `.ai/api.md`);
  unique ordering with a tie-breaker, always. Matching indexes are required for hot or high-
  cardinality collections and queries shown materially expensive at representative scale. A low-
  frequency operator/admin list expected to remain in the low thousands may rely on its FK index
  and a database sort; an `EXPLAIN` containing `Sort` is not by itself a finding. Prefer
  `WHERE EXISTS` over broad `IN` subqueries; no unbounded `pluck` fed into a second query; analyze
  plans for new expensive queries as executed.
- A `LIMIT` on affected rows does not bound discovery work when joins, anti-joins, OR predicates,
  filters, or ordering run before it. Recurring and bulk convergence must first materialize an
  index-aligned source window, count every scanned source row against the invocation budget, and
  apply cross-table or otherwise unindexable predicates only to that window. When representative
  retained-history skew matters, refresh statistics and explain the exact production source and
  applying SQL; a logically matching index is not accepted merely because PostgreSQL could choose
  it in theory. Applying DML must not reintroduce an unbounded range or child-table scan after ids
  have been materialized.
- A hard source-window plan regression pins the plan property: after refreshing statistics, explain the
  exact production source with `ANALYZE, BUFFERS` against representative data whose eligible source
  is larger than the window cap. The plan must let `LIMIT` stop an order-preserving `Index Scan` or
  `Index Only Scan` at that cap, with every source predicate either in the index condition or
  implied by the chosen partial-index predicate, no pre-limit sort/bitmap/sequential walk, and no
  source predicate degraded to a post-scan filter. A bitmap scan, or a PG 18 skip scan over an
  unrelated leading prefix, is not hard-window capture merely because its child has the right
  index conditions: it may materialize or walk the full eligible set before sorting and limiting.
  Pin the index name when it is part of the proof. This hard-window rule applies to recurring or
  incrementally drained work, not to a deliberately synchronous authority cut implemented as one
  indexed set DML statement over its owning table. That single statement is already the physical
  boundary; do not manufacture a source relation, cursor, temporary table, row-lock cohort, or
  progress ledger merely to prove that it is bounded. Its guarded target relation may include the
  correlated predicate that defines which rows lose authority in the accepted command order; that
  does not turn the single authority update into recurring convergence. The statement still needs
  an index-aligned entry into its owning target table and a representative query-plan argument. An
  exact index below a pre-limit join or sort does not prove early stopping.
  When two indexes price within noise of each other on a real source, that ambiguity is itself the
  defect: remove the rival (a state-partial frontier usually does) rather than blessing whichever
  plan.
  Representative seeds must make dominance decisive in the estimator's terms — the planner prices
  share-of-table and LIMIT fractions and is blind to physical id clustering, so a profile that
  owns a quarter of the corpus makes every full-walk rival look cheap no matter where its rows sit.

## Locking Ladder And Transactions

Use the least blocking mechanism that proves the invariant, in order:

1. Database constraints (unique indexes, FKs), with `RecordNotUnique` rescue only when the product
   contract requires a stable loser — the constraint alone already protects singleton creation.
2. Lock-free business-precondition checks and guarded writes (compare-and-set `UPDATE ... WHERE`,
   treating 0 rows changed as losing the race).
3. Rails optimistic locking (`lock_version`) when stale-write detection is enough.
4. A single-row lock (`lock!`, `with_lock`, locked relation) on the one row that owns the write
   ordering — the aggregate being mutated. The aggregate's own lock, taken first under a service's
   `call` (`@conversation.with_lock do … Outcome.refused(:not_found) if tombstoned?`), is this
   rung and needs no separate justification. Every other lock site requires one: a second row locked
   under the first, a locked relation, a lock inside a model method or a sweep — one line naming the
   race and why the weaker rungs cannot express it (a verb that answers which precondition failed
   cannot read that off a CAS's 0 rows changed); reviewers reject those sites without it. Never a
   recursive ancestor lock chain — read ancestor operability lock-free; stragglers are absorbed by
   mark-then-cleanup.
5. `with_advisory_lock` last, only for a short cross-row critical section no constraint can
   express; bounded timeouts on request paths, stable namespaced lock names. Each sanctioned use is
   pinned by a guard test.

- A record already in hand locks itself with `with_lock`; `Model.lock.find_by(id:)` belongs to
  id-addressed entrypoints such as jobs. Singleton creation uses `create_or_find_by!`, with
  `previously_new_record?` selecting the branch. Optimistic `lock_version` writes use `save` and
  map `StaleObjectError` into the namespace result inside the service, never a controller-wide
  `rescue_from`.
- Never acquire row or advisory locks inside ActiveModel validations — validations are side-effect
  free; operability gating during writes belongs to the owning transaction or a cleanup/admission
  pass.
- One SQL statement sees one snapshot, taken when it starts — not when its locks arrive. A blocked
  UPDATE/DELETE re-evaluates only the conflicting rows it already found; a row committed by a
  concurrent transaction while the statement waited is invisible to every part of that statement,
  including sibling sub-statements of a data-modifying CTE. Therefore: when a contract promises a
  same-transaction collateral effect, claim and collateral are separate statements in one
  transaction — the second statement's fresh snapshot sees commits the first waited out, and the
  claim's held row locks fence the gap. A single statement whose predicate reads other tables is
  acceptable in a level-triggered sweep where the next pass heals lag, or in a chartered authority
  cut where that statement's snapshot defines the accepted target set and no same-transaction
  collateral effect is promised. Other uses need a load-bearing reason written at the site: either
  every writer of the predicate's tables serializes on a row lock this statement already holds, or
  a domain argument (e.g. a family deep past its lapse window cannot mint tokens) excludes
  concurrent writers outright.
- ModelInvocation authority cancellation is one indexed guarded `UPDATE` of nonterminal parent
  Invocations. It acquires no explicit row-lock cohort and does not synchronously mutate Attempts;
  the level-triggered post-cut owner converges Attempt and settlement disposition afterward.
- Deadlocks are prevented by one global acquisition order, not review intuition. The current
  ladder is pinned mechanically by `nexus/test/lock_order/*_test.rb`, using
  `nexus/test/test_helpers/lock_order_test_helper.rb` — it instruments the SQL
  stream of the real flows and fails on any transaction acquiring tables out of order, and on any
  table taking explicit locks without a deliberate place on the ladder. A new locking flow derives
  its additions from its schema, extends the guard's ladder and driven flows, and documents the
  intended order at each lock site with a race test for the
  write-write pairs (the within-table edges — mapped agent before connecting human, humans by id —
  are what the site comments and race tests carry; the guard sees only tables).
- The live guard is the sole authority for table ranks:
  `nexus/test/test_helpers/lock_order_test_helper.rb`
  (`FOUNDATION_LOCK_LADDER`, `MODEL_WORK_LOCK_LADDER`), with failure-mode tests in
  `nexus/test/lock_order_guard_test.rb`. Do not keep a prose rank list. Existing Workspace/User
  authority rows precede the model-work suffix; only tables taking explicit locks are ranked.
  The private OAuth task is the receipt exception: its write-once terminal slot locks after its
  Session. Fully immutable receipt/entry/attachment/event child rows stay unranked so a new
  explicit lock fails loudly. Each new locking flow extends the driven guard rather than
  improvising a rank.

## Provider Configuration And Authorization

- Provider configuration, authorization, credential, and runtime writers acquire only their real rows in
  the live guard's order. Any required issuing-User lock precedes the provider suffix. Provider IO
  holds no database row lock or connection. Account stays off the operational ladder: the
  configure-once cost-unit command uses a nil-only guarded update, never `Account FOR UPDATE`.
- `ModelProviderConfig` is the sole database catalog overlay and retained provider-lane mutex.
  Absence means no database overlay. Creation uses the unique `(account_id, provider_id)` winner,
  including a first enable/definition edit/model removal/visibility choice. A visibility choice
  creates its missing Config disabled and never changes credentials. Disable changes the existing row; model
  tombstones live in `model_overrides`; neither command deletes the Config.
- The nullable `provider_definition` replaces the provider declaration; `model_overrides` then
  applies model definitions and independent Account-wide `hidden_models` and `unavailable_models`.
  Unavailable models retain their definitions and pricing and join the effective hidden set; clearing
  unavailability never removes an explicit hidden setting. `ModelProviderConfig`
  defines the bounded document's closed keys, `upsert | remove` entries, lane containment, ref/byte
  bounds, and validation. `ModelCatalog::ModelOverlay` validates composition and warns while
  ignoring invalid stored entries. Provider connections and optional pricing use these owners.
- An effective edit locks/updates its Config using ordinary `lock_version`. Readers compose
  committed Config rows with one current in-memory file snapshot; there is no Account-wide
  CatalogState, generation bump, or invalidation proof. Database failure propagates as
  unavailability, never an empty overlay. Public editing rules live in `.ai/api.md`.
- Authorization acceptance locks Config first. A Human device start may create a disabled anchor
  and run while disabled; refresh requires an existing enabled lane. Start resumes its issuer's
  pending ceremony unless an explicit restart creates its successor. The Config orders those
  commands against disable/clear; there is no command-create receipt or exact replay contract.
- Each outbound claim locks Config then Session, rechecks the persisted next-action time, and
  inserts one private ModelProviderOAuthTask. Release every lock and connection before HTTPX IO.
  Apply/stale-dispatch collection locks Session then Task, followed by Credential if needed.
  Installation locks Config, Session, Task, then Credential. A successful device start enables
  Config in that transaction; refresh never changes enablement. API-key save likewise locks
  Config before Credential and enables only on success. Existing lineage/generation fences stop
  old results from replacing newer credentials. Progress without a claim may end at Session.
- Disable locks Config then pending Sessions and revokes them even if already disabled; a stale
  Config version changes neither. Clear locks Config, pending Sessions, then Credential, closing
  and secret-clearing Sessions and removing the local credential atomically without provider IO.
  Apply still needs a pending Session and dispatching Task, so clear-first blocks late recreation
  and install-first is followed by clear. Human authorization is checked at the Platform boundary,
  without adding a User lock around this low-frequency command.
- Collection requires terminal `updated_at + 30 days` and terminal children. Delete OAuth Task
  children before Session; its `RESTRICT` FK enforces that order. The authorization domain owns
  refresh/reuse/crash recovery; `.ai/jobs.md` owns wake scheduling and `.ai/api.md` the public
  projection. Development diagnostics introduce no durable lineage or digest.
- Provider start uses ModelInvocation as its arbiter, reloads the Attempt under that lock, and
  adds no Attempt lock. Priced work consults the settled-cumulative budget guard at admission;
  start takes no budget or catalog-state lock. It resolves the current Catalog/profile/endpoint
  and credential before claiming, using the Invocation's immutable model keys and semantic
  options. Only the in-process send context crosses the claim. There is no persisted revision,
  digest comparison, or drift requeue; a local token cannot prove a remote provider's version.
- `model_provider_runtime_states` is written last in `ApplyResult` by one
  `INSERT ... ON CONFLICT DO UPDATE`, after Invocation and usage writes. This implicit row lock
  is outside the explicit-lock guard. Any additional writer must preserve that order; a new
  observation mechanism also meets `.ai/jobs.md`'s Model And Provider Recovery requirements.

## Execution, Settlement, And Reclamation

- Aggregate/execution writers follow the live guard, including its Workspace/User, purpose-owner,
  content, and Invocation ordering. A candidate scan may precede locking; recheck write facts after
  acquisition. Skipping unused ranks is valid; reversing ranks is not. In settlement, a
  still-existing User is a serialization anchor even when suspended or removed, not an operability
  gate. UsageBudgetEntry is an inserted immutable child and takes no explicit lock.
- The receipt writer converges on immutable UsageRecord by unique insert. The normal apply path
  shares the Invocation transaction: reload/write Attempt under the parent arbiter and increment
  the usage summary there. The separate spend batch claims receipts `FOR UPDATE SKIP LOCKED`
  before discovering payers, then locks payers and sorted UsageBudgets and commits each receipt's
  settlement marker with its charge. Effective pricing is recorded with the receipt, not frozen at
  provider start; spend settlement never locks ModelProviderConfig.
- ModelInvocation cancellation changes nonterminal parents through the single indexed set update
  described in Locking Ladder And Transactions. Post-cut/deadline passes materialize bounded
  Attempt ids before parent reads, lock the Invocation arbiter, and reload/recheck Attempt without
  a child lock. A terminal parent is never rewritten. Pending-settlement Attempts fence
  reclamation; `CloseAbandonedSettlements` bounds that wait.
- Lock order and FK-safe deletion order are distinct. `InferenceRequests::Drain` locks its aggregate parents,
  then deletes ContentBodies and lets declared cascades remove entries and body-upload joins.
  Shared Fragments stay for orphan reaping. Explicitly purge output blobs where bulk Invocation
  deletion bypasses Active Storage callbacks.

## Cross-Aggregate Transactions And Implicit Locks

- Two-phase cross-aggregate applies are the ordinary house idiom: flip and commit the owning row
  first, then apply results to other aggregates after commit. A domain command explicitly chartered
  under `.ai/boundaries.md` may instead make one accepted-order authority cut with an indexed set
  DML statement on the real authority rows. It documents the query plan and bypassed side effects;
  this does not authorize cross-aggregate orchestration or per-record callbacks while holding the
  owner.
- An INSERT takes a `FOR KEY SHARE` lock on every row its FK columns reference, and that conflicts
  with `FOR UPDATE` — a held-lock INSERT is a hidden lock acquisition. Before adding an INSERT (or
  an FK-changing UPDATE) inside a transaction that already holds row locks, check its FK target
  tables against rows other lanes hold; the explicit lock call is absent from the diff.
- For every model-work insert or FK-changing update performed while an authority, owner, body, or
  invocation row is already locked, enumerate the ordinary FK targets as implicit
  `FOR KEY SHARE` edges during review. A new edge that points back above an already-held table is a lock-order defect even when no
  explicit `lock` call appears in the diff.

## Usage And Content Lock Edges

The following writer/FK edges supplement the explicit-lock guard:

- Result output application: `ApplyResult` stages Active Storage blob IO before the transaction,
  locks the Invocation, reloads the Attempt under that arbiter, writes response/reasoning bodies
  and attaches output blobs; the receipt writer shares that transaction. Body, Upload, and
  Attachment FKs point only to handled parents. Every exit that did not attach purges staged blobs.
- Task operation acceptance and first observation serialize on the owning AgentRun,
  as do child settlement, retry, Stop and execution-detail collection. Operation INSERTs reference
  Account and the parent AgentRunTask; observation ContentBodies reference Account and that
  operation. Entry INSERTs reference Account, the new body and shared ContentFragments; upload
  joins reference the new body and already-bound ContentUploads. Operation rows take no explicit
  lock or independent rank. Account has no operational exclusive lock, and existing child upload
  joins retain captures until the observation creates its own joins. Collection destroys each
  operation's bodies before the operation and parent task, leaving shared fragments and uploads
  to their existing orphan collectors.
- UsageRecord retains only its required Account FK plus immutable public-id attribution
  snapshots, including its Human payer. It has no User/Workspace/InferenceRequest/Invocation/
  BillingSubject live sourcing FK, so no lane through the receipt can acquire a reverse
  authority/owner edge. Every headroom-changing writer (the settle batch) takes the
  still-existing User locks first — including suspended/removed rows until hard-delete,
  without treating that lock as an active gate.
- UsageBudget's live User FK is required, in the column and on the association; a budget leaves
  only with the Account's own cascade, which `Account` declares ahead of `has_many :users`.
  Immutable User public-id/kind snapshots and Account/budget anchors retain ledger interpretation
  and settlement without a cascading delete.
- The event plane (`inference_request_events`, `inference_request_event_items`, `inference_request_event_cursors`) has live
  InferenceRequest FKs on all three tables, so every append's RI check takes `FOR KEY SHARE` on the aggregate.
  The events converger therefore locks the InferenceRequest before its Invocation, matching Drain's
  acquisition order. The cursor is the plane's one explicitly locked table, ranked by the live
  guard; Drain deletes the plane
  child-first under the same inference_request lock it already holds.
- Usage summary and time-bucket tables take no explicit locks and stay off the ladder. Summaries
  are create-or-incremented in the receipt transaction. `UsageRecords::Record` uses the caller's
  Invocation lock or acquires that lock itself, including for discarded/abandoned results, then
  reloads Attempt. Pending settlement also fences reclamation; `CloseAbandonedSettlements` closes
  that wait after the 7-day late-evidence window. Drain deletes
  summaries under its InferenceRequest lock. Conversation reap deletes its summary under the
  Conversation lock after locking pending receipt-writing Invocations, including Runs
  detached by turn undo and found through their immutable conversation attribution.
  A late receipt retains that attribution but never recreates a deleted subject's cache.
  The recurring bucket drain claims receipts
  `FOR UPDATE SKIP LOCKED`, then updates buckets in sorted `[bucket_start_at, aggregation_key]`
  order so implicit UPDATE locks cannot invert. Both tables' Account FK takes `FOR KEY SHARE` on
  insert; no model-work path exclusively locks Account.

Every future FK added to these paths updates this writer/FK map and its driven guard/race tests
in the same change.

## Transaction Boundaries And Races

- Write-write interaction pairs whose ordinary workflow promises convergence or whose failure can
  violate integrity, duplicate an irreversible effect, or leave partial state get a race test
  asserting the documented outcomes. An exceptional fully rolled-back database loser needs an
  invariant/constraint test, not a friendly-result rescue or a threaded race harness.
- Do not lock independent aggregates or add a final reread merely to make commit timestamps choose a
  winner. When every result is equivalent to an allowed serial order and a dominant durable status
  remains the final authorization/effect gate, an intermediate stale read is harmless. Coordination
  is required only when the otherwise-reachable final state breaks an invariant, repeats an
  irreversible effect, leaves partial state, or violates a written cross-command winner rule.
- Keep transactions short: no HTTP, filesystem, long CPU, or cross-system side effects inside.
  Render/list/poll/status paths acquire no locks. Schedule jobs after commit when they depend on
  committed state. Execute large `UPDATE`/`DELETE`/backfills in small bounded batches; use a
  resumable job when one scheduled invocation cannot safely finish the work. The narrow exception
  is a rare domain command whose correctness boundary is one atomic authority transaction over one
  indexed set DML statement on real authority rows, as chartered by `.ai/boundaries.md`. The
  exception needs an expected-cardinality/query-plan argument and explicit replacement for any
  model callbacks or derived projections bypassed by bulk DML; it never extends to temporary
  winner relations, progress ledgers, waiting for graceful convergence, scanning historical rows
  without an index, or a Ruby per-record loop. If one statement is materially too large, move the
  collateral convergence after the authority cut and drain it with the ordinary bounded recurring
  rules instead of weakening the cut.
- Credential KDF and verification follow prepare-then-commit: perform BCrypt and other expensive
  password work outside transactions and row locks, and treat the result only as prepared data.
  For a new credential, validate and persist that prepared record inside the owning transaction.
  For an existing credential, recheck the mutable snapshots that own its winner rule and whose
  staleness could leave an authorizing credential after the mutation should lose: the identifier,
  credential digest, recovery/authority generation fences, and, when the write can create or
  preserve usable authority, the acting member's status. An independent dominant status that still
  gates every later use need not share a lock merely to force commit-time ordering. Never hold a
  database connection or lock merely to run a KDF.
- `destroy`/`destroy!` when relying on `dependent: :restrict_with_exception`. Avoid `reload` as a
  freshness tool — return the mutated object or do a narrow scoped lookup; `reload(lock: true)`
  only when a fresh row image and `FOR UPDATE` are both deliberately needed.
