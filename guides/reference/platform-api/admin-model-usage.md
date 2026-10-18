# Platform API v1: admin model-usage report

This read-only report aggregates model usage. Budgets and settlement read
receipts directly; this report cannot change balances or settlement.

## Routes

```http
GET /api/v1/admin/model_usage/report
GET /api/v1/admin/model_usage/analysis
```

## Read a report

### Endpoint

```http
GET /api/v1/admin/model_usage/report
```

### Authentication

Requires an active Human owner or administrator using an API Session or
platform-plane access token. The [Platform API's safe-cookie-read rule](../platform-api.md#authentication)
also applies.

### Request

Query parameters:

- `from`, `to` — required ISO8601 instants, half-open `[from, to)`, both
  aligned to the unit's UTC boundary.
- `unit` — `hour` (default), `day`, or `month`.
- The window may contain at most 1,000 series points. Use a larger unit or split
  a longer range into adjacent aligned windows.
- Optional exact-match dimension filters: `provider_id`, `catalog_model_ref`,
  `workload`, `status`. Member, payer, Workspace and billing-subject filters are
  unsupported; this report provides no member activity or content drilldowns.

### Response

```json
{
  "report": {
    "unit": "hour",
    "series": [
      { "bucket_start_at": "2026-08-21T10:00:00Z", "request_count": 3,
        "input_tokens": 900, "cache_read_tokens": 0,
        "cache_creation_tokens": 0, "output_tokens": 120,
        "reasoning_tokens": 0, "total_tokens": 1020,
        "cost_amount": "0.0405", "cost_complete": true }
    ],
    "totals": { "request_count": 3, "...": "same members" }
  }
}
```

The series zero-fills every unit boundary in the window — a quiet hour
reads as zeros, not a hole. `cost_complete` is the aggregate statement:
every counted billable receipt has known money (non-billable failures
count vacuously; an unmetered success keeps it false, exactly as the
receipt's own public shape reads).

Reports combine stored rollups with usage not yet rolled up under one database
snapshot. They include the exact aligned window; execution-detail cleanup does
not remove usage receipts.

### Status codes

`200` returns the report. An unaligned or overwide window returns `400`
(`window_invalid`, `window_too_wide`, or `unit_unsupported`) without truncating
the requested range. Every non-window query key is treated as a filter: an
unknown key is `filter_unsupported` and a non-scalar value is
`filter_invalid`, never a silent account-wide widening.

The browser report is under **Administration → Usage**. See
[Inspect and recover work](../../operate/work-console.md) for the separate
member-scoped Dashboard.

## Read an analysis

```http
GET /api/v1/admin/model_usage/analysis
```

This independent query adds model grouping, Top N and exact latency percentiles.
It has the same Human administrator authentication as the report. It reads
permanent Account receipts directly and includes standalone work without
revealing a member, Workspace, receipt, Run, tool name or content link.

The query accepts `from`, `to`, `group_by`, `rank_by`, `limit`, and the four
exact-match filters `provider_id`, `catalog_model_ref`, `workload`, `status`.
Supply both timestamps or neither. Omission selects seven complete UTC days;
zone-less values are UTC. The exact half-open window may span at most 90 days,
without rounding or truncation. There is no `unit` or time series.
Response `from` and `to` preserve that exact database window as UTC ISO8601 with
six fractional digits; `as_of` retains ordinary timestamp encoding precision.

`group_by` is one of the four dimensions, default `provider_id`. `rank_by` is
`request_count` (default), `total_tokens` or `cost_amount`. `limit` defaults to
10 and is 1–50. Blank filter choices mean all. Unknown query keys, including
member, payer, Agent, Workspace and billing-subject selectors, return
`400 filter_unsupported`; a present non-scalar dimension returns
`400 parameter_invalid`. Invalid group/rank or scalar limit also returns
`400 parameter_invalid`; unordered windows use `400 window_invalid` and windows
over 90 days use `400 window_too_wide`. These refusals never silently widen or
clamp the requested analysis.

`200` returns `{analysis: {from, to, as_of, cost_unit, model_usage}}`.
`model_usage` has `totals`, `status_counts`, `latency` and `breakdown`, using the
exact [work-analysis model schema](../agent-api/work-analysis.md#model-usage).
It does not have `execution`, `workspace_public_id` or `agent_public_id`.

Totals and each group's counters include `amount_sample_count`, separately
from `cost_complete`. A costless failed attempt may be complete under the
existing evidence rule but have no amount sample; a real zero amount is a
sample. Money stays an exact decimal string. Top N does not replace full-window
totals; `other` contains all omitted groups and derives completeness from their
own counters. Known-cost sorting does not declare unknown money to be free.

Receipt time is `recorded_at`, not Run creation or model-start time.
`duration_ms` and `time_to_first_token_ms` each have independent sample/missing
counts and nearest-rank `p50`/`p95` integer milliseconds. Zero is valid, no
samples means `null`, and a single sample supplies both percentiles. TTFT
requires a captured text/reasoning delta. All components read one database
snapshot; group rows carry counters, and filtering to a group reveals that
group's percentiles. No accumulated bucket percentile is averaged.

The browser entry is `/admin/model_usage`, with a fixed seven-day summary and
a separate aggregate download. Interactive analysis remains available through
this API; see [Export retained data](../../operate/export-data.md).
