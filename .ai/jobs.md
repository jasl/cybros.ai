# Job And Queue Principles

**Applies to:** `nexus` — Active Job, Solid Queue, scheduling, and asynchronous recovery.

## Execution Hosts

- Streaming LLM calls run on `nexus/bin/model_runner`; Solid Queue runs blob workloads and provides
  another capable host for text work. `nexus/config/queue.yml` configures fiber workers. Size
  database pools for the installed Solid Queue version, actual concurrency, and connection
  retention; do not assume a fixed fibers-plus-offset boot requirement. Fiber execution requires
  Rails' fiber-scoped isolated execution state, and provider IO holds no database connection.
- Wake every capable host immediately: text work notifies the model runner and enqueues its Solid
  Queue job; blob work enqueues its job. `ModelInvocations::Wake` owns this dispatch. There is no
  acceptance-time execution-pair routing, fallback grace period, or persisted delivery preference.
- `ExecuteAttempt` resolves the Invocation's stable provider/model keys against one current Catalog
  snapshot, compiles, then calls `ProviderStart`. The profile's closed allowed-pair set gates the
  actual host/transport before IO. The send context carries that pair in-process, never on the
  Attempt. The single start winner alone consumes the call; other claimants no-op. A different
  host/transport implementation stays disabled until the profile explicitly permits it.
  Claim locking follows `.ai/database.md`'s Provider Policy And Authorization section.
- Real-provider diagnostics remain local development tools under `.ai/repository.md`'s Development
  And Test Placement rules; no diagnostic manifest or output selects production work.

## Job Boundaries

- Jobs are shallow shells: deserialize, call one domain method, and re-enqueue from its answer.
  The call is a service entrypoint or model class method, optionally once per row in a set the
  model owns. Queries, transactions, row locks, and domain arithmetic stay out of `perform`.
  Recurring schedules live in `nexus/config/recurring.yml` as job classes or model class methods;
  the domain logic is testable without the scheduler.
- Models exposing both asynchronous and synchronous entrypoints use `_later`/`_now` pairs.
  An asynchronous-only boundary does not gain an unused synchronous method for naming symmetry.
- Arguments are JSON-native ids and small option hashes, never Active Record objects, large
  payloads, credentials, or prompt bodies. Put the highest-level resource first and optional
  parameters last; extend the trailing options instead of reordering arguments. Jobs never read
  `Current`; actor context is an explicit argument.
- Action Mailer is the argument/shell exception: a domain model may schedule a small Mailer using
  Rails' GlobalID record argument or the flow's stable id. Use `ActionMailer::MailDeliveryJob`
  through Solid Queue; do not add a domain wrapper or subclass solely to recreate the framework.
- Stale job lookups use `find_by` and return when their target is gone. State-mutating jobs recheck
  ancestor operability at perform time and long-running checkpoints; an archive after enqueue
  must not start new work. Converge to the workflow's deferred/canceled state. Cancel/interrupt
  are explicit lifecycle commands; archive cascades only where its contract says so.
- Mark or document idempotency. A non-idempotent job states its duplicate-execution risk and
  mitigation. Schedule after commit when committed state is required.
- Destructive payload changes need a drain or documented queue reset. Any temporary tolerance
  inside a rollout must obey `.ai/boundaries.md`'s No Compatibility Before Release, And What Is
  Not Dead Code rules; it never becomes a committed compatibility layer.

## Continuation And Recovery

- Work spanning IO, time, or crash boundaries uses durable continuation state, idempotent re-entry,
  and a domain termination bound such as an execution deadline or step budget. Hops are short
  transactions, and cancellation lands between them. Do not add hops solely for style on hot paths:
  they cost dispatch latency and additional re-entry/state-machine obligations.
- Long sweeps carry a cursor through bounded jobs that re-enqueue between batches, yielding the
  worker pool. `ActiveJob::Continuable` is appropriate only when that job needs resumability across
  worker stops; it does not replace the fairness of separate job hops. Batch fan-out uses
  `ActiveJob.perform_all_later` over `in_batches`.
- Discovery and applying SQL obey `.ai/database.md`'s Query Design And Bounded Discovery section.
  Every materialized source row consumes budget, including clean, blocked, or retained rows.
  Each independently scanned phase has its own cursor. A phase reaching a partial window parks
  for that continuation chain; the next recurring wake starts it again and revisits blockers.
  A phase whose acted rows necessarily leave its source may self-drain without a cursor.
- Jobs and WebSocket wakes accelerate durable-state convergence. Polling or sweeps remain
  sufficient for correctness; models never depend on a prior job having run. Recompute jobs are
  level-triggered: derive from current rows and continue when more work remains.
- Model work uses Solid Queue's independent `queue` database. Primary authority commits first;
  after-commit enqueue is best effort, and an indexed durable-state scan recovers lost wakes.
  Do not add an outbox, cross-database transaction, or mirrored delivery ledger for that signal.
- Scheduled-input recovery (`Conversations::Inputs::WakeDueJob`) carries `(deliver_at, id)` and
  the chain's original database-clock cutoff, counts every due source row, and deduplicates hosts
  within a page. Busy/paused rooms may retain due inputs indefinitely; the next scheduled scan
  revisits them. Turn convergence has independent reply, settle, reopen, and replace windows;
  pair qualification follows materialization, using bounded correlated probes. A transition that
  already knows its loop sends that precise hint to the same convergence writer without starting
  a global continuation chain.
- Child-reply recovery uses the reply turn's `relayed_at`, with an after-commit child hint and
  `relay_spawned_replies` as the recurring keyset floor. The mail-path receipt and the transaction
  around await settlement plus the relay stamp keep duplicate delivery idempotent.
- Agent removal follows `.ai/boundaries.md`'s Administration Boundary. Its credential cut is
  immediate; the domain stop path runs after commit and from a bounded recurring floor, rechecks
  current removed state, and skips restored Profiles. It distinguishes live historical/background
  work from an unrelated current turn. A paused loop cannot recover a lost wake by its frozen
  timeout clock; the recurring floor is required.
- `SolidQueue::Job.clear_finished_in_batches` is the framework-maintenance exception to application
  continuation rules. One hourly call freezes `finished_before`, deletes self-removing rows in
  upstream 500-row statements without a transaction across batches, and stops at the first empty
  batch. The next hourly call recovers interruptions. Keep the upstream recipe unless representative
  measurement shows it crowds queue work; then select a schedule, throttle, or continuation policy
  from that evidence. It is not a precedent for an application-owned full-corpus drain.

## Model And Provider Recovery

- `ModelInvocations::RedriveStalled` re-wakes aged, still-prepared attempts from a bounded keyset
  frontier. It neither writes lifecycle state nor repeats started provider IO; `ProviderStart`
  still decides whether the work may start. `ApplyResult` owns provider-result application and
  stages/attaches binary outputs through Active Storage; there is no separate output-adoption
  lifecycle. Its transaction and cleanup rules live in `.ai/database.md`'s Usage And Content Lock
  Edges section.
- `ConvergePostCut` materializes active `prepared | running` Attempt ids before reading parent
  status, then locks/rechecks the Invocation and closes the Attempt without rewriting a terminal
  parent. Started work retains pending settlement; admission reserves no unstarted hold.
  `DeadlineSweep` independently scans active Attempts against a database-clock cutoff. A still-live
  parent and its expired Attempt time out together; an already-terminal parent remains the winner
  and its Attempt belongs to post-cut convergence. Provider start checks that same deadline under
  its Invocation arbiter and cannot start IO at or after it. Every scanned source row counts toward
  the batch; duplicate wakes are harmless and neither pass repeats provider IO.
- Provider authorization continuation jobs carry only the Session public id and call the owning
  progression entrypoint. Process death, timeout, and response loss recover from durable child
  deadlines and current Session state, never Active Job replay. Status reads do not enqueue or
  drive the flow. No job argument, queue row, log, or error carries device handles, user codes,
  authorization codes, PKCE material, or access/refresh tokens.
- Provider credential resolution performs bounded proactive refresh before admission/provider
  start. Recurring progression, refresh, and collection are backstops; the authorization domain
  owns claim deadlines, poll cadence, ceilings, and retention. Jobs neither select diagnostics nor
  reload production catalog data.
- A provider-runtime observation mechanism needs its writer, reachable reader, recovery, and
  distinguishing tests together. The provider admission floor has these owners: `ApplyResult`
  writes the provider's floor, `AdmitQueuedWork` and the lane presenter read it, and clock expiry
  restores admission. Do not prebuild a separate health projection, wake, or scan for an unwired
  consumer.

## Failure Handling

- Unexpected exceptions propagate for visibility. A durable external effect requiring automatic
  retry declares finite `retry_on` backoff and uses provider idempotency keys where available.
  Transport calls always have finite timeouts; external effects with a product lifecycle also
  expose explicit timeout state. Transaction and IO separation follow `.ai/database.md`.
- Ordinary mail is best effort: native delivery failures remain visible in Solid Queue, and the
  person may resend/re-request. SMTP has no exactly-once primitive; add no business delivery
  ledger, SMTP exception taxonomy, or custom retry job.
- Log lifecycle facts with stable safe identifiers and enough progress to explain continuation or
  completion. Handled per-row failures follow `.ai/backend-rails.md`'s Logging section.
