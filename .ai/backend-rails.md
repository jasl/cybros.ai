# Backend Rails Principles

**Applies to:** `nexus` — Rails style and structure. Shared Ruby style lives in `.ai/repository.md`.

Nexus uses vanilla Rails with the application-service allowance defined below. The complete house
style lives in `.ai/repository.md`, this file, and the owning topical modules; `.ai/patterns.md`
indexes the applicable patterns and their limits. No external checkout or style file is required.
Mechanical prohibitions are
enforced by static guard tests under `nexus/test/code_style/`; when a guard fails, its message is
the rule. Verify Rails behavior from this project's Rails version, gem source, or official docs,
never memory. Rails-native APIs are the behavior boundary:
add no guards, conversions, rescues, or validations unless source/docs show a real gap for this
repo's contract. Defensive paths follow `.ai/boundaries.md`'s Design Expansion Gate.
HTTP/controller rules belong to `.ai/api.md`; persistence, locking, and transaction rules belong to
`.ai/database.md`; asynchronous execution and continuations belong to `.ai/jobs.md`.

## Nexus Rails Style

- The global conditional-return, case-fallback, method-order, invocation-order, and bang-method
  rules in `.ai/repository.md` apply unchanged.
- No newline under visibility modifiers; indent the content under them. A module that is entirely
  private marks `private` at the top (blank line after, no indent).
- Asynchronous/synchronous entrypoint naming follows `.ai/jobs.md`'s Job Boundaries section.
- Comments explain non-obvious reasons and constraints in place; debt comments describe the
  concrete limitation and its consequence, without internal plan/spec references. No inline
  RuboCop disables without a same-line reason.

## Layering

- One-way request flow: controllers call models or application services; services orchestrate
  models and outbound boundaries. Models never depend on services, controllers, views, or
  presenters. No queries in views.
- Controllers follow `.ai/api.md`'s Controllers and Parameter Doctrine sections.
- Models are rich and assembled from small, trait-named concerns: model-specific aspects live
  under the owning namespace (`app/models/conversation/*.rb`, `Conversation::Timeline`),
  genuinely cross-cutting traits (`Eventable`, `Notifiable`) in `app/models/concerns/` and
  specialized per-model by wrapping. Target model files under ~200 lines; document concern
  ordering dependencies inline. Models own persistence-backed domain behavior: associations,
  scopes, validations, durable predicates, and semantic lifecycle transitions (`activate`,
  `archive`, `claim`) — workflow code never writes enum/status columns directly.
- Application services and other POROs are allowed when a genuinely complex use case spans models
  or aggregates, coordinates transaction/lock/side-effect boundaries, or integrates an external
  system no single model should own. They are not the default bridge between every controller and
  model, and are not justified by CRUD, one-line queries, parameter filtering, or thin wrappers.
  Name them after a concrete domain operation or use case (`Conversations::Create`), with one
  public entrypoint and inputs as domain objects or typed
  keywords (never `request`/`params`). Expected business outcomes are explicit return values or
  validation errors, never exceptions for ordinary branches. When a namespace needs a shared
  result object, it defines exactly one, carrying domain reason symbols, never HTTP statuses —
  controllers map status. Never allow a second result convention into the codebase. Two
  spellings share this convention: `Result` is what a service answers — its own, or the one its
  namespace's steps hand along
  (`ModelProviders::CodexAuthorization::Result`); `Outcome` is the plane-shared answer every verb
  of a namespace speaks and a controller family maps (`Conversations::Outcome`,
  `Executors::Outcome`). A value object that states a wire fact rather than a step's answer
  (`Transport::Delivery`, `Responses::Disposition`) is neither and is named for the fact.
- API-callable read/status predicates are side-effect-free, lock-free, and IO-free. Long IO belongs
  in jobs or named blocking entrypoints, never render paths. Database-independent support lives in
  `lib/nexus`.
  Deployment administration follows `.ai/api.md`'s bounded local-IPC exception: a configured
  Unix-socket client reads the separate installation owner's Nexus-only state without Rails persistence.
  Registry checks are explicit commands; application lifecycle work never runs in a Rails job.
  Agent application and combined-installation upgrades stay outside Nexus administration.

## Closed Internal Shapes

- Business-owned Ruby values have closed, knowable shapes. Normalize external or wire input once at
  its owning boundary, then pass one canonical class, key, and value shape downstream. Do not make
  domain code probe or enumerate historical, speculative, or merely possible shapes.
- HTTP scalar normalization follows `.ai/api.md`'s Parameter Doctrine. Use `present?` only when
  blankness selects a real branch; otherwise let model validation or the closed contract fail fast.
  Do not use `is_a?(String)` or `respond_to?` probes for Rails attributes, normalized parameters,
  or typed keywords.
- A declared multi-type input branches exhaustively on its actual class or explicit discriminator
  with `case ... when ... else` or `if ... elsif ... else`. Where the dispatched values cross a
  file, caller, or process boundary — wire input, third-party library contracts such as pagy's
  `series`, multi-caller public methods — the final branch rejects an unsupported type as a
  boundary or programmer error. A private helper called only with same-file literal arguments still
  uses an explicit programmer-error `else`, keeping every `case ... when` structurally exhaustive.
  Do not use `respond_to?` chains, rescue-driven dispatch, or fallback key/type probing.
- **A banned type probe remains banned under an equivalent spelling.** `case x / when String then nil /
  else return <error>` on a value that is not a declared multi-type input is `is_a?` in a case
  costume; so are a shape gate stacked above a guard that already normalizes and refuses
  (`ref.to_s.start_with?(...)` needs no String gate in front of it), a single-armed
  `when String then true else false` predicate, and nested type cases on the receiver's own
  validated attributes. The house form is duck typing: normalize once (`to_s`, `to_h`,
  `fetch`-with-default), then one loud early guard that produces the domain error. Reserve
  `case ... when <Class>` for a real union — a closed vocabulary dispatch (`op` in
  `upsert | remove`) or a genuinely polymorphic boundary node (a YAML/JSONB value that may be
  mapping, sequence, or scalar, where each arm has distinct handling). Adding a type gate that
  merely re-refuses what an existing guard, validation, or `fetch` already refuses is redundant
  and prohibited.
- Pick one hash key shape at each ingestion boundary. No `symbolize_keys`, `deep_symbolize_keys`,
  or `with_indifferent_access` in app code. One-time ingestion normalization where an external
  payload enters `lib` (such as a YAML catalog or a value object's `from_h`) is permitted; never
  repeat it downstream.
- Business-owned Hashes use symbol keys with explicit required and optional keys and value types.
  Use `fetch` for required keys whose absence is a programmer error. Strings remain strings only at
  an external/wire boundary that defines them; normalize a closed selector or configuration value
  once to a symbol before passing it into application code. Internal code does not accept both
  string and symbol keys or silently reinterpret alternate shapes.
- Explicitly opaque/free-form agent or provider payloads remain opaque. They may be bounded, stored,
  or forwarded according to their contract, but domain code must not inspect them through
  speculative shape handling.

## Trusted Internal Values

- Inside `app/models` (and POROs they own), values from associations, typed attributes (Attributes
  API, StoreModel, enum), `normalizes`-declared attributes, and keyword defaults are trusted;
  re-checking their Ruby class or re-applying normalization is a review-blocking defect. Exceptions
  need a call-site comment explaining the applicable contract and the concrete exception.
- Ownership-backed creation follows `.ai/database.md`'s Migrations, Tables, Columns section.
- Never let ambient `Current` cross an execution-context boundary: channels and POROs that outlive
  the request receive explicit records. Job arguments follow `.ai/jobs.md`'s Job Boundaries.

## Iteration

- Plain iteration over bounded in-memory data needs no justification — termination is structural.
- A drain loop (repeatedly scanning for remaining work) must declare its termination invariant in a
  one-line comment: the monotonic progress quantity and the bound. Loop bodies do no IO; a drain
  loop held under a row lock must be bounded by in-memory data size, never by external state.
- Work spanning IO, time, or crash boundaries follows `.ai/jobs.md`'s Continuation And Recovery
  rules. Do not add queue hops solely for style on a hot path.

## Scopes, Callbacks, Control Flow

- Scope names reveal shape: `for_` (belongs_to filter), `with_` (joins/predicates),
  `including_`/`preload_` (eager loading), `order_by_`. Reused composition lives in model
  scopes/class methods, not inline in controllers. AR DSL over raw SQL unless SQL clearly wins.
- Callbacks only transform data on the current model; external calls, jobs, and associated-record
  side effects go through after-commit steps (one domain event per transition, fan-out in
  subscribers); `normalizes` for attribute cleanup. String-backed enums for
  genuine multi-value lifecycles; domain transitions get app-owned semantic methods, not enum bang
  methods.
- Validation errors use symbol types and I18n, not inline English. Validations stay pure and
  bounded: no locks, no unbounded queries, no guards for unreachable states. Extract compared
  literals into model constants.
- No exceptions as expected control flow; reserve `raise`/`rescue` for boundary failures and
  programmer errors; never `rescue Exception`. Prefer `find_by!` when bang is the intent.
- Validation logic shared by several models is one
  `ActiveModel::EachValidator` under `app/validators`, declared per attribute, and cross-field
  presence/absence is declared with `with_options`/`absence:` — never an imperative
  `errors.add(:x, :blank) if x.blank?` method (`validates :metadata, bounded_json: { bound:
  :conversation_metadata_bound, shape: Hash }`).
- Lock API choice, singleton creation, and optimistic-write conflict mapping follow
  `.ai/database.md`'s Locking Ladder And Transactions section.

## Ruby, Loading, Modules

- `app/**` relies on Zeitwerk — no manual `require`. No application logic, queries, or service
  calls at constant-definition time, in routes, or in initializers.
- Concerns are behavioral, not code-slicing buckets. Modules own only the instance variables they
  initialize. No instance variables in partials — pass locals with explicit defaults.
- Freeze mutable constants; `attr_reader` only for public contracts.

## Logging

- Structured logging, not ad hoc `puts`: a single line with a leading `event=` key and snake_case
  `key=value` fields, written inline with plain `Rails.logger` at the few moments that matter — no
  wrapper class, no logging gems. Log state flips at the cause, not per-symptom.
- Stable field names and value types; durations are numeric seconds in fields ending `_s`; no
  dynamic field names. Never log credentials, tokens, secrets, or values produced by users,
  providers, or models; do not double-log exceptions.
- An unexpected error a sweep must swallow is reported once through
  `Rails.error.report(error, handled: true, context: { event: … })`, and one subscriber in
  `config/initializers/error_reporting.rb` writes the `event=` line for every report. Services and
  jobs carry no hand-formatted rescue blocks; that subscriber is the application's log path for
  handled reports in every environment.
