# Backend Rails Principles

**Applies to:** `nexus` — Rails style and structure. Shared Ruby style (any Ruby subproject) lives in `repository.md`.

This module applies to Rails code under `nexus/`; the shared Ruby rules live in
`.ai/repository.md` and apply to every project. The Nexus house style is Fizzy-first vanilla Rails
(`references/fizzy/STYLE.md` in the old repo checkout is the source text; `.ai/patterns.md` maps the
named recipes), with the application-service allowance defined below. Mechanical prohibitions are
enforced by static guard tests re-established under `nexus/test/code_style/` as the code they guard
lands; when a guard fails, its message is the rule. Verify Rails behavior from this project's Rails
version, gem source, or official docs — never memory. Rails-native APIs are the behavior boundary:
add no guards, conversions, rescues, or validations unless source/docs show a real gap for this
repo's contract. Defensive paths follow the exceptional-collision allowance and ordinary-flow
exclusions defined in `.ai/boundaries.md` — one formula, one home.

## Nexus Rails Style (Fizzy)

- The global conditional-return, case-fallback, method-order, invocation-order, and bang-method
  rules in `.ai/repository.md` apply unchanged.
- No newline under visibility modifiers; indent the content under them. A module that is entirely
  private marks `private` at the top (blank line after, no indent).
- When a model intentionally exposes both asynchronous and synchronous job entrypoints, their
  enqueue helpers pair `_later`/`_now` suffixes (`.ai/jobs.md`). An asynchronous-only boundary does
  not gain an unused `_now` method solely for naming symmetry.
- Comments explain non-obvious reasons and constraints in place; debt comments describe the
  concrete limitation and its consequence, without internal plan/spec references. No inline
  RuboCop disables without a same-line reason.

## Layering

- One-way request flow: controllers call models or application services; services orchestrate
  models and outbound boundaries. Models never depend on services, controllers, views, or
  presenters. No queries in views.
- Controllers own the HTTP boundary and stay thin: load through the authenticated scope, authorize,
  call one intention-revealing model verb or service entrypoint, render. `before_action` loads and
  authorizes only. Non-CRUD verbs become nested singular resources (`cards/:id/closure`), never
  custom actions — the one exception is a URL an RFC fixes: the OAuth namespace's
  `device_authorization` (RFC 8628), `token` (RFC 6749) and `revoke` (RFC 7009) are custom actions
  (with the ceremony's own `device_authorization/cancellation` beside them), outside the nested-verb
  guard's reach (`test/code_style/nested_resource_verbs_test.rb` pins the agent family only). Every
  namespace has a matching `BaseController`; auth and broad guards live on the narrowest owning
  base with narrow `allow_unauthenticated_access only:` opt-outs. The OAuth namespace is the one
  with two roots, by wire plane rather than by name: `OAuth::BrowserController` (the cookie
  ceremony, on `ApplicationController`) and `OAuth::MachineController` (form in, JSON out, on
  `ActionController::API`); neither is named `BaseController`. Inflections: `API`, `OAuth`.
- Models are rich and assembled from small, trait-named concerns: model-specific aspects live
  under the owning namespace (`app/models/conversation/*.rb`, `Conversation::Branching`),
  genuinely cross-cutting traits (`Eventable`, `Notifiable`) in `app/models/concerns/` and
  specialized per-model by wrapping. Target model files under ~200 lines; document concern
  ordering dependencies inline. Models own persistence-backed domain behavior: associations,
  scopes, validations, durable predicates, and semantic lifecycle transitions (`activate`,
  `archive`, `claim`) — workflow code never writes enum/status columns directly.
- Application services and other POROs are allowed when a genuinely complex use case spans models
  or aggregates, coordinates transaction/lock/side-effect boundaries, or integrates an external
  system no single model should own. They are not the default bridge between every controller and
  model, and are not justified by CRUD, one-line queries, parameter filtering, or thin wrappers.
  Name them after a concrete domain operation or use case (`Signup`, `Notifier`,
  `TaskDelivery::Publication`), with one public entrypoint and inputs as domain objects or typed
  keywords (never `request`/`params`). Expected business outcomes are explicit return values or
  validation errors, never exceptions for ordinary branches. When a namespace needs a shared
  result object, it defines exactly one, carrying domain reason symbols, never HTTP statuses —
  controllers map status. Never allow a second result convention into the codebase. Two
  spellings, one convention (architecture audit 2026-09-15, doctrine-8): `Result` is what a
  service answers — its own, or the one its namespace's steps hand along
  (`ModelProviders::CodexAuthorization::Result`); `Outcome` is the plane-shared answer every verb
  of a namespace speaks and a controller family maps (`Conversations::Outcome`,
  `Executors::Outcome`). A value object that states a wire fact rather than a step's answer
  (`Transport::Delivery`, `Responses::Disposition`) is neither and is named for the fact.
- API-callable read/status predicates are side-effect-free, lock-free, and IO-free. Long IO belongs
  in jobs or named blocking entrypoints, never render paths. Database-independent support lives in
  `lib/nexus`.
- (idiom audit 2026-09-05) A `*Scoped` concern's `before_action :set_workspace, :set_conversation`
  loads through the access graph and a `before_action :ensure_writable, only:` authorizes; every
  family `BaseController` owns exactly one refusal→status mapper and one idempotent-receipt
  renderer, and a refusal the controller already holds renders (`render_not_found`), never re-
  raises `RecordNotFound` to reach its own `rescue_from`.
- (idiom audit 2026-09-05) Records travel to URL helpers as records (`PublicIdentified#to_param =
  public_id`, `redirect_to [:admin, @member]`); presenters hand the encoder raw values with
  `ActiveSupport::JSON::Encoding.time_precision` pinned once and stated in docs/agent-api, and
  typed scalars come through Strong Parameters while the endpoint-named opaque fields (`content`,
  `structured_content`, `metadata`) are read from `request.request_parameters` with the contract
  cited — never behind a `Hash.try_convert(…) || {}`.

## Parameter Doctrine

Four lines at API/controller boundaries: values Strong Parameters filter out behave as omitted;
invalid-but-present values fail model validation and render the family's `422`; missing required
roots fail `params.expect` and render the family's `400`; any additional controller guard requires
a call-site comment stating the contract and reason demanding it, and deleting a guard never requires
proof. Unknown, legacy, and unconsumed fields are ignored. Unless a written transport contract
requires source separation, controllers retain Rails' merged request-parameter semantics; do not
add body-only parsing or query/body precedence wrappers merely to protect a caller from how it
constructed its own request.

- Controllers own request shape only: malformed JSON, missing roots/selectors, invalid uploads,
  concurrency selectors such as `lock_version`, and present values that choose another operation
  path. Semantic validation belongs to models or StoreModel types. Per-action `*_params` methods
  use explicit Strong Parameters allowlists bound to action-local variables — never `@*_params`,
  `to_unsafe_h`, or blacklist `except`. Use `params.expect(...)` when the root has required
  consumed fields; use `params.permit(root: ...).fetch(:root)` when the root is required but every
  consumed field inside it is optional.
- Public opaque/free-form JSON request fields are explicit, endpoint-named exceptions (store/content
  values, opaque task `input`/`config` payloads). Object-only fields such as `metadata` use a
  Strong Parameters object envelope and model/StoreModel validation for shape and size.
  Provider-ready message arrays, raw provider responses, and raw scheduler structures are not
  public API shapes; accept structured kernel fields and build provider/internal snapshots below
  the controller boundary.
- Pick one hash key shape at the boundary; no `symbolize_keys`, `deep_symbolize_keys`, or
  `with_indifferent_access` in app code. One-time ingestion normalization where an external payload
  enters lib (YAML catalogs) is the sanctioned boundary — never repeated downstream. Validate
  uploads once at the boundary, then pass the upload object as a known type.
- Booleans and times use Rails casting; validate the application invariant, not the wire type.
  Bounded integers with a written `400` contract go through one shared helper.

## Closed Internal Shapes

- Business-owned Ruby values have closed, knowable shapes. Normalize external or wire input once at
  its owning boundary, then pass one canonical class, key, and value shape downstream. Do not make
  domain code probe or enumerate historical, speculative, or merely possible shapes.
- A permitted HTTP scalar is normalized when constructing the downstream value: when that contract
  requires a String, call `to_s` once at the controller boundary. Use `present?` only when blankness
  selects a real branch; otherwise let model validation or the closed internal contract fail fast.
  Do not use `is_a?(String)` or `respond_to?` probes for Rails attributes, normalized parameters,
  or typed keywords.
- A declared multi-type input branches exhaustively on its actual class or explicit discriminator
  with `case ... when ... else` or `if ... elsif ... else`. Where the dispatched values cross a
  file, caller, or process boundary — wire input, third-party library contracts such as pagy's
  `series`, multi-caller public methods — the final branch rejects an unsupported type as a
  boundary or programmer error. A private helper called only with same-file literal arguments still
  uses an explicit programmer-error `else`, keeping every `case ... when` structurally exhaustive.
  Do not use `respond_to?` chains, rescue-driven dispatch, or fallback key/type probing.
- **The banned probe does not become legal by changing its spelling** (owner ruling 2026-08-13,
  after a review-agent fix round laundered type probes repo-wide). `case x / when String then nil /
  else return <error>` on a value that is not a declared multi-type input is `is_a?` in a case
  costume; so are a shape gate stacked above a guard that already normalizes and refuses
  (`ref.to_s.start_with?(...)` needs no String gate in front of it), a single-armed
  `when String then true else false` predicate, and nested type cases on the receiver's own
  validated attributes. The house form is duck typing: normalize once (`to_s`, `to_h`,
  `fetch`-with-default), then ONE loud early guard that produces the domain error. Reserve
  `case ... when <Class>` for a real union — a closed vocabulary dispatch (`op` in
  `upsert | remove`) or a genuinely polymorphic boundary node (a YAML/JSONB value that may be
  mapping, sequence, or scalar, where each arm has distinct handling). Adding a type gate that
  merely re-refuses what an existing guard, validation, or `fetch` already refuses is defect
  noise, not defense.
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
- Subordinate rows are created via `owner.children.create!`/`build` or a semantic owner method; the
  owner copies redundant anchors (`belongs_to :account, default: -> { parent.account }` is the
  house idiom). Direct assignment stays fine for stable roots and invalid-state tests.
- Never let ambient `Current` silently cross an execution-context boundary: jobs, channels, and
  POROs that outlive the request receive explicit records (jobs receive ids and never read
  `Current`; a job that needs actor context takes it as an argument, `.ai/jobs.md`).

## Iteration And Continuation

- Plain iteration over bounded in-memory data needs no justification — termination is structural.
- A drain loop (repeatedly scanning for remaining work) must declare its termination invariant in a
  one-line comment: the monotonic progress quantity and the bound. Loop bodies do no IO; a drain
  loop held under a row lock must be bounded by in-memory data size, never by external state.
- Work that spans IO, time, or crash boundaries — or is unbounded by nature — uses continuation
  style: job hops with durable state, idempotent re-entry guards, and a DOMAIN-level termination
  bound (execution deadline, step budget). The DB row is the continuation, hops are short
  transactions, cancellation lands between hops.
- Do not add queue hops for style on hot paths: each hop costs dispatch latency, re-entrancy
  obligations, and state-machine surface.

## Scopes, Callbacks, Control Flow

- Scope names reveal shape: `for_` (belongs_to filter), `with_` (joins/predicates),
  `including_`/`preload_` (eager loading), `order_by_`. Reused composition lives in model
  scopes/class methods, not inline in controllers. AR DSL over raw SQL unless SQL clearly wins.
- Callbacks only transform data on the current model; external calls, jobs, and associated-record
  side effects go through after-commit steps (one domain event per transition, fan-out in
  subscribers — `.ai/patterns.md`); `normalizes` for attribute cleanup. String-backed enums for
  genuine multi-value lifecycles; domain transitions get app-owned semantic methods, not enum bang
  methods.
- Validation errors use symbol types and I18n, not inline English. Validations stay pure and
  bounded: no locks, no unbounded queries, no guards for unreachable states. Extract compared
  literals into model constants.
- No exceptions as expected control flow; reserve `raise`/`rescue` for boundary failures and
  programmer errors; never `rescue Exception`. Prefer `find_by!` when bang is the intent.
- (idiom audit 2026-09-05) Validation logic shared by several models is one
  `ActiveModel::EachValidator` under `app/validators`, declared per attribute, and cross-field
  presence/absence is declared with `with_options`/`absence:` — never an imperative
  `errors.add(:x, :blank) if x.blank?` method (`validates :metadata, bounded_json: { bound:
  :conversation_metadata_bound, shape: Hash }`).
- (idiom audit 2026-09-05) A record already in hand locks itself with `with_lock`;
  `Model.lock.find_by(id:)` belongs to id-addressed entrypoints (jobs) only, singleton creation is
  `create_or_find_by!` with `previously_new_record?` deciding the branch, and an optimistic
  `lock_version` CAS is `save` rescuing `StaleObjectError` into the namespace result inside the
  service — never a controller `rescue_from` (`store_entries/update.rb:31-38`).

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
- (idiom audit 2026-09-05) An unexpected error a sweep must swallow is reported once through
  `Rails.error.report(error, handled: true, context: { event: … })`, and one subscriber in
  `config/initializers/error_reporting.rb` writes the `event=` line for every report — services
  and jobs carry no hand-formatted rescue blocks (Rails ships no logging subscriber in any environment — `Rails.error.logger` only reports a subscriber that raised — so that one subscriber is the sole log path everywhere).
