# Agent API keys

These Human personal settings issue long-lived keys for a steward's Agent,
its application address, or a private Runner managed by that Human. Authentication
follows the [Platform API contract](../platform-api.md). Each key has one fixed
plane, no expiry and no refresh token. Agent runtime keys cannot call these
management routes.

## Routes

```http
GET /api/v1/agents/{agent_id}/api_keys
POST /api/v1/agents/{agent_id}/api_keys
POST /api/v1/agents/{agent_id}/api_keys/{key_id}/revocation
GET /api/v1/agents/{agent_id}/executor/api_keys
POST /api/v1/agents/{agent_id}/executor/api_keys
POST /api/v1/agents/{agent_id}/executor/api_keys/{key_id}/revocation
GET /api/v1/agents/{agent_id}/private_runners/{runner_id}/api_keys
POST /api/v1/agents/{agent_id}/private_runners/{runner_id}/api_keys
POST /api/v1/agents/{agent_id}/private_runners/{runner_id}/api_keys/{key_id}/revocation
```

## List keys

### Endpoint

```http
GET /api/v1/agents/{agent_id}/api_keys
GET /api/v1/agents/{agent_id}/executor/api_keys
GET /api/v1/agents/{agent_id}/private_runners/{runner_id}/api_keys
```

### Request

Use the [Agent list pagination](agents.md#list-agents) fields. The route
determines the credential owner and plane:

| Resource | Plane | Binding |
| --- | --- | --- |
| Agent `api_keys` | `member` | The Agent's data authority |
| Agent `executor/api_keys` | `executor_transport` | Its application address and current epoch |
| Private Runner `api_keys` | `executor_transport` | The Runner's address and current epoch |

### Response

```json
{
  "api_keys": [
    {
      "public_id": "01900000-0000-7000-8000-000000000003",
      "name": "Production application",
      "note": null,
      "plane": "member",
      "created_at": "2026-10-14T00:00:00Z",
      "last_used_at": null,
      "revoked_at": null,
      "usable": true
    }
  ],
  "pagination": { "next_after": null }
}
```

Lists contain API keys, not OAuth credentials, and never contain secrets or
digests. `usable` reflects the key's current authority fences. A key can be
unusable because of removal, connection replacement or an epoch change even
when its own `revoked_at` is null. `last_used_at` is a sampled observation,
updated at most once per hour; it is not a lease or expiry.

### Status codes

`200` returns the page. Invalid pagination returns `400 parameter_invalid`.
A scoped owner lookup miss returns `404 not_found`.

## Issue a key

### Endpoint

```http
POST /api/v1/agents/{agent_id}/api_keys
POST /api/v1/agents/{agent_id}/executor/api_keys
POST /api/v1/agents/{agent_id}/private_runners/{runner_id}/api_keys
```

### Request

```json
{ "api_key": { "name": "Production application", "note": "Primary service" } }
```

`name` is required and has a maximum of 160 characters. `note` is optional,
with a maximum of 2,000 characters. The route fixes the plane and binding;
neither is caller-selectable. Named Agents cannot receive independent keys.

Issuing the first application key creates the Agent's application address.
Subsequent keys share that address's current epoch. Creating a key does not
rotate an existing key, advance the epoch or revoke another credential.
Create a [private Runner](private-runners.md) before issuing its key.

### Response

```json
{
  "api_key": {
    "public_id": "01900000-0000-7000-8000-000000000003",
    "name": "Production application",
    "note": "Primary service",
    "plane": "member",
    "created_at": "2026-10-14T00:00:00Z",
    "last_used_at": null,
    "revoked_at": null,
    "usable": true
  },
  "secret": "sk-cybros-api-v1-…"
}
```

The `201` response has `Cache-Control: no-store`. Save the secret privately
before leaving this response; Nexus stores only its salted digest and cannot
reveal it again. Present it directly as `Authorization: Bearer <secret>`.

### Status codes

`201` issues the key. Missing input returns `400 parameter_missing`; invalid
attributes return `422 validation_failed`; a closed issuance authority returns
`422 not_issuable`. A scoped lookup miss returns `404 not_found`. Issuance is
limited to ten requests per Human per three minutes; `429 rate_limited` carries
`Retry-After`.

## Revoke a key

### Endpoint

```http
POST /api/v1/agents/{agent_id}/api_keys/{key_id}/revocation
POST /api/v1/agents/{agent_id}/executor/api_keys/{key_id}/revocation
POST /api/v1/agents/{agent_id}/private_runners/{runner_id}/api_keys/{key_id}/revocation
```

### Request

No body. `key_id` is the key metadata's public UUID.

### Response

`204` with an empty body. Subsequent requests presenting this key return `401`.
Other keys and the executor address remain unchanged. Repeating the command
for the same retained key succeeds.

A program may revoke a key it possesses through the existing
[`POST /oauth/revoke`](../oauth/device-flow.md#post-oauthrevoke) endpoint.
Standalone keys have no refresh family, so that endpoint also revokes only the
presented key.

### Status codes

`204` completes revocation. A scoped owner or key lookup miss returns
`404 not_found`.

## Authority lifecycle

Agent removal and connection revocation fence member keys through the existing
User authority generation. Application transport keys also follow the
executor epoch. Restoring an Agent does not revive an old key. An OAuth
replacement connection fences previous member keys and application transport
credentials. Independent Runner keys retain the Runner's lifecycle.

HTTP authentication checks these fences on every request. A request already
accepted can finish under its existing contract. Transport subscriptions
also recheck their authority periodically; key revocation is not a command
to undo a completed effect or cancel every accepted task.
