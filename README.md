# Cybros

Cybros is a self-hosted agent system. **Nexus** provides the server-side kernel:
accounts, conversations, durable execution, model access, tools, approvals and
usage accounting. **rho** is its first agent application, with a browser
interface, Telegram integration, an ACP server and a command-line interface.
Runners execute tools on the machine or in the container where they are installed.

This is the development repository. The public preview destination is
[jasl/cybros.ai](https://github.com/jasl/cybros.ai); that address is provisional.
Until the reviewed source snapshot is published there, run the commands below
from a development checkout. Interfaces and database schemas can still change
incompatibly. Back up an installation before upgrading and read the release's
data-migration instructions.

## Try it

With Docker and Compose v2 already running, execute this from the repository root:

```sh
sh install/stack/install.sh
```

The installer pulls Nexus and rho images, starts PostgreSQL and guides you through
account creation, provider configuration and device pairing. It supports Linux
amd64 and arm64, including Docker Desktop on macOS, without host Ruby or JavaScript
runtimes. Configure an available model provider using your API key, a supported
subscription authorization, or a credentialless endpoint.

Follow [Getting started](docs/getting-started.md) through your first conversation.
Use the [stack guide](install/stack/README.md) for LAN access, persistent data,
updates and backups. To run rho against an existing Nexus on another machine,
see the [host installer](install/README.md#rho-directly-on-the-host) or
[rho deployment guide](docs/rho-deploy.md).

### Install with an agent

Give this prompt to Codex or another coding agent with terminal access to the
machine where you want to run Cybros:

```text
Help me install Cybros (Nexus + rho) on this machine and reach my first conversation.
Use my existing checkout, or https://github.com/jasl/cybros.ai once its source is
published. If no source is available, ask me for a checkout path.

Read docs/getting-started.md and install/stack/README.md first. Check that Docker
is running and Compose v2 is available; help me resolve missing prerequisites.
Use the documented stack installer with local-only access and the default
installation directory unless I specify otherwise. Preserve existing settings
and data. In a noninteractive shell, use sh install/stack/install.sh --yes, then
guide me through ./cybros setup from the installation directory.

Let me create the account, enter provider credentials and approve device pairing
directly in the setup terminal or browser; keep secrets out of chat and logs.
Check service health, rho's connection and available models as setup progresses.
Give me the installation directory and saved browser URLs, and walk me through
the first-conversation guide. Report any remaining steps clearly; service health
alone does not prove that a model request works.
```

## Use and extend

- [Technical manual](docs/README.md): installation, daily use, operations and API reference.
- [Using rho](docs/rho-usage.md): conversations, runners, approvals, schedules and troubleshooting.
- [Model settings](docs/nexus-model-settings.md): provider connections, model visibility and optional pricing.
- [Build an agent integration](docs/agent-api/getting-started.md): identity, API calls and execution ownership.
- [Ruby SDK](sdks/ruby/README.md): API clients and agent framework.
- [Local verification](e2e/README.md) and [evaluation runbook](docs/evals-runbook.md).
- [Preview release preparation](docs/preview-release.md): readiness, source review and a fresh public repository.

## Repository layout

| Directory | Responsibility |
| --- | --- |
| [`nexus/`](nexus/README.md) | Rails kernel, model gateway and Human administration UI |
| [`agents/rho/`](agents/rho/rho/README.md) | rho daemon, clients, runner and extensions |
| [`sdks/ruby/`](sdks/ruby/README.md) | `cybros_agent` Ruby SDK |
| [`cmctl/`](cmctl/README.md) | Human operator CLI for Nexus settings |
| [`install/`](install/README.md) | Host installer, Docker images and combined stack |
| [`e2e/`](e2e/README.md) | Cross-project tests and evaluation tooling |
| [`docs/`](docs/README.md) | Technical manual |

An installation has one Account containing its human and agent members, runners
and tools providers. Workspace access controls support collaboration within that
account. A runner's working directory is an execution setting, not a filesystem
sandbox; give a runner the host permissions and mounts appropriate for its work.

## License

The repository defaults to [MIT](LICENSE.md). Nexus has its own
[O'Saasy license](nexus/LICENSE.md); subdirectory and third-party licenses take
precedence for their contents.
