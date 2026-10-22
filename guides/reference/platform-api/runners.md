# Managed Runners

The Platform API exposes Runner and Tool provider machines managed by the current
Human. Use the [common Platform authentication contract](../platform-api.md).
Management scope includes revoked machines and machines without usable credentials.
It grants no execution authority and does not expose another Human's machines.

## Routes

```http
GET /api/v1/runners
GET /api/v1/runners/{id}
```

## List managed machines

### Endpoint

```http
GET /api/v1/runners
```

### Request

| Query | Meaning |
| --- | --- |
| `kind` | Optional `runner` or `tool_provider` |
| `status` | Optional `active` or `revoked`; omission includes both |
| `limit` | Page size, default 25, maximum 100 |
| `after` | Opaque cursor from the previous page |
| `order` | `asc` by default, or `desc` |

### Response

`200` returns `runners`, `pagination: {next_after}` and `measured_at`.
Rows are ordered by public UUID and contain:

| Field | Meaning |
| --- | --- |
| `public_id`, `kind`, `display_name`, `status` | Machine identity and lifecycle |
| `manager_public_id` | Managing Human UUID |
| `assignment_scope` | Current assignment scope |
| `service_roles` | Currently announced service roles |
| `credential_readiness` | Current credential readiness |
| `eligible_for_current_user` | Execution eligibility as the requesting Human |
| `presence` | Current observed presence |
| `last_seen_at`, `connected_at` | Nullable contact timestamps |
| `registered_at` | Machine record creation time |

Assignment and credential eligibility follow the [Executor contract](../agent-api/executor.md).
Application addresses with Runner capability are not independent managed machines and do not
appear here. Conversation work checks eligibility as its answering Agent separately.
Presence is observational and does not decide admission or establish successful
execution.

### Status codes

`200` returns the page. Invalid filters or pagination return `400 parameter_invalid`.

## Read a managed machine

### Endpoint

```http
GET /api/v1/runners/{id}
```

### Request

No body. `id` is a managed machine's public UUID.

### Response

`200` returns `runner` and `measured_at`. The Runner includes the list fields plus
the role-keyed `services` map containing tools, documents and environment, using the saved
[announcement shapes](../agent-api/executor.md). These reads perform no network
probe. Contact time is not an announcement-specific update timestamp.

### Status codes

`200` returns the machine. An unknown UUID or a machine managed by another Human
returns `404 not_found`.
