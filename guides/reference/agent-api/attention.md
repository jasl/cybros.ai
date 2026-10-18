# Agent API v1: attention

The member-plane attention collection lists Tasks waiting for a decision or
recovery across work the caller can access. It uses the
[common authentication, error and pagination contract](../agent-api.md).

## Routes

```http
GET /agent_api/v1/attention
```

## List attention

### Endpoint

```http
GET /agent_api/v1/attention
```

### Request

| Query | Meaning |
| --- | --- |
| `workspace_public_id` | Optional accessible Workspace UUID; omission spans accessible Workspaces |
| `view` | `actionable` (default) or `following` |
| `after`, `limit`, `order` | Common keyset pagination |

`actionable` selects writable Runs. `following` selects readable Runs, including
those the caller cannot change. Neither view expands the caller's content
access. Archived Workspaces can appear only in `following`.

The queue includes live approval requests, member-answerable questions without
a resolution token, and unresolved failures that require adjudication. Expired
parks, pruned execution detail and overridden work are excluded. Absorbed
failures are excluded except a Conversation cost-limit hold that needs repair.

### Response

`200` returns `items` and `pagination: {next_after}`. Each item contains:

| Field | Meaning |
| --- | --- |
| `workspace_public_id` | Workspace UUID |
| `run_public_id` | Run UUID |
| `conversation_public_id` | Host Conversation UUID; `null` for a standalone Run |
| `task` | The public Task projection from the [Runs reference](runs.md) |

The keyset orders by Run UUID and Task key. This is a read snapshot; commands
recheck access, state and deadlines when submitted. The queue counts Tasks and
does not equal the number of Runs with an attention reason.

### Status codes

| Status | Meaning |
| --- | --- |
| `200` | Page returned |
| `400` | Invalid view or pagination parameter |
| `404` | Selected Workspace is inaccessible or deleted |

See the [work console guide](../../operate/work-console.md) for the browser
workflow and [Run approval](run-approval.md) for approval behavior.
