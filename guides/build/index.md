# Build agents

Nexus runs the agent loop so that your application does not have to. You declare what the agent is — its tools, prompts, approval rules, model and hooks — and submit inputs; Nexus drives the model rounds, delivers tool calls to executors, parks calls for approval, compacts context, persists every turn and task, records usage and streams events back.

## What Nexus does for you

- Durable **conversations** with inputs, turns, candidate answers, forks and per-conversation access.
- A **round driver** that calls the model, expands tool calls into tasks, waits for results and continues, with retries, fallback models and failure policies.
- **Tool delivery** to the agent application, runners and tool providers through one inbox protocol with exclusive claims and write-once results.
- An **approval stage** every tool call crosses, evaluated from your rules against opaque tool input.
- **Compaction** when context will not fit, with the kernel's summarizer or your own.
- **Memory**, an opaque **store** and **uploads** as durable state.
- **Orchestration** primitives: delegated branches, child conversations, messages between conversations, waits, authored DAG steps and your own code tool.
- **Schedules**, **lifecycle hooks**, **usage** records and **retention**.

## What your application owns

- Prompt meaning and the system prompt, persona and summarizer documents.
- Model selection, fallback, reasoning settings and tiers.
- Which tools exist, what they mean, and the approval mode and rules that govern them.
- Orchestration strategy, memory extraction and ranking, user interface and external channels.

rho is one such application: an always-on personal agent and a coding agent, built only on these APIs. Your application can run beside it on the same Nexus with its own identity, prompts and rules, and rho's source is the worked example for every page in this section. [Build your own agent](../get-started/build-an-agent.md) orients a new integration; this section is the detail.

## Choose how deep to go

| You want to | Use |
| --- | --- |
| A conversation reply from a declared agent | A Workspace, a Conversation and an input with `kind: direct_reply` — see the [quickstart](quickstart.md) |
| A runnable application with connection, tool results and process recovery | [Run a standalone SDK Agent](standalone-agent.md) |
| Accepted work that continues after the application exits | [Run an Agent while its application is offline](offline-agents.md) |
| Tools that run on a machine | A [runner](../runners/index.md) selected for the conversation, with its tools declared on the agent |
| Tools your application serves itself | Announce them on the application's own executor address and claim them from its inbox |
| Parallel or delegated work | [Orchestration](orchestration.md): `delegate_task`, `spawn`, `send`, `wait`, authored steps or a `code` tool |
| A model call with no conversation | A [direct model call](direct-model-calls.md) |
| Work on a timer | [Schedules](schedules.md) or a queued input with `deliver_at` |

## The API families

| Family | Base path | Who calls it |
| --- | --- | --- |
| Agent API | `/agent_api/v1` | Agent applications on the member plane; runners, tool providers and applications on the executor transport plane |
| Platform API | `/api/v1` | Humans for personal settings; owners and administrators under `/api/v1/admin` |
| OAuth | `/oauth/*` | Application login and device connection |

Start with [Credentials and planes](credentials-and-planes.md), then the [quickstart](quickstart.md). The [SDKs](sdks.md) wrap the same endpoints with typed resources, credential rotation and durable event following.
