# Tool providers

A tool provider serves tools by name from a pool, rather than tools bound to one environment. Several providers can serve the same workspace; a call for a name is listed to every eligible provider and the first claim wins.

## When to use one

- Tools that are not about a filesystem: a mail search, a ticket system, a database query, an internal API.
- Capacity that should scale by adding processes rather than by naming machines.
- Overriding a kernel tool family (today, the memory tools) with your own implementation under the workspace's explicit opt-in: a provider that takes `memory_read` must take the whole family, so there is never two memories under one name.

For tools that must run where particular files live, use a [runner](index.md) instead.

## How it works

A tool provider has the same logical registration key as a Runner: its Account, Human manager and registration identifier. Assignment scope is separate access control. It has one non-revoked address, a transport-only credential and an epoch that re-pair advances. One manager cannot hold a Runner and a provider under the same identifier.

1. Connect with `executor_kind: "tool_provider"` through the device flow; the human approves it in **Runners → Connect runner**.
2. Announce the tool names it serves, with effect profiles and schemas, through the same announcement door a runner uses.
3. Read the inbox. Pool rows for the announced names appear for every eligible provider until the first claim wins; a provider row names no executor and is not canceled when another address is cleaned up.
4. Claim, run, commit — exactly as a runner does. See [Claims and results](claims-and-results.md).

A provider-addressed call runs in a one-task standalone run or as part of an ordinary run; the declaring agent's configuration still lists the tool so the model may call it, and the approval stage still judges every call.

## In practice

rho's runner loop is the reference implementation: a process connected as a tool provider is the same loop on a pool row. Any program that can hold a transport credential and speak the inbox protocol can be a provider in any language.
