# Balances, allowances, and ledgers

Nexus records amounts in the Account's configured cost unit. Amounts keep their exact decimal precision; Nexus does not convert currencies.

## Find the right budget

- **Settings → My balance** shows the signed-in Human's own balance, windows, and ledger. This page is read-only.
- **Agents → an Agent → Agent allowance** lets its current Human steward read and manage its allowance. This includes paired and named Agents.
- **Administration → Users → a user → Balance** lets an administrator read and manage that Human's balance. Agent allowances belong to their steward's Agent pages.

Budget access does not grant access to Conversations, Runs, model requests, or other activity. A ledger shows entry UUID, sequence, kind, amount, cost unit, Human actor when present, reason, and time. It does not link to the model receipt behind a charge.

## Understand a window

The current window is selected for the page's displayed read time. Its start is inclusive and its expiry is exclusive. A future, expired, or revoked window remains readable in **All windows**. History pagination does not change which window is current.

**Remaining amount** is total credited minus total debited. A negative amount is a deficit and is displayed without rounding it to zero. **No current usable window** means this balance or allowance imposes no spending cap; it does not mean the balance is zero.

The window list and ledger have bounded pagination, a page-size control, and ascending or descending order. **Next page** continues the same ordering; **First page** returns to its start. Times are shown in UTC.

## Open, adjust, or revoke

Use **Open budget window** to set an initial amount, start, optional expiry, and optional reason. Enter an ISO 8601 time with a time zone, such as `2026-10-16T00:00:00Z`. An empty expiry leaves the window open-ended. Windows cannot overlap another usable window for the same member.

**Adjust amount** adds a credit or deducts credit through a new ledger entry. It does not rewrite earlier entries. A manual deduction cannot exceed the remaining amount. You can credit an expired or revoked window to repair a deficit; previous spending stays in its original window.

**Revoke window** removes that window's spending cap. It does not suspend the member, stop accepted work, or erase spending. If no other window is usable, this balance or allowance imposes no cap.

Each command form keeps its operation key when displaying an error. Correct the fields and retry the same form. An exact repeat of a saved operation does not apply twice. If the key was already saved with different values, open a new form for a new operation. Errors keep the submitted fields; the page never automatically replays them with a different key.

## Allowance consumption

A priced model attempt checks the Human payer's current balance and, when the actual consumer is an Agent, that Agent's current allowance. Each side without a usable window is uncapped. These are soft checks without reserved amounts; concurrent work and delayed settlement can leave a deficit.

Settlement appends the known positive model cost to the captured Human payer's balance and the actual Agent consumer's allowance independently. Human-initiated work does not consume the answering Agent's allowance. A steward change does not transfer earlier charges or change the payer captured by an existing receipt.

Agent allowance consumption covers settlements made after allowance accounting was enabled. Already settled history is not charged again. Do not treat an older allowance ledger as a complete history of Agent usage.

For request shapes and API permissions, see the [Platform budget reference](/reference/platform-api/budgets) and [member profile reference](/reference/agent-api/profile).
