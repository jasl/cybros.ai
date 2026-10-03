# Database Principles

**Applies to:** `nexus` — it is the only project with a database.

## Schema Policy

Pre-release: correctness and maintainability beat compatibility. Destructive schema cleanup is
allowed, compatibility shims for deleted names are never kept, and local/generated data may be
cleared when it blocks a clean reset. `nexus` owns `db/schema.rb`, the truth every world loads
(`db:schema:load:primary`; the e2e worlds never walk the migration path).

**The migrations fold** (owner ruling 2026-09-14): at each fold `db/migrate` holds ONE
schema-creating migration (`create_nexus_schema`) that produces `db/schema.rb` exactly, and every
intermediate step — renames, relaxations, backfills, every data migration — is deleted; between
folds a schema change is one migration per change. A development database from before a fold is
rebuilt, never migrated across it: run `bin/rails db:reset` before `bin/setup`.
`bin/setup --reset` runs `db:prepare` first, so a pre-fold schema can fail
before that script reaches its reset step.

Proving that the migrations reproduce the committed schema: `db:migrate` against an empty primary
loads `db/schema.rb` first when the file exists, so move the dump aside, run
`bin/rails db:drop db:create db:migrate`, and diff the fresh dump against the committed one.
Reset or load queue/cable only through their database-qualified tasks (`db:reset:queue`,
`db:reset:cable`, `db:schema:load:queue`, `db:schema:load:cable`) when that database is
intentionally in scope: the unqualified `db:migrate:reset` drops every configured database,
migrates only the primary, and can overwrite `db/queue_schema.rb` and `db/cable_schema.rb` with
empty dumps.

## Migrations, Tables, Columns

- Domain tables, models, and independently persisted state not already required by the accepted
  design are subject to the Design Expansion Gate in `.ai/boundaries.md`; persistence convenience
  is not a domain boundary.
- One schema-creating migration at each fold; between folds one migration per change, named
  after the concrete schema change, never after a plan, phase, or umbrella such as `foundation`.
- Reversible `change` or explicit `up`/`down`; non-reversible data migrations explain why rollback
  is a no-op. DDL separate from large DML. No application models/services in migrations — use a
  small local migration class. No DB access from initializers.
- Foreign keys for real ownership; index FK columns. Add query indexes for current hot or high-
  cardinality `WHERE`/`JOIN`/`ORDER BY`/`GROUP BY` paths; when a composite index is justified, match
  its filter+order and let it replace indexes it makes redundant. Define `ON DELETE` intentionally.
  Append-only ledger tables take no hard FKs from hot paths — nullify-FK plus public-id snapshot
  columns preserve attribution after hard deletes (`.ai/patterns.md`).
- A self-referential parent on `users` is a nullable FK with `on_delete: :nullify` and its own
  index — `steward_id` (the Human a profile answers to) and `derived_from_id` (the paired instance
  that DECLARED a named definition, capabilities III); the named definition's other two facts are
  `definition_scope` (`instance | steward`, NULL on every paired row — the marker column the door
  matches on, never a prefix read back from the identifier) and `description` (`limit: 1024`,
  the one line a spawner chooses it by). Removal is a status cascade in the model, never a
  `dependent:` on the association.
- Every domain table denormalizes `account_id`, populated by the owning creation path
  (`belongs_to :account, default: -> { parent.account }`), never public input; freeze with
  `attr_readonly`. Two shapes carry none: a pure join row (`content_body_uploads`) and an
  immutable child of an account-anchored parent (`usage_budget_entries`, which snapshots
  `account_public_id` for attribution instead).
- **Status and other closed vocabularies take NO length limit** (owner ruling 2026-09-04). A status
  is an internal field whose every value the program defines and `validates :inclusion` enforces; a
  byte ceiling on top of that constrains nothing a caller can reach and everything a designer can
  name. It cost a real decision once: the agent-loop plane nearly named its reserved approval state
  to fit sixteen bytes rather than because it was the better word. Existing columns keep their
  limits until a change has a reason to touch them; new ones declare none.
- Rails models own business validation and the actionable errors returned to callers. Normalized
  values, length and numerical bounds, allowed vocabularies, and cross-field or lifecycle shapes
  use Active Record validations, not SQL CHECK constraints. Nexus application migrations do not
  use `add_check_constraint`; a future storage-level exception requires explicit user approval.
  Database types and limits, `NOT NULL`, foreign keys, unique indexes, and defaults remain
  structural and concurrency backstops. Model preconditions/validations provide the ordinary
  friendly uniqueness path and a unique index decides the final winner. Map a database loser to a
  domain result only when the written contract or an ordinary production collision requires it;
  exceptional fully rolled-back losers follow `.ai/boundaries.md`.
- **Model-work programme scoped ruling (2026-07-31):** specs 12, 20, and 21 deliberately enforce
  their closed owner/purpose/active shapes through owning associations, model validation, one
  semantic writer, owner-row serialization, and guarded status transitions. Those slices do not
  add typed `(account_id, id)` composite foreign keys, owner-role/purpose/active-attempt partial
  unique indexes, or product SQL CHECK constraints. They retain ordinary foreign keys to real parents,
  nullability, query indexes, and ordinary unique indexes that are themselves an identity or a
  real concurrency winner (for example public ids, receipt keys, owner/invocation 1:1 identities,
  attempt ordinals, body positions, and Account-scoped digests). This is a named exception for
  that programme, not a weakening of the default structural-backstop rule for unrelated models.
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
- A hard source-window plan regression pins the PROPERTY: after refreshing statistics, explain the
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
  exact index appearing below a pre-limit join or sort does not prove early stopping for work that
  actually requires a bounded source window.
  When two indexes price within noise of each other on a real source, that ambiguity is itself the
  defect: remove the rival (a state-partial frontier usually does) rather than blessing whichever
  plan.
  Representative seeds must make dominance decisive in the ESTIMATOR's terms — the planner prices
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
   ordering — the aggregate being mutated. The aggregate's own lock, taken FIRST under a service's
   `call` (`@conversation.with_lock do … Outcome.refused(:not_found) if tombstoned?`), is this
   rung by name and carries no sentence. Every other lock site does — a second row locked under
   the first, a locked relation, a lock inside a model method or a sweep — one line naming the
   race and why the weaker rungs cannot express it (a verb that answers WHICH precondition failed
   cannot read that off a CAS's 0 rows changed); reviewers reject those sites without it. Never a
   recursive ancestor lock chain — read ancestor operability lock-free; stragglers are absorbed by
   mark-then-cleanup.
5. `with_advisory_lock` last, only for a short cross-row critical section no constraint can
   express; bounded timeouts on request paths, stable namespaced lock names. Each sanctioned use is
   pinned by a guard test.

- Never acquire row or advisory locks inside ActiveModel validations — validations are side-effect
  free; operability gating during writes belongs to the owning transaction or a cleanup/admission
  pass.
- One SQL statement sees one snapshot, taken when it starts — not when its locks arrive. A blocked
  UPDATE/DELETE re-evaluates only the conflicting rows it already found; a row COMMITTED by a
  concurrent transaction while the statement waited is invisible to every part of that statement,
  including sibling sub-statements of a data-modifying CTE (the M5 cancellation CTE lost a
  reconciler-committed projection row exactly this way). Therefore: when a contract promises a
  SAME-TRANSACTION collateral effect, claim and collateral are separate statements in one
  transaction — the second statement's fresh snapshot sees commits the first waited out, and the
  claim's held row locks fence the gap. A single statement whose predicate reads OTHER tables is
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
  table taking explicit locks without a deliberate place on the ladder. A new lane (task-delivery,
  conversation) re-derives its additions from its own schema, extends that guard's ladder and
  driven flows, and still documents the intended order at each lock site with a race test for the
  write-write pairs (the within-table edges — mapped agent before connecting human, humans by id —
  are what the site comments and race tests carry; the guard sees only tables).
- THE LIVE GUARD IS THE LADDER'S ONE AUTHORITY:
  `nexus/test/test_helpers/lock_order_test_helper.rb`
  (`FOUNDATION_LOCK_LADDER` + `MODEL_WORK_LOCK_LADDER`), with the guard's own
  failure-mode tests in `nexus/test/lock_order_guard_test.rb`.
  This file once froze a prose copy of the ranks and the copy rotted — the re-audit found it
  still naming six deleted or renamed tables (`usage_reservations`, `usage_ledger_heads`,
  `event_streams`, `model_invocation_queue_entries`, the two `authorization_*` spellings)
  while omitting the live head (`usage_records`, ranked first for the settle batch's
  scan-is-discovery shape) and tail (`one_shot_event_cursors`) — so the prose copy is gone:
  read the guard. What stays here is the RULES: existing Workspace/User authority rows precede
  the model-work suffix; only rows expected to take explicit locks are ranked; the OAuth task
  row is the named exception among receipts (its write-once terminal slot is locked after
  Session); fully immutable receipt/entry/attachment/event child rows stay absent so any future
  explicit lock on one fails loudly; each physical slice adds its real driven flow to the
  guard, never a newly improvised rank.
- `model_provider_runtime_states` is written by one `INSERT … ON CONFLICT DO UPDATE` last inside
  `ApplyResult`'s invocation-locked block: an implicit row lock the guard cannot see, safe by order
  (after `model_invocations` and the usage rows; no other writer).
- Provider policy/authorization/credential/runtime writers acquire only their real rows in the
  order above. They resolve and acquire any required issuing-User lock before the provider suffix
  and never hold any database row or connection across provider
  IO. Account remains intentionally absent from the ladder: model work does not use
  `Account FOR UPDATE`; the configure-once cost-unit command is the named nil-only guarded root
  update and does not enter an operational lock chain.
  An absent ModelProviderPolicy remains semantically “no database overlay”. The ordinary
  policy-enable and definition-authoring commands, including a first interactive model removal,
  share its unique `(account_id, provider_id)` winner, which owns concurrent creation. Once
  present, the row is retained as the provider-lane mutex: there is
  no delete writer — disable updates the flag/overlay in place and model tombstones are operations
  inside the `model_overrides` document, never row deletes.
  `ModelProviderPolicy` is the sole database catalog-content overlay: its nullable
  `provider_definition` replaces a provider declaration, then `model_overrides` applies model
  definitions and its independent Account-wide `hidden_models` visibility list. The model
  document's shape, entry vocabulary, containment, and logging contract remain spec 12 D2's;
  the 2026-09-30 custom-model-settings ruling permits provider connections and optional pricing.
  A committed effective change locks and updates its ModelProviderPolicy row with ordinary
  optimistic `lock_version`; there is no Account-wide CatalogState row, generation bump, or
  invalidation proof. Readers compose committed Policy rows with one current in-memory file
  snapshot. Database unavailability propagates as unavailability rather than being treated as an
  empty overlay.
  Provider authorization acceptance locks the ModelProviderPolicy lane first; a Human device
  start creates a disabled anchor when absent and may run while disabled. Refresh requires
  an existing enabled lane. Device start resumes
  its issuer's pending ceremony, unless an explicit restart supersedes it and creates its
  successor. There is no command-create receipt or exact replay contract. The Policy orders
  start/restart against disable and clear. Each outbound claim locks Policy then Session,
  rechecks the persisted next-action time and inserts one private ModelProviderOAuthTask;
  every lock and connection is released before HTTPX sends a byte. Apply and stale-dispatch
  collection lock Session before its OAuth Task, followed by the current Credential when
  needed. Credential installation first locks Policy, then Session, Task and Credential; a
  successful device start enables Policy in that transaction, while refresh never changes it.
  Interactive API-key save likewise locks Policy before Credential and enables only on success. The existing lineage/generation comparison prevents an old result installing over
  newer credentials. A progress mutation with no claim may end at Session.
  Disable locks Policy → pending Sessions and revokes them even when already disabled; a stale
  policy version changes neither. Clear locks Policy → pending Sessions → Credential and terminalizes/secret-clears the
  sessions and removes the local credential in one transaction, with no provider IO. An apply
  still requires its Session pending and its Task dispatching, so clear-first forbids late
  recreation; install-first is followed by clear. Issuing Human authorization is checked at
  the Platform request boundary, not by a new User lock around this low-frequency command.
  A terminal Session is collectible only after its terminal `updated_at + 30 days` and all
  children terminal; its collector explicitly deletes OAuth Task children before the parent,
  whose required `RESTRICT` FK prevents cascade/order
  drift. Crash recovery and refresh/reuse mechanics remain owned by the authorization domain;
  development diagnostics add no persisted lineage or digest.
- Provider start is a distinct forward-only lane. It uses ModelInvocation as the start arbiter and
  reloads the Attempt under that lock; it does not add a second Attempt lock. Priced work
  consults the settled-cumulative budget guard at admission; provider start takes no budget or
  catalog-state lock.
  The send reads one current process-local Catalog snapshot, then derives the execution profile,
  endpoint, and other wire facts used to compile the request before ProviderStart claims the
  Attempt. The Invocation's narrow immutable fields supply stable provider/model keys and semantic
  options. Only the resulting in-process send context crosses the claim. There is no persisted
  revision, digest comparison, or drift requeue:
  a local token cannot prove the version of a remote Provider. Credential resolution also reads
  current state immediately before claim. Provider IO holds no database lock.
  Any future provider-observation projection must land its writer, reader,
  recovery pass, and tests as one reachable slice. Do not prebuild a runtime
  state row or partial lock suffix for an unwired consumer.
- Outside that provider-start lane, aggregate and execution writers start with any real
  Workspace/User authority rows (the pinned principal order), then their purpose owner
  (OneShot), ModelInvocation, then content rows
  (ContentBody, ContentFragment/ContentUpload) — the live guard carries the full ranks. An
  unlocked candidate scan may precede the first lock; every fact is rechecked after
  acquisition. Skipping an unused rank is valid; reversing one is not. In every settlement
  lane, "still-live User" means the row still exists — a serialization predicate, not an
  operability gate. UsageBudgetEntry is an inserted immutable child and takes no explicit
  lock. Account remains outside the ladder.
  RECEIPT AND SPEND ARE THE LANDED LANES (Stage 4 item 3; the reserved first-insert
  revalidation lanes this section once specified left with the reservations): the receipt
  writer converges on the immutable UsageRecord by unique insert inside its caller's
  Invocation transaction (the Attempt is reloaded and written under the parent arbiter; the
  summary increment rides the same transaction); the
  settle batch claims receipts `FOR UPDATE SKIP LOCKED` — the ladder's HEAD, because the
  scan IS the discovery — then locks payers and their sorted UsageBudgets, and marks each
  receipt settled with its charge in one commit. Settlement reads effective pricing at
  settlement (D17); nothing frozen at start remains to compare, and settlement never locks
  ModelProviderPolicy.
  ModelInvocation cancellation changes only nonterminal parents in its single indexed set update.
  Post-cut Attempt convergence and deadline discovery start from their indexed frontiers,
  materialize bounded ids before any parent join, lock the Invocation arbiter, then load/recheck
  the Attempt without a duplicate child lock; an already-terminal parent is never rewritten. The
  reclamation gates
  additionally fence on pending-settlement attempts (item-7 review;
  `CloseAbandonedSettlements` bounds the fence).
  Teardown lock order and FK-safe delete order are distinct. `OneShots::Drain` locks its real
  aggregate parents, then deletes ContentBody rows and lets their declared database cascades remove
  entries and body-upload joins; shared Fragments remain for the orphan reaper. It still explicitly
  purges output blobs where bulk Invocation deletion bypasses Active Storage callbacks.
- Two-phase cross-aggregate applies are the ordinary house idiom: flip and commit the owning row
  first, then apply results to other aggregates after commit. A domain command explicitly chartered
  under `.ai/boundaries.md` may instead make one accepted-order authority cut with an indexed set
  DML statement on the real authority rows. It documents the query plan and bypassed side effects;
  this does not authorize cross-aggregate orchestration or per-record callbacks while holding the
  owner.
- An INSERT takes a `FOR KEY SHARE` lock on every row its FK columns reference, and that conflicts
  with `FOR UPDATE` — a held-lock INSERT is a hidden lock acquisition. Before adding an INSERT (or
  an FK-changing UPDATE) inside a transaction that already holds row locks, check its FK target
  tables against rows other lanes hold; this edge is invisible in diffs (it caused the old repo's
  2026-06-11 production-class deadlock).
- For every model-work insert or FK-changing update performed while an authority, owner, body, or
  invocation row is already locked, enumerate the ordinary FK targets as implicit
  `FOR KEY SHARE` edges during review. Copied admission scan facts intentionally have no
  independent Account/User/provider FKs; the entry has only its real ModelInvocation owner FK.
  A new edge that points back above an already-held table is a lock-order defect even when no
  explicit `lock` call appears in the diff.
- The M0 implicit-FK audit fixes the four current high-risk paths:
  - Result output application (the landed shape — binary outputs ride Active Storage by owner
    ruling; the ModelInvocationAttemptOutput adoption lane and its reserved finalizer suffix
    this bullet once specified left with the reservations): ApplyResult stages blob IO BEFORE
    the transaction, locks Invocation, reloads the Attempt under that arbiter, writes the
    response/reasoning bodies and
    attaches, and the receipt writer rides the same transaction. Body, Upload, Attachment FKs
    point only to already handled parents; every exit that did not attach purges what was
    staged.
  - UsageRecord retains only its required Account FK plus immutable public-id attribution
    snapshots, including its Human payer. It has no User/Workspace/OneShot/Invocation/
    BillingSubject live sourcing FK, so no lane through the receipt can acquire a reverse
    authority/owner edge. Every headroom-changing writer (the settle batch) takes the
    still-existing User locks first — including suspended/removed rows until hard-delete,
    without treating that lock as an active gate.
  - UsageBudget's live User FK is required, in the column and on the association; a budget leaves
    only with the Account's own cascade, which `Account` declares ahead of `has_many :users`.
    Immutable User public-id/kind snapshots and Account/budget anchors retain ledger interpretation
    and settlement without a cascading delete.
  - The event plane (one_shot_events / _items / _cursors, Stage 4 item 4) carries live one_shots
    FKs on all three tables, so EVERY append's RI check takes FOR KEY SHARE on the aggregate row.
    The events converger therefore locks the OneShot BEFORE the invocation it converges — the
    ascending-edge ABBA against Drain (one_shot FOR UPDATE, then the invocations) was caught in
    the item-4 review and closed by that ordering. The cursor is the plane's one explicitly
    locked table (the ladder's last rank, with a driven guard flow); Drain deletes the plane
    child-first under the same one_shot lock it already holds.
  - The rollup planes (model_usage_summaries / model_usage_time_buckets, Stage 4 item 7) take NO
    explicit locks, so neither table joins the ladder: summaries are create-or-incremented inside
    the receipt writer's transaction — the applied paths hold the invocation far above, and the
    one path that does not (record_discarded, after losing the CAS) is fenced by the reclamation
    gates' pending-settlement predicate instead, so Drain never overlaps a live summary writer
    (the item-7 review caught the original "caller already holds the invocation" claim as false
    for that path); the fence is bounded by `CloseAbandonedSettlements` (capture-dead pendings
    become `abandoned` after the 7-day late-capture window, so no aggregate wedges) — and
    deleted by Drain under its one_shot lock; bucket rows are touched
    only by the recurring drain, which claims receipts FOR UPDATE SKIP LOCKED (the ladder head)
    and then applies bucket increments in sorted [bucket_start_at, aggregation_key] order so
    overlapping drains never take the same implicit UPDATE locks in opposite orders. Both tables'
    account FK takes KEY SHARE on accounts at insert; accounts stays deliberately off the ladder
    (nothing in model work locks it exclusively).
  Every future FK added to one of these paths must update this audit and its driven guard/race tests
  in the same slice.
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
