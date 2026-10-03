# Platform API — Admin Budgets

These resources manage windowed virtual balances. Priced work checks the
payer's usable budget at admission: an exhausted balance refuses new work;
no usable budget means no spend cap. Admission reserves no funds, so
concurrent in-flight work and delayed settlement can exceed the balance.
This is a soft spend guard, not a hard spending ceiling. Work with missing or
unresolved pricing runs unmetered and does not use this guard; usage quantities
are still recorded and unknown monetary amounts remain absent. Adjusting a
budget changes its balance through an attributed entry; revocation removes that
window from use. Every endpoint demands a live Human administrator (the family's
`403 administrator_required` otherwise), and an Agent member's budget is
administered by its current steward alone.

## Routes

```http
PUT    /api/v1/admin/account/cost_unit
POST   /api/v1/admin/users/{user_public_id}/budgets
PATCH  /api/v1/admin/users/{user_public_id}/budgets/{public_id}
POST   /api/v1/admin/users/{user_public_id}/budgets/{public_id}/revocation
```

## Configure the account cost unit

`PUT /api/v1/admin/account/cost_unit` with `{"account": {"cost_unit": "USD"}}`
is configure-once: the first setting wins, a same-value replay reads as
already configured (`200`), and a different value is `409 cost_unit_conflict`
— nothing rewrites a unit money was already counted in. Ordinary browser setup
configures USD, with an advanced alternative at owner creation. The kernel and
Account factory still allow an unset unit. Opening a budget refuses until the
unit is set; model calls can still run with unknown cost. A pricing unit that
differs from the Account unit likewise leaves cost unknown rather than converting
it. This API supplies no default.

## Open a budget

`POST /api/v1/admin/users/{user_public_id}/budgets` requires an
`Idempotency-Key` header (the ledger's operation key). Body:

```json
{
  "budget": {
    "amount": "25.00",
    "starts_at": "2026-08-21T00:00:00Z",
    "expires_at": null,
    "reason": "august allowance"
  }
}
```

- `amount` is an exact decimal string — floats are refused (`422`).
- `201` returns the budget projection (`public_id`, `user_public_id`,
  `credited_amount`, `debited_amount`, `cost_unit`, `starts_at`,
  `expires_at`, `revoked_at` — `null` until revoked). An exact replay under
  the same key returns the standing budget with `201`; a divergent payload
  is `409 idempotency_envelope_mismatch`.
- Overlapping an existing usable window is `409 budget_window_overlap`; an
  unconfigured account unit is `422 account_unit_unconfigured`.
- A target that cannot take a budget from this caller is
  `403 user_not_administrable` — a removed Human member, or an Agent member
  whose budget only its current steward opens. The gate's
  `administrator_required` above is about the caller; this one is about the
  target.

## Adjust a budget

`PATCH /api/v1/admin/users/{user_public_id}/budgets/{public_id}` requires an
`Idempotency-Key` header (the entry's operation key). Body:

```json
{ "budget": { "kind": "credit", "amount": "5.00", "reason": "top-up" } }
```

- `kind` is `credit` or `debit`; `amount` an exact decimal string as on
  open. The entry is appended and the head (`credited_amount` or
  `debited_amount`) moved in one transaction.
- `200` returns `{budget, entry}` — the projection above and the entry
  written: `{sequence, kind, amount, reason, operation_key, created_at}`.
  An exact replay under the same key returns the same entry and moves
  nothing; a divergent payload (or the key reused on another budget of
  the same member) is `409 idempotency_envelope_mismatch`.
- A debit past the remaining headroom is `409 budget_insufficient_headroom`.
- A credit is legal on a revoked or expired budget: deficit repair
  applies to the window against which the spend was recorded.
- A kind outside `credit | debit`, a float, an overlong key or reason:
  `422 validation_failed`. A budget the target does not hold: `404`.

## Revoke a budget

`POST /api/v1/admin/users/{user_public_id}/budgets/{public_id}/revocation`
requires an `Idempotency-Key` header (stored as the budget's
`revoke_operation_key`). Body, optional:

```json
{ "revocation": { "reason": "misuse" } }
```

- `200` returns the projection with `revoked_at` set. The window no longer participates in
  admission or settlement; no entry already written moves. Revoking the
  only usable budget removes its spend cap; it does not disable the member
  or cancel work. The same key with the same reason
  replays the standing row; the same key with another reason is
  `409 idempotency_envelope_mismatch`; a different key on a budget already
  revoked is `409 budget_already_revoked`.
- `403 user_not_administrable` names the target on every door: a removed
  Human member, or an Agent member whose budget only its current steward
  administers.
