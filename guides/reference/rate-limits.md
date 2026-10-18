# Rate limits

Budgets are per resource, not per family: each endpoint family holds its own counter, so exhausting one leaves the others untouched. Each resource carries two fixed one-minute counters:

1. A broad **source-IP backstop**, one hundred times the resource's ordinary budget, charged first by every request.
2. The **ordinary resource budget**, 6,000 requests per minute by default. After credential resolution an accepted credential is keyed by its non-secret token identifier; a missing, malformed, unknown, expired, revoked or wrong-plane credential falls back to the source IP.

| Resource | Per minute | Why |
| --- | --- | --- |
| Conversation, run and InferenceRequest `events` | 6,000 | Event replay and bounded polling; realtime subscriptions reduce polling demand |
| Store entries (profile, workspace, conversation) | 6,000 | Reads and writes share the budget |
| `inference_requests` | 6,000 | Every create plus bounded list and read polling |
| Executor claim status (`GET`) | 600 | Recovers missed cancellation for concurrent held claims; the claim `POST` has its own 6,000 |
| Executor `progress` | 10,000 | Also one frame per key per 250 ms per kernel process; excess is acknowledged and dropped |
| Upload thumbnail and preview | 30 | Bounds derivative generation independently of upload reads |
| Everything else | 6,000 | Including `inference_requests/input_estimate` and cancellation |

The default accommodates parallel agents sharing one credential; it is an admission budget, not a throughput guarantee. Neither key contains the raw `Authorization` header or secret, so header spelling variants share one budget and invalid values cannot create fresh buckets. Different valid credentials behind one NAT have independent ordinary budgets; an exceptionally large shared NAT may share the backstop.

Either exhausted counter returns:

```json
{ "error": { "code": "rate_limited", "message": "…" } }
```

with `429` and `Retry-After: 60`.

Other fixed limits: ten model connection tests per human in three minutes; invitation email resends at least 60 seconds apart; a parked approval or question waits 24 hours; a device authorization lives 15 minutes and its polling at most 900 seconds; an authorization code five minutes; a password reset link 15 minutes.
