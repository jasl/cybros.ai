# Platform API v1: admin model-usage report

This read-only report aggregates model usage. Budgets and settlement read
receipts directly; this report cannot change balances or settlement.

## Route

```http
GET /api/v1/admin/model_usage/report
```

Requires an active Human owner or administrator using an API Session or
platform-plane access token. The [Platform API's safe-cookie-read rule](../v1.md#authentication)
also applies. Query parameters:

- `from`, `to` — required ISO8601 instants, half-open `[from, to)`, both
  aligned to the unit's UTC boundary.
- `unit` — `hour` (default), `day`, or `month`.
- The window may contain at most 1,000 series points. Use a larger unit or split
  a longer range into adjacent aligned windows.
- Optional exact-match dimension filters: `consumer_user_public_id`,
  `payer_user_public_id`, `workspace_public_id`, `billing_subject_key`,
  `provider_id`, `catalog_model_ref`, `workload`, `status`.

## Answer

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
not remove usage receipts. An unaligned or overwide window returns `400`
(`window_invalid`, `window_too_wide`, or `unit_unsupported`) without truncating
the requested range. Every non-window query key is treated as a filter: an
unknown key is `filter_unsupported` and a non-scalar value is
`filter_invalid`, never a silent account-wide widening.
