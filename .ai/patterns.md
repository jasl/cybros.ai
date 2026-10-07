# Nexus Pattern Index

**Applies to:** `nexus` — current Rails and business patterns with their adoption limits.

The owning modules define the rules: `.ai/backend-rails.md` for Rails structure,
`.ai/database.md` for schema/query/locking behavior, `.ai/api.md` for HTTP/controllers/presenters,
`.ai/jobs.md` for scheduling/recovery, `.ai/security.md` for security boundaries,
`.ai/frontend.md` for UI, and `.ai/testing.md` for tests. Product and authority boundaries stay in
`.ai/boundaries.md`. This index is self-contained: applying a pattern requires no external checkout
or research cache. A pattern does not establish a new schema, product surface, gem, metaprogramming
layer, tenant model, or scale infrastructure; those choices must satisfy the owning modules.

## Rails And Domain Patterns

| Pattern | Nexus application |
| --- | --- |
| Small trait-named concerns around a rich model | Rails structure follows `backend-rails.md`; model-specific behavior stays under its owner. |
| Nested resource verbs and scoped loading | The controller boundary follows `api.md`; complex orchestration may use the service allowance in `backend-rails.md`. |
| Request context | Establish context once per execution boundary; jobs receive explicit arguments under `jobs.md`, never ambient request context. |
| Account founding and credential/member separation | Keep first-run/authentication behavior small within the single Account trust domain; do not add tenant machinery. |
| Shallow jobs and declared schedules | Job shells, paired entrypoints, bounded hops, and the limited use of `ActiveJob::Continuable` follow `jobs.md`. |
| One event writer with async fan-out | Eventable → Event → Notifier → Notification; model-owned prompt rendering is a separate `Promptable#to_prompt` pattern. |
| Aggregate refreshes plus targeted streams | Use broad Turbo refresh for aggregates; targeted updates serve incremental UI under `frontend.md`. |
| Append-only entries and materialized totals | Use cursor-based reconciliation and controlled recording suppression during purge; actual usage ownership/locking stays in `database.md`. |
| Outbound delivery records and a small delinquency circuit | A concrete webhook lifecycle may use this pattern with `security.md`'s outbound boundary and `jobs.md`'s retry contract. |
| Show-once API token reveal | Use an expiring MessageVerifier reveal; lock redemption where the owning credential contract requires a winner. |
| Fixtures-first behavior tests | Use canonical fixture worlds and real integration flows; test doctrine lives in `testing.md`. |
| Separate commercial overlay | A complete self-hostable kernel may expose deliberate extension seams; this pattern alone does not authorize an overlay. |

Business validation belongs in Active Record, with types, nullability, ownership FKs, and unique
indexes for storage integrity. Online nullability and physical-text-limit CHECK constraints solve
different migration problems. Nexus's constraint policy and approval requirement are defined only
in `.ai/database.md`'s Migrations, Tables, Columns section.

## ACL Changes And Bulk Side Effects

| Pattern | Nexus application |
| --- | --- |
| Current broad policy plus explicit relationship rows | Keep current authority compact; Workspace ownership, dedication, and any future sharing rows follow `boundaries.md`'s Trust Domain. |
| Complete bulk revoke operation | Bulk `delete_all` must account for skipped counters, derived state, broadcasts, events, and webhooks; `database.md` owns the transaction exception. |
| Authority separate from derived access projection | Change the authoritative edge and update its real projections; do not treat a derived table as a second authority. |

Broad access loss follows `.ai/boundaries.md`'s Mutation Topology: cut real authority and converge
actual actionable rows. These patterns do not justify theoretical-user enumeration or a temporal
cohort/audit-roster entity without its own product contract. Organization membership is not a
contained-resource ACL analogue.

## Task Inbox And Scheduling

| Pattern | Nexus application |
| --- | --- |
| State transitions with after-commit effects | Use own-column transitions and separate fan-out, with one guarded lifecycle per owner. |
| Typed, task-scoped transport authorization | Keep binding and typed pre-checks within the executor-addressed inbox contract. |
| Registration and rotatable executor credentials | The Nexus device-flow contract owns the registration ceremony and credential lifecycle. |
| Per-state stuck-work recovery | Use distinct failure reasons through normal lifecycle transitions; bounded indexed discovery follows `database.md` and `jobs.md`. |
| Idempotent recompute and atomic slot claims | Use re-entry and guarded UPDATE discipline; an advisory lock must earn the last rung of the Nexus lock ladder. |
| Chunked trace append and resynchronization | A transport with that written contract may use Content-Range/416/backoff; this pattern does not add another Nexus output protocol. |

The task inbox remains the single claim/deadline/write-once-commit protocol in
`.ai/boundaries.md`'s Product Boundaries and `docs/agent-api/v1/executor.md`. A claimant may extend
its own deadline through that contract; retry creates lineage-linked work. Large payload/result
rows are storage projections. A competitive claim loop, delivery lease/heartbeat, separate
build-attempt authority, or pending-build projection does not apply to this protocol.

## Business Recipes

| Pattern | Nexus application |
| --- | --- |
| Reviewable action queue | Use dynamic authorized actions, explicit transition results, optimistic conflicts, and history; this does not require recasting Nexus approval with STI. |
| Sliding-window rate limiting | Preserve refund behavior and one shared 429 mapping; use the adopted Nexus cache/database infrastructure rather than importing Redis. |
| Request-scoped authorization | Use domain predicates and null-object behavior, with the same authority available to presentation. |
| Basic-to-full response hierarchy | Use plain Ruby presenters and conditional fields under `api.md`, without AMS. |
| Entity-scoped live updates | Use server-computed audiences and thin messages with REST recovery under `api.md`. |
| Distinct notification hooks and value modifiers | Use typed, enabled-gated registries behind one curated extension facade when the product needs both semantics. |
| Guarded UPDATE status changes | Zero changed rows means the write lost; use `database.md`'s least-blocking mechanism. |

## Ledger Scale Recipes

- Time partitioning can support retention by partition drop.
- Independently retained append-only data may need asynchronous referential cleanup,
  reconciliation, and batched backfills.

These are scale patterns, not standing instructions to partition Nexus tables or remove ordinary
ownership FKs. A proposed use must satisfy `.ai/database.md` and the Design Expansion Gate in
`.ai/boundaries.md`.

## Excluded Shapes

- `default_scope` soft delete, multisite, settings god objects, `*_custom_fields` key-value
  tables, `method_missing`-generated `ensure_*!`, or competing service conventions.
- Dual-edition module injection, feature flags inside hot business logic, replica topology in
  domain code, cop-enforced layering, parallel Grape/GraphQL/controller APIs, or Redis-cached
  heartbeat machinery below the scale that actually requires it.
- Has-one-record state composition for execution lifecycles, O(accounts) serial recurring
  sweeps, framework monkey-patch trays, or application patches over schema-level race fixes.
  Job examples never override `jobs.md`'s product-effect retry contract or Action Mailer
  exception; pattern adoption does not authorize framework upgrades as unrelated cleanup.
