# Coming from managed agents

Claude Managed Agents and the OpenAI Agents API run an agent harness in the vendor's cloud; you send input and optionally attach an environment. Cybros runs the same kind of harness on your own infrastructure and splits it in two: Nexus provides the mechanisms, your agent (or rho) provides the policy. This page maps the vocabulary.

## Concept map

| Hosted platforms | Cybros | Notes |
| --- | --- | --- |
| Agent (model, system prompt, tools, MCP servers, skills; versioned) | [Agent configuration](../build/agents-and-configuration.md), or an application's reusable Agent Preset | Configuration has no member identity. A Cybros Agent is the durable member that uses it. Inline configuration is captured at input acceptance; standing defaults are captured when the turn materializes. |
| Environment (cloud sandbox or self-hosted sandbox / worker) | [Runner](../runners/index.md) | Always self-hosted. A runner polls its inbox over outbound HTTP exactly like a self-hosted environment worker. There is no cloud sandbox and no `environment` resource; environment facts are announced by the runner. |
| Session | [Conversation](../build/conversations-and-inputs.md) plus the [Runs](../build/orchestration.md) backing its turns | The person's unit and the execution unit are separate resources. Cybros's Platform API Session is a Human login credential. |
| Events (SSE stream of user/agent/tool/status events) | Inputs, turns, variants and three feeds: durable events with replay cursors, transcript deltas, progress frames | HTTP is the source of truth; the cable is a latency hint. See [Events and streaming](../build/events-and-streaming.md). |
| Send a user message | `POST …/inputs` with `kind: direct_reply` | `kind: message` records speech without starting a reply. |
| Steer or interrupt | `delivery_mode: steer` or `steer_now`; Stop | `steer_now` inserts a model boundary ahead of pending tools without canceling them. |
| Permission policy per toolset (`always_allow`, `always_ask`, `auto`) | Approval mode (`bypass`, `ask`, `rules`) plus agent-authored [approval rules](../build/approvals-and-rules.md) | Rules are globs over opaque tool input; the kernel never interprets a tool's arguments. |
| Scheduled deployments | [Schedules](../build/schedules.md) | `once`, `interval` or `daily`; each occurrence runs in a child conversation and reports back. |
| Subagents, multi-agent orchestration, programmatic tool calling | `delegate_task`, `spawn`, `send`, `wait`, authored DAG steps, and the agent's `code` tool | Waiting, lifetime and wake are independent choices. See [Orchestration](../build/orchestration.md). |
| Memory stores mounted in the sandbox | [Memory](../build/memory-store-and-uploads.md) documents in Nexus, read and written through tools | Separate from working files and from the opaque store. |
| Files and artifacts | Uploads and executor captures with resource links | Bytes are read over HTTP with range support. |
| Skills | Documents served by a runner or the kernel and loaded with the `skill` tool | |
| Session budgets | Account cost unit, member budgets and agent allowances | Admission guards, administered per member. See [Usage and cost](../build/usage-and-cost.md). |
| Vaults for MCP or sandbox secrets | Provider and Nexus-managed MCP credentials in Nexus; executor-hosted tool credentials stay with the executor | The component making the outbound call holds its credentials. |
| Webhooks | Not provided | Nexus never dials out to an application. Use the cable plus HTTP replay; see [Events and streaming](../build/events-and-streaming.md). |
| Multi-language SDKs | Ruby SDK today | The HTTP contract is primary; see [SDKs](../build/sdks.md) and the [roadmap](roadmap.md). |

## What is different on purpose

**The harness is yours.** The loop, the sandbox protocol and the data all run in your installation. Nothing about a conversation leaves it except the model requests you configured.

**Mechanism and policy are separate.** A hosted platform exposes one agent object with a fixed harness. In Cybros the kernel drives the loop and persists every task, while the application declares what the tools mean, which model answers, and what needs a person's approval. Two applications can run on one Nexus with different policies.

**Models are a gateway, not a vendor.** Nexus resolves a model reference to one of the providers an administrator configured: an API-key provider, a subscription authorization or a local server. Fallback models, reasoning effort and prompt-format adaptation are per-model settings.

**Execution is multi-environment.** One run can call tools on several runners, each task recording its target. Runner effects are recorded per runner so a rewind restores each one independently.

**Members, not API keys.** People and agents are members of one account with stewards, workspace ownership and per-conversation access levels, rather than API keys with project scopes.

## What you will miss, and what replaces it

| Missing | Replacement |
| --- | --- |
| Cloud sandbox | The stack's in-container runner, a runner on a host or a separate runner container. Desktop runners are on the [roadmap](roadmap.md). |
| Webhooks | Durable event replay with cursors plus cable subscriptions. |
| Per-session budget | Member budgets and agent allowances at admission; an application can enforce finer limits from usage reads. |
| An addressable agent version number | Per-turn freezing of the declaration plus prompt document versions. |
| Vault | Keep executor-hosted tool credentials with the executor that uses them; provider and Nexus-managed MCP credentials live in Nexus as write-only settings. |
