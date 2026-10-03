# Security Principles

**Applies to:** every project. The trust domain, secret handling, shell/path safety, and AI/LLM safety are language-independent; clauses naming Rails mechanisms are `nexus`-only and say so.

## Trust Model

One `Account` is the single trust domain (`.ai/boundaries.md`). The security boundaries are:

1. The account edge: authentication (sessions, `sk-cybros-*` credentials, OAuth flows).
2. Executor binding: a task-executor-bound credential reads and mutates only its own directed
   Tasks; per-Task scoping keeps running work inside its own resources.
3. Effects and content: tool effect profiles, approvals, and untrusted-content handling. What is
   untrusted is content — LLM output, tool results, ingress payloads, user data — not connectors.

Workspace access control is product-level authorization among trusted members, not a security
isolation layer; do not build concealment semantics on it.

Every proposed security control first passes `.ai/boundaries.md`'s Threat-Model And Portability
Gate: name the asset, attacker, capability, boundary, and distinguishing test. The user's trusted
environment and deliberately installed implementation packages are not hostile same-process
actors; a digest is integrity/version capture rather than identity or authority; compatibility
does not depend on machine fingerprints or transient inventories; probes collect only explicitly
allowed typed capabilities; and supply-chain controls stay at the distribution boundary rather
than entering model execution.

**Local file access by an agent program is the product, not a vulnerability** (owner ruling,
2026-07-26). rho exists to read and write the human's own files on the machine the human ran it
on, under that human's own uid; a finding that says "rho can write arbitrary local paths" is
describing the feature. Those coding tools execute on the **runner** role — a separate abstraction for
environment-bound tools, expected to run in a container or the cloud; an agent plays that role
only on an executor address of its own, never by lending its member bearer (rho pairs a SECOND
executor row of kind `runner` on a transport-only credential beside its agent-application address
— S-D step 2, cb415c44 — and names that runner-kind row on every host it opens). A runner is a
passive delivery address that may serve multiple eligible Agent
Profiles within its assignment scope, not a security principal or a Profile-exclusive companion.
Switching runner is an explicit handoff the agent application invokes and the kernel records
before it addresses future work to the new one (`.ai/boundaries.md`). Do not require an in-process filesystem sandbox, a chroot, a path allowlist
over the user's own files, or a capability layer between rho and the disk — proposing one blocks
the product on a boundary the architecture deliberately places elsewhere.

What that carve-out does **not** cover, and what stays in scope for review:

- **rho's own secrets.** The credential vault, staging slot, local bearer, and log files stay
  0600-under-0700 and fail closed; a log line or diagnostic that could carry a token is a real
  finding (spec 41).
- **The local control surface.** Bearer check, Host/DNS-rebinding check, bind rules, and the
  transport assertions for a non-loopback bind are unchanged and enforceable.
- **Traversal across a boundary the design does declare.** Public identifiers become path
  segments, and `Rho::Home` refuses any that could escape the tree; workspace bindings pin a root
  fingerprint. Those are real fences and breaking one is a real finding — the carve-out is about
  the user's own files, not about escaping rho's own structure.
- **Untrusted content deciding what to touch.** LLM output, tool results, and ingress payloads are
  untrusted (clause 3 above). The control is tool effect profiles and approvals (spec 13), not a
  filesystem sandbox — so review those, and review whether an effect that should require approval
  can reach the disk without one.

## Authorization

- Default-deny at the namespace/base controller; public or bootstrap endpoints are explicit,
  narrow, searchable exceptions. Every `skip_before_action` — including
  `allow_unauthenticated_access` and every guard-relaxing macro built on it — supplies an explicit
  `only:` action allowlist, even when every action currently defined by that controller is exempt;
  a blanket skip silently exempts future actions from the guard. No dynamic permission names; no UI visibility or feature flags as the only control.
  Tests cover what an actor can and cannot do.
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
  Agent/Runner credential under specs 01/03; Model Plane provider OAuth is an Account-admin
  authorization workflow for Codex subscription and never mints a Nexus principal credential.
  A Human device-start may create a disabled ModelProviderPolicy anchor and run while the
  lane is disabled. Successful credential installation enables that lane atomically; failure
  does not. Internal refresh still requires an enabled lane and never changes enablement.
  Disable retains the mutex row and revokes pending authorization, so a late success cannot
  undo it; clear has the same cancellation precedence. No Policy delete writer exists
  (owner ruling 2026-10-01).
  Production provider authorization creates a dedicated Nexus-owned token lineage. It must not
  import, copy, refresh, or share the refresh token in an active `CODEX_AUTH_FILE`; a small explicit local
  development diagnostic may read only an already-issued CLI access token, account identity, and
  expiry into memory for one call. It applies the selected execution timeout, refuses before IO
  unless the token outlives that deadline plus the release-owned skew, then discards the values
  without refresh or persistence. It carries no capture ancestry, source-currentness proof, or
  promotion state. The owner-authorized development seed exception (2026-08-29) may install the
  access/refresh pair from `CODEX_AUTH_FILE` through `InstallOAuthPair`, refusing any pending OAuth
  session and any environment other than development/test. That explicit tool and its tests live
  under `e2e/manual`; Nexus never loads them. The file is a one-time seed, not a synchronized token
  store: Nexus owns subsequent rotation, so the operator must not keep the CLI rotating that same
  pair independently. This adds no production import route. Long-lived production Codex inference
  authenticates only from the encrypted credential installed by Nexus's own device start. Selection and ProviderStart
  treat it as usable only when
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
  carrying userinfo, query, fragment, redirect, or code material are rejected. Exchange mechanics
  and the classified digest-input inventories are owned by spec 12 and spec 42.
- Ownership and last-admin invariants are protected at the controller boundary and in the domain
  transition, with allowed and denied paths tested.
- Credential endpoints (login, first-boot signup, password reset, token issuance) get
  controller-boundary rate limiting; authenticated issuance keys the limit to the authenticated
  actor, not the remote IP.
- A bearer proves possession of one credential authority; it does not attest a physical device,
  process, or network location. Executor single-device rules are enforced as one logical
  registration, at most one current address, and one current credential epoch when that address
  exists. IP address and User-Agent remain
  audit capture only — NAT, proxies, reconnects, and legitimate process retries make them invalid
  uniqueness keys. Copying a current credential into independent stores is unsupported and cannot
  be made distinguishable by adding IP binding, device fingerprinting, heartbeat state, or a
  session coordinator without a separately approved threat model and product protocol.
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
- Principal removal is an immediate member/data-authority and new-admission fence; restore never
  reactivates old credentials. Agent Profile removal also synchronously fences its Agent-application
  transport through the existing credential epoch while retaining the active address, then
  asynchronously force-stops related work (owner ruling 2026-09-19; `.ai/boundaries.md`). An
  independent Runner is not revoked by that Profile's removal. Human removal/erase keeps its
  separate managed-resource shutdown protocol: remove-only Human generation plus independent
  applied generations on Agent Profiles and TaskExecutors preserve that episode across restore.
  When that convergence removes a Profile, the Agent credential cut and asynchronous force-stop
  apply too; other managed executors retain the transport needed for safe task reconciliation
  until their epochs/lifecycles are fenced. A generation mismatch blocks member authority,
  Connect/Consume, re-pair and new admission. An older connected device Request also
  loses on its frozen browser-actor authority generation after remove→restore. Operator tooling keeps credential families
  separate — a foreign bearer credential is never saved or reused as the tool's own credential.

## Secrets, Logging, Parsing

- Never commit or log credentials, tokens, passwords, keys, or raw secrets. Salted digests when
  only comparison is needed; Rails encryption plus length validation when plaintext must be
  retrievable. Encryption at rest and no-render code paths are the protection; a serializer
  except-filter over decrypted attributes is ineffective theater, never a security boundary
  (owner ruling 2026-08-13) — do not add or request one.
- Every application-owned BCrypt entry point rejects candidate strings BCrypt cannot represent,
  including NUL, before invoking the KDF. Verification maps them to an ordinary credential failure;
  new passwords surface model validation errors. Never clean the candidate or broadly rescue KDF
  exceptions.
- JSON from HTTP bodies, webhooks, user files, executors, and model providers is untrusted: parse
  safely, return a safe error, never expose parser internals, stack traces, or raw malformed
  payloads. Regexes on user input use `\A`/`\z` anchors with a length cap first; user-supplied
  regexes need a safe engine, a timeout, or a prohibition.

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
  - Narrow Telegram exception (owner-approved 2026-09-29): `rho-ingress-telegram` may use
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
  (`.ai/patterns.md` RateLimiter recipe). Unknown monetary cost is not zero, but optional
  pricing does not block otherwise eligible model work (owner ruling 2026-09-30,
  `.ai/nexus.md`); record usage quantities independently.
