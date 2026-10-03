# Job And Queue Principles

**Applies to:** `nexus` — Active Job and Solid Queue.

This repository uses Rails Active Job and Solid Queue. Streaming LLM provider calls execute on
`bin/model_runner` (fiber host); jobs own blob workloads and act as the runner's degraded-mode
fallback. Every worker runs 3 fibers (`config/queue.yml`, fiber-mode Solid Queue); the database
pool must exceed fibers + 2, or Solid Queue refuses to boot.

Each send resolves the Invocation's stable provider/model choice against one current in-memory
Catalog snapshot. Wake every platform host capable of the durable workload immediately: text work
notifies `bin/model_runner` and enqueues its Solid Queue runner, while blob work only needs Solid
Queue. Wake and rediscovery do not route from an acceptance-time execution pair, wait through a
fallback grace period, or persist a delivery preference. At provider start, the current profile's
closed allowed-pair set gates the actual host/transport pair before IO and the resulting in-process
send context carries that pair to the single start winner. It is not mirrored on the Attempt; every
other claimant no-ops without consuming call budget. A semantically different host/transport
implementation remains disabled until the current profile explicitly permits it. Real-Provider
diagnostics are explicit, local-development-only tools; their manifests and outputs never choose
production work.

- Jobs are shallow shells: deserialize, call one domain method, re-enqueue on its answer, nothing
  else. The one call is a service's `call` or a model class method — or that one call over each
  row of a set the model names (`ModelProviderCredential.refresh_due(limit:, now:)`); a query, a
  transaction, a row lock or domain arithmetic never lives in `perform` (`AgentLoops::DrainSweepJob`
  is `AgentLoops::DrainSweep.call` and the wake its pass earns). Models that expose
  both asynchronous and synchronous entrypoints use paired `_later`/`_now` names; an
  asynchronous-only product boundary does not add an unused `_now` method solely for symmetry.
  Recurring work is declared in `config/recurring.yml` as a job class or a plain model class method
  so all recurring logic lives on models and is testable without the scheduler. The Action Mailer
  delivery pipeline is the named exception: a domain model may schedule a small Mailer directly,
  using Rails' ordinary GlobalID record argument or a stable id chosen by the mail flow, instead of
  adding a domain Job solely to recreate the framework shell.
  Ordinary application email uses Rails'
  `ActionMailer::MailDeliveryJob` through Solid Queue; do not subclass it merely to classify SMTP
  errors or invent application retry policy. Long sweeps continue as a HOP CHAIN: the job
  hand-carries its cursor and re-enqueues itself between bounded batches, so every hop yields the
  3-fiber pool to other work — the deliberate fairness choice (`config/queue.yml`). Scheduled-input
  recovery (`Conversations::Inputs::WakeDueJob`, every minute) follows the same bounded keyset
  continuation rule (owner approval 2026-09-19, replacing the cursorless exception): a busy or
  paused room may retain due inputs indefinitely, so every scanned source row consumes budget
  and advances the `(deliver_at, id)` cursor. The chain keeps its first database-clock cutoff,
  deduplicates hosts within each page, and revisits retained rows on the next scheduled scan.
  `ActiveJob::Continuable` drains a job's whole frontier in one execution and is adopted per job
  only when that job needs resumability across a worker stop; no job does today. Batch fan-out
  uses `ActiveJob.perform_all_later` over `in_batches`.
- Outside the Action Mailer exception above, arguments are JSON-native ids and small option hashes
  — never Active Record objects, large payloads, credentials, or prompt bodies; highest-level
  resource first, optional trailing params hash. Add optional keys to the trailing hash instead of
  reordering arguments.
- Mark or document idempotency; non-idempotent jobs explain the duplicate-execution risk and
  mitigation. Recompute-style jobs are level-triggered and idempotent: events say "something
  changed", the job derives state from current rows and re-enqueues itself if more work remains
  (`.ai/patterns.md`). Jobs and WebSocket wakes are latency optimizations — polling/sweeps are
  always sufficient for correctness, and models never depend on a job having run.
  Model Plane fallback jobs keep Solid Queue on its independent `queue` database: primary authority
  commits first, enqueue is after-commit best effort, and an indexed durable-state sweep closes the
  lost-enqueue gap. Do not add an outbox, cross-database transaction, or mirrored delivery ledger
  for that latency-only signal. The child-reply relay is the conversation plane's instance of the
  rule (S-I step 2): the turn converger's kick names the child, the durable marker is the reply
  turn's own `relayed_at`, and `relay_spawned_replies` (every minute, the hop chain over the
  spawned children keyset by id) delivers whatever a lost kick left behind — a receipt on the
  mail path and one transaction around the await settle and the stamp make either path exactly-once.
  Provider authorization continuation jobs obey the same rule and remain shallow wakes: their JSON-native
  argument is only the AuthorizationSession public id, and `perform` calls one guarded domain
  progression entrypoint on the owning models. Recovery from a process death, timeout, or response
  loss derives from the durable child-deadline frontier, never from Active Job retry or replay. No
  job argument, queue row, log, or error contains a device handle, user code, authorization code,
  PKCE verifier/challenge, or access/refresh token. Status reads never enqueue or drive this work.
  Jobs never choose or apply E2E diagnostic/capture state or reload the production loader; a job
  only advances the
  already-persisted selected Session. Steady-state token refresh is the bounded proactive
  single-winner performed before admission/provider start (spec 12 D13/P11); the recurring sweep
  is the level-triggered backstop that seals stale children, expires pending device starts, and
  reaps collectible sessions. Claim/deadline derivation, poll cadence
  and ceilings plus retention mechanics are owned by the provider-authorization domain.
  Model Plane terminal-apply wakes are accelerators too. Their recurring source is a bounded
  keyset scan of `ModelInvocation.status = running`, followed by an indexed greatest-ordinal
  Attempt lookup; only a terminal provider-started current Attempt is retained. The recovery job
  locks/rechecks the Invocation arbiter, reloads the Attempt without a second child lock, and calls
  the same idempotent terminal-convergence owner.
  It never scans for terminal parent Invocations, repeats provider IO, or applies unresolved binary
  output; that branch only wakes the separate AttemptOutput adoption owner. Parent status or
  guarded requeue makes direct/error work leave the source set, while binary work leaves only after
  adoption seals or expires.
  Cancellation/authority-cut follow-up is independently level-triggered. One bounded phase
  materializes `prepared | running` Attempt ids from the active `(status, id)` frontier before any
  parent join, then retains only rows whose Invocation is already terminal. Under the global lock
  ladder it closes the Attempt and preserves pending settlement for started work (there is no
  "priced unstarted hold" to release — reservations were deleted in the course correction;
  settlement is a separate per-receipt batch). A separate `(deadline_at, id)` frontier over
  `prepared | running` Attempts finds every execution deadline regardless of parent status.
  Provider start checks the same database-clock boundary under the Invocation arbiter and cannot
  begin IO at or after it. A prepared Attempt under a still-running parent times out with the
  parent; a terminal parent remains the first winner while only its Attempt converges. There is no
  reservation or unstarted hold to release. Every scanned source row consumes batch budget,
  duplicate wakes are harmless, and neither phase repeats provider IO.
- Do not prebuild a provider-runtime observation projection, wake, or recurring scan. A future
  runtime-health circuit must land its real observation writer, reachable operator/product reader,
  recovery behavior, and distinguishing tests in the same owning slice. The one such circuit that
  exists is the provider admission floor (2026-09-15): writer `ApplyResult`, readers
  `AdmitQueuedWork` and the lane presenter, recovery the clock, tests the floor suites and the
  `provider_floor` journey.
- A multi-phase recurring sweep carries an independent cursor for every phase that can scan clean,
  blocked, or otherwise retained source rows. A phase that reaches a partial window parks for the
  rest of that continuation chain; only the next recurring wake restarts it and revisits blockers.
  A phase whose acted rows necessarily leave its source set may self-drain without a cursor. In
  every case continuation and budget accounting follow materialized source rows, never only the
  number of successful updates or deletes.
  Turn convergence follows four independent windows (reply, settle, reopen, replace). Pair
  qualification happens only after the source ids are materialized; correlated bounded probes
  prevent the planner from moving the joined status filters back onto the full corpus. A loop
  transition or a new successor already knows the affected loop and sends that precise hint;
  it reuses the locked convergence writer without starting a global continuation chain.
- Agent removal force-stop is current-state cleanup (owner ruling 2026-09-19). Its immediate
  credential cut does not wait for a job. After-commit wakes and a bounded recurring floor use the
  same domain stop path, rechecking that the Profile is still removed before stopping its related
  work. Restore makes stale cleanup skip; no task marker, removal episode, new generation or
  restore barrier is owed. Keep live historical/background loops distinct from an unrelated
  current turn in the same Conversation. A paused loop has no ordinary timeout progress, so a
  lost wake is recovered by the floor, not by a promise that its frozen clock will expire.
- Solid Queue's checked-in `SolidQueue::Job.clear_finished_in_batches` command is the narrow
  framework-maintenance exception to the application-sweep continuation rule. One hourly call
  freezes its `finished_before` cutoff, deletes self-removing source rows in upstream 500-row
  statements with no transaction held across batches, and stops after the first empty batch; an
  interrupted call is recovered by the next hourly wake. One run is therefore linear in the
  eligible backlog present at its fixed cutoff, not a precedent for an application-owned
  full-corpus drain. Keep the upstream recipe until representative measurement shows it materially
  crowds queue work; only then choose a narrower schedule, throttle, or continuation policy from
  measured capture.
- `perform` uses guarded lookup (`find_by`), returning early for stale jobs. Jobs that mutate
  workspace, conversation, task, or executor state re-check ancestor operability at perform time
  and at long-running checkpoints: if an ancestor was archived after enqueue, do not start new
  work — converge to the documented deferred/canceled state.
- Jobs receive ids and never read `Current` (no job under `app/jobs` does); a job that needs
  actor context takes it as an argument. Never rely on ambient context crossing the enqueue
  boundary.
- Let unexpected exceptions propagate for visibility. A durable external effect whose owning
  contract requires automatic retry declares a finite `retry_on` policy with backoff; use provider
  idempotency keys wherever the provider offers them. Ordinary Action Mailer delivery is simpler:
  the native job propagates failure so Solid Queue records the exception, while a user explicitly
  resends or re-requests mail when needed. SMTP has no exactly-once primitive, so best-effort email
  gets no business delivery ledger, SMTP exception taxonomy, or custom retry job. Network and long
  external work stay outside transactions and always have transport timeouts. External effects
  with a product lifecycle also expose explicit timeout state. Schedule after commit when the job
  depends on committed state.
- Cancel/interrupt are explicit job-visible lifecycle commands; archive alone cancels only when the
  workflow contract says it cascades.
- Already-enqueued jobs need a plan when payloads change destructively: drain, tolerate briefly, or
  document the queue reset.
- Log lifecycle facts with stable keys and safe identifiers; long cleanup jobs record enough
  progress to explain completion or continuation.
