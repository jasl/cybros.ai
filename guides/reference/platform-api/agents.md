# Agent settings

These Human personal settings inspect the current Human's stewarded Agents and
manage their independent Agents. They use the [Platform API authentication contract](../platform-api.md).
An owner or administrator cannot manage another Human's Agents through these
routes. Read routes include paired and named Agents. Named Agents use their
declarer's application address when the shared serving relationship remains
valid; their saved configuration and prompt documents remain their own. Creation,
credentials and lifecycle commands apply only to independent Agents.

## Routes

```http
GET /api/v1/agents
POST /api/v1/agents
GET /api/v1/agents/{agent_id}
GET /api/v1/agents/{agent_id}/configuration
POST /api/v1/agents/{agent_id}/connection_revocation
POST /api/v1/agents/{agent_id}/removal
POST /api/v1/agents/{agent_id}/restoration
```

## List Agents

### Endpoint

```http
GET /api/v1/agents
```

### Request

| Query field | Meaning |
| --- | --- |
| `limit` | Page size, default 25, maximum 100 |
| `after` | Opaque `pagination.next_after` from the previous page |
| `order` | `asc` by default, or `desc`; preserve it when continuing a page |

Rows are ordered by public UUID. The same pagination grammar applies to the
nested API-key and private-Runner lists.

### Response

```json
{
  "agents": [
    {
      "public_id": "01900000-0000-7000-8000-000000000001",
      "handle": "lark",
      "display_name": "Notes assistant",
      "status": "active",
      "agent_identifier": "01900000-0000-7000-8000-000000000002",
      "named_agent_scope": null,
      "description": null,
      "derived_from_public_id": null
    }
  ],
  "pagination": { "next_after": null }
}
```

`agent_identifier` is an opaque, non-secret registration identifier. Programs
retain it when using application OAuth after importing API keys. It is not a
credential and does not grant access. `status` is `active` or `removed`.
`named_agent_scope`, `description` and `derived_from_public_id` are nullable.
The last field identifies the declaring Agent for a named definition.

### Status codes

`200` returns the page. Invalid pagination returns `400 parameter_invalid`.

## Create an Agent

### Endpoint

```http
POST /api/v1/agents
```

### Request

```json
{ "agent": { "display_name": "Notes assistant" } }
```

The current Human becomes its steward. Nexus generates its public UUID,
handle and registration identifier. Creation needs no OAuth ceremony and
creates no executor address or credential.

### Response

`201` with `{ "agent": { "…": "…" } }`, using the fields above. Issue a
[member API key](agent-api-keys.md) to call the Agent API. An application
transport key creates the application address when needed.

### Status codes

`201` creates the Agent. Missing required input returns `400 parameter_missing`;
invalid attributes return `422 validation_failed`.

## Read an Agent

### Endpoint

```http
GET /api/v1/agents/{agent_id}
```

### Request

No body. The route names an Agent public UUID belonging to the current steward.

### Response

`200` with `{ "agent": { "…": "…" } }`, using the list's fields and nullable
`application_connection`. A connection contains `executor_public_id`,
`owner_agent_public_id`, `status`, `credential_readiness`, `presence`,
`last_seen_at` and `connected_at`. The last two timestamps are nullable.
A named Agent's connection belongs to its declarer. Removed or otherwise
ineligible principals have no usable shared connection in this projection.
Credential readiness and presence are separate facts; neither proves a request
has succeeded.

### Status codes

`200` returns the Agent. An unknown UUID or another steward's Agent returns
`404 not_found`.

## Read saved configuration

### Endpoint

```http
GET /api/v1/agents/{agent_id}/configuration
```

### Request

No body. The current Human must be this paired or named Agent's steward.
Removed Agents remain inspectable.

### Response

`200` returns `agent` with the basic identity fields, `configuration`,
`prompt_documents`,
`agent_updated_at` and `measured_at`.
Configuration uses the [profile declaration shape](../agent-api/profile-configuration.md).
Prompt documents contain only this Agent's own `system_prompt` and `summarizer`,
using the [prompt document shape](../agent-api/profile-prompt-documents.md).

This is the saved declaration. It does not assemble a Workspace-specific request,
read private memory notes or inherit the declaring Agent's prompts. An unavailable
model can remain in the declaration. `agent_updated_at` is the User record's
update time; it is not a configuration-specific version or timestamp.

The application owns declaration writes through the Agent API. This Platform
projection reads the configuration and owned documents in one database snapshot.

### Status codes

`200` returns the declaration. A scoped lookup miss returns `404 not_found`.

## Revoke a connection

### Endpoint

```http
POST /api/v1/agents/{agent_id}/connection_revocation
```

### Request

No body.

### Response

`200` with the Agent. This fences all its existing member credentials, revokes
its application address and OAuth refresh lineages, and retains the Agent.
It also works for a member-only Agent with no address. Independent private
Runner credentials remain separate. A later connection can issue new keys;
an application address created after revocation receives a new public UUID.

### Status codes

`200` returns the Agent. A scoped lookup miss returns `404 not_found`.

## Remove an Agent

### Endpoint

```http
POST /api/v1/agents/{agent_id}/removal
```

### Request

No body.

### Response

`200` with the Agent in `removed` status. Removal immediately fences member
credentials and the application executor epoch; related work stops through
asynchronous cleanup. The application address is retained. Independent
Runners retain their addresses and credentials. The
[Agent lifecycle contract](../agent-api/profile.md) describes the authority
and cleanup rules.

### Status codes

`200` returns the Agent. A scoped lookup miss returns `404 not_found`; a refused
lifecycle transition returns `422` with its domain error code.

## Restore an Agent

### Endpoint

```http
POST /api/v1/agents/{agent_id}/restoration
```

### Request

No body.

### Response

`200` with the restored Agent. Its public identity is preserved. Restoration
does not revive old credentials or resume stopped work. Issue fresh keys or
complete a new OAuth connection.

### Status codes

`200` returns the Agent. A scoped lookup miss returns `404 not_found`; a refused
lifecycle transition returns `422` with its domain error code.
