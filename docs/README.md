# Cybros technical manual

Cybros combines Nexus, the server-side agent kernel, with agent applications,
runners and tools providers. This manual describes the implemented interfaces
and operating procedures. Start with the guide for what you want to do;
component READMEs provide local development and extension details.

## Start using Cybros

| Task | Guide |
| --- | --- |
| Install, configure account/provider access, pair rho and start a first conversation | [Getting started](getting-started.md) |
| Use conversations, tools, approvals, scheduled jobs and CLI runs | [Using rho](rho-usage.md) |
| Install on a local computer or LAN server | [Combined Docker stack](../install/stack/README.md) |
| Connect a host installation of rho to an existing Nexus | [Host installation](../install/README.md#rho-directly-on-the-host) |
| Choose daemon modes, containers and separate runners | [rho deployment](rho-deploy.md) |
| Use the browser interface | [rho WebUI](../agents/rho/rho-webui/README.md) |
| Use Telegram | [Telegram extension](../agents/rho/rho-ingress-telegram/README.md) |
| Connect an ACP client | [rho ACP server](../agents/rho/rho-acp/README.md) |

## Operate an installation

- [Model settings](nexus-model-settings.md): provider connections, model definitions, visibility and optional pricing.
- [cmctl](../cmctl/README.md): Human operator login and terminal administration.
- [Human member onboarding](member-onboarding.md): invitations, expiry, email delivery and temporary passwords.
- [Human member recovery](member-recovery.md): email reset, deployment-local recovery and credential invalidation.
- [Stack operations](../install/stack/README.md#status-logs-and-upgrades): service status, logs, image updates and database compatibility.
- [Backup and restore](../install/stack/README.md#back-up-and-restore): complete installation data, secrets and retention.
- [Nexus setup and deployment](../nexus/README.md): standalone server setup, environment and workers.
- [Build and publish images](../install/docker/README.md): build targets, platforms and release tags.

## Components and ownership

| Component | Responsibility | Start here |
| --- | --- | --- |
| Nexus | Accounts, workspace and conversation access, durable history, DAG execution, task delivery, model invocation, approvals, and usage accounting | [Nexus setup and deployment](../nexus/README.md) |
| Agent application | Product prompts, model selection, and product behavior through the kernel's APIs | [Ruby SDK](../sdks/ruby/README.md), [rho](../agents/rho/rho/README.md) |
| Runner | Tools associated with a conversation's execution environment, including files, shell commands, and processes | [rho runner](../agents/rho/rho-runner/README.md) |
| Tools provider | Separately registered tools addressed by name; several providers can be available to a workspace | [Executor protocol](agent-api/v1/executor.md) |
| Client | Human interaction with an agent application through its supplied interfaces | [Using rho](rho-usage.md), [ACP server](../agents/rho/rho-acp/README.md), [ACP client](../agents/rho/rho-acp-client/README.md) |

One Account contains human and agent members, runners, and tools providers.
Workspace and conversation access determine what those members can read and
change. They are collaboration controls within that account; there is no
separate tenant-isolation layer. An agent is a member identity, while a
TaskExecutor is an address to which Nexus delivers work. A program may hold
both identities through separately authenticated credentials.

A conversation holds inputs, turns, and history. A reply can run a DAG of
model and tool tasks; dependencies, joins, cancellation, and durable task
state let Nexus track concurrent work. Agent applications select policy while
Nexus owns the execution lifecycle. Conversations can fork history, accept
steering input, delegate to child conversations, and exchange messages under
their access rules.

A conversation has at most one bound runner; changing it uses the handoff
protocol. Assigning filesystem and other environmental side effects to that
runner is a convention, not a sandbox: an agent or ordinary tools provider can
also implement tools with side effects. Executor polling is the work-delivery
and recovery path. Action Cable adds notifications and streaming; durable
event replay recovers persisted events, while progress frames are ephemeral.

## Integrate with the kernel

Start with [Your first Agent API integration](agent-api/getting-started.md) for
credentials, workspace selection and a first request. Then use the references
for the contract you are implementing.

In the Nexus browser, **Agents → Connect agent** and **Runners → Connect runner**
open the existing device-code ceremony. Start the program first, then enter the
code it displays. These links do not create registrations by themselves.

Use **Workspaces → New workspace** to create a named workspace you own. **Private**
is selected by default and gives access to you and your agents. Select
**Account-wide** explicitly to let other members and their agents use its data;
you remain the only settings manager. Agent programs can also create their own
dedicated workspaces. Creating one does not establish a global default workspace.

- [Orchestration and task lifetime](orchestration.md): choosing tasks or child conversations, waiting, background mail, DAG composition, and current limits.
- [Lifecycle hooks](lifecycle-hooks.md): turn start, compaction, and bounded continuation before a natural stop.
- [Device flow and credential lifecycle](oauth/device-flow.md): pairing, refresh, and revocation.
- [Agent API](agent-api/v1.md): Agent work, member resources and executor delivery.
- [Platform API](platform-api/v1.md): Human personal settings and administrator system settings.
- [Conversations](agent-api/v1/conversations.md): access, inputs, turns, history changes, and events.
- [Agent loops](agent-api/v1/agent_loops.md): DAG authoring, kernel tools, and task lifecycle.
- [Executor protocol](agent-api/v1/executor.md): discovery, tool announcements, claims, results, and handoff.
- [Profiles](agent-api/v1/profile.md): model settings, tools, approvals and context policy.
- [Scheduled jobs](agent-api/v1/scheduled-jobs.md): delayed and recurring work with separate execution conversations.

## Extend rho

- [rho configuration and CLI reference](../agents/rho/rho/README.md)
- [Browser tools](../agents/rho/rho-browser/README.md)
- [MCP tools](../agents/rho/rho-mcp/README.md)
- [Web tools](../agents/rho/rho-web-tools/README.md)
- [Browser interface](../agents/rho/rho-webui/README.md)
- [ACP client tools](../agents/rho/rho-acp-client/README.md)
- [Developer console](../agents/rho/rho-dev/README.md): checkout-only conversation commands, excluded from shipped installations.

## Develop, verify and release

- [Nexus development](../nexus/README.md#development) and the owning package READMEs: local runtimes and component checks.
- [E2E verification](../e2e/README.md): GitHub smoke, full local acceptance and explicit installation journeys.
- [Evaluation runbook](evals-runbook.md): local gates, optional paid runs, artifacts and result interpretation.
- [Container evaluations](evals-containers.md): Agents-on-Rails, Terminal-Bench and installation journeys.
- [Preview release preparation](preview-release.md): real-use evidence, backlog review, public source review and repository migration.

The [Terminal-Bench archive report](evals/terminal-bench-2026-09-18.md)
describes a dated run on a selected task subset, including its evidence limits.
It is historical measurement, not qualification of the current checkout.
Use the runbook to reproduce a measurement and keep its source revision,
configuration, artifacts, and results together.
