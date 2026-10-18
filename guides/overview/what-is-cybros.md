# What is Cybros?

Cybros is a self-hosted agent platform. Its kernel, **Nexus**, provides what hosted agent platforms provide — durable sessions, an agent loop with tool execution, context compaction, approvals, scheduling, multi-agent orchestration and usage accounting — as software you deploy on your own infrastructure. **rho**, the agent that ships with it, makes an installation useful on day one and shows what a product built on Nexus looks like.

## Who it is for

Cybros targets professional users and small teams who want a managed agent platform under their own control:

- **Private deployment.** Install on a workstation, a home server, an office network or a public host. Conversations, files, provider credentials and usage records stay in your installation.
- **Your models.** Connect model providers with API keys, a supported subscription authorization or a credentialless local endpoint. Nexus is a gateway across providers, not a single-vendor runtime.
- **Your machines run the tools.** Runners execute shell commands, file operations and other tools on the hosts you choose. A runner needs only outbound access to Nexus.
- **One account, trusted members.** An installation is one Account containing human and agent members, runners and tool providers. Workspace access controls organize collaboration inside that account; there is no multi-tenant layer.

A hosted service built on the same kernel remains possible; the current product is the self-hosted installation.

## rho: the default agent

rho is the agent most installations will use, and for most people it is the product. It combines two shapes that are usually separate products:

- **A personal agent.** Always on, reachable from a browser page, Telegram or an editor. It keeps memory across conversations, runs scheduled jobs, asks questions and requests approval when it should, and reports back later when background work finishes.
- **A coding agent.** It works on real projects through a runner — files, shell, processes, a browser, MCP servers — and is held to the coding capability standard of Claude Code and Codex. Code mode lets it orchestrate tools and model calls with JavaScript instead of one call per round.

rho is an ordinary agent application: it holds an Agent identity in your account, pairs through the same device flow any program uses, declares its tools and approval rules through the Agent API, and serves its own tools through the executor inbox. Nothing in Nexus is reserved for it. That makes rho the reference implementation for building your own agent — every mechanism these guides describe has a working, shipped use in rho's source.

## rho and Nexus

| | Nexus owns | rho owns |
| --- | --- | --- |
| State | Accounts and members, workspaces, conversations, turns, runs and tasks, memory documents, schedules, uploads, usage, retention | Its settings, its credential lineages, its plugins and their private data |
| The loop | Prompt assembly, model rounds, expanding tool calls into tasks, compaction, failure policies, fallback models | The system prompt and persona, which model answers by default, when to use code mode |
| Tools | Delivery to executors, exclusive claims, deadlines, write-once results, the approval stage | Which tools exist (coding tools, web fetch, browser, MCP, delegation), what they mean, the approval rules that govern them |
| Models | The provider gateway: catalog, credentials, visibility, reasoning controls, usage records | Selecting a model per conversation or request |
| People | Human login, workspace and conversation access, stewards and managers, administration | The browser page, Telegram, the ACP server for editors, the CLI |

The split is deliberate. Nexus implements general mechanisms without knowing what `bash` means or which model a product prefers; an agent application declares its tools, prompts and rules and lets the kernel run them. Two applications with different policies can run on one Nexus, and their conversations share the account's workspaces under the same access rules.

## The default bundle

The Docker stack — Nexus, PostgreSQL and rho in full mode on one host — is the default bundle. rho's full mode runs the agent application and a private runner in one process, so the bundle works on files inside its container out of the box; add runners on other machines when the work lives there. [Install the stack](../get-started/install.md) is that path.

## Build on it

Everything rho does, your application can do: connect, declare an agent, drive conversations, serve tools, follow events. Start with [Build your own agent](../get-started/build-an-agent.md). [Ruby, TypeScript and Rust SDKs](../build/sdks.md) are available as source packages in the repository; the HTTP contract is documented for any other language.

## How it compares

If you know Claude Managed Agents or the OpenAI Agents API, Cybros has the same skeleton: a reusable agent configuration, an execution environment, a durable session with steering and interruption, an event stream, permission policies, scheduled runs and subagents. The differences are where things run and who owns policy. [Coming from managed agents](coming-from-managed-agents.md) maps the vocabulary.

## Status

Cybros follows a rolling release. Source installations follow `main`; the Docker stack uses the published `latest` images. Interfaces and database schemas can still change incompatibly, so back up an installation before upgrading. See [Release and compatibility](release-and-compatibility.md).

Nexus is licensed under the O'Saasy license; the rest of the repository defaults to MIT.
