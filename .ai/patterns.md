# Reference Pattern Adoption Map

**Applies to:** `nexus` — the adoption map is drawn from Rails codebases.

Named recipes mined from the four reference codebases (paths are under the old repo's
`references/` checkout). Fizzy is the default Rails style inside Nexus; Once Campfire supplies a
small first-run/authentication baseline; Discourse and GitLab supply recipes for the places vanilla
strains. Adopt the discipline, not the framework: no pattern justifies importing a gem, a
metaprogramming layer, or scale machinery the recipe happened to ship with.

## Default Nexus Rails Style (Fizzy — default with named local exceptions)

- Rich models from small trait-named concerns; model files ~200 lines max
  (`fizzy/app/models/card.rb` + `card/*.rb`).
- Non-CRUD verbs as nested singular resources; thin controllers calling one domain entrypoint — a
  model verb for simple flows or an application service for justified complex orchestration
  (`fizzy/app/controllers/cards/closures_controller.rb`; local service allowance:
  `.ai/backend-rails.md`).
- Scoped-finder authorization: unreachable through your access graph ⇒ 404
  (`fizzy/app/controllers/concerns/card_scoped.rb`).
- `Current` with cascading setters; context established once per execution context — request
  middleware, job concern, cable connection; no `default_scope`
  (`fizzy/app/models/current.rb`, `app/jobs/concerns/account_tenanted.rb`).
- Identity (global credential: email/passkeys/sessions/API tokens) / User (per-account member with
  role enum incl. synthetic `system`) / Account (`create_with_owner`, `Account.none?` first-boot
  gating, `multi_tenant` flag defaulting off) (`fizzy/app/models/{identity,user,account}.rb`).
- Shallow jobs + `_later`/`_now` pairs when both entrypoints are product-reachable +
  `recurring.yml` invoking model class methods; `ActiveJob::Continuable` checkpoints for long
  sweeps (`fizzy/config/recurring.yml`).
- Eventable → Event → Notifier factory → Notification pipeline: one write path, many async
  consumers; `Promptable#to_prompt` for model-renders-itself-into-LLM-context
  (`fizzy/app/models/concerns/eventable.rb`, `app/models/notifier.rb`).
- Two-tier Turbo broadcasting: `broadcasts_refreshes` on aggregates, targeted streams only for
  genuinely incremental UI (`fizzy/app/models/card/broadcastable.rb`).
- Append-only ledger + materialized snapshot with `last_entry_id` cursor + two-cursor reconcile +
  `suppressing_recording` during purges — the shape for usage metering
  (`fizzy/app/models/storage/{entry,total}.rb`).
- Outbound webhook delivery: per-delivery record, SSRF-pinned hardened HTTP, delinquency circuit
  breaker as a tiny table (`fizzy/app/models/webhook/delivery.rb`).
- Show-once API token reveal (expiring MessageVerifier id); JoinCode `with_lock` redemption
  (`fizzy/app/models/identity/access_token.rb`).
- Fixtures-first behavior testing: canonical fixture world, integration tests driving real flows,
  `assert_changes`/`assert_difference` on behavior, concern tests in their own files.
- `saas/` overlay directory: OSS kernel complete and self-hostable; commercial concerns in a
  parallel tree behind an env flag, decorating deliberate extension seams (`fizzy/saas/`).

## Foundational Schema Boundary (All Four References)

- Business normalization, formats, product bounds, closed vocabularies, and cross-field lifecycle
  shapes belong to Active Record validations. Fizzy, Once Campfire, and Discourse foundational
  tables do not mirror those rules with SQL CHECK constraints. GitLab likewise keeps foundational
  business vocabularies and relationships in models; most of its CHECKs serve online `NOT NULL`
  rollout and physical `text` limits, with a small number of storage-specific structural backstops.
- Database columns and limits, `NOT NULL`, defaults, real ownership foreign keys, query indexes,
  and unique indexes retain storage integrity. Unique and partial unique indexes decide reachable
  write-race winners; model validations or preconditions provide the ordinary friendly error path.
- Do not copy GitLab's scale-migration CHECK constraints or exceptional storage backstops into this
  reset-era schema without the concrete storage invariant and explicit approval required by
  `.ai/database.md`; Nexus uses direct nullability and bounded string columns.

## ACL Authority Changes And Bulk Side Effects (Discourse + GitLab)

- Keep current authority compact. Workspace v1 needs only its direct Human owner plus current
  `account_wide | private` mode; Agent access is derived from the current live steward, and Agent
  writes additionally consult the create-frozen `agent_identifier` dedication column, which is
  null for Human-created rows and automatically derived from every Agent creator (a column, not an
  ACL row — it grants nothing and only refuses mismatched Agent writes). It does not
  prebuild sharing rows. When a real sharing consumer exists, explicit Human relationship rows may
  compose with that current broad-visibility policy without migrating Workspace rows. Discourse
  represents category-wide access as current category policy and explicit restrictions as
  `CategoryGroup`/`GroupUser`; it does not create temporal per-User rows merely to remember who
  once inherited broad access
  (`discourse/app/models/category.rb`, `app/models/category_group.rb`,
  `lib/group_manager.rb`).
- A rare revoke may use set-based DML on real ACL rows. Discourse's `GroupManager` performs a bulk
  `delete_all`, but explicitly repairs counters/title/flair and publishes the required updates,
  events, and webhooks. Adopt the complete domain operation, not the bare association call:
  `delete_all`/`update_all` skips callbacks.
- Separate authority from projections. GitLab's `Member` rows are direct ACL while
  `ProjectAuthorization` is derived access data refreshed asynchronously; deleting members without
  scheduling that refresh leaves stale projection authority
  (`gitlab/app/models/member.rb`, `app/models/project_authorization.rb`,
  `app/services/user_project_access_changed_service.rb`).
- For broad access loss, mutate the authority edge first and freeze consequences on actual
  actionable/derived rows. Do not enumerate every theoretical User or add a cutoff-cohort/history
  entity unless the product truly promises that audit roster. GitLab Organization membership is
  not a contained-resource ACL analogue and supplies no reusable disable-all flow.

## Task Inbox Domain (GitLab CI)

- State-machine discipline: `before_transition` mutates only own columns; `after_transition` only
  `run_after_commit` job enqueues; one domain event per terminal transition, fan-out in
  subscribers (`gitlab/app/models/ci/pipeline.rb` — heed its "do not add operations here" comment).
- One frozen status vocabulary on the single Task metadata state machine
  (`gitlab/app/models/concerns/ci/has_status.rb` supplies the discipline, not our model split).
  Partial indexes over non-terminal/per-state due rows provide O(outstanding) delivery and reaper
  scans; GitLab's denormalized pending-build table is explicitly not adopted because Nexus has no
  competitive queue and must not create a second mutable state authority.
- Per-Task scoped transport authorization with a typed-error auth finder: a running Task touches
  only its own
  resources (`gitlab/app/finders/ci/auth_job_finder.rb`, `ci/job_token/scope.rb`).
- Registration secret exchanged for per-executor rotatable auth token; `TokenAuthenticatable`
  shape for prefixed encrypted token fields (`gitlab/app/models/ci/runner.rb`).
- Per-state stuck-work reapers with distinct failure reasons, dropping through the normal state
  machine event (`gitlab/app/services/ci/stuck_builds/`).
- Exclusive-lease-guarded idempotent recompute + self-requeue as the scheduler core (PG advisory
  lock replaces Redis); single-UPDATE atomic slot claims (`gitlab/app/services/ci/
  pipeline_processing/atomic_processing_service.rb`, `ci/resource_group.rb`).
- Content-Range chunked append + 416 resync + server-driven backoff for streaming executor output
  (`gitlab/app/services/ci/append_build_trace_service.rb`).
- Boundary note: our delivery is the task inbox (owner ruling R1, 2026-09-05): an executor-addressed
  claim with a per-claim token exclusive until the task's own deadline — no lease, no heartbeat;
  a claimant may extend its own deadline, bounded and narrated (an extension, never a lease, node
  review 2026-09-08 change 8) — then one write-once commit; retry authors a new lineage-linked task. Large
  payload/result rows are storage projections, not lifecycles. GitLab's competitive claim loop,
  separate build-attempt lifecycle, and pending-build projection do not apply; its
  reaper/token/typed pre-check recipes do.

## Complex Business Writing (Discourse)

- Reviewable as the approval-inbox blueprint: STI + enum status + `perform_#{action}` returning a
  result object that declares the transition + optimistic version conflicts + history rows +
  guardian-filtered `actions_for` dynamic action menus (`discourse/app/models/reviewable.rb`).
- RateLimiter: sliding-window algorithm + `rollback!` refund + `rate_limit` on-create model macro +
  exactly one global 429 rescue; swap Redis for Solid Cache/PG (`discourse/lib/rate_limiter.rb`).
- Guardian: one request-scoped authorization object, `can_*?` predicates split into domain mixins,
  AnonymousUser null object, reused as serializer scope (`discourse/lib/guardian.rb`).
- Basic→full presenter hierarchy with `include_*?` gates and the authorization object as scope; one
  shape source shared by REST and streamed events; implement on plain POROs, not AMS
  (`discourse/app/serializers/basic_user_serializer.rb`).
- Live-update discipline: channel-per-entity, audience allow-lists computed server-side at publish
  time, thin typed messages (ids + deltas; client refetches via REST)
  (`discourse/app/models/topic_tracking_state.rb`).
- Extension hooks: notify-only events vs value-modifier chains as two distinct primitives, with
  enabled-gated typed registries and a curated facade (`discourse/lib/discourse_event.rb`,
  `lib/plugin/instance.rb`).
- Guarded-UPDATE compare-and-set for simple status flips (0 rows changed = lost the race, no lock)
  (`discourse/app/services/topic_status_updater.rb`).

## Ledger Scale-Out (GitLab)

- Declarative time partitioning with retention-by-partition-drop for append-only tables
  (`gitlab/app/models/concerns/partitioned_table.rb`, `hooks/web_hook_log.rb`).
- No hard FKs into hot append-only tables; async referential cleanup + reconciliation sweeper;
  batched backfills (`gitlab/config/gitlab_loose_foreign_keys.yml`).

## Do Not Copy

- Discourse: `default_scope` soft delete; multisite; SiteSetting god object; `*_custom_fields`
  key-value tables; `method_missing`-generated `ensure_*!`; three coexisting service conventions.
- GitLab: `prepend_mod` dual-edition injection; feature flags inside hot business logic; replica
  topology leaking into domain code; RuboCop-cop-enforced layering; triple API surface
  (Grape + GraphQL + controllers); Redis-cached heartbeat machinery below ~1M-executor scale.
- Fizzy: has_one-record state composition for execution lifecycles (use a single guarded status
  column per GitLab discipline); O(accounts) single-threaded recurring sweeps (use indexed
  due-scans); Rails-HEAD chasing plus framework monkey-patch trays; durable product-effect jobs
  without their contract-required retry/backoff policy (ordinary best-effort Action Mailer follows
  `.ai/jobs.md`); app-code patches over schema-level race fixes (use DB sequences/unique indexes/
  atomic UPDATE guards).
