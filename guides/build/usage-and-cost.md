# Usage and cost

Every model invocation records its usage: tokens by kind, the model and provider that answered, and the cost when the model has a price in the account's unit. Usage is a kernel fact independent of settlement; nothing an application does rewrites a recorded invocation.

## Where to read it

| Scope | Where |
| --- | --- |
| One run | `usage` events on the run's feed; the run and task reads |
| One conversation | `usage_summary` on the conversation: cumulative tokens and known cost across every candidate and background call. Choosing another candidate or undoing a turn never subtracts spending. |
| One direct model call | The InferenceRequest's result |
| Readable work | **Overview** shows period usage attributed to currently readable Conversations; see [Inspect and recover work](../operate/work-console.md) for coverage and time windows |
| The account | **Administration → Usage** and the Platform API's [admin usage report](../reference/platform-api/admin-model-usage.md) provide aggregate usage without member activity or content drilldowns |

Usage survives [retention](../operate/retention-usage-budgets.md): after execution detail is pruned, the conversation's summary keeps its totals.

## Cost

Cost is an estimate from the model's optional pricing (amounts per million tokens) in the account's configure-once cost unit. Work with missing or unresolved pricing runs unmetered: quantities are recorded and the monetary amount stays absent. A complete explicit zero-price schedule produces a zero estimate. Token counts come from the model's declared tokenizer where one is preloaded and are planning inputs, not an exact prediction of provider billing.

## Budgets and allowances

A budget is a windowed virtual balance for one member. Priced work checks the Human payer's usable budget and, when the actual consumer is an Agent, that Agent's allowance. Exhaustion refuses new work with `budget_exhausted` or `allowance_exhausted`; no usable window skips that side's cap. Admission reserves no funds, so in-flight work can exceed the balance.

- Owners and administrators administer human budgets through `POST /api/v1/admin/users/{id}/budgets` and its adjust and revoke doors.
- An agent's allowance is administered by its human steward alone through `/api/v1/agents/{agent_id}/budgets`. The agent reads its own balance and headroom through `/agent_api/v1/profile/budgets` and cannot change it.
- A `billing_subject` — the member a conversation's spending is attributed to — grants no balance authority.

Settlement appends the known positive receipt cost to the captured Human payer
and Agent consumer independently, using each side's usable window. It allows
deficits and commits both ledgers with the receipt marker atomically. A Human
request answered by an Agent remains Human consumption. Previously settled receipts
are not backfilled into Agent allowance history. See [balances and allowances](../reference/platform-api/budgets.md)
for exact projections and [the money pages](../operate/budgets.md) for browser use.

## Limit one Conversation's cost

Set `cost_limit` on the Conversation when a long-running task should stop
admitting priced model work at a chosen known subtotal. The limit uses the
Account's cost unit and the existing cumulative usage. It does not include child
Conversations, and forks, Sides and spawned children start uncapped.

When the subtotal reaches the limit, a refused model task reports
`conversation_cost_limit_reached` and holds its Run for repair. Read the current
Conversation, PATCH a higher `cost_limit` or null with its `lock_version`, then
retry the failed task. This preserves completed tools, results and the original
execution. Raising the limit alone does not restart work; a direct reply uses
Regenerate after adjustment.
The browser provides the same explicit sequence; see
[Recover a Conversation cost limit](../operate/recover-conversation-cost.md).

Already admitted calls can finish, so actual cost may overshoot. Known-free and
unmetered work retain their ordinary admission rules; unknown costs stay absent.
Display `cost_complete: false`
as an incomplete known subtotal. See [Conversation cost limits](../reference/agent-api/conversations.md#cost-limits)
for exact amounts, permissions and admission behavior, and
[Errors and recovery](errors-and-recovery.md) for task repair.

## Prompt caching

The continuation chain is designed around cache reuse: the declared tool list sits at the front of every cached prefix (which is why the declaration is replaced whole, not merged), and continuations replay the same history so providers that support prompt caching reuse it. Cache markers are placed after prompt-format adaptation, during request compilation.
