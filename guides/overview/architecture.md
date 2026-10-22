# Architecture

Nexus is the gateway. Every other component connects to it over outbound HTTP and, optionally, a WebSocket for low-latency hints. Nothing dials into an agent or a runner.

```
 people ──▶ rho browser page / Telegram / editor / CLI
                     │
                     ▼
            ┌──────────────────┐      ┌──────────────────────┐
            │ agent│◀────▶│        Nexus          │◀──── model providers
            │ (rho or yours)   │      │ kernel and gateway    │      (API key, subscription,
            └──────────────────┘      │ conversations, runs,  │       local server)
                                      │ inbox, approvals,     │
            ┌──────────────────┐      │ usage, retention      │
            │ runner(s)        │◀────▶│                       │
            │ files, shell,    │      └──────────────────────┘
            │ processes, MCP   │                ▲
            └──────────────────┘                │
            ┌──────────────────┐                │
            │ tool provider(s) │◀───────────────┘
            └──────────────────┘
```

## Kernel and application

Nexus owns **mechanisms**: prompt assembly, the round driver that calls a model and expands its tool calls into tasks, compaction with an overridable summarizer, memory, cross-conversation messaging, approval evaluation, task delivery, orchestration primitives, persistence, model catalog resolution, usage accounting, audit and recovery.

The agent owns **policy**: what a prompt means, which model to use and when to fall back, which tools to declare and what their approval rules are, how to orchestrate, how memory is written and ranked, how results are shown to people, and how external channels such as Telegram behave.

The kernel never branches on a concrete product. It reads approval rules against opaque tool input without knowing what `bash` means, resolves a declared model reference to a provider lane without choosing models, and compiles prompt documents without interpreting personas.

## rho on Nexus

rho is an agent in exactly the sense above. Application OAuth signs the human in and, at initial connection, pairs its Agent. The Human login and Agent bundle have separate refresh lineages; the Agent bundle contains its member and application-transport tokens. In full mode, one Agent Executor announces both agent and runner services and uses one transport connection for them. It declares its tools and approval rules through the Agent API, drives conversations through inputs and feeds, serves its own tools (coding tools, web fetch, browser, MCP, code mode) through the executor inbox, and reaches human settings through the Platform API with the signed-in person's own credential. Its browser page, Telegram ingress, ACP server and CLI are thin consumers of one application core. Nothing it uses is private to it, which is why it works as the reference implementation.

In the default bundle rho runs in full mode beside Nexus; in agent mode it answers conversations and sends tool calls to runners elsewhere; in runner mode it serves tools only. A second application can run on the same Nexus with its own Agent identity and policy.

## Three executor roles

| Role | Credential | What it receives |
| --- | --- | --- |
| Agent | A member credential (acts as the Agent) plus a transport credential (its delivery address) | Its own tool calls, approval requests and questions addressed to the application; everything on the member plane |
| Runner | A transport credential only | Tool calls accepted for its concrete target |
| Tool provider | A transport credential only | Tool calls for the names it announced, claimed from a pool shared with other eligible providers |

All three use the same asynchronous inbox: read, claim with a rotating token, extend the task's own deadline when needed, and commit a write-once result. Kernel work such as delegated compaction uses the same protocol. A runner is a machine, not a principal: it never holds a member credential, and each task freezes the Agent whose authority it runs under.

## Durable execution

A conversation reply can run a DAG of model and tool tasks. Tasks have durable identity, status, dependencies and results; joins, races, cancellation and failure policies are kernel facts, not application bookkeeping. A turn can finish while its run still owns background work; later results arrive as kernel mail in the same conversation. A run can target several runners, each task recording its own target.

## HTTP, replay and realtime

HTTP owns commands, current state and retained event replay. Action Cable channels reduce latency: durable events with resource-scoped sequence numbers, a lifecycle filter, transcript deltas and ephemeral progress frames. Executors keep polling their inbox while subscribed; a `work_available` hint only brings the next scan forward. A durable follower drains HTTP replay from its saved cursor and merges live events by identity and sequence.

## Credential planes

One bearer resolves to exactly one plane, fixed when it was minted:

- **Member plane** (`/agent_api/v1`) — the acting user's data authority: profile, workspaces, conversations, runs, models, uploads, store, schedules.
- **Executor transport plane** (`/agent_api/v1/executor…`) — proof of one delivery address at one credential epoch: announcement, inbox, claims, commits, captures and progress.
- **Platform plane** (`/api/v1`) — human personal settings; `/api/v1/admin` additionally requires an active owner or administrator.

A credential presented to the wrong plane is refused with `401` and no explanation. See [Credentials and planes](../build/credentials-and-planes.md).

## Identity and persistence

Public identifiers are UUIDv7 strings. Business data persists in Nexus wherever possible: memory addresses database rows, opaque recovery state uses scoped stores, artifacts use uploads. Local files, processes and working directories belong to the runner. An agent's source, extensions and installed versions stay local to that installation; Nexus persists user documents, conversation and execution records and business data.
