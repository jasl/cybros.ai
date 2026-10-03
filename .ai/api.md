# API Principles

**Applies to:** `nexus` — the kernel's public JSON API. A subproject that publishes its own API brings its own contract module.

API-family contracts — surface split, credential-plane rules, lifecycle contracts — are pinned in the
founding specs (account-identity, task-delivery) and per-resource docs as they land; any public
behavior change updates its doc in the same change. Parameter handling follows
`.ai/backend-rails.md`; this file keeps the cross-family style rules.

## Public Contract

- Public, executor-facing, and durable audit payloads use public identifiers
  (`.ai/boundaries.md`), never internal bigint ids — including ActiveStorage blob/attachment/signed
  ids; render authenticated download/preview URLs at response time instead.
- Public APIs expose kernel resource fields and task/timeline/capture projections, never raw
  scheduler mechanics (countdowns, generations, row ids) and never provider-ready request
  snapshots. A loop's graph is written only through STEPS placed in written order — `parallel`
  names a fan, a barrier is named (`until`/`losers`) never drawn, no client authors an edge — and
  read whole on its graph route as task keys and a Mermaid text (owner ruling 2026-09-05). Convert
  structured kernel inputs into provider/internal snapshots below the public API boundary.
- Timestamp names carry wire semantics: `*_at`/`*_until` ISO8601 strings, `*_timestamp`
  JSON-integer Unix epoch milliseconds, `_ms` reserved for durations and latency.
- Every public endpoint has an explicit parameter boundary, response shape, status-code contract,
  and authorization behavior; it is implemented only when routes, controller, request tests, E2E
  where applicable, and public docs agree. No internal compatibility with old-repo shapes.
- Resource-first REST: `GET` reads, `POST` creates or runs named commands, `PATCH` partial update,
  `PUT` only for true full replacement (the task-result PUT is the canonical example). Archive,
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
- Unknown fields outside allowlists are ignored and tested as unchanged, never rejected to prove a
  resource has no such attribute.
- API families follow responsibility (owner clarification 2026-09-29): `/agent_api/v1` serves
  Agent work; `/api/v1` serves Human personal settings and system settings. System settings
  under `/api/v1/admin` are visible and usable only by a live Human owner/admin; personal
  settings do not acquire that role requirement. A conversation/work WebUI uses its Agent
  application's control surface and Agent API client. Browser use of the Platform API belongs
  only to settings pages; `cmctl` is a CLI consumer of the same settings capabilities.
- Authentication and route-family authority are server-owned. Human cookie/API Session/platform
  credentials serve ordinary website and Platform APIs, with admin resources additionally
  requiring a live Human owner/admin. Member-plane credentials serve only explicitly documented
  member/data resources for their bound User kind; the Workspace family is the current named
  surface that also permits a Human owner's member credential. Agent Users never authenticate to
  Platform APIs. Executor-transport credentials serve only the bound executor's inbox
  transport (inbox, claim, commit, cable); runner and tools-provider bindings never imply member
  or Platform authority.
  Wrong-plane credentials fail authentication rather than degrading to another principal.
- The first-party device flow is a connection ceremony, not a permission-approval surface. The
  optional scalar OAuth `scope` wire parameter is accepted for standard-library compatibility and
  ignored: Nexus negotiates, persists, and returns no OAuth scope vocabulary. A credential's
  authority is its mint-frozen `credential_plane`
  (`member | executor_transport | platform`). `agent_identifier` and `runner_identifier` are
  the program's release-stable, non-secret constant (`Rho::AGENT_IDENTIFIER`,
  `Rho::RUNNER_IDENTIFIER`) plus an INSTANCE part derived at first boot and never typed by a
  person (owner ruling 2026-09-09; rho presents `rho.<instance_id>` /
  `rho-runner.<instance_id>`, `agents/rho/rho/lib/rho/connection.rb:287-291`), so two installs
  of one program under one steward pair as two rows; neither part is import/export material or
  browser copy, and Nexus stays kernel-blind to the part's shape — the identifier is an opaque
  string it bounds by length only (`device_authorization.rb:51-54`). The identifier branches
  discriminate the role — branch A the agent, branch B the machine — and an agent that also plays
  the runner pairs BOTH in one combined grant A+B: both claim sets on one request, one approval,
  two lineages, the runner fixed private (`.ai/nexus.md` *Executor Roles And The Gateway*;
  `device_authorization.rb:77-102`). Branch B may additionally name its machine kind,
  `executor_kind: runner (default) | tools_provider` — a kind on branch A, or a value outside
  that vocabulary, is `invalid_request`, and a re-pair naming the other kind for a live key is
  invalidated at Consume (S-C step 5, 2026-09-07).
  `assignment_scope` is not a machine-request field and the first-party SDK
  cannot express it; an extra raw parameter is merely an unknown field under the rule above and
  can never influence authorization. An active
  cookie-authenticated human may Connect or Cancel. Nexus resolves an Agent from that human plus
  the exact code constant and derives its executor internally. For a Runner, Connect alone
  chooses the initial assignment scope of a fresh registration: an ordinary member is fixed to
  their own `user_private` registration, while an owner/admin connecting their own Runner gets one
  account-wide checkbox, default unchecked; checked means `account_wide`. Connect freezes that
  choice as `selected_assignment_scope` on the DeviceAuthorization for Consume. A live matching
  registration instead renders its stored scope without a selector and re-pairs without changing
  it; a terminally revoked registration permits a later fresh registration to choose again.
  A Runner page echoes the live registration public id it observed, or `absent`, as a reject-only
  precondition. POST locks and re-resolves the manager-bound key; a mismatch returns
  `registration_changed`, leaves the grant pending, and requires a reload. The observation cannot
  grant authority, name another key, or select scope; Connect's separately frozen pairing marker
  protects Consume from later changes. The
  browser never chooses an existing Agent or executor and never renders either identifier or the
  program-provided display name. It does show the generic replacement consequence: if that logical
  registration is already connected, a winning Consume re-pairs its sole non-revoked address,
  advances the credential epoch, and fences the previous device; this warning exposes no selector,
  secret, or executor topology. Platform authority is structurally unreachable from device flow.
  Connect freezes the browser actor's current authority generation as well as the selected
  consequence. Consume compares it under the actor lock, so a remove→restore cycle invalidates an
  older connected Request even when no executor existed at Connect time.
  RFC 8628 polling still uses `authorization_pending` and `access_denied` at the machine boundary.
  Nexus also exposes one explicitly first-party, non-RFC machine cancellation command keyed by the
  exact client id and device-code secret. It serializes with Consume on the DeviceAuthorization
  row: `200` means no credential consequence exists and the client may safely stop; a consumed
  loser is typed `409 too_late` and the client must finish/adopt the token result. Every unknown
  secret, transport failure, throttle, or server failure is non-safe.
  Runner connection management is separate from assignment ACL: only the Runner's Human manager
  may use the current `/runners` lifecycle and credential commands. `account_wide` grants no
  administrator control over another Human's Runner, and v1 exposes neither scope change nor
  manager transfer.
- Model-provider subscription OAuth is not the first-party `/oauth` ceremony above. Provider
  authorization uses the existing ModelProviderOAuthSession, private per-claim OAuth task and
  continuation services. Human owner/admin callers use the Platform provider authorization
  resource (`docs/platform-api/v1/provider-authorization.md`). POST starts or resumes the
  current issuer's pending device start; another issuer or pending refresh requires explicit
  restart. `202 Location` names the actual Session. There is no command receipt or exact
  response replay: after a failed POST, GET recovers recorded state before another deliberate
  command. GET is side-effect free; precise job wakes and recurring recovery advance the
  Session without a public poll/retry/refresh command. No credential PUT or import route accepts
  a CLI refresh token. OAuth tasks remain private and have no public id.
  Optional inference diagnostics remain explicit local commands under root `e2e/**`.
  Session and task rows persist only the semantic progress and outcomes needed
  to resume or diagnose the product flow. No runtime contract digest,
  qualification envelope, or E2E fingerprint becomes public or durable input.
  Presenters may expose the reviewed verification URI/user code only to its issuing Human while the
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
  The concrete Codex adapter names its issuer, client id, verification/redirect URI, and phase
  endpoints directly. HTTP input does not choose those adapter facts. Adding another issuer or a
  configurable adapter is a product decision with its own boundary, not a runtime integrity proof
  against the deployment operator.
  Development-diagnostic planning and crash recovery have no HTTP surface — a later public
  adapter exposes no capture rewrite/promotion, predecessor-depth, branch-selection, or
  old-refresh override.
  Human device-start accepts a missing or disabled provider Policy, creating its disabled
  anchor when needed. A successful device authorization or API-key save enables the lane in
  the same transaction; failures do not. Internal refresh requires an enabled lane and never
  changes enablement. Explicit lane writes keep their observed-version contract; disable
  retains the mutex row and cancels pending authorization, as does clear, so late callbacks
  cannot re-enable the provider (owner ruling 2026-10-01;
  `docs/platform-api/v1/admin-models.md`). Model discovery stays available to every member-plane Agent at
  `GET /agent_api/v1/models`, always filtered to currently available models. The admin models
  read retains the whole catalog with visibility and availability reasons. The admin provider's
  `model_visibility` PUT controls Account-wide visibility through the existing Policy document
  and version; hidden models are not selectable or admitted for new calls, while their definitions
  and pricing remain available for administration and settlement.
  Human admin provider-definition and model-definition routes expose the Policy's connection
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
  Pricing is optional: unpriced and unknown-cost models remain usable, an explicitly complete
  all-zero formula may enter `admitted_free`, and unknown money never becomes a zero charge.
  There is no
  selector CRUD or Policy DELETE endpoint in v1. The overlay document's shape, bounds, entry
  vocabulary, and validation contract are owned by spec 12 D2.

## Controllers

- Discipline: load through the authenticated principal's scope (scoped finders are the
  authorization default), authorize residual checks with explicit predicates, operate via one
  model verb, render. Nested resources load through the parent scope — a valid child id under the
  wrong parent is `404`.
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

## Responses And Pagination

- API JSON is built by plain-Ruby presenter objects in a Basic→full hierarchy: the Basic presenter
  defines the minimal canonical shape, richer presenters extend it, conditional fields gate on the
  authorization scope, and REST responses and streamed events share the same presenter — one shape
  source per resource (`.ai/patterns.md`). No serializer gem, no `to_json`/`as_json` for public
  responses, no view templates.
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
