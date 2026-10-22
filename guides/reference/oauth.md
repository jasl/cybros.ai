# OAuth and device flow

Nexus is the authorization server for two public first-party clients.

| Client | Grants | Used by |
| --- | --- | --- |
| `cybros-application` | A human platform credential plus, on first connection, the application's agent and optional runner bundles | Browser-based applications such as rho |
| `cybros-first-party-connector` | Agent, runner or tool-provider credentials only | Integrations that need no human login |

## Endpoints

```http
GET  /oauth/authorize
POST /oauth/token
POST /oauth/device_authorization
POST /oauth/device_authorization/cancellation
POST /oauth/revoke
GET  /oauth/device                   # the human's verification page
```

## Application login

**Authorization Code with PKCE S256.** `GET /oauth/authorize` takes `client_id=cybros-application`, `response_type=code`, `redirect_uri`, `state`, `code_challenge`, `code_challenge_method=S256`, optional `scope=application`, `connection_mode=connect|login` (default `connect`) and the registration fields of the Agent or machine shape. Approval requires a Nexus human browser session; a bearer cannot substitute. The code expires after five minutes, is single use and is bound to client, callback, PKCE challenge and approved consequence.

`POST /oauth/token` with `grant_type=authorization_code`, `client_id`, `code`, `redirect_uri` and `code_verifier` answers `access_token`, `token_type: "Bearer"`, `plane: "platform"`, `expires_in`, `refresh_token`, `scope: "application"` and `user: { public_id, display_name, role }`. An initial connection nests the agent bundle under `agent` and the runner bundle under `runner`; `connection_mode=login` verifies current ownership and returns the human lineage alone.

**Device flow for the application client.** `POST /oauth/device_authorization` with the same client, scope, connection mode and registration fields answers a device code, user code, verification URLs, a fifteen-minute expiry and a polling interval. Before account initialization it answers `409 initialization_required` with an `initialization_uri`; complete first boot and start again.

If Nexus has not been initialized, the authorization page retains the validated request and opens first boot; creating the owner signs them in and resumes the authorization.

## Device connection

`POST /oauth/device_authorization` with `client_id=cybros-first-party-connector` and one of two branches:

| Branch | Registration fields | Issues |
| --- | --- | --- |
| A — agent | `agent_identifier`, `agent_display_name`, `executor_display_name` | A member credential and an executor transport credential |
| B — machine | `registration_identifier`, `runner_display_name`, optional `executor_kind: "tool_provider"` | A transport credential alone |

The human opens the verification URL (**Agents → Connect agent** or **Runners → Connect runner** in the Nexus browser), checks the code and approves. A fresh machine registration selects its assignment scope there; a live registration re-pairs with its stored scope. Authorization by a human other than the instance's existing steward is refused before any credential is issued.

`POST /oauth/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code` polls for the result, honoring the interval, `slow_down`, `Retry-After` and the 900-second deadline. `POST /oauth/device_authorization/cancellation` asks Nexus for the winner when a client abandons a ceremony it still holds: `canceled` means stop and forget; `consumed` means keep polling and adopt the credentials.

## Refresh and revocation

`POST /oauth/token` with `grant_type=refresh_token` rotates one lineage and returns only that lineage's new pair. Each of the human, agent and runner lineages rotates independently. `POST /oauth/revoke` presents a lineage's refresh token and ends it. Reconnecting the same identifier re-pairs the logical address and advances its credential epoch, fencing every credential of the previous epoch.

## Deployment settings

| Setting | Meaning |
| --- | --- |
| `NEXUS_OAUTH_REDIRECT_URIS` | Optional JSON array of exact allowed callback URLs, replacing the default HTTP/HTTPS `/auth/callback` policy for loopback, `localhost`, private IPv4 and IPv6 unique-local addresses on any valid port |
| `NEXUS_OAUTH_ALLOW_HTTP` | Permits explicitly registered HTTP callbacks outside the default local/private address ranges; it does not relax PKCE, state, single-use codes or exact callback matching |
| `NEXUS_SETUP_SECRET` | Optional; requires a private secret for first-owner creation |

HTTPS is the normal deployment. Credential prefixes are `sk-cybros-api-v1-` for access tokens and `sk-cybros-session-v1-` for API sessions; raw secrets never appear in logs or inspection output.

## The contracts

- [Application login](oauth/application-login.md) — the `cybros-application` client: authorization request, code exchange, device flow, renewal, logout, deployment origins and first boot.
- [Device flow](oauth/device-flow.md) — the `cybros-first-party-connector` client: the three registration branches, cancellation, token grants, revocation, the browser ceremony, errors and client requirements.
