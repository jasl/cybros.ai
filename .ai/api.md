# API Principles

**Applies to:** `nexus` — the kernel's public JSON API. A subproject that publishes its own API brings its own contract module.

This module owns public HTTP contracts, controller boundaries, parameter handling, and response
shapes. Per-resource contracts live in `docs/agent-api/**`, `docs/platform-api/**`, and
`docs/oauth/device-flow.md`; public behavior changes update the owning contract in the same change.
Trust-domain and credential authority remain owned by `.ai/boundaries.md`.

## Public Contract

- Public, executor-facing, and durable audit payloads use public identifiers
  (`.ai/boundaries.md`), never internal bigint ids — including ActiveStorage blob/attachment/signed
  ids; render authenticated download/preview URLs at response time instead.
- Public APIs expose kernel resource fields and task/timeline/capture projections, never raw
  scheduler mechanics (countdowns, generations, row ids) and never provider-ready request
  snapshots. A loop's graph is written only through steps placed in written order — `parallel`
  names a fan, a barrier is named (`until`/`losers`) never drawn, no client authors an edge — and
  read whole on its graph route as task keys and a Mermaid text. Convert
  structured kernel inputs into provider/internal snapshots below the public API boundary.
- Timestamp names carry wire semantics: `*_at`/`*_until` ISO8601 strings, `*_timestamp`
  JSON-integer Unix epoch milliseconds, `_ms` reserved for durations and latency.
- Every public endpoint has an explicit parameter boundary, response shape, status-code contract,
  and authorization behavior; it is implemented only when routes, controller, request tests, E2E
  where applicable, and public docs agree. Before release, evolve first-party contracts together
  without compatibility shims or parallel shapes (`.ai/boundaries.md`).
- Resource-first REST: `GET` reads, `POST` creates or runs named commands, `PATCH` partial update,
  `PUT` only for true full replacement (the executor announcement PUT is an example). Archive,
  restore, and cancel are named `POST` commands, never `DELETE`; `DELETE` is reserved for delete
  intent itself. A create endpoint that would branch on a type field splits into per-type nested
  resources. Explicit `only:` lists; conventional `params[:id]` carries public ids. This verb
  doctrine governs explicit public API contracts; ordinary HTML resources may retain the standard
  verb recognition produced by Rails resource routing.
- Status codes: `201` sync creation; `200` reads and state commands returning the resource; `202`
  only for enqueued durable async work; `204` only for intentionally empty bodies; `422`
  validation failures; `409` reachable write conflicts (stale `lock_version` → `stale_object`,
  idempotency envelope mismatch, write-once result conflict). Within one trust domain,
  authorization failures may be honest `403`s; scoped-finder misses stay `404`. Be consistent
  per family and test both.
- Racy client-editable resources expose `lock_version` and require it for `PATCH`. Idempotency
  keys are operation scoped; exact replays return the stored response only when the contract says
  the operation is replayable.

## API Families And Connection Contracts

- API families follow responsibility: `/agent_api/v1` serves
  Agent work; `/api/v1` serves Human personal settings and system settings. System settings
  under `/api/v1/admin` are visible and usable only by a live Human owner/admin; personal
  settings do not acquire that role requirement. A conversation/work WebUI uses its Agent
  application's control surface and Agent API client. Browser use of the Platform API belongs
  only to settings pages; `cmctl` is a CLI consumer of the same settings capabilities.
- Server-owned authentication, credential planes, and member/executor authority follow
  `.ai/boundaries.md`'s Trust Domain section. Wrong-plane credentials fail authentication; client
  libraries and executor bindings cannot widen authority.

### First-Party Device Flow

- The first-party device flow follows `docs/oauth/device-flow.md`. It is a connection ceremony:
  the optional scalar OAuth `scope` is accepted and ignored, with no negotiated or persisted OAuth
  scope vocabulary. `agent_identifier` and `runner_identifier` combine a release-stable program
  constant with an instance part derived at first boot; neither is typed, imported, or exported
  by a person. Nexus treats the complete identifier as an opaque bounded string.
  `.ai/boundaries.md` owns logical identity, pairing, assignment ACL, and management authority.
  Agent and machine claims are distinct branches; a combined grant pairs both with its runner
  fixed private. `executor_kind` is machine-only and closed to `runner | tools_provider`.
- Browser Connect freezes the permitted consequence, selected fresh-registration scope, and the
  actor's authority generation. Consume rechecks them under the owning locks. The Runner form's
  observed registration public id or `absent` is reject-only: a mismatch is
  `registration_changed`, leaves the grant pending, and requires a reload. It never grants
  authority, names another key, or changes scope. Connect's separate pairing marker fences changes
  after POST. A live registration re-pairs without changing its scope; a later fresh registration
  after terminal revocation may choose again. Keep these two stale-state guards distinct.
- Browser Connect never lets a person select an existing Agent/executor and renders neither the
  registration identifier nor the program-provided display name. It presents the generic replacement
  consequence: a winning Consume
  re-pairs the logical registration's sole non-revoked address and fences the prior credential
  epoch. Platform authority is unreachable from this ceremony.
- Machine polling uses RFC 8628's `authorization_pending` and `access_denied`. The first-party
  cancellation command is keyed by the exact client id and device-code secret and serializes with
  Consume. `200` means no credential consequence exists and the client may stop; `409 too_late`
  requires finishing/adopting the token result. Unknown secrets, transport errors, throttles, and
  server failures never count as safe cancellation.

### Provider Authorization And Model Settings

- Model-provider subscription OAuth uses its own ModelProviderOAuthSession, private per-claim task,
  and continuation services, separate from first-party `/oauth`. Human owner/admin callers use the Platform provider authorization
  resource (`docs/platform-api/v1/provider-authorization.md`). POST starts or resumes the
  current issuer's pending device start; another issuer or pending refresh requires explicit
  restart. `202 Location` names the actual Session. There is no command receipt or exact
  response replay: after a failed POST, GET recovers recorded state before another deliberate
  command. GET is side-effect free; precise job wakes and recurring recovery advance the
  Session without a public poll/retry/refresh command. No credential PUT or import route accepts
  a CLI refresh token. OAuth tasks remain private and have no public id.
  Session/task persistence follows `.ai/database.md`'s Provider Policy And Authorization rules.
  Diagnostics remain local under `.ai/repository.md`'s Development And Test Placement: no
  diagnostic envelope, fingerprint, capture-promotion, or recovery control becomes public input.
- Presenters may expose the reviewed verification URI/user code only to its issuing Human while the
  device-start session is pending: for Codex the URI is derived solely from the reviewed HTTPS
  issuer plus `/codex/device`, with no userinfo/query/fragment, and is never accepted from the
  user-code response or a redirect. The bounded user code is the sole secret reveal. Device handles,
  authorization codes, PKCE challenge/verifier, access/refresh tokens, account headers, raw
  provider responses, and secret-derived metadata are absent.
  The public Session projection never exposes or duplicates child delivery disposition, dispatch
  deadline, claim ordinal, terminal normalized status, or child bigint identity; it derives only
  bounded Session progress/outcome after the domain owner has applied those private facts.
  The public surface has no code-exchange command: the internal Session alone progresses through
  persisted `user_code_request → device_token_poll → code_exchange`, and poll success exposes no
  token or exchange grant.
- The concrete Codex adapter names its issuer, client id, verification/redirect URI, and phase
  endpoints directly. HTTP input does not choose those adapter facts. Adding another issuer or a
  configurable adapter is a product decision with its own boundary, not a runtime integrity proof
  against the deployment operator.
- Human device-start accepts a missing or disabled provider Policy, creating its disabled
  anchor when needed. A successful device authorization or API-key save enables the lane in
  the same transaction; failures do not. Internal refresh requires an enabled lane and never
  changes enablement. Explicit lane writes keep their observed-version contract; disable
  retains the mutex row and cancels pending authorization, as does clear, so late callbacks
  cannot re-enable the provider (`docs/platform-api/v1/admin-models.md`).
- Model discovery stays available to every member-plane Agent at
  `GET /agent_api/v1/models`, always filtered to currently available models. The admin models
  read retains the whole catalog with visibility and availability reasons. The admin provider's
  `model_visibility` PUT controls Account-wide visibility through the existing Policy document
  and version; hidden models are not selectable or admitted for new calls, while their definitions
  and pricing remain available for administration and settlement.
- Human admin provider-definition and model-definition routes expose the Policy's connection
  and model authoring commands, shared by browser settings, cmctl and terminal onboarding.
  Provider directory discovery lists upstream IDs without inference or inferred capabilities.
  Every explicit Policy edit requires the rendered `lock_version` (`expected_lock_version`), with no
  file-base digest echo or separate catalog-health gate. Public definition authoring validates
  the resulting provider lane and selector references. Malformed, out-of-shape, or over-bound
  documents are `422` with no Policy mutation; a stale `lock_version` is `409`, and same-value
  replay returns the unchanged representation. Internal inert-document writes may retain a
  structurally valid future provider/model name: the compiler validates final composition, and
  a currently inapplicable or invalid stored entry is warned and ignored without crashing or
  hiding valid file data.
- Pricing is optional: unpriced and unknown-cost models remain usable, an explicitly complete
  all-zero formula may enter `admitted_free`, and unknown money never becomes a zero charge.
  There is no selector CRUD or Policy DELETE endpoint in v1. Policy persistence and overlay
  ownership follow `.ai/database.md`'s Provider Policy And Authorization section.

## Controllers

- One request path: load through the authenticated principal's scope, authorize residual checks,
  call one intention-revealing model verb or justified application service, render. Nested
  resources load through their parent: a valid child under the wrong parent is `404`.
  `*Scoped` concerns load in `before_action`; write predicates use action-scoped authorization
  callbacks. Service/result structure follows `.ai/backend-rails.md`'s Layering section.
- Non-CRUD verbs use nested singular resources, never custom actions. The explicit exception is
  the OAuth protocol's fixed `device_authorization`, `token`, and `revoke` URLs, with first-party
  `device_authorization/cancellation` beside them. The guard
  `nexus/test/code_style/nested_resource_verbs_test.rb` covers the Agent API family.
- Every namespace has a matching `BaseController`, with authentication and broad guards on the
  narrowest owning base and narrow `allow_unauthenticated_access only:` opt-outs. OAuth instead
  has two wire-plane roots: `OAuth::BrowserController` on `ApplicationController` for the cookie
  ceremony, and `OAuth::MachineController` on `ActionController::API` for form input and JSON
  output. Use the `API` and `OAuth` inflections.
- A family base owns one refusal-to-status mapper and one idempotent-receipt renderer. A refusal
  already held by the controller is rendered directly, never raised again to reach `rescue_from`.
- Pass records to URL helpers: `PublicIdentified#to_param` supplies the public id.
- Controller-handled errors render through one shared errors concern on the family bases (rescue
  ladder, stable `{ error: { code, message } }` shape). Leaf controllers never define error
  renderers; controller-handled `400`s name the offending parameter and never echo raw payloads.
  Malformed query parsing may fail before controller dispatch; Rails' `400` floor applies there,
  but the response body and media type are not a stable family envelope.
- Unhandled application, server, and intermediary `5xx` responses are likewise outside the stable
  family envelope. Clients tolerate non-JSON, empty, or proxy-generated responses; application
  code does not add a catch-all rescue solely to normalize their presentation.
- Validation failures are record-first: render from `save`/`update` returning false;
  `save!`/`RecordInvalid` is for internal rollback.
- No external clients (model providers, OAuth flows) in controllers — delegate to the owning
  model/PORO and map its result; read/list/status resource actions stay lock-free and IO-free.
  Successful AccessToken authentication may perform its bounded, non-authoritative hourly
  `last_used_at` sample before such an action runs, and executor-plane authentication the
  executor's per-minute `last_seen_at` stamp. A successful exact-current executor-bound refresh may
  update that same address-contact sample; it proves contact, not online presence or completed
  work. `presence` (`Nexus::Presence`, presenter-computed from the executor socket's edge-written
  mark, live only while the `nexus_servers` row the mark names still heartbeats — the database is
  the authority, the set loaded once per page) is display only: rendered beside the executor,
  never read by a service or job.
  `last_used_at` and `last_seen_at` are deliberately separate: never let a presence/contact
  sample extend credential authority.

## Parameter Doctrine

- Strong Parameters-filtered values behave as omitted; invalid-but-present values fail model
  validation with the family's `422`; missing required roots fail `params.expect` with the
  family's `400`. Additional controller guards need a call-site comment stating the contract and
  reason. Guard removal follows `.ai/review.md`'s Finding Capture Protocol and never weakens a
  pinned invariant merely to make a change coherent.
- Ignore unknown, legacy, and unconsumed fields, and test them as unchanged. Keep Rails' merged
  request-parameter semantics unless the written transport contract requires source separation;
  do not add body-only parsing or precedence wrappers for a caller's own request construction.
- Controllers own request shape: malformed JSON, missing roots/selectors, invalid uploads,
  concurrency selectors such as `lock_version`, and present values that select another operation.
  Semantic validation belongs to models or StoreModel types. Per-action `*_params` methods use
  explicit allowlists bound to action-local variables, never `@*_params`, `to_unsafe_h`, or
  blacklist `except`. Use `params.expect(...)` when a required root has consumed required fields;
  use `params.permit(root: ...).fetch(:root)` when all consumed fields inside a required root are
  optional.
- Public opaque/free-form JSON fields are explicit endpoint-named exceptions, such as store
  values, content, and task `input`/`config`. Read those fields from
  `request.request_parameters` only where the contract calls for that exception, with the
  contract cited; never hide them behind `Hash.try_convert(...) || {}`. Object-only fields such
  as `metadata` use a Strong Parameters object envelope and model/StoreModel shape and size
  validation. Provider-ready messages/responses and raw scheduler structures are not public API
  shapes; build them below the controller boundary from structured kernel fields.
- Normalize a permitted scalar once when constructing its downstream value; use `to_s` when the
  contract requires a String. Booleans and times use Rails casting; validate the application
  invariant rather than the wire type. Bounded integers with a written `400` contract go through
  one shared helper. Validate uploads once, then pass the known upload object downstream.
  Closed internal values follow `.ai/backend-rails.md`'s Closed Internal Shapes section.

## Responses And Pagination

- API JSON is built by plain-Ruby presenter objects in a Basic→full hierarchy: the Basic presenter
  defines the minimal canonical shape, richer presenters extend it, conditional fields gate on the
  authorization scope, and REST responses and streamed events share the same presenter — one shape
  source per resource. Presenters pass raw values to the encoder;
  `ActiveSupport::JSON::Encoding.time_precision` is configured once and documented in the API
  contract. No serializer gem, no `to_json`/`as_json` for public responses, no view templates.
- Ordinary lists use Pagy with its default request semantics unless the owning public contract
  records a framework-compatibility exception and supplies one shared, tested pagination concern;
  paginated pages render only on GET. Scalable lists use keyset pagination with opaque cursors
  (`next_after`); whether Pagy or that documented concern generates the cursor is not part of the
  wire contract, and clients never parse cursors for embedded ids. Transcripts, logs,
  and timeline windows are not ordinary lists: define the windowing contract
  (`before`/`after`/`around`/`since`, tail/head, replay/resume) first.
- Keep response fields bounded — no large prompt/context/secret/tool payloads by default.
  Streaming/websocket payloads are public contracts: version event names, bound size, compute
  audiences server-side at publish time, keep messages thin (type + ids + deltas; durable rows are
  the recovery path, REST replay is truth). Avoid polling-focused design — return the durable
  resource/status and let ActionCable push wake-ups.
- Collection endpoints document and test ordering, pagination, empty results, N+1, cursor opacity,
  and the `max_limit` cap; endpoint tests cover success, denied, not found, and validation failures.
  Cover malformed consumed params only when their handling protects security or durable data
  integrity.
