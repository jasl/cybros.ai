# Nexus application login

The public first-party client `cybros-application` uses Nexus as its authorization
server. Authorization Code with PKCE S256 serves browser applications; Device Flow
serves terminals and browsers that need a user code. Both grant a Human platform
credential and can connect the application's Agent and optional Runner in the same
operation. The retained `cybros-first-party-connector` client and its
[device connection](device-flow.md) remain available for integrations that need
only Agent or executor credentials.

## Authority and instance ownership

There is one coarse scope, `application`, used by default. It covers the Human's
ordinary `/api/v1` access; `/api/v1/admin` additionally checks the Human's current
owner/admin role on each request. There is no separate administrator scope.
Suspension, removal, recovery fences and revocation still invalidate credentials.
An Agent credential cannot use these Human APIs. The Human application lineage
also retains its authorized Agent or Runner binding. A later steward transfer
fences the previous Human's application access and refresh; it does not rely on
rho to cache or infer ownership.

`agent_identifier` is an opaque, stable program-instance identifier prepared by
the application, such as `rho.<instance_id>`. Nexus has one Agent per
`(account_id, agent_identifier)`, including removed Profiles. Authorization by its
existing Human steward reuses that Profile. Authorization by another Human is
refused before issuing any Human, Agent or Runner credentials. Signing out, a new
browser session, or a role change does not transfer the instance to another Human.
The same rule applies to Agent connections through the retained connector client.

An initial `connection_mode=connect` grant issues separate credential lineages:

- A Human platform access/refresh pair for login and settings.
- An Agent member and application-executor pair with its own refresh token.
- An optional Runner transport pair with its own refresh token.

Runner-only applications can use the existing machine registration shape. The
Runner remains a delivery address rather than a Human or Agent principal.

For an already connected runtime, `connection_mode=login` verifies its current
Human ownership and issues only the Human lineage. It does not re-pair executors,
fence their epochs, or disturb running work. Clients choose this mode from live
connection state; users do not need to choose it.

## Browser flow and first boot

1. rho starts and serves its public page with **Connect to Nexus**.
2. The browser begins authorization with state, a PKCE S256 challenge and its
   deployment-registered rho callback URI.
3. If Nexus has not been initialized, it retains the validated internal
   authorization destination and opens first boot. The bundled installation lets
   the visitor create the first owner directly, without a setup secret. An
   operator may explicitly configure `NEXUS_SETUP_SECRET` to require a private
   secret for this step; rho's public Connect response never supplies it.
4. First boot creates the owner and signs that Human into Nexus. It resumes the
   authorization page without requiring a second password login.
5. After approval, Nexus returns a single-use authorization code and the original
   state to rho. rho verifies the local attempt and exchanges the code with its
   PKCE verifier. It saves the separate credential bundles before using them and
   gives that browser a distinct local session bearer.

Nexus must be running before connection is possible. A network failure is not an
uninitialized Account. Model configuration can follow successful login and does
not block the connection.

### Authorization request

`GET /oauth/authorize` takes `client_id=cybros-application`,
`response_type=code`, `redirect_uri`, `state`, `code_challenge`,
`code_challenge_method=S256`, optional `scope=application`, and
`connection_mode=connect|login` (default `connect`). Registration fields use the
same Agent, combined Agent/Runner, or machine-only shapes as the connector's
[device start](device-flow.md#branch-ab--combined-connection-an-agent-that-is-also-a-runner).

Nexus validates the callback before using it. Approval requires a Nexus Human
browser session. A bearer token cannot substitute for that browser authorization.
The consent page is not cached. Its `Referrer-Policy: same-origin` preserves the
same-origin native form POST needed by Rails CSRF verification while withholding
the authorization URL from cross-origin destinations. The page requires a full
document navigation, including after setup or sign-in through Turbo, so that the
browser applies this response policy before submitting consent.
The code expires after five minutes, is single use and is bound to client, callback, PKCE challenge and approved
consequence. Wrong verifiers, changed callbacks and replays cannot mint credentials.

### Code exchange

`POST /oauth/token` takes `grant_type=authorization_code`,
`client_id=cybros-application`, `code`, `redirect_uri` and `code_verifier`.
Requests and OAuth errors follow the encoding, no-store and error-envelope rules
of the [connector protocol](device-flow.md).

The successful envelope contains `access_token`, `token_type: "Bearer"`,
`plane: "platform"`, `expires_in`, `refresh_token`, `scope: "application"`, and
`user: { public_id, display_name, role }`. An Agent connection also identifies
`agent_public_id`. Initial connection nests the Agent's existing credential bundle
under `agent` and, when requested, the Runner bundle under `runner`. Login-only
responses omit runtime bundles. These are distinct principals and must be stored
and refreshed independently.

## Device Flow

`POST /oauth/device_authorization` uses `client_id=cybros-application`, the same
scope, connection mode and registration fields. The usual response contains the
device code, user code, verification URLs, a fifteen-minute expiry and polling interval. The Human
opens Nexus, signs in and approves; rho polls `/oauth/token` with
`grant_type=urn:ietf:params:oauth:grant-type:device_code`. Successful polling returns
the same Human envelope and optional runtime bundles as a code exchange.

Before Account initialization, device start returns `409` with
`error: "initialization_required"` and `initialization_uri`. That URL contains no
installation secret. Complete Nexus first boot and explicitly start the device
flow again. Do not treat initialization as a pending device grant or continually
create grants while waiting. Device Flow finishes through polling; it requires no
OAuth callback to rho.

## Renewal, logout and local storage

The Human refresh token uses `/oauth/token` with `grant_type=refresh_token` and
`client_id=cybros-application`. A successful rotation returns only the new Human
pair and profile envelope. Agent and Runner lineages rotate independently through
their existing credential owner, using `client_id=cybros-application` for every
lineage issued by that application grant. Token revocation uses `/oauth/revoke`.

rho persists Human login credentials in its private local session state, separate
from the Agent member/executor vaults. Browser `sessionStorage` contains only its
local bearer and pending login attempt. The daemon checks live Human authority
through `/api/v1/profile`; `/api/v1/session` is the API Session resource and is not
an OAuth identity check. The same browser's Human credential serves rho's settings proxy,
`POST /nexus/request` with `{ "method": "GET", "path": "/api/v1/profile" }`
(and a `body` for mutations). It returns the Nexus response status and body. Nexus decides current permissions for every resource.
Logging out revokes that Human lineage and local session, while the Agent and
Runner continue under their own credentials. rho no longer has an access-password,
unlock, or console-code browser login flow.

## Deployment origins and HTTP

`NEXUS_OAUTH_REDIRECT_URIS` is a JSON array of exact allowed callback URLs. The
built-in local defaults are `http://127.0.0.1:7777/auth/callback` and
`http://localhost:7777/auth/callback`. Configure other ports and deployed origins
explicitly. Callback URLs have no userinfo or fragment.

HTTPS is the normal deployment. Loopback HTTP callbacks work for local use.
`NEXUS_OAUTH_ALLOW_HTTP=true` explicitly permits registered HTTP callbacks for
local/private-network deployments. This deployment exception does not provide
transport encryption or relax PKCE, state, single-use code or callback matching.
Device Flow also needs an appropriately protected connection to Nexus.

rho distinguishes its internal Nexus URL (`RHO_NEXUS_URL`), browser-visible Nexus
URL (`RHO_NEXUS_PUBLIC_URL`) and browser-visible rho URL (`RHO_PUBLIC_URL`). For a
combined LAN installation these may be `http://nexus`,
`http://10.0.0.115:3300` and `http://10.0.0.115:7777`, respectively. Ordinary users
open the public rho URL directly; SSH forwarding is an optional deployment choice.

## Boundary verification

Before initialization, the default deployment allows a visitor who can reach
Nexus to create its first owner. Account creation closes that first-boot entry.
An operator-configured `NEXUS_SETUP_SECRET` adds a private secret check to first
boot; an absent or incorrect secret then cannot create the owner. The bundled
installer does not generate or require that optional secret.

Human login credentials and existing Agent/Runner ownership remain protected by
the authorization flow. An unauthenticated network browser can visit rho and
start an OAuth attempt, but cannot obtain a session without completing its own
authorized attempt. A different signed-in Human may request the same instance
identifier but cannot claim it. An intercepted code is insufficient without the
verifier. Tests exercise direct default first boot, the optional setup-secret
check, wrong callback/verifier, code replay, cross-Human binding refusal, revoked
refresh, ordinary-Human access, and live admin demotion.
The deployment operator and deliberately installed application are trusted; this
contract introduces no host attestation or same-process isolation mechanism.
