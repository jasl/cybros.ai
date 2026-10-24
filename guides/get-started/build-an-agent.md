# Build your own agent

[Install the stack](install.md) gives you Nexus with rho, the default agent. This page is the other starting point: you want an agent with your own prompts, interface or channel, you want to embed Nexus in a product, or you want to add tools from your own machines or services.

## What you need

- A running Nexus. The stack from the previous pages is fine; rho stays installed and is useful to compare against.
- An owner or administrator login, and at least one usable text model configured under [Models and providers](../operate/models-and-providers.md).
- A Human steward who can issue an Agent API key or approve your program's OAuth connection.

## Choose the shape

| You are building | What it holds | Start here |
| --- | --- | --- |
| An **agent** — a product that talks to people and answers as an Agent | A member credential (the Agent's identity) and a transport credential (its own tool inbox) | [Build agents quickstart](../build/quickstart.md) |
| A **runner** — tools bound to a machine or container | A transport credential only | [Runner quickstart](../runners/quickstart.md) |
| A **tool provider** — tools served by name from a pool | A transport credential only | [Tool providers](../runners/tool-providers.md) |
| A **direct model integration** — model calls through the gateway, no conversation | An agent's member credential | [Direct model calls](../build/direct-model-calls.md) |

An agent can also implement a runner for its own machine: its application address
announces both services through one transport credential. This works with your own
implementation in any language; rho and `rho-env` are optional. See
[Implement a Runner in your Agent](../runners/index.md#implement-a-runner-in-your-agent).

## Choose a language

| | Status | What you get |
| --- | --- | --- |
| **Ruby** — `cybros_agent` | Available | Device connection and credential rotation, every member and executor resource, durable event following, typed step authoring, an optional realtime module. rho is built on it. |
| **JavaScript / TypeScript** — `@cybros/agent` | Source package | Typed async clients for Node.js; see [TypeScript SDK](../build/sdk-typescript.md). |
| **Rust** — `cybros-agent` | Source crate | Typed async clients on Tokio; see [Rust SDK](../build/sdk-rust.md). |
| **Any other language** | Through the HTTP contract | Bearer authentication, JSON envelopes, idempotency keys, opaque cursors and a documented durable-follower procedure. See the [reference](../reference/index.md). |

See [SDKs](../build/sdks.md).

For an independently runnable example, [run the standalone TypeScript
Agent](../build/standalone-agent.md). It connects, serves a tool, recovers an
accepted execution after process exit and downloads its results.

## The path

1. **Connect.** Use an Agent API key issued by its Human steward, or choose a stable installation identifier and complete the OAuth device flow. Store credentials privately. [Credentials and planes](../build/credentials-and-planes.md)
2. **Declare the agent.** One atomic write of tools, approval mode and rules, prompt mechanism, compaction policy, models and hooks, plus the agent's prompt documents. [Agents and configuration](../build/agents-and-configuration.md)
3. **Converse.** Create or reuse a workspace, create a conversation, submit an input, follow it to the settled answer over HTTP, then add the cable for latency. [Quickstart](../build/quickstart.md), [Events and streaming](../build/events-and-streaming.md)
4. **Serve tools.** Announce what your executor serves, claim calls from its inbox, commit results, publish captures. [Claims and results](../runners/claims-and-results.md)
5. **Decide with people.** Surface approvals and questions from your inbox in your own interface. [Approvals and rules](../build/approvals-and-rules.md)
6. **Go further.** Delegation and subagents, schedules, lifecycle hooks, memory and store, direct model calls. [Build agents](../build/index.md)

## Learn from rho

rho uses only the public APIs, so its source is a complete worked example. The repository is [jasl/cybros.ai](https://github.com/jasl/cybros.ai); rho lives under `agents/rho/`.

| You need | Where rho does it |
| --- | --- |
| Device pairing, credential storage and rotation, the settings file | `rho` — the daemon core and CLI |
| Following conversations, rendering streamed answers, approvals and questions in a UI | `rho-webui` — plain browser modules over the daemon's control API |
| The inbox claim loop, file and shell tools, checkpoints, process management | `rho-env` |
| Orchestrating tools and model calls from JavaScript (programmatic tool calling) | `rho-codemode` |
| An external channel as an ingress: consent, routing, delivery | `rho-ingress-telegram` |
| MCP servers as tools, with OAuth login | `rho-mcp` |
| Reading the web safely from a runner | `rho-web-tools` |
| Serving an editor over a standard protocol, and delegating to other agents | `rho-acp`, `rho-acp-client` |
| Delegating a coding assignment to another harness | `rho-t3` |

Your application does not have to look like rho. A chat bot with no runner, a workflow service with no conversation interface, or a second agent beside rho with a different persona and stricter rules are all ordinary agents on the same Nexus.
