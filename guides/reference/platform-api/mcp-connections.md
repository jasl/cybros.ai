---
title: MCP connections
description: Manage Human-owned HTTP MCP service accounts, credentials and saved catalogs.
---

# MCP connections

A connection belongs to one Human and names one fixed HTTP MCP endpoint and
external account. Only its owner can manage it; administrator status grants no
access to another Human's connections. Use the [Platform authentication contract](../platform-api.md).
The Nexus console exposes the same operations under Settings → MCP connections.

## Routes

```http
GET /api/v1/mcp_connections
POST /api/v1/mcp_connections
GET /api/v1/mcp_connections/{public_id}
PATCH /api/v1/mcp_connections/{public_id}
PUT /api/v1/mcp_connections/{public_id}/credential
DELETE /api/v1/mcp_connections/{public_id}/credential
POST /api/v1/mcp_connections/{public_id}/catalog_refresh
POST /api/v1/mcp_connections/{public_id}/authorization
```

## List

### Endpoint

`GET /api/v1/mcp_connections`

### Request

`limit` defaults to 25, accepts 1–100, and `after` continues an opaque cursor.
`order` is `asc` by default or `desc`, ordered by connection UUID. A cursor
retains its order. Only the authenticated Human's connections are returned.

### Response

`200 {mcp_connections: [...], pagination: {next_after: null}}`.
Every row uses the representation under Read. Empty lists remain successful.
GET reads only saved state and never discovers remote tools.

### Status codes

`200` on success; `400 parameter_invalid` for invalid pagination;
`401 unauthorized` without accepted Platform authority.

## Read

### Endpoint

`GET /api/v1/mcp_connections/{public_id}`

### Request

The connection must belong to the authenticated Human.

### Response

```json
{
  "mcp_connection": {
    "public_id": "01900000-0000-7000-8000-000000000091",
    "name": "Work documents",
    "account_label": "Company account",
    "endpoint_url": "https://tools.example/mcp",
    "auth_type": "bearer",
    "enabled": true,
    "available": true,
    "credential_configured": true,
    "authorization_status": "not_applicable",
    "authorization_expires_at": null,
    "tools": [],
    "catalog_refreshed_at": null,
    "lock_version": 0
  }
}
```

`tools` is the complete saved directory: entries have `name`, `description`,
`input_schema`, and may have `output_schema` and `annotations`. The owner's
Agents use these connections through their current steward relationship; there
is no per-Agent grant or connection-level tool allowlist. Tokens are write-only. `credential_configured` is also true for `auth_type: "none"`.
`account_label` is an optional non-secret explanation shown with approvals.

`authorization_status` describes saved OAuth state. Reads never contact the
service or refresh credentials. `authorization_expires_at` is the saved access
token's expiration when supplied by the service, otherwise null.

| Status | Meaning |
| --- | --- |
| `not_applicable` | The connection uses no authentication or a static Bearer. |
| `not_authorized` | Authorize the OAuth service before using it. |
| `pending` | Browser authorization is in progress. |
| `authorized` | Access is available or can be renewed with the saved refresh token. |
| `refreshing` | Nexus is renewing access. |
| `reauthorization_required` | Start a new browser authorization. |

### Status codes

`200` on success; `401 unauthorized` without Platform authority;
`404 not_found` for an unknown connection or another owner's connection.

## Create

### Endpoint

`POST /api/v1/mcp_connections`

### Request

```json
{
  "mcp_connection": {
    "name": "Work documents",
    "account_label": "Company account",
    "endpoint_url": "https://tools.example/mcp",
    "auth_type": "bearer",
    "bearer_token": "<service token>",
    "enabled": true
  }
}
```

`name` is required and at most 100 characters. `account_label` is optional and
at most 256 characters. `auth_type` is `none`, `bearer` or `oauth`; only Bearer connections
accept `bearer_token`, at most 4096 characters and with no CR, LF or NUL. The URL
must be a supported public HTTP(S) destination of at most 8192 bytes. Private environment services
remain reachable through a Runner or tool provider.

A new connection has an empty catalog. Creating it performs no remote IO;
discover its tools before selecting them for execution. The endpoint and authentication kind are
immutable. Changing the external account requires a new connection; same-account
Bearer rotation uses the credential operation.
For OAuth, omit `bearer_token`, authorize the service in the browser, then
discover its tools. Creating the connection does not start authorization.

### Response

`201` with the saved `mcp_connection` representation. Save its UUID.

### Status codes

`201` on success; `400 parameter_missing` for a missing root;
`401 unauthorized`; `422 validation_failed` for invalid configuration.

## Update

### Endpoint

`PATCH /api/v1/mcp_connections/{public_id}`

### Request

```json
{
  "mcp_connection": {
    "lock_version": 0,
    "name": "Work documents",
    "account_label": "Company account",
    "enabled": true
  }
}
```

Send the current `lock_version` and the fields to change. Disabling a connection
blocks future starts for every Agent that uses it. Per-Agent connection and tool
choices belong to the application's Presets. A name or label change leaves
every accepted route bound to the same UUID.

### Response

`200` with the saved connection and its resulting `lock_version`.

### Status codes

`200` on success; `400 parameter_missing` or `parameter_invalid` for a missing
or invalid version; `401 unauthorized`; `404 not_found`; `409 stale_object` for
a concurrent edit; `422 validation_failed` for invalid fields.

## Rotate a credential

### Endpoint

`PUT /api/v1/mcp_connections/{public_id}/credential`

### Request

`{"credential":{"lock_version":1,"bearer_token":"<new service token>"}}`

This operation rotates a Bearer for the same external account. Nexus trusts the
owner's account choice; a Bearer alone cannot prove account identity. It is not
an account-switch operation and does not grant tools or Agents.

### Response

`200` with the non-secret connection representation. The token is encrypted and
never returned. Calls not yet started read the current credential.

### Status codes

`200`; `400 parameter_missing` or `parameter_invalid`; `401 unauthorized`;
`404 not_found`; `409 stale_object`; `422 validation_failed` for an invalid token
or `credential_not_applicable` for a connection without Bearer authentication.

## Clear a credential

### Endpoint

`DELETE /api/v1/mcp_connections/{public_id}/credential`

### Request

`{"command":{"lock_version":2}}`

Clearing removes the locally saved Bearer or OAuth credentials and cancels pending
OAuth work. A late authorization or refresh response cannot restore cleared
credentials. This does not revoke access at the external service. Use that
service's account controls for remote revocation.

### Response

`200` with the connection representation. Re-enabling does not recover a cleared
token. An unauthenticated connection has no token to clear; disable it to stop use.

### Status codes

`200`; `400 parameter_missing` or `parameter_invalid`; `401 unauthorized`;
`404 not_found`; `409 stale_object`; `422 credential_not_applicable` for a connection
without authentication.

## Authorize a service

### Endpoint

`POST /api/v1/mcp_connections/{public_id}/authorization`

### Request

`{"command":{"lock_version":3}}`

The connection must use `oauth`, be enabled and belong to the authenticated
Human. Nexus discovers the service's authorization metadata and prepares a
browser authorization with PKCE. A new explicit start replaces prior pending
work. The service must support an issuer-bound saved registration or dynamic
registration for a public authorization-code client. Unsupported registration
fails without installing credentials.

### Response

```json
{
  "authorization": {
    "connection_public_id": "01900000-0000-7000-8000-000000000091",
    "authorization_url": "https://service.example/authorize?state=opaque",
    "expires_at": "2026-10-15T12:00:00Z"
  }
}
```

`200` returns an opaque browser-navigation URL and the pending authorization's
expiration. Open the URL and finish the service's consent page. The callback
returns to Nexus Settings and requires a browser session for the connection's
owner. Signing in again as the same owner is supported; a Platform bearer alone
cannot finish the callback. Read the connection afterward to observe its saved
status. The response is not cached and contains no remote access or refresh token.

Nexus owns token exchange and renewal. SDKs expose this command and typed status
fields; they do not exchange or store the remote credentials. An expired token
without renewal authority, a rejected grant or an uncertain exchange requires a
new browser authorization. Nexus never retries a tool call to repair authentication.

### Status codes

`200`; `400 parameter_missing` or `parameter_invalid`; `401 unauthorized`;
`403 not_authorized` for a disabled connection or inactive owner; `404 not_found`;
`409 stale_object`; `422 credential_not_applicable`, `authorization_pending`,
`reauthorization_required`, `authorization_failed` or `authorization_timeout`;
`429 rate_limited` after ten starts per Human per minute.

## Refresh a catalog

### Endpoint

`POST /api/v1/mcp_connections/{public_id}/catalog_refresh`

### Request

`{"command":{"lock_version":4}}`

This is explicit remote IO, bounded to 20 seconds. Complete bounded `tools/list`
pagination is validated and published together; a failed page publishes nothing.
Discovery accepts at most 16 pages, cursor values of at most 4096 bytes, and
a complete normalized catalog within the existing 1 MiB tool-definition bound.
New tools become available to the owner's Agents for future selections. rho
Presets default to using them unless their connection or exact tool is disabled.
Captured executions keep their existing tool set. A concurrent edit wins over
the stale discovery result.
For OAuth, Nexus resolves or renews credentials before discovery. Internal token
renewal does not change the management version or invalidate this command's own
catalog publication.

### Response

`200` with the saved directory, refresh timestamp and resulting version.

### Status codes

`200`; `400 parameter_missing` or `parameter_invalid`; `401 unauthorized`;
`403 not_authorized` when an OAuth connection is disabled; `404 not_found`;
`409 stale_object`; `422 missing_credential`, `discovery_failed`, `authorization_pending`,
`reauthorization_required`, `authorization_failed`, `authorization_timeout` or
`validation_failed`; `429 rate_limited` after ten refreshes per Human per minute.

## Lifecycle and support

Connections have no delete, transfer or archive operation. Disable a connection
to stop future use; optionally clear credentials. Owner suspension
blocks new starts; reactivation permits enabled connections again. Owner removal
disables connections, and restore does not re-enable them. Reassigning an Agent's
steward changes its available connections and blocks new starts against the previous owner's connections. Already-started work retains its original
ToolTask settlement and may have external effects after a disable or revoke.
Disabling also cancels pending OAuth work. If a refresh may already have spent
its token, enabling again requires a new authorization. Otherwise disabling
retains the saved credential and catalog.

See [Agent MCP connections](../agent-api/mcp-connections.md) for tool selection,
approval, supported protocol versions, uncertain outcomes and content handling.
The Ruby SDK uses `platform.mcp_connections` with `list`, `fetch`, `create`,
`update`, `start_authorization`, `refresh_catalog`, `rotate_credential` and
`clear_credential`. Writes require the version last read; the SDK does not retry
stale writes automatically.
