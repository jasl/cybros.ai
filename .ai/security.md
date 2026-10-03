# Security Principles

**Applies to:** every project. The trust domain, secret handling, shell/path safety, and AI/LLM
safety are language-independent; clauses naming Rails mechanisms apply only to `nexus`.

## Trust Model

One `Account` is the single trust domain (`.ai/boundaries.md`). Enforce these declared boundaries:

1. The account edge: authentication (sessions, `sk-cybros-*` credentials, OAuth flows).
2. Executor binding is a correctness boundary: a bound credential reads and mutates only its inbox
   tasks; per-Task scoping keeps running work inside its own resources.
3. Effects and content: tool effect profiles, approvals, and untrusted-content handling. What is
   untrusted is content — LLM output, tool results, ingress payloads, user data — not connectors.

Workspace access control is product-level authorization among trusted members, not tenancy.
Apply the access and concealment rules in `.ai/boundaries.md` without inventing a tenant layer.

Every proposed control or finding first passes `.ai/boundaries.md`'s Threat-Model And
Portability Gate. State the concrete asset, attacker, capability, boundary, and distinguishing test.

**Local file access by an agent program is a supported product capability.** rho reads and
writes the human's files under that human's uid through its Runner role. Runner credentials,
assignment scope and explicit handoff follow `.ai/boundaries.md`; this does not create an
in-process filesystem sandbox, chroot, path allowlist over the user's own files, or a new
capability layer between rho and disk. Deployment isolation belongs to the runner/container.

What that carve-out does **not** cover, and what stays in scope for review:

- **rho's own secrets.** The credential vault, staging slot, local bearer, and log files stay
  private from the first byte and fail closed; token exposure in logs or diagnostics is a
  finding. State-file mode and publication rules are below.
- **The local control surface.** Bearer check, Host/DNS-rebinding check, bind rules, and the
  transport assertions for a non-loopback bind are unchanged and enforceable.
- **Traversal across a boundary the design does declare.** Public identifiers become path
  segments, and `Rho::Home` refuses any that could escape the tree. The carve-out covers the user's
  own files, not escaping rho's own structure.
- **Untrusted content deciding what to touch.** LLM output, tool results, and ingress payloads are
  untrusted (clause 3 above). The control is tool effect profiles and approvals, not a
  filesystem sandbox — so review those, and review whether an effect that should require approval
  can reach the disk without one.

## Authorization

- Default-deny at the namespace/base controller; public or bootstrap endpoints are explicit,
  narrow, searchable exceptions. Every `skip_before_action` — including
  `allow_unauthenticated_access` and every guard-relaxing macro built on it — supplies an explicit
  `only:` action allowlist, even when every action currently defined by that controller is exempt;
  a blanket skip silently exempts future actions from the guard. No dynamic permission names or
  UI visibility/feature flags as the only control. Tests cover allowed and denied actions.
- Use Rails HTTP token authentication helpers and grammar (`Token`/`Bearer`); separate credential
  families with token prefixes, digest lookup tables, controller bases, and lifecycle policy —
  never custom header parsing without a written design.
- At a boundary that accepts both an `Authorization` credential and a browser cookie, a present
  header is authoritative for principal selection. Failed header authentication returns an error;
  it never falls back to a different cookie principal.
- Browser resource-owner connection pages (OAuth device flow) stay on a cookie-only
  authentication boundary; a shared concern that can also resume bearer sessions must not
  authenticate them.
- Keep the two device-flow domains distinct. Nexus's first-party `/oauth` ceremony connects an
  Agent/Runner credential on its own credential planes; Model Plane provider OAuth is an
  Account-admin authorization workflow for Codex subscription and never mints a Nexus principal.
  A Human device-start may create a disabled ModelProviderPolicy anchor and run while the
  lane is disabled. Successful credential installation enables that lane atomically; failure
  does not. Internal refresh still requires an enabled lane and never changes enablement.
  Disable retains the mutex row and revokes pending authorization, so a late success cannot
  undo it; clear has the same cancellation precedence. No Policy delete writer exists.
  Production provider authorization creates a dedicated Nexus-owned token lineage. It must not
  import, copy, refresh, or share the refresh token in an active `CODEX_AUTH_FILE`; a small explicit
  local development diagnostic may read only an issued CLI access token, account identity, and
  expiry into memory for one call. It applies the selected execution timeout, refuses before IO
  unless the token outlives that deadline plus the release-owned skew, then discards the values
  without refresh or persistence. It carries no capture ancestry, source-currentness proof, or
  promotion state. The explicit development seed exception may install the access/refresh pair
  from `CODEX_AUTH_FILE` through `InstallOAuthPair`, refusing any pending OAuth
  session and any environment other than development/test. That explicit tool and its tests live
  under `e2e/manual`; Nexus never loads them. The file is a one-time seed, not a synchronized token
  store: Nexus owns subsequent rotation, so the operator must not keep the CLI rotating that same
  pair independently. This adds no production import route. Long-lived production Codex inference
  authenticates only from the encrypted credential installed by Nexus's own device start.
  Selection and ProviderStart treat it as usable only when
  `expires_at > now + profile.total_execution_deadline + oauth_clock_skew`; equality or less
  refuses use and lets the owning authorization flow refresh or require a fresh device start.
  That clock crossing is only an effective-view mask: it never persists a Credential
  reauthorization mark/reason or a Catalog proof marker. Only a verified matching 401,
  invalid/reused refresh authority, or possibly-sent poll/code-exchange/refresh ambiguity may invoke
  the locator/lineage/generation-CAS mark owner.
  Every Catalog profile's `total_execution_deadline` is a positive finite bounded duration; a
  missing, nonpositive, noncanonical, nonfinite, or overflowing value rejects locally before
  authorization or inference IO. Acceptance snapshots its selected value and admission uses that
  value to stamp the Attempt's absolute deadline. At the actual send, the current Catalog rebuilds
  the profile: ProviderStart uses that current duration for credential-expiry sufficiency and
  carries it only in the in-process send context that enforces the request timeout. It is not
  persisted as start evidence. The two values need not be identical and no revision proof compares
  them. `oauth_clock_skew` is the fixed five-minute execution-profile constant, never an
  ENV/operator/request/runtime knob; profile deadline/skew use the same injected database/UTC clock
  in gates/tests.
  Absolute expiry comes only from the profile-pinned token-response/JWT-`exp` sourcing contract
  after bounded type/range/overflow and canonical database-UTC validation. Never guess a TTL, use a
  worker clock, or partially install a missing/invalid/already-expired token response; fail the
  session, clear its session secrets, and pause for owner reauthorization.
- Provider OAuth issuer, client id, redirect URI, and user-code, poll, code-exchange and refresh
  endpoints are release-pinned constants. They have no ENV, CLI, database, request, operator or
  runtime override surface. A new issuer or configurable adapter requires its own accepted
  product boundary; these constants are not an integrity proof against the trusted operator.
- Provider OAuth continuation is fail-closed around single-use grants. A spent or superseded
  refresh token is never retried, and send-safety is never inferred from a missing response: once
  request bytes may have committed, the outcome is ambiguity — terminalize, pause owner work, and
  require a fresh dedicated device start. Authorization exchanges run on a dedicated adapter and
  connection middleware with redirects and every hidden automatic retry disabled; a wire attempt
  exists only under its own persisted exchange claim. Code-exchange/refresh success installs the
  complete access/refresh pair atomically; a partial response is failure, never a mixed old/new
  pair. OAuth material and device handles use Rails encryption plus strict size/schema bounds
  because they must be retrieved; every terminal Session clears its encrypted session secrets at
  that first terminal transition, retaining only bounded sanitized status. The sole user-visible
  secret reveal is the bounded user code. Request/outcome digests cover only non-secret contract
  facts and never hash a device handle, authorization code, verifier, or token. Provider
  authorization pages and responses are hostile input: the verification URL is derived only from
  the reviewed issuer, never accepted or auto-followed from a provider response, and URIs
  carrying userinfo, query, fragment, redirect, or code material are rejected. Keep exchange
  mechanics and non-secret digest-input inventories explicit in the owning contract and tests.
- Ownership and last-admin invariants are protected at the controller boundary and in the domain
  transition, with allowed and denied paths tested.
- Credential endpoints (login, first-boot signup, password reset, token issuance) get
  controller-boundary rate limiting; authenticated issuance keys the limit to the authenticated
  actor, not the remote IP.
- A bearer proves possession of one credential authority; it does not attest a physical device,
  process, or network location. Executor single-device rules are enforced as one logical
  registration, at most one current address, and one current credential epoch when that address
  exists. IP address and User-Agent remain audit capture only — NAT, proxies, reconnects, and
  legitimate process retries make them invalid
  uniqueness keys. Copying a current credential into independent stores is unsupported and cannot
  be made distinguishable by adding IP binding, device fingerprinting, heartbeat state, or a
  session coordinator without a separately approved threat model and product protocol. Presence
  proves only that at least one current-epoch subscription exists, not physical single-instance
  execution. Logical-key, epoch and first-party local-lock requirements remain enforceable.
- Runner assignment ACL never expands management authority. Regardless of `user_private |
  account_wide`, only the Runner's current Human manager may use v1's `/runners` lifecycle and
  credential commands. Account administrator status supplies no takeover or emergency bypass when
  that manager is removed; the accepted Human-shutdown generation protocol remains authoritative.
  A future manager transfer requires a separate explicit authorization and route contract.
- The primitive that generates and reveals a raw bearer secret is a PORO, not an Active Record
  model factory. Ordinary independent issuance uses optimistic preconditions plus database
  constraints and owns no row lock. When issuance is one step inside an already-chartered
  lifecycle winner — device Consume, single-use refresh rotation, or recovery generation/fencing —
  that outer command retains its specified transaction and owner-row locks; the raw-secret
  primitive neither acquires hidden locks nor reloads lifecycle owners. Models keep persisted
  credential integrity (ownership, digest storage, plane/binding exclusivity, revocation, expiry).
  Raw secrets are shown once (expiring-verifier reveal, `.ai/patterns.md`) and stored only as salted
  digests.
- Enforce principal removal, restoration and transport retention through `.ai/boundaries.md`'s
  Administration Boundary. A shutdown-generation mismatch blocks member authority,
  Connect/Consume, re-pair and new admission. An older connected device Request also loses on its
  frozen browser-actor authority generation after remove→restore. Operator tooling keeps
  credential families separate: never save or reuse a foreign bearer as the tool's own credential.

## Supported Authorization Semantics

- Installed agent programs and their identity/display-name claims are owner-selected software
  within the Account trust domain. Review normal mapping, credential-plane and fencing failures;
  software phishing, same-identifier claims and installation sourcing do not create a Nexus
  impersonation boundary. Registration shape and reconnect behavior live in `.ai/boundaries.md`
  and `docs/oauth/device-flow.md`.
- A browser operator may deliberately log out, reauthenticate or switch principals before
  continuing a local authorization/device-confirmation page. That is supported when the current
  principal is authorized and durable integrity holds. Escalate an uninvolved principal acting
  without the operator, excess authority, or a broken invariant.
- Rails query/body parameter merging does not require custom body-only parsing merely because a
  caller can put its own secret in a query or submit conflicting copies. Enforce transport-source
  separation only for an explicit endpoint contract, influence by another principal, or exposure
  created or propagated by the application.
- Device-code `interval` and `slow_down` are cooperative pacing and best-effort abuse controls.
  Concurrent polls in one short-lived ceremony may share pending observations or coalesce a bump;
  exact additive increments do not require locks/CAS. Double mint, terminal bypass, credential
  corruption, unbounded work or a supported-load resource failure remain defects. This tolerance
  does not support copying the resulting credential bundle across independent stores, and does
  not replace deployment-layer WAF/proxy controls.

## Local Credential Persistence

- rho's daemon-lifetime boot lock is the single-writer boundary for one `RHO_HOME`. `StateFile`
  owns atomic publication, persist-before-use ordering, ambiguous-publish no-retry behavior,
  secret redaction and in-process synchronization. The trusted operator, copied homes and
  processes excluded by that lock do not justify sidecar locks, inode revalidation, pid files,
  NFS protocols or cross-process sibling adoption. A first-party path bypassing the lifetime lock,
  a non-atomic credential write, secret exposure or retry after ambiguous publication is a failure.
- `StateFile::PublishedError` distinguishes successful rename/link followed by failed directory
  fsync from a pre-publication failure. The document has been published and the caller must not
  retry. This also applies when `create_once` loses to a winner and directory fsync fails: a
  document is published. Do not require opening the directory descriptor before publication
  merely to prevent the labeled outcome; that raises peak descriptor use without preventing it.
- State files are created with mode 0600 under private 0700 directories and checked for ownership.
  Existing files need no group or other access, not exact mode equality: stricter modes remain
  accepted. Refuse widened file permissions on read and write; silently repairing them would hide
  an exposure and could rotate away the exposed token before it is reported.
- `CybrosAgent::Credentials::OAuth` keeps its persisted document after terminal authority loss for
  diagnosis, and latches that loss in memory. Restart permits one new attempt; no persisted latch
  is required. After a successful rotation that cannot be persisted, retain the new pair in memory
  and raise `NotDurable`; the old refresh token is spent and must never be restored or retried.
  A known published write is distinguished from a failure to persist. Persisted expiry is wall
  clock; skew and reactive retry absorb ordinary clock changes. Never serve a credential plane the
  verified document does not contain, retry a latched loss, or report durability loss as a failed
  server-side rotation.
- rho chooses its renewal lead independently of kernel credential constants. It must renew
  comfortably within its assumed inactivity window; it need not import, fetch or derive the
  kernel's constants. A renewal interval beyond the lead, a lead beyond the assumed window, or a
  comment presenting that assumption as a server guarantee needs correction.

## Secrets, Logging, Parsing

- Never commit or log credentials, tokens, passwords, keys, or raw secrets. Salted digests when
  only comparison is needed; Rails encryption plus length validation when plaintext must be
  retrievable. Encryption at rest and no-render code paths are the protection; a serializer
  except-filter over decrypted attributes is not a security boundary — do not add or request one.
- Every application-owned BCrypt entry point rejects candidate strings BCrypt cannot represent,
  including NUL, before invoking the KDF. Verification maps them to an ordinary credential failure;
  new passwords surface model validation errors. Never clean the candidate or broadly rescue KDF
  exceptions.
- JSON from HTTP bodies, webhooks, user files, executors, and model providers is untrusted: parse
  safely, return a safe error, never expose parser internals, stack traces, or raw malformed
  payloads. Regexes on user input use `\A`/`\z` anchors with a length cap first; user-supplied
  regexes need a safe engine, a timeout, or a prohibition.
- Caller-controlled opaque JSON is not a credential field merely because the caller could put a
  secret in it. Do not enumerate arbitrary container names or filter `metadata`, `value`, task
  inputs or tool payloads on that possibility alone. Applications needing confidential opaque
  storage encrypt it before upload and own the keys. Explicit credential fields and written
  privacy contracts remain enforceable.
- Synthetic credentials generated for isolated tests are public test inputs. Their appearance in
  local logs, exceptions, screenshots or retained test artifacts is not a security or quality
  finding; redaction may reduce noise. This exception excludes real external credentials,
  production data and harnesses capable of addressing non-test environments.

## Outbound Requests, Shell, HTML

- All production outbound HTTP uses `httpx`; configure `SimpleInference::HTTPAdapters::HTTPX`
  explicitly. No `Net::HTTP`, `OpenURI`, Faraday, or Typhoeus in production paths without a
  written exception.
  - Standing exception (stack-coherence doctrine): processes that run inside an Async reactor use
    `async-http` — async process → async-native client; thread process → `httpx`. Current
    adopters: `bin/model_runner`'s provider IO (`SimpleInference::HTTPAdapters::AsyncHTTP`) and
    `cybros_agent`'s agent-framework/daemon transports. Each adopter re-earns the transport
    contract (no redirect following, error wrapping, timeout budget, bounded pool) in its own
    pinned test battery. The gem's client-plane default transport, Puma, and Solid Queue workers
    stay on `httpx`.
  - Narrow Telegram exception: `rho-ingress-telegram` may use
    `telegram-bot-ruby`'s `Api#call` through its instance-owned Faraday HTTPX adapter inside
    rho's Async reactor. This reuses the gem's Bot API parameter/multipart encoding without
    adopting its polling lifecycle. The default Net::HTTP adapter, redirect following and
    automatic retries are prohibited; HTTPX sets `max_retries: 0`. Polling and sending own
    separate bounded connections with finite connect/read timeouts, and shutdown cancels and
    closes outstanding requests. The package's loopback HTTP tests pin concurrent poll/send,
    raw new fields, 429 `retry_after`, no retry/redirect, ambiguous POST handling, timeout and
    cancellation. rho still owns durable offsets, admission, explicit recovery and delivery;
    token-bearing URLs and upstream exception causes never reach its diagnostics. This
    exception does not change other Async transports or qualify live Telegram behavior.
  - A Model-Plane execution-pair fallback must be an explicit product profile whose request,
    signer, parser, and result behavior has direct tests. Development capture does not authorize a
    transport pair.
- Parse URLs with `URI`, never substring checks; validate scheme, host, port, redirects. Block
  loopback, private RFC 1918, IPv6 loopback, and link-local ranges for user-controlled
  destinations; resolve then pin the public IP (DNS rebinding). Timeouts on every external call.
  The explicit `rho-web-tools` setting `allow_private_network: true` lifts only loopback and
  RFC 1918; metadata, link-local, CGNAT, IPv6 unique-local and other reserved ranges stay blocked.
  This does not prohibit a trusted Human administrator from configuring their own local or
  private model provider. Provider directory discovery follows the configured connection with
  finite timeouts and no redirects; the deployment operator is not an attacker.
- Prefer Ruby APIs over shelling out; argv-array form with user data as separate arguments and
  `--` separators — never interpolated shell strings with user data. Validate user paths before
  joining (an absolute path discards the base); archive extraction rejects traversal and symlinks.
- No `html_safe`/`raw` with user-controlled values; sanitize URL schemes before links/redirects;
  reject invalid input rather than sanitizing it into a semantically different value.

## AI And LLM Features

- LLM responses are untrusted output: sanitize before rendering. Validate and bound inputs feeding
  prompts or tool calls. Tools are available only through explicit contracts and current
  enablement; tool effect profiles are declarations, never a security boundary on their own.
- Rate-limit endpoints that can trigger model calls, expensive tool work, or unbounded agent loops
  (`.ai/patterns.md`, Business Recipes). Unknown monetary cost is not zero, but optional
  pricing does not block otherwise eligible model work (`.ai/nexus.md`); record usage quantities
  independently.
