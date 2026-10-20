# Cybros

Cybros is a self-hosted agent platform: a managed agent kernel you run on your
own machines, with an agent that is useful on day one.

- **Nexus**, the kernel, keeps one account of human and agent members, durable
  conversations and runs, a model gateway across providers, tool delivery to
  your machines, approvals, schedules, memory, usage accounting and retention.
- **rho**, the default agent, is an always-on personal assistant you talk to in
  a browser, in Telegram or from your editor, and a coding agent that works on
  your projects through a runner. It is built only on Nexus's public APIs, so it
  is also the reference for building your own agent.
- **Runners** execute tools where the files are — a workstation, a server, a
  container — and only ever dial out to Nexus.

It is built for professional users and small teams: install it on a laptop, a
LAN server or a public host, and bring your own model providers — API keys, a
supported subscription authorization, or a local server.

## Quick start

You need Docker with Compose v2 running, and `curl`. Linux amd64 and arm64 and
Docker Desktop on macOS are supported; no host Ruby or JavaScript runtime is
needed.

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh
```

The installer asks for an installation directory (default
`~/.local/share/cybros`), whether this is your own computer or a home server
reached from your LAN, and the ports (Nexus `3300`, rho `7777`). It pulls the
images, starts PostgreSQL, Nexus and rho, and prints rho's URL.

1. Open the rho URL and choose **Connect to Nexus**.
2. Create the first owner account. Nexus signs you in and continues the
   authorization; no setup secret is needed.
3. Approve rho. This connects its agent and its private runner and returns you
   to rho.
4. rho opens **Agents › rho** while a model is still missing. Follow the link to
   Nexus administration, add a provider with an API key, a subscription
   authorization or a local endpoint, and make a model visible.
5. Back in rho, create a conversation, choose the model and the stack's runner,
   use `/home/runner` as the working directory, and ask it to list the files
   there.

From the installation directory, `./cybros status` shows service health,
`./cybros instructions` repeats the URLs and setup steps, and `./cybros logs`
shows recent output. To let a coding agent do the installation for you, give it
the prompt in [Install with an agent](guides/get-started/install-with-an-agent.md).

## Documentation

The documentation site's source is under [`guides/`](guides/index.md).

| Section | Start with |
| --- | --- |
| Overview | [What is Cybros?](guides/overview/what-is-cybros.md), [core concepts](guides/overview/core-concepts.md), [architecture](guides/overview/architecture.md), [coming from managed agents](guides/overview/coming-from-managed-agents.md), [roadmap](guides/overview/roadmap.md) |
| Get started | [Install the stack](guides/get-started/install.md), [your first conversation](guides/get-started/first-conversation.md), [connect a host installation](guides/get-started/connect-a-host-installation.md), [build your own agent](guides/get-started/build-an-agent.md) |
| Use rho | [Conversations](guides/use/conversations.md), [approvals and questions](guides/use/approvals-and-questions.md), [schedules](guides/use/schedules.md), [sub-agents](guides/use/sub-agents.md), [Telegram](guides/use/telegram.md), [editors](guides/use/editors-acp.md), [plugins and code mode](guides/use/plugins-and-code-mode.md), [troubleshooting](guides/use/troubleshooting.md) |
| Operate | [Deployment layouts](guides/operate/deployment-layouts.md), [models and providers](guides/operate/models-and-providers.md), [members](guides/operate/members.md), [workspaces and access](guides/operate/workspaces-and-access.md), [retention, usage and budgets](guides/operate/retention-usage-budgets.md), [upgrades](guides/operate/status-logs-upgrades.md), [backup and restore](guides/operate/backup-and-restore.md), [cmctl](guides/operate/cmctl.md) |
| Build agents | [Overview](guides/build/index.md), [quickstart](guides/build/quickstart.md), [credentials and planes](guides/build/credentials-and-planes.md), [agents and configuration](guides/build/agents-and-configuration.md), [conversations and inputs](guides/build/conversations-and-inputs.md), [events and streaming](guides/build/events-and-streaming.md), [orchestration](guides/build/orchestration.md), [approvals and rules](guides/build/approvals-and-rules.md), [errors and recovery](guides/build/errors-and-recovery.md), [SDKs](guides/build/sdks.md) |
| Runners | [Overview](guides/runners/index.md), [quickstart](guides/runners/quickstart.md), [deploy a runner](guides/runners/deploy.md), [claims and results](guides/runners/claims-and-results.md), [tool providers](guides/runners/tool-providers.md), [security model](guides/runners/security-model.md) |
| Reference | [Agent API](guides/reference/agent-api.md), [Platform API](guides/reference/platform-api.md), [OAuth](guides/reference/oauth.md), [events](guides/reference/events.md), [statuses](guides/reference/statuses.md), [rate limits](guides/reference/rate-limits.md), [kernel tools](guides/reference/kernel-tools.md), [command line](guides/reference/cli.md), [glossary](guides/reference/glossary.md) |

## Development

| Directory | What it is | Verify with |
| --- | --- | --- |
| [`nexus/`](nexus/README.md) | The Rails kernel, model gateway and administration UI | `bin/setup`, `bin/dev`; `bin/ci` for the full local pipeline |
| [`agents/rho/`](agents/rho/rho/README.md) | rho: the daemon and CLI, the runner, the browser page, Telegram, ACP, MCP, browser tools, code mode | `bundle exec rake` in each gem |
| [`sdks/ruby/`](sdks/ruby/README.md) | `cybros_agent`, the Ruby SDK and agent framework | `bundle exec rake` |
| [`sdks/typescript/`](sdks/typescript/README.md) | `@cybros/agent`, the TypeScript and JavaScript server SDK | `pnpm install --frozen-lockfile`, `pnpm run check` |
| [`sdks/rust/`](sdks/rust/README.md) | `cybros-agent`, the async Rust SDK | `bin/ci` |
| [`cmctl/`](cmctl/README.md) | The human operator CLI for Nexus settings | `bundle exec rake` |
| [`install/`](install/README.md) | The host installer, Docker images and the combined stack | |
| [`e2e/`](e2e/README.md) | Cross-project journeys and evaluation tooling | `bundle exec rake` |
| [`guides/`](guides/index.md) | The documentation site (VitePress, built with Bun) | `bun install`, `bun run dev`, `bun run build` |
| [`docs/`](docs/README.md) | The internal development manual | |

Prerequisites for working on the Ruby projects: Ruby 4.0 (see `.ruby-version`),
PostgreSQL 17 with pg_uuidv7 (or PostgreSQL 18+) and libvips for Nexus, plus Bun
for Nexus assets and the documentation site. `nexus/bin/setup` installs dependencies and prepares the
databases; `nexus/bin/dev` runs the web server, the job workers and the asset
watchers. Agent instructions for this repository are in [`AGENTS.md`](AGENTS.md).

Cybros follows a rolling release: source installations follow `main`, and the
Docker stack uses the published `latest` images. Interfaces and database schemas
can still change incompatibly; back up an installation before upgrading. See
[Release and compatibility](guides/overview/release-and-compatibility.md).

## License

The repository defaults to [MIT](LICENSE.md). Nexus has its own
[O'Saasy license](nexus/LICENSE.md); subdirectory and third-party licenses take
precedence for their contents.
