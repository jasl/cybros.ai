# Usage and cost

Every model invocation records its usage: tokens by kind, the model and provider that answered, and the cost when the model has a price in the account's unit. Usage is a kernel fact independent of settlement; nothing an application does rewrites a recorded invocation.

## Where to read it

| Scope | Where |
| --- | --- |
| One run | `usage` events on the run's feed; the run and task reads |
| One conversation | `usage_summary` on the conversation: cumulative tokens and known cost across every candidate and background call. Choosing another candidate or undoing a turn never subtracts spending. |
| One direct model call | The InferenceRequest's result |
| The account | Administrator statistics under **Administration** and the Platform API's admin usage reports (aggregate; never per-agent activity) |

Usage survives [retention](../operate/retention-usage-budgets.md): after execution detail is pruned, the conversation's summary keeps its totals.

## Cost

Cost is an estimate from the model's optional pricing (amounts per million tokens) in the account's configure-once cost unit. Work with missing or unresolved pricing runs unmetered: quantities are recorded and the monetary amount stays absent. A complete explicit zero-price schedule produces a zero estimate. Token counts come from the model's declared tokenizer where one is preloaded and are planning inputs, not an exact prediction of provider billing.

## Budgets and allowances

A budget is a windowed virtual balance for one member. Priced work checks the payer's usable budget at admission; an exhausted balance refuses new work with the ordinary task failure path, and no usable budget means no cap. Admission reserves no funds, so in-flight work can exceed the balance — a soft guard, not a hard ceiling.

- Owners and administrators administer human budgets through `POST /api/v1/admin/users/{id}/budgets` and its adjust and revoke doors.
- An agent's allowance is administered by its human steward alone. The agent reads its own balance and headroom on the member plane and cannot change it.
- A `billing_subject` — the member a conversation's spending is attributed to — grants no balance authority.

There is no per-conversation or per-session budget in the kernel. An application that wants one enforces it from usage reads and its own policy.

## Prompt caching

The continuation chain is designed around cache reuse: the declared tool list sits at the front of every cached prefix (which is why the declaration is replaced whole, not merged), and continuations replay the same history so providers that support prompt caching reuse it. Cache markers are placed after prompt-format adaptation, during request compilation.
