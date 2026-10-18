# Agent API v1: work report

The member-plane work report summarizes the caller's currently readable work.
It uses the [common authentication and error contract](../agent-api.md).
Administrator status grants no additional content access.

## Routes

```http
GET /agent_api/v1/work_report
```

## Read a work report

### Endpoint

```http
GET /agent_api/v1/work_report
```

### Request

| Query | Meaning |
| --- | --- |
| `workspace_public_id` | Optional accessible Workspace UUID; omission spans accessible Workspaces |
| `agent_public_id` | Optional Agent UUID; filters associated Runs and attributed usage |
| `from`, `to` | ISO8601 instants defining the half-open window `[from, to)` |
| `unit` | `hour` or `day`; default `day` |

Supply both window bounds or neither. Omission selects the last seven complete
UTC days. Both bounds must align to the selected UTC unit. A report contains at
most 1,000 buckets; an invalid or overwide request is refused without truncation.

### Response

`200` returns `{report: {...}}` with these fields:

| Field | Meaning |
| --- | --- |
| `from`, `to`, `unit` | Applied window and grouping |
| `as_of` | Time the report read began |
| `workspace_public_id` | Applied Workspace UUID or `null` |
| `agent_public_id` | Applied Agent UUID or `null` |
| `current.run_counts` | Count for each Run status |
| `current.attention_count` | Readable Runs with a standing attention reason |
| `totals` | Measurements for the selected period |
| `series` | One measurement object per bucket, with `bucket_start_at` |
| `previous` | `from`, `to` and `totals` for the preceding equal-length window |

`current` ignores the historical window. The status keys are `pending`,
`running`, `paused`, `needs_attention`, `canceling`, `completed` and `canceled`.

Every `totals` and series measurement contains `created_runs`,
`active_answering_agents` and `conversation_usage`. `created_runs` counts Runs by
creation time. `active_answering_agents` counts distinct Agent answerers captured
on Conversation Turns whose Runs were created in that period. The whole-period
distinct count need not equal the sum of bucket distinct counts. Standalone Run
creators and live executor connections do not contribute to this measure.

`conversation_usage` contains `request_count`, `input_tokens`,
`cache_read_tokens`, `cache_creation_tokens`, `output_tokens`, `reasoning_tokens`,
`total_tokens`, `cost_amount` and `cost_complete`. It counts recorded model
attempts attributed to currently readable Conversations, including retries,
using receipt time. Standalone usage without Conversation attribution is
excluded. Quiet buckets contain zeros. Missing token fields add no recorded
tokens; these totals do not establish complete token coverage. `cost_amount` is
a decimal string for the known amount in the account's cost unit;
`cost_complete: false` means it is an incomplete subtotal.

An Agent filter keeps Conversation Runs whose Turn captured that answering Agent,
and standalone Runs created by it. Usage additionally requires that Agent's UUID
as the receipt consumer. Human-submitted work remains attributed to the Human,
even when the selected Agent answers. The filter does not grant access to work
outside the caller's readable Conversations and Runs.

Visibility is checked at read time for both current and historical data.
Access, deletion and retention changes can change the visible history. Usage
receipts survive execution-detail collection. These measurements do not change
budgets or settlement. The account-wide report is separately documented under
[Admin model usage](../platform-api/admin-model-usage.md).

### Status codes

| Status | Meaning |
| --- | --- |
| `200` | Report returned |
| `400 parameter_invalid` | Missing or malformed window parameter |
| `400 window_invalid` | Window is unordered or not aligned |
| `400 window_too_wide` | More than 1,000 buckets |
| `400 unit_unsupported` | Unsupported grouping |
| `404` | Selected Workspace is inaccessible or deleted, or the Agent UUID does not identify an Agent |

See [Inspect and recover work](../../operate/work-console.md) for the browser
Dashboard and its drilldowns.

For model grouping, Top N, exact latency percentiles and retained tool analysis,
use the independent [work analysis](work-analysis.md) query.
