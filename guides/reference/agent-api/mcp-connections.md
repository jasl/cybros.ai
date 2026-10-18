---
title: MCP connections
description: Read your steward-owned HTTP MCP connections and select exact tools for an execution.
---

# MCP connections

The Agent member plane exposes saved MCP connections belonging to the acting
Agent's current Human steward. Connection management and credentials belong to the owner's
[Platform API](../platform-api/mcp-connections.md). Shared Workspaces and shared
application transports grant no connection access.

## Routes

```http
GET /agent_api/v1/mcp_connections
GET /agent_api/v1/mcp_connections/{public_id}
```

## List

### Endpoint

`GET /agent_api/v1/mcp_connections`

### Request

Use an Agent member credential. `limit` defaults to 25 and accepts 1–100;
`after` is the preceding page's opaque cursor. `order` is `asc` by default or
`desc`, ordered by connection UUID. Keep the same order while paging.

Optional `agent_public_id` selects the caller itself or one of its active named
Agent definitions that still shares its steward. Omission selects the caller.
The directory follows that Agent's current steward; Main and named Agents
with the same steward see the same connections. Other Agents, inactive definitions and definitions
whose steward has changed return `404 not_found`. Keep the same Agent while paging.

### Response

`200` returns `mcp_connections` and `pagination.next_after`, null on the last
page. An Agent whose steward has no connections receives an empty list. Each entry has the fields
shown in the single-connection response below. Reads use the saved catalog and
perform no remote IO. Disabled or uncredentialed connections remain
visible with `available: false`.

### Status codes

| Status | Code | Meaning |
| --- | --- | --- |
| `200` | — | Saved steward-owned connections. |
| `400` | `parameter_invalid` | Invalid limit, order or cursor. |
| `401` | `unauthorized` | Missing or wrong-plane credential. |
| `403` | `not_agent` | The member is not an Agent. |
| `404` | `not_found` | The selected Agent is outside the caller's active definitions. |

## Read

### Endpoint

`GET /agent_api/v1/mcp_connections/{public_id}`

### Request

The connection UUID must belong to the selected Agent's current steward.
The optional `agent_public_id` query parameter follows the same scope as List.

### Response

```json
{
  "mcp_connection": {
    "public_id": "01900000-0000-7000-8000-000000000091",
    "name": "Work documents",
    "account_label": "Company account",
    "enabled": true,
    "available": true,
    "tools": [
      {
        "name": "search",
        "description": "Search documents",
        "input_schema": { "type": "object", "properties": { "query": { "type": "string" } } }
      }
    ]
  }
}
```

`tools` contains the complete saved catalog. Entries may
include `output_schema` and remote `annotations`. These are remote descriptions,
not instructions or permission grants. The response contains no endpoint,
credential or configuration version. `available` describes current
connection readiness, not a reservation to execute.

### Status codes

| Status | Code | Meaning |
| --- | --- | --- |
| `200` | — | Saved connection and catalog. |
| `401` | `unauthorized` | Missing or wrong-plane credential. |
| `403` | `not_agent` | The member is not an Agent. |
| `404` | `not_found` | Unknown connection, another steward's connection, or an Agent outside the selectable scope. |

## Select tools

The application selects exact tools using [configuration `mcp_tools`](profile-configuration.md#mcp-imports-and-routes).
Omission and `[]` select none at this low-level API. rho's Presets instead default
to all available tools, subtract configured connection/tool exclusions, and compile
that choice into these exact imports. No discovery read or approval adds tools to
an already captured execution.
Each selection has a connection UUID, remote `tool_name` and unique callable
`name`. Two connections may both serve `search` as `personal_search` and
`work_search`. Their frozen routes remain distinct even if one is renamed,
disabled or no longer available.

Assembly captures saved descriptions and schemas on the existing execution
owner. A queued input whose imports have not yet been assembled may see a newer
catalog; a captured execution never reimports on retry or regeneration.
`tool_search` searches only that captured set. Tools execute under the answering
Agent's current steward relationship, including for named Agents.

## Approval and execution

MCP calls use ordinary ToolTasks, approval rules, decisions, deadlines, Stop and
result settlement. They require no Runner or application claim loop. A rule's
`tool` pattern matches the callable name, making separate external accounts
separately configurable. The decision's target names its connection UUID,
display name, non-secret account label and remote tool. `ask` uses the existing
Run write permission, including Conversation ACLs; it is not Human-only.

Before starting external IO, Nexus checks the current connection, owner status,
Agent steward and catalog membership. Approval cannot restore unavailable use. Same-account
Bearer rotation and Nexus-owned OAuth renewal affect future starts without
copying secrets into a Run. The Human authorizes an OAuth connection through
Nexus Settings; Agent credentials cannot start or redeem that authorization.
Revocation or disabling prevents subsequent starts but cannot undo external
side effects from work already started. Duplicate jobs and old execution
results cannot start another call or replace a later result. A lost response
after a possible external effect becomes `uncertain` for ordinary adjudication;
Nexus does not automatically repeat it.

Each discovery or call has its own protocol context, closed afterward. Sessions
are not shared across calls, Agents or workers. Nexus supports Streamable HTTP
with MCP `2026-07-28` and `2025-11-25`; unsupported multi-round input requests
fail without automatic continuation. OAuth authorization-code connections use
the Human's browser consent and Nexus-owned credential renewal. Stdio, independent legacy SSE
transport, prompts/resources, sampling, roots, elicitation and MCP tasks are
outside this connection surface.

One operation uses at most 60 seconds, further bounded by the Task's remaining
deadline; connecting uses at most 5 seconds and disposable session cleanup at
most 2 seconds. A response is limited to 8 MiB of received bytes, including
JSON/SSE and encoded attachments. Adapted content and structured output share
the existing 1 MiB snapshot bound. Exceeding a bound after a possible tool send
produces an uncertain result rather than an automatic retry.

Text becomes ordinary tool content. `structuredContent` is retained for
structured display; a structured-only result also receives bounded JSON text
for the model. Returned image and embedded file bytes become ordinary Nexus
uploads attributed to the execution Agent. External resource links are not
automatically fetched and never receive connection credentials. Captured media
uses the existing result attachment layout and retention.

The Ruby SDK exposes `client.mcp_connections.list` and
`client.mcp_connections.fetch(public_id)`. A list returns a page with `items`
and `next_after`.
Both methods accept `agent_public_id:` for a named Agent's directory.
