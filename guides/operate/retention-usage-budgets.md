# Retention, usage and budgets

## Execution detail retention

Nexus keeps conversation text and reclaims completed execution detail. The account's retention window defaults to 90 days after an execution completes.

What stays: turns and candidate answers, their original prompt, final content, model selection and landed follow-up messages; forks keep referencing them; keyword search keeps working. What is removed: the execution graph, task inputs and outputs, tool result bodies, sealed provider requests and responses, reasoning traces, invocation attempts and invocation-owned output files. A run keeps its public identity and terminal state; the conversation's cumulative usage keeps its tokens and known cost.

Change the window under **Administration → Retention**, or:

```sh
./cybros cmctl account retention        # read the current setting
./cybros cmctl account retention 180    # retain details for 180 days
./cybros cmctl account retention off    # disable automatic cleanup
```

The background jobs service must be running for cleanup. Increasing the window or disabling cleanup cannot restore removed detail; restore a backup if it is needed. The event feed keeps its separate 30-day replay window. Standalone runs and direct model requests have their own lifecycle.

After expiry, a run's detail routes return `410 execution_details_pruned`, regeneration of an expired answer returns `409`, and new inputs still work with the retained history. See [Errors and recovery](../build/errors-and-recovery.md).

## Usage

Every model invocation records its usage. A conversation's `usage_summary` accumulates tokens and known cost across every candidate and background call; choosing another candidate or undoing a turn never subtracts spending. Administrators read account-wide usage and cost statistics under **Administration**; these reports never change budgets or settlement. Per-member detail is aggregate only: an administrator does not inspect a specific agent's activity.

Cost is an estimate from the model's optional pricing in the account's cost unit. Work with missing pricing runs unmetered: quantities are recorded, monetary amounts stay absent.

## Cost unit

The account's cost unit is configured once — USD by default at owner creation, or another unit chosen under **Advanced options** on that form — and never changed afterward. Model pricing in a different unit leaves cost unknown rather than converting it. Opening a budget requires the unit to be set; model calls run regardless.

## Budgets

A budget is a windowed virtual balance for one member. Priced work checks the payer's usable budget at admission: an exhausted balance refuses new work, and no usable budget means no spending cap. Admission reserves nothing, so concurrent in-flight work can exceed the balance; this is a soft guard, not a hard ceiling.

- Owners and administrators open, adjust (credit or debit) and revoke any human's budget, including their own, with an attributed reason.
- An agent's budget is administered only by its current steward. The agent can read its own balance and headroom but cannot change it.
- Overlapping windows are refused; a credit remains legal on a revoked or expired budget to repair a deficit.

These controls expose amounts only — no content, workspace, provider trace or per-agent activity. The API is described in [Admin budgets](../reference/platform-api/admin-budgets.md), [Account retention](../reference/platform-api/retention.md) and [Admin model usage](../reference/platform-api/admin-model-usage.md).
