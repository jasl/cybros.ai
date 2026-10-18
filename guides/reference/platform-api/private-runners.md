# Private Runners

These Human personal settings create and inspect Runners assigned to one
stewarded Agent. They use the [Platform API authentication contract](../platform-api.md).
The current Human is the Runner's manager; its assignment is fixed to
`agent_private` and the route's Agent. This grants no authority over another
Human's Runner.

For all managed Runner and Tool provider announcements and execution eligibility,
use [managed Runners](runners.md).

## Routes

```http
GET /api/v1/agents/{agent_id}/private_runners
POST /api/v1/agents/{agent_id}/private_runners
GET /api/v1/agents/{agent_id}/private_runners/{runner_id}
```

## List private Runners

### Endpoint

```http
GET /api/v1/agents/{agent_id}/private_runners
```

### Request

Use the [Agent list pagination](agents.md#list-agents) fields.

### Response

```json
{
  "private_runners": [
    {
      "public_id": "01900000-0000-7000-8000-000000000004",
      "display_name": "Workstation",
      "status": "active",
      "registration_identifier": "01900000-0000-7000-8000-000000000005",
      "assignment_scope": "agent_private",
      "assignment_agent_public_id": "01900000-0000-7000-8000-000000000001"
    }
  ],
  "pagination": { "next_after": null }
}
```

`registration_identifier` is opaque and non-secret. An importing application
retains it for later Human login. The Runner remains a separate delivery
address, not an Agent principal. See [Executor](../agent-api/executor.md) for
assignment eligibility and credential epochs.

### Status codes

`200` returns the page. Invalid pagination returns `400 parameter_invalid`;
a scoped Agent lookup miss returns `404 not_found`.

## Create a private Runner

### Endpoint

```http
POST /api/v1/agents/{agent_id}/private_runners
```

### Request

```json
{ "private_runner": { "display_name": "Workstation" } }
```

Nexus generates the registration identifier and fixes the manager and
assignment. The request cannot choose another scope, manager or Agent.

### Response

`201` with `{ "private_runner": { "…": "…" } }`, using the fields above.
Creation does not issue a secret; issue a separate
[Runner API key](agent-api-keys.md) before starting its executor loop.

### Status codes

`201` creates the Runner. Missing input returns `400 parameter_missing`;
invalid attributes return `422 validation_failed`; a scoped Agent lookup
miss returns `404 not_found`.

## Read a private Runner

### Endpoint

```http
GET /api/v1/agents/{agent_id}/private_runners/{runner_id}
```

### Request

No body. Both route identifiers are public UUIDs.

### Response

`200` with `{ "private_runner": { "…": "…" } }`, using the list's fields.

### Status codes

`200` returns the Runner. A lookup outside this Agent and manager's private
Runners returns `404 not_found`.
