# Nexus OAuth Device Flow (v1)

This page describes the retained connector client: device flow (RFC 8628), refresh
rotation (RFC 6749 §6, RFC 9700), and revocation (RFC 7009). The separate
[application client](application-login.md) adds Human login, Authorization Code with
PKCE, and automatic Agent connection; rho uses that client.
Authorization Code and redirects are not supported by the connector client.

This protocol connects an Agent application, Runner, or tools provider to Nexus.
For the interactive rho setup path, see [Getting started](../getting-started.md).
It is separate from a model provider's [subscription authorization](../platform-api/v1/provider-authorization.md):
that flow installs the provider's credentials and does not connect an Agent to Nexus.

## Client identity

The connector ceremony uses the first-party public client

```
client_id = cybros-first-party-connector
```

It is OAuth metadata, not a product entity. Every machine request must carry exactly this value;
`invalid_client` otherwise. There is no client secret.

## Requests, responses, and caching

- Machine requests are `application/x-www-form-urlencoded` or `application/json` POSTs
  (the SDK's wire is JSON — the contract fixtures pin it); any other media type is
  `invalid_request`, because the duplicate-scalar counter below can only count media it can
  read. A duplicated scalar — form field or JSON key — is `invalid_request`. Normal
  endpoint-produced successes and defined OAuth errors are JSON when non-empty.
- Those normal successes and defined OAuth errors set `Cache-Control: no-store` and
  `Pragma: no-cache` (RFC 6749 §5.1; the device-authorization response carries codes and pins
  the same headers).
- An unhandled application failure or an upstream proxy failure is not an OAuth response
  contract: any 5xx body may be JSON, non-JSON, or empty, and its media type and cache headers
  are not stable. Clients classify it from the status and tolerate all of those representations.
- Machine endpoints never use cookies or CSRF state; the browser ceremony never accepts a bearer.
- Each endpoint reads only its listed fields. Unknown parameters are ignored; empty values are
  treated as omitted. A duplicated scalar field, or an array/object where a scalar is required,
  returns `invalid_request`.
- Raw `device_code`, access-token, and refresh-token values appear exactly once, in the issuing
  response. They are never echoed elsewhere, never placed in URLs (the complete verification URI
  carries only the user code), and are redacted from server logs. Clients must redact them from
  their own logs and diagnostics too.

## Credential formats

Wire values are opaque to clients; only the prefixes are stable:

| Credential | Shape |
| --- | --- |
| Access token | `sk-cybros-api-v1-…`, expires 1209600 seconds after issuance |
| Refresh token | `rt-cybros-api-v1-…` |
| Device code | `dc-cybros-v1-…`, single connection transaction only |
| User code | 8 characters from `BCDFGHJKLMNPQRSTVWXZ`, displayed `XXXX-XXXX` |

An access token is unusable at or after its expiry instant on either plane.
Authentication never extends that deadline; its last-use timestamp is only a
contact sample.

## POST /oauth/device_authorization

Starts one connection transaction.

A request declares one of three **connection shapes**: branch A (the agent triple alone),
branch B (the runner pair alone), or the combined shape A+B (BOTH claim sets, complete — an agent
that also serves as a runner on its own machine). Combined = both sets
complete; anything between — a half triple, a half pair — is a mix and `invalid_request`. All
three share the same browser ceremony, poll, and error vocabulary, and differ only in what a
winning consume materializes.

Always required:

| Field | Rule |
| --- | --- |
| `client_id` | exactly `cybros-first-party-connector` |

An optional scalar `scope` is accepted for compatibility with standard OAuth
libraries and ignored. Nexus negotiates no OAuth permission grant; credential
authority comes only from the server-minted credential plane, and responses
never contain a `scope` member.

### Branch A — agent connection

Materializes/reconnects the connecting human's Agent and opens its connection — the
refresh lineage that records the signed-in program. The connection carries the profile's one
`agent_application` delivery address, always: the response is a member credential plus that
address's executor transport credential.

| Field | Rule |
| --- | --- |
| `agent_identifier` (required) | a stable, non-secret identifier for the program instance, combining its product constant with a locally persisted instance part: 1–128 printable non-NUL characters, no surrounding whitespace, compared exactly and case-sensitively |
| `agent_display_name` (required) | nonblank, at most 100 characters; the program-owned Agent User name written by the winning Consume after browser connection |
| `executor_display_name` (required) | nonblank, at most 100 characters |

### Branch B — machine connection (a runner, or a tools provider)

Materializes/re-pairs a machine delivery address only — a `runner` or a `tool_provider`, which is the same registration shape serving tools by name and
claiming from pools. It resolves and creates **no Agent**, carries no agent fields, and
returns only an executor transport credential — a machine is not a principal.

| Field | Rule |
| --- | --- |
| `registration_identifier` (required) | a stable, non-secret identifier for the machine program instance, combining its product constant with a locally persisted instance part; nonblank, at most 128 characters, compared exactly and case-sensitively |
| `runner_display_name` (required) | nonblank, at most 100 characters |
| `executor_kind` (optional) | `runner` (the default when absent) or `tool_provider`; any other value is `invalid_request`. The first-party SDK always sends it. |

A machine request never carries `agent_identifier`, `agent_display_name`, or
`executor_display_name`: the transport consequence is implied by the identifier branch. The
identifier branch is the request discriminator and `executor_kind` is branch B's alone: Nexus
derives `agent_application` from an Agent request, and an `executor_kind` on branch A — any
value — is `invalid_request`. The requested kind is frozen on the authorization
(`requested_executor_kind`) and minted at Consume.
`assignment_scope` is not part of the machine request schema or first-party SDK; any
extra raw parameter is an unknown field and cannot influence authorization. Assignment scope is
selected only by the human at browser Connect and applies only when Consume creates a fresh
logical registration.

### Branch A+B — combined connection (an agent that is also a runner)

The five required fields of branches A and B on one request, each under its own branch's
rule: `agent_identifier`, `agent_display_name`, `executor_display_name`, `registration_identifier`,
`runner_display_name`. `executor_kind` may be absent or exactly `runner` — the runner half's kind is
fixed `runner` (a tools provider under an agent's grant is meaningless; any other value is
`invalid_request`). The grant fixes `user_private` at issuance as the scope for a fresh Runner
registration. Re-pair preserves a live match's stored scope, including `account_wide`. The human
approves ONE page — branch A's page plus a facts row describing the runner's local read, write,
and command capabilities and its scope, with no scope selector. Pending and connected pages show
the live match's stored scope, or the private default when no live match exists. The winning
consume materializes BOTH halves in one transaction: the agent's profile and address as branch A,
and the runner registration as branch B (re-pairing a live `(account, manager, registration_identifier)`
key in place, creating a fresh row otherwise), minting TWO refresh lineages (the family index is
per executor) and returning the nested `runner` object of the Success shape below.

Both halves commit together. A refused consume creates no partial Agent or Runner
connection and returns no credentials. If the Runner's previous registration was
revoked and collected, a successful combined connection creates a fresh Runner
registration with a new public ID.

Agent and Runner products combine a release-stable product constant with an instance part
established when their local home is prepared. For example, rho sends `rho.<instance_id>`;
its standalone runner sends `rho-runner.<instance_id>`. Nexus treats the complete identifier
as opaque and does not parse either part. The browser never displays or asks a person to
choose it. Restarting the same home preserves its logical identity; preparing a fresh home
creates a distinct instance even when the product is the same. Reconnecting the same exact
identifier re-pairs its address and fences its previous credentials. Copying credentials
into independent stores is not a supported way to run multiple instances.

Nexus uses the exact `(account_id, agent_identifier)` key. An Agent already stewarded
by another Human refuses the connection, including through this retained connector flow. A database
unique index has no status predicate, so active and removed rows retain the slot and there is never
a duplicate Profile choice. Nexus reconnects the active row, restores and reconnects the removed
row, or creates a new Agent User stewarded by that human only when the key is absent. Model
validation provides the ordinary friendly uniqueness error; the database decides a concurrent
loser. An Agent with `status=suspended` violates the model and supported-lifecycle invariant; the
wire contract defines no compatibility mapping or outcome for a row created by bypassing it.

For the connecting Human manager, the same complete Runner instance identifier resolves the same
`(account_id, manager_id, registration_identifier)` logical registration key regardless of assignment
scope. A fresh home registers a distinct instance; reconnecting an existing home keeps its key.
Browser Connect chooses `user_private | account_wide` only for a fresh
logical registration. Re-pairing a live match preserves its stored scope; after terminal
revocation, a later fresh registration may choose again.

Every winning consume writes the latest `agent_display_name` to the mapped Agent User.
Paired Agents are created by this device connection; there is no administrator
pre-creation path. Browser and administrator surfaces do not edit an Agent User's program-owned
name. The browser connection page never displays `agent_display_name`.
`executor_display_name` names the profile's current address when one exists, and a re-pair renames it — the name is
program-owned, so the program connecting now is the one that says what it is called.

There is no negotiated OAuth `scope` grant in this protocol. Nothing is negotiated on a closed
first-party flow — the credential's authority is its mint-frozen plane — but Nexus
accepts and ignores the optional scalar wire parameter so off-the-shelf OAuth libraries need no
special request shaping. Empty and non-empty scalar values have the same non-authorizing effect,
and no value is stored or returned. `admin`-family authority is structurally unreachable here
(agent Users are permanently role `member`, and this client never mints a Human
platform credential). Missing/invalid names or identifier, or
an Agent request without `executor_display_name`, fail with `invalid_request`.
Runner `assignment_scope` is a separate fresh-registration consequence, chosen in the browser
rather than requested or negotiated by the machine.

The connection shape is decided by the identifier branch. An Agent request always
materializes or re-pairs the mapped Profile's `agent_application` address, named by the required
`executor_display_name`; a machine request materializes or re-pairs an address of the kind it
requested — `runner` by default, `tool_provider` on request. The kind is a machine selector on
branch B only, never a browser one (the grant page names it — "Connect runner" / "Connect tools
provider" — and offers no kind control), and is executed at the successful poll:

- Agent branch → the winning poll opens the profile's **connection**
  and its single logical delivery address, named from `executor_display_name`. An Agent
  has at most one current logical address/registration, so finishing another connection
  **re-pairs that same address**: the public id is unchanged, its credential epoch advances, and
  every credential the previous connection held stops working: its transport credential by the
  epoch fence, its member credential because the superseded refresh lineage is revoked with it —
  the same re-pair a runner has always done (branch B below), extended to the member plane an agent
  also holds. A program reached from several places solves that on its own side; it does not create
  another Nexus address for the same Profile. Removing the Agent User synchronously fences its
  member credentials and advances this address's credential epoch, while retaining the active
  address and its public id. Old credentials stop working immediately; related work is
  force-stopped asynchronously. An independent Runner's registration and credentials are not
  revoked by Agent removal. Ordinary restore does not revive the old credentials or wait for
  the stop sweep. A new successful connection restores the same Profile when necessary and
  re-pairs its retained address with fresh credentials. A combined connection also performs
  its ordinary Runner re-pair; that is a consequence of the new grant, not of Agent removal.

Branch B (machine) resolves the exact
`(account_id, manager_id, registration_identifier)` key, which is kind-blind: one live address per key
across both machine kinds. A partial database unique index over
non-revoked rows is the hard boundary. A match **re-pairs that machine in place** — the delivery
address, public id, kind, Human manager, and stored assignment scope survive; the epoch advances
and the previous device's credential is fenced. A live match whose kind differs from the one the
authorization requested is drift, refused the way a forged scope is: the authorization is
invalidated and the poll answers `access_denied` (the kind is the registration's, frozen at
creation like its scope). No live match creates a new machine of the REQUESTED kind managed by
the connecting Human and applies the initial `user_private | account_wide` scope frozen at
browser Connect. A live Runner rotates its own credential through the OAuth protocol, while its Human
manager alone has the `/runners` management/revoke surface; after authorization loss the Runner
reconnects under the same `registration_identifier` and keeps its identity.
`account_wide` is pure new-work ACL and gives administrators no view, credential, revoke, takeover,
or emergency-offboarding authority over another Human's Runner. V1 has no scope-change or
manager-transfer command.

The one-current-registration contract is logical, not physical. A bearer proves only possession
of current credential authority; Nexus cannot distinguish two OS processes or independent
credential stores presenting copies of the same secrets. Such concurrent copies are unsupported
and do not become separately manageable devices. IP address and User-Agent are audit evidence,
never registration or uniqueness keys.

Connect freezes the primary address's internal pairing state — the unique live matching address
identity/epoch/lifecycle; otherwise the newest retained terminal marker; otherwise absence when no
matching row remains. A Connected authorization that froze a terminal marker keeps that row from
being reaped until the authorization resolves; after its durable dependencies disappear, convergence
may reap it and a later Connect legitimately observes absence. If several authorizations Connect
against that same state, only the first successful Consume may create or re-pair the address and
mint credentials; the others finish as `access_denied`. A new authorization issued and Connected
after that success sees the new state and may deliberately re-pair again. An older connected
authorization never refreshes its frozen precondition, so it cannot overwrite a newer pairing or
reverse an explicit address/connection revoke.
For a combined grant, this marker covers the Agent address only; the Runner half has no separate
browser precondition or frozen pairing marker and is resolved at Consume.

Success (200):

```json
{
  "device_code": "dc-cybros-v1-…",
  "user_code": "BCDF-GHJK",
  "verification_uri": "https://nexus.example/oauth/device",
  "verification_uri_complete": "https://nexus.example/oauth/device?user_code=BCDF-GHJK",
  "expires_in": 900,
  "interval": 5
}
```

The verification URIs are absolute. A direct localhost or LAN-IP deployment uses the request
origin that created the authorization. When the deployment configures an internal/public domain
`BASE_URL`, that canonical origin overrides request and forwarded host/protocol/port values. The
complete URI only prefills the code. Connection requires a signed-in active human to compare the
displayed code. An Agent connection always resolves that human's own steward key. A machine
connection — a Runner's or a Tools provider's; the page names which — always resolves that
Human as manager, and both kinds take the same scope block. An ordinary member's fresh registration is
fixed to `user_private`; an owner/admin connecting their own Runner gets one **account-wide**
checkbox, default unchecked, and checking it selects `account_wide` for a fresh registration.
That role permits only this initial ACL choice: it does not alter the manager key or grant
management of another Human's Runner. A live matching registration re-pairs with its stored scope.

The program must display the formatted `user_code` and instruct its human to compare it with the
code shown on the Nexus connection page. The whole transaction — browser connection and token
collection — must finish within `expires_in` (900 seconds); connecting does not extend it.
Connection and credential issuance recheck that original cutoff after their required member
and executor locks, before recording the connection or beginning pairing/credential writes.
An elapsed cutoff refuses the operation even when the request arrived before it.

## POST /oauth/device_authorization/cancellation

This is a Cybros first-party machine extension, not an RFC 8628 cancellation endpoint. It lets the
program abandon the exact short-lived authorization whose raw device secret it still holds.

Fields: `client_id`, `device_code`, plus the optional scalar compatibility-only `scope` described
above. Its value is ignored. Unknown fields are ignored, while duplicated or non-scalar listed
fields are `invalid_request` under the common machine rule. A malformed, unknown, or mismatched
device code is `invalid_grant`; that response never confirms that stopping is safe. The device
code is never echoed in any response.

Cancel and Consume take the same DeviceAuthorization row lock:

| Result | Meaning |
| --- | --- |
| `200` with an empty body | cancel won, or the Request was already `canceled`, `expired`, or `invalidated`; no credential consequence exists and the client may safely stop its poller |
| `409 {"error":"too_late"}` | Consume already won; the client must not kill the poller and must let the token response finish and be adopted |

When cancel wins from `pending` or `connected`, Nexus atomically marks the Request `canceled` and
clears its frozen browser/mapping/pairing tuple. No Agent, TaskExecutor, access token,
refresh token, or refresh family is created or mutated. A subsequent token poll sees
`access_denied`. Repeating the command against any safe terminal state remains `200`.

`invalid_client`, `invalid_request`, `invalid_grant`, 429 throttling, transport
failure, and every 5xx are all non-safe outcomes: the caller retains the ceremony and must not
infer that it can stop. This asymmetry closes the boundary where Consume may have committed while
its successful response is still in flight.

## POST /oauth/token

One endpoint, two grants. `grant_type` selects; a missing `grant_type` or missing selected-grant
secret is `invalid_request`; an unknown `grant_type` is `unsupported_grant_type`. Client
validation precedes secret lookup. A present but malformed, unknown, or mismatched secret is
`invalid_grant` with no indication of which check failed.

### grant_type=urn:ietf:params:oauth:grant-type:device_code

Fields: `client_id`, `device_code`, plus the optional scalar compatibility-only `scope`. Its value
is ignored and never appears in the token response.

Each client instance polls at its current `interval`. Nexus applies `slow_down` as a best-effort
abuse guard, raising the persisted interval by 5 seconds up to 60 for ordinary serial polls.
Concurrent clients sharing the same authorization may both observe `authorization_pending` or
coalesce an interval bump; the hard guarantees are that only one Consume can mint for one
authorization and only one authorization Connected against a given frozen pairing state can win
that state transition. Responses while the transaction is open:

| error | Meaning |
| --- | --- |
| `authorization_pending` | awaiting browser connection; keep polling at the current interval |
| `slow_down` | polled too fast; interval increased — back off |
| `expired_token` | the 900-second transaction deadline passed; stop this authorization |
| `access_denied` | canceled, or the connected authorization became invalid before minting (authority or frozen pairing-state drift); stop this authorization |
| `invalid_grant` | unknown, malformed, or already-consumed device code |

A new authorization after either terminal outcome requires an explicit
application or operator action; never restart the browser ceremony automatically.

A consumed code replays as `invalid_grant` even after the deadline. Success atomically mints the
connection's whole credential bundle — one refresh family per executor, so a combined consume
mints two (see Success shape) — together with its shape's executor consequence. In either branch, a matching non-revoked address re-pairs in
place and advances the epoch that fences the credential the previous connection held. A
never-connected or terminally revoked key instead creates a new TaskExecutor/public id; revoked
history is not revived (see Branch A above for the agent branch's full rule, including the
superseded lineage).

Re-pair does not move work the previous epoch already claimed. The new epoch may claim an
unclaimed task addressed to this executor, but a claimed task is never re-granted. The fenced
old epoch cannot continue its delivery protocol. A claimed task converges under its existing
deadline and effect profile: replayable work becomes `timed_out`, otherwise `uncertain`. A committed
result stays valid and continues materializing. See
[executor replacement and work in flight](../agent-api/v1/executor.md#what-replacement-means-for-work-in-flight)
for the recovery rules.

### grant_type=refresh_token

Fields: `client_id`, `refresh_token`, plus the optional scalar compatibility-only `scope`. Its
value is ignored and never appears in the token response. Rotation always reissues the
connection's exact bundle and negotiates nothing.

Only the current (most recently issued) refresh token rotates. Success supersedes it and returns
a new access token + refresh token pair.

The family lapses only by sitting unused, on a rolling inactivity window that every rotation
refreshes. The window is two access-token lifetimes, derived from that constant rather than
chosen: it has to outlast any access token the family minted, or a lineage could be collected
while a credential it issued still authenticates. There is deliberately **no absolute ceiling**: a lineage that keeps rotating
keeps living, however old it is, because expiring a working connection on a calendar forces a
human back through the browser ceremony for no security gain — rotation with reuse detection, not
a countdown, is what bounds a leaked lineage. Presenting the current token past the inactivity
deadline is ordinary lapse: `invalid_grant`, nothing else happens. Presenting a consumed/superseded token while its
replay evidence is retained is reuse: the whole family and every still-live access token it
minted are revoked, and the response is the same `invalid_grant`. When a transport failure or an
unhandled/proxy 5xx leaves it uncertain whether rotation committed, the client must treat the
connection as lost and raise its terminal authorization-loss outcome. It must never retry that
refresh token or automatically start DeviceFlow; a new device authorization requires an explicit
application/operator ceremony. If the transport can prove the request was not dispatched, it may
instead report a retryable request-not-sent failure; retrying the unchanged refresh token is safe
only in that case.

### Success shape (both grants)

```json
{
  "access_token": "sk-cybros-api-v1-…",
  "plane": "member",
  "executor_access_token": "sk-cybros-api-v1-…",
  "refresh_token": "rt-cybros-api-v1-…",
  "token_type": "Bearer",
  "expires_in": 1209600,
  "runner": { "access_token": "sk-cybros-api-v1-…", "refresh_token": "rt-cybros-api-v1-…" }
}
```

One connection is one lineage that issues a **credential bundle**. `access_token` carries the
bundle's leading credential and `plane` names which plane that is — `member` or
`executor_transport`. Do not infer the plane from the request: an agent connection normally
leads with its member credential, but a lineage whose member authority has since died reissues
its transport half alone and leads with that instead, exactly as an identity-less
runner always does. `executor_access_token` accompanies the leading credential only when a
bundle carries both planes, and is always the `executor_transport` one; a transport-led response
never carries it. Agent removal is not such a transport-only downgrade: it fences the
Agent application's epoch too, so the old refresh token returns `invalid_grant` and cannot mint
either plane. Each secret answers exactly one plane: a
member credential is rejected on executor-transport endpoints and vice versa. Refresh rotates the
whole bundle atomically and returns the same shape; revoking any credential of the lineage ends
the lineage. `runner` is present only on a combined consume, never on rotation — it is the SECOND
lineage, the in-process runner's transport credential and its own refresh token, and each lineage
rotates on its own refresh token (a rotation body never carries the other half; a transport-led
response never carries it). There is no `scope` member — RFC 6749 §5.1 requires the echo only for
a negotiated request, and nothing here negotiates. No other fields are returned.

## POST /oauth/revoke

Fields: `client_id`, `token`, optional non-authoritative `token_type_hint`.

Structurally missing fields are `invalid_request`; a missing/incorrect client is
`invalid_client`. After those checks, the response is always `200` with an empty body — it never
reveals whether the token existed, was already revoked, or lapsed (RFC 7009).

A recognized refresh token revokes its whole family and every still-live access token that
family minted. A recognized OAuth access token revokes itself and its minting family. A
recognized standalone member access token (for example, a Human's self-issued personal token) has
no family and revokes that row only.
Revocation of an OAuth credential therefore severs the connection's whole refresh chain. The
program reports terminal loss and waits for an explicit application/operator connection ceremony;
it never starts DeviceFlow automatically.

## Browser ceremony (human side)

`GET /oauth/device` is the only stable browser URL a device client references. The signed-in
active human enters (or arrives with) the user code, compares it with the device's code, sees only
the connection kind plus remaining expiry/necessary state, and chooses **Connect** or **Cancel**.
The page does not display `agent_identifier`, `registration_identifier`, the program-supplied display
name, executor kind, executor name, existing Agent candidates, or executor topology, and offers no
Agent or executor selector. For a Runner, an ordinary member has a fixed personal
`user_private` initial ACL; an owner/admin connecting their own Runner additionally sees one
account-wide checkbox, default unchecked, only when no live registration matches. A live match
instead renders its stored scope without a selector and re-pair preserves it. A combined grant
renders the agent program's page with one added facts row for its runner half and no scope
selector. Its pending and connected pages show a live matching Runner's stored scope, including
account-wide scope, or the private default for a fresh registration.

Every Agent and runner Connect page always renders the same conditional replacement warning,
which itself does not claim whether the logical address is currently connected:

> If this Agent or runner is already connected, once the requesting device finishes connecting,
> the winning Consume replaces that connection and invalidates the previous device's credentials.
> Work that has not started may continue under the new epoch. Running work does not move
> to the new device and may fail or become uncertain.

This wording is intentionally conditional even when no address exists, so a render-time
observation cannot become a stale promise. The separate Runner ACL area may show the fixed stored
scope for a live match or the initial-scope control for a fresh registration. The runner-only form
also echoes the live registration public id observed by GET, or an explicit `absent` marker.
This is an untrusted, reject-only precondition: POST locks and re-resolves the current Human's
manager-bound key, and a mismatch leaves the grant pending with a reload warning. It cannot name
another key, grant authority, or select scope. A successful POST then freezes its own pairing
marker on the DeviceAuthorization, so Consume also rejects any address change after Connect.

Clicking Connect does not itself replace anything: Connect only freezes the consequence. The
epoch advances and the old credentials are fenced only if the requesting device subsequently
completes the winning Consume.

Connect deterministically resolves and freezes the branch consequence: reconnect, restore, or
create the current human's mapped Agent User; or re-pair the current Human's Runner, creating it
with the browser-selected initial assignment scope when no live match exists. For the runner-only
branch the authorization records that decision as `selected_assignment_scope`; the machine cannot
alter it. Winning Consume applies
that value only to a fresh registration and preserves a live match's current scope. A combined
grant retains `selected_assignment_scope: user_private` as its fresh-registration default;
re-pair still preserves the Runner's stored scope. Cancel shares no authority. Connect
durably freezes its consequence on the
DeviceAuthorization Request but materializes no target/member/executor/credential consequence:
Profile creation/restore/program-name write, the derived executor, and every credential commit
together inside the device's one successful poll. An unconsumed connection therefore leaves only
the Request behind. The short-lived `DeviceAuthorization` coordinates the browser and polling
legs, expires on the original deadline, and is reaped after its bounded terminal retention; it is
not a credential. The console never displays a minted secret.

The authorization lifecycle is `pending → connected → consumed`,
`pending → canceled|expired`, or `connected → canceled|expired|invalidated`. Cancellation stays
available on a connected, unconsumed Request — no target authority exists yet to unwind.
Browser cancellation and the first-party machine cancellation command share that transition.
Cancellation and invalidation both project the RFC `access_denied` result to the polling client.

Every browser response in the ceremony sets `Cache-Control: no-store` and a no-referrer policy.
Successful verification establishes a browser-held context for that authorization. Refresh and
back do not recharge its exposure budget. Session expiry, reauthentication, or a deliberate switch
of the signed-in human preserves that context but resolves the mapping again for the current
human, who must be active when connecting or canceling. An authentication or forced
password-change gate carries that page's safe same-origin GET target independently from other
tabs or windows. An interrupted POST is never replayed; after the gate, the browser returns to
the owning connection GET for an explicit retry.

A code's exposure budget is five distinct successful browser-held verification contexts; past the
budget the code no longer verifies. Wrong guesses are rate-limited and never reveal whether a
code exists. The browser carries exactly one encrypted, HTTP-only context cookie, never one cookie
per authorization. Nexus stores only the context digest on at most five parent-owned verification
rows per authorization; those rows have no independent lifecycle and are deleted with the
authorization. When that cookie is absent, Nexus derives its first value from the already-resolved
browser Session with a dedicated server-side HMAC key. Concurrent first requests under one Session
therefore converge without exposing the Session public id or any session credential. Once present,
the context cookie remains authoritative and independent of later Session replacement. It is
renewed while the ceremony is in use and expires after the authorization TTL plus
terminal-retention window. This keeps request headers bounded while preserving independent grants
across tabs and across browser Session replacement.

## Errors, statuses, and rate limits

Defined OAuth errors use the top-level OAuth envelope — `{"error": "…"}` with exactly one error
string, no nested envelope, no localized prose on the wire.

| Outcome | HTTP status |
| --- | --- |
| Success (issuance, token, accepted revocation) | 200 |
| `invalid_request`, `invalid_client`, `invalid_grant`, `unsupported_grant_type`, `authorization_pending`, `slow_down`, `expired_token`, `access_denied` | 400 |
| First-party machine cancellation lost to Consume — `too_late` | 409 |
| Transport rate limit — `temporarily_unavailable` | 429 + `Retry-After` (whole seconds) |

Transport throttling (429) is distinct from protocol pacing (`authorization_pending` /
`slow_down`): honor `Retry-After`, then resume the protocol. `invalid_client` is returned as 400
(v1 authenticates the public client in the form body, never via the `Authorization` header).

Device-authorization creation allows 6 requests per source IP per minute and
returns `Retry-After: 60` when exhausted. Machine cancellation and revocation
each allow 12 requests per source IP per minute, with `Retry-After: 5`.
These are separate counters; a cancellation throttle does not confirm that the
authorization was canceled.

`POST /oauth/token` first applies two fixed one-minute transport counters. Every request charges a
broad source-IP backstop of 12,000 requests per minute. With the correct client and a recognized
credential secret, the ordinary 120-request budget is keyed by DeviceAuthorization for
`device_code` or RefreshTokenFamily for `refresh_token`; a scalar secret that does not resolve uses
the source IP for that ordinary budget, so random values cannot mint cache keys. The raw secret and
digest never enter a counter key. Different valid grants/families behind one NAT have independent
ordinary budgets, and IP address is never credential, device, or registration identity.
Exhausting either one-minute counter returns `temporarily_unavailable` with `Retry-After: 60`.

A recognized refresh request additionally charges durable-write budgets: 12 requests per refresh
family per hour and 120 requests across the installation's singleton Account per hour. These
limits include rejected replay/state checks once a secret resolves, so successful rotation can
never outrun the bounded access/refresh evidence collectors under the supported ingress envelope.
They do not apply to device-code polling or unknown secrets and therefore do not turn a shared NAT
address into credential identity. Exhausting either returns `temporarily_unavailable` with
`Retry-After: 3600`.

Unhandled application and proxy 5xx responses are transport failures rather than defined OAuth
errors; clients must not require an OAuth envelope, JSON media type, or particular cache headers
from them.

## Client implementation requirements

- One DeviceFlow instance never polls faster than its latest observed server interval;
  `slow_down` and `Retry-After` only ever increase that instance's next delay. This is cooperative
  pacing, not a cross-process lock for clients sharing credentials. Polling has an independent finite budget for consecutive transport
  failures, and an unhandled 5xx response consumes it exactly like a connection failure; a
  handled response — credentials, a defined OAuth error, or 429 throttling — resets that
  consecutive-failure count, and exhausting the budget surfaces the failure. The exact count and
  backoff formula are not frozen. No retry or backoff outlives the 900-second authorization
  deadline.
- Combine a release-stable product constant with a per-home instance part established at
  preparation, and persist that part across restarts. Send the complete value as
  `agent_identifier` or `registration_identifier`; do not ask the person to choose or type it.
  Each fresh home gets a distinct instance. Reconnection uses the existing home's identifier
  and a fresh device flow rather than sharing credentials across independent stores.
- Store received credentials with show-once discipline and redact all `sk-`/`rt-`/`dc-` values
  from logs and error output.
- Treat `access_denied`, `expired_token`, and refresh reuse/lapse as terminal for the current
  connection: report the loss and require an explicit application/operator action to begin another
  device authorization. Never auto-start DeviceFlow.
- Treat an inconclusive refresh rotation as terminal and never retry that refresh token. Retry is
  safe only when the transport explicitly proves the request was not dispatched.
