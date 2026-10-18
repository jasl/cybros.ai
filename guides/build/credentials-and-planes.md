# Credentials and planes

One bearer resolves to exactly one authorization plane, fixed when the credential was minted. There is no scope vocabulary: the plane is the whole of a credential's authority.

| Plane | Prefix | What it is | What it reaches |
| --- | --- | --- | --- |
| `member` | `sk-cybros-api-v1-` | The acting user's data authority | `/agent_api/v1` member resources: profile, workspaces, conversations, runs, models, uploads, store, schedules |
| `executor_transport` | `sk-cybros-api-v1-` | Proof of one delivery address at one credential epoch | `/agent_api/v1/executor…`: announcement, inbox, claims, commits, captures, progress |
| `platform` | `sk-cybros-api-v1-` or a session `sk-cybros-session-v1-` | A human's personal settings; administration with the owner/admin role | `/api/v1`, `/api/v1/admin` |

A credential presented to another plane's endpoint is refused with `401`, never accepted with a degraded principal. The response never says why: a wrong-plane, revoked, fenced and expired credential are deliberately indistinguishable. The remedy is the same — present a live credential of the right plane, or reconnect. Failures carry `WWW-Authenticate: Bearer realm="Nexus"` and the `unauthorized` JSON envelope. Cookies are never accepted on the Agent API.

## API keys

A Human steward can create an Agent and issue long-lived API keys in **Agents**
or through the [Agent settings API](../reference/platform-api/agents.md). An Agent
member key is enough for model calls, conversations and other member resources.
An application that receives inbox work needs a separate application transport
key. A private Runner uses its own transport key. Named Agents reuse
their declaring application's transport and do not receive independent keys.

Pass the key on every request as `Authorization: Bearer <key>`. A key has no
expiry or refresh token. Revoking it makes subsequent requests fail with `401`;
other keys keep their authority. To replace a key, issue a new one, configure the
client, then revoke the old one. The raw value is returned only when issued.

See [API keys](../reference/platform-api/agent-api-keys.md) for issuance,
listing, revocation and the existing User/epoch fences that also apply to keys.

## What OAuth issues

- An **agent connection** yields both member and transport credentials in one refresh lineage: the application acts as the Agent and holds the Agent's one delivery address. Rotating that lineage replaces both tokens together. That address is capability, not a promise of work; a conversational agent may validly receive zero tasks.
- A **runner or tool-provider connection** yields the transport plane alone. A runner is a delivery address, not a principal, and never calls a member endpoint.
- A **human login** through application OAuth yields a platform credential and, at first connection, the agent and runner bundles above as separate lineages.

The planes have independent lifecycles. A member credential dies with the user's authority: for an agent, member authority requires the agent to be active and its steward live. Removing an agent revokes its member access and application transport credentials synchronously; its address stays active with old credentials returning `401`. Transport also dies by explicit revocation, expiry or an epoch advance when a replacement connection wins. A program holding both may find one plane dead and the other alive.

## Connecting with OAuth

**Device flow** (`/oauth/device/*`): the program requests an authorization with its stable registration identifier, shows the user code and verification URL, and polls until the person approves in the Nexus browser (**Agents → Connect agent** or **Runners → Connect runner**). Polling honors the server interval, `slow_down`, `Retry-After` and the 900-second authorization deadline. An agent that also serves as a runner on its own machine pairs both in one grant; the two lineages rotate independently.

**Application login** (Authorization Code with PKCE S256, or device flow for the `cybros-application` client): a browser-based application such as rho obtains a human platform credential plus optional agent and runner bundles. The application owns state and PKCE validation and persists each lineage privately. Redirect URIs must match the deployment's registration exactly.

Reconnecting the same identifier re-pairs the same logical address and advances its credential epoch; copying a credential document to another installation is unsupported and indistinguishable from the original.

## OAuth refresh and revocation

Each lineage rotates on its own refresh token; a rotation never carries the other half. If a transport failure leaves a rotation outcome uncertain, treat the connection as lost and start a new device authorization rather than replaying the old refresh token. Revocation presents a lineage's refresh token to `/oauth/revoke`. The same endpoint accepts a standalone API key and revokes only that key.

## Registration identifiers

An OAuth application chooses a non-secret identifier and keeps it stable for the installation it represents (rho combines its product constant with a per-home instance ID). Nexus treats it as opaque and resolves it under the connecting human steward. The Agent settings API generates that identifier for an Agent created there. The Agent reads it from its profile; an importing application keeps it for later Human login. A runner uses a separate `registration_identifier`; one manager cannot hold a runner and a tool provider under one identifier.

Full endpoint details are in the [OAuth reference](../reference/oauth.md).
