# Platform API — Balances and Agent allowances

Financial reads expose amounts and attributed adjustments. They grant no
Conversation, Workspace, model or provider activity access. Human balance
administration is documented in [Admin budgets](admin-budgets.md).

## Routes

```http
GET   /api/v1/profile/budgets
GET   /api/v1/profile/budgets/{public_id}
GET   /api/v1/profile/budgets/{budget_public_id}/entries
GET   /api/v1/agents/{agent_id}/budgets
GET   /api/v1/agents/{agent_id}/budgets/{public_id}
GET   /api/v1/agents/{agent_id}/budgets/{budget_public_id}/entries
POST  /api/v1/agents/{agent_id}/budgets
PATCH /api/v1/agents/{agent_id}/budgets/{public_id}
POST  /api/v1/agents/{agent_id}/budgets/{budget_public_id}/revocation
```

Profile reads belong to the authenticated Human. Agent resources belong to
the current active Human steward, including both paired and named Agents;
administrator status adds no authority. An Agent outside that stewardship,
or a budget outside its target, returns `404`.

## Read windows

List queries accept `limit` (default 25, maximum 100), `after` and
`order=asc|desc` (default `asc`). Windows are ordered by `(starts_at, public_id)`.
The opaque cursor carries its direction; continuing it with another direction
is `400 parameter_invalid`. Filtering and target authority apply before paging.

The list response is:

```json
{
  "user_public_id": "01900000-0000-7000-8000-000000000001",
  "user_kind": "human",
  "cost_unit": "USD",
  "measured_at": "2026-10-16T01:00:00Z",
  "current_budget": null,
  "budgets": [],
  "pagination": { "next_after": null }
}
```

`current_budget` is the usable window at `measured_at`, independent of the
history page. Null means no cap from this side of admission, not a zero balance.
History includes future, expired and revoked windows. The point read returns
`{budget, measured_at}`.

A budget carries `public_id`, `user_public_id`, `user_kind`, `cost_unit`,
`credited_amount`, `debited_amount`, `headroom`, `starts_at`, `expires_at`,
`revoked_at`, `revoked_by_public_id`, `revoke_reason` and `usable`. Amounts are
exact decimal strings; `headroom = credited_amount - debited_amount` retains
negative deficits. `usable` describes window validity, independent of headroom.
The cost unit can be null before Account configuration; opening a window then
refuses. Reads never settle outstanding receipts.

## Read entries

Entries use the same paging grammar, ordered by monotonically increasing
`sequence`. The response is `{entries, pagination: {next_after}}`. Each row has
`public_id`, `sequence`, `kind`, `amount`, `cost_unit`, `actor_public_id`,
`reason` and `created_at`. `actor_public_id` is the Human command actor or null
for settlement. Kinds include `initial_grant`, `credit_adjustment`,
`debit_adjustment`, `charge` and `allowance_consumption`; consumers should retain
unknown future kinds. Reads omit receipt IDs and all operation keys.

## Manage an allowance

Open, adjust and revoke use the same request envelopes, `Idempotency-Key`,
exact amounts, responses and refusal codes as [Human budget commands](admin-budgets.md).
Use the Agent route and current steward credential. Open/adjust/revoke return
the standing budget; adjustment also returns its attributed command entry,
including its operation key for intentional replay. Read entries have the
separate amount-only projection above.

An exhausted Agent allowance rejects new priced admission with
`allowance_exhausted`; the Human payer's check can independently reject with
`budget_exhausted`. An allowance is checked only when the captured consumer is
an Agent. Human work answered by an Agent consumes the Human budget only.

Known positive receipt cost settles to the captured Human payer and Agent
consumer independently, in one transaction. Either side may have no usable
window. Settlement allows a deficit and is exactly once per receipt and target;
it never changes the captured payer after a steward transfer. There is no
reservation or hard spending ceiling. Unknown, zero and unmetered amounts do
not create positive charges. Agent allowance consumption covers receipts settled
after this mechanism was enabled; previously settled history is not backfilled.

Revoking the only usable window removes that side's cap. It does not freeze the
Agent or stop work. Adjusting an expired or revoked window can repair its deficit.
