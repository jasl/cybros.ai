# Agent API v1: work analysis

The analysis query adds grouping, Top N and elapsed-time percentiles to the
caller's currently readable work. It uses the [common authentication and error
contract](../agent-api.md). It is independent of the lightweight
[work report](work-report.md), and reads do not modify usage or settlement.

## Routes

```http
GET /agent_api/v1/work_analysis
```

## Read work analysis

### Request

| Query | Meaning |
| --- | --- |
| `workspace_public_id` | Optional accessible Workspace UUID |
| `agent_public_id` | Optional Agent UUID |
| `from`, `to` | ISO8601 instants defining the exact half-open window `[from,to)` |
| `provider_id`, `catalog_model_ref`, `workload`, `status` | Optional exact-match model receipt filters; blank means all |
| `group_by` | `provider_id` (default), `catalog_model_ref`, `workload`, or `status` |
| `rank_by` | `request_count` (default), `total_tokens`, or `cost_amount` |
| `limit` | Number of model groups and tool names returned, default 10, range 1–50 |

Supply both bounds or neither. Omission selects the last seven complete UTC
days. Zone-less timestamps are interpreted as UTC. The maximum window is 90
days. Bounds need not align to an hour or day; they are not rounded. There is no
`unit` parameter or time series. Overwide windows refuse without truncation.
Supplying `unit` or a non-scalar model dimension returns `400 parameter_invalid`
instead of silently changing the requested selection.
Response `from` and `to` use UTC ISO8601 with six fractional digits to preserve
the actual database window, an explicit exception to ordinary timestamp
encoding precision. `as_of` keeps the common timestamp encoding.

The four model filters apply only to `model_usage`. Run and tool analysis uses
current content permission, Workspace/Agent scope and the Run creation window.
The model status `failed` does not select a Run state.

### Response

`200` returns `{analysis: {...}}`:

| Field | Meaning |
| --- | --- |
| `from`, `to`, `as_of` | Applied window and read time |
| `cost_unit` | Account's configured unit or `null` |
| `workspace_public_id`, `agent_public_id` | Applied resource filters or `null` |
| `model_usage` | Model receipt totals, statuses, latency and groups |
| `execution` | Run cohort and its retained tools |

#### Model usage

`model_usage.totals` has the [work report's usage counters](work-report.md), plus
`amount_sample_count`: the count of receipts whose `cost_amount` is non-null,
including real zero amounts. Known amounts remain exact decimal strings.
`cost_complete` retains its existing cost-evidence rule; a failed receipt with
no money can be complete with zero amount samples. Do not use that boolean to
infer whether money was observed. Missing token values add no recorded tokens.

`status_counts` includes `succeeded`, `failed`, `discarded`, and `abandoned`.
One receipt represents one actually started model attempt, so retries count
separately. An attempt failure is not a Run or user-goal outcome.

`latency.duration_ms` and `latency.time_to_first_token_ms` each contain
`sample_count`, `missing_count`, `p50`, and `p95`. Each field excludes its own
null samples; zero is valid. Percentiles use PostgreSQL `percentile_disc`, the
nearest-rank observed integer millisecond sample. With no samples, both
percentiles are `null`; with one sample both equal it. Duration covers Dispatch
IO, and TTFT exists only when a text or reasoning delta was captured.

`breakdown` contains `group_by`, `rank_by`, `limit`, `total_group_count`,
`groups: [{value, totals}]`, and `other`. Each group's `totals` and the remaining
groups' `other` carry the same counters and amount sample count as the window
totals. Groups sort by rank descending, then dimension value ascending. A full
catalog reference includes its provider, so same-named wire models are not
merged. Known-cost ranking uses known amounts while retaining evidence
completeness. Empty and wholly unknown amounts must not be presented as known
zero costs. Top N limits output, not the database's aggregation work.

Totals, status counts, groups and exact percentiles use one database snapshot.
Percentiles cover the entire filtered receipt set; group rows contain counters.
To inspect a group's percentiles, repeat the query with its dimension filter.
Neither averaged historical percentiles nor sums of bucket counters determine
these values.

Receipt filtering uses `recorded_at`, the receipt's write time. Only receipts
attributed to currently readable, retained Conversations are included. Permanent
receipts never restore content access; standalone receipts without Conversation
attribution are excluded. An Agent filter additionally selects its receipt
consumer UUID. Human-submitted work remains attributed to the Human even when an
Agent answers. This is a content-scoped usage analysis, not a personal bill.

#### Runs and tools

`execution` contains:

- `run_count`, `retained_run_count`, `details_pruned_run_count`;
- `status_counts` for the [Run statuses](../statuses.md);
- `delivered_count`, `undelivered_count`, `completed_count`,
  `uncompleted_count`;
- `latency.delivery_ms` and `latency.completion_ms`, each with the same
  percentile/sample shape;
- `tools` as described below.

Runs must be currently readable and created in `[from,to)`. Agent scope keeps
the captured Conversation answerer or the standalone Run creator. Delivery
measures `delivered_at-created_at`; completion measures
`completed_at-created_at`. Background work may continue after delivery.
Elapsed values are floored to whole milliseconds **before** computing
nearest-rank percentiles. A missing endpoint yields a missing sample.

`tools` contains `task_count`, `status_counts`, `error_result_count`, `latency`,
`total_group_count`, `groups`, and `other_task_count`. Each group contains
`tool_name`, `task_count`, `status_counts`, `error_result_count`, and `latency`.
Tool names sort by task count descending, then saved name ascending; the same
`limit` caps this list. `other_task_count` counts tasks in omitted name groups.

Only retained ToolTask rows in this Run cohort contribute. Each row represents
its current execution generation; retry clears the prior timestamps, outcome
and claimant. This is not every historical tool attempt. Tool state counts use
the [Task status vocabulary](../statuses.md). `error_result_count` counts
completed tools whose result has `is_error: true`, separately from execution
`failed`. Elapsed time uses `completed_at-started_at`, floored to whole
milliseconds, with the same percentile/sample rules. It includes dispatch
waiting, pause and result return, and is not pure tool runtime. Parallel tool
times are never summed into a Run duration.

Pruned Task details are unavailable evidence, not zero calls. Retained Run
clocks and the `details_pruned_run_count` remain visible under the ordinary
[execution retention](execution-retention.md) rules. Administrator, steward
and Workspace-owner roles add no content bypass.

### Status codes

| Status | Meaning |
| --- | --- |
| `200` | Analysis returned |
| `400 parameter_missing` / `parameter_invalid` | Missing bound, malformed timestamp, unsupported group/rank, or invalid scalar limit |
| `400 window_invalid` | Start is not before end |
| `400 window_too_wide` | Window exceeds 90 days |
| `404` | Workspace is inaccessible/deleted or selected UUID is not an Agent |

The browser uses `/usage`, with all filters in its URL. Account administration
has a separate [model-only analysis](../platform-api/admin-model-usage.md#read-an-analysis).
