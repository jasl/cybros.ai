# Cybros

Cybros is a self-hosted agent system. **Nexus** provides the server-side kernel:
accounts, conversations, durable execution, model access, tools, approvals and
usage accounting. **rho** is its first agent application, with a browser
interface, Telegram integration, an ACP server and a command-line interface.
Runners execute tools on the machine or in the container where they are installed.

Source is available at [jasl/cybros.ai](https://github.com/jasl/cybros.ai).
Cybros follows a rolling release: source installations follow `main`, and the
Docker stack uses the published `latest` images. Interfaces and database schemas
can still change incompatibly. Back up an installation before upgrading and
check the [upgrade guidance](install/stack/README.md#status-logs-and-upgrades).

## Try it

With Docker and Compose v2 already running, run this in a terminal with `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh
```

The installer pulls Nexus and rho images, starts PostgreSQL and prints a private
rho console link. Open it, choose your rho access password, then follow rho's
link to create your Nexus owner account in a new tab. The setup secret is filled
automatically, and the bundled rho Agent and private Runner connect after account
creation. Return to rho Settings to continue. Linux
amd64 and arm64, including Docker Desktop on macOS, are supported without host
Ruby or JavaScript runtimes. Configure a model provider using your API key, a supported
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
Use the public source and guides at https://github.com/jasl/cybros.ai on main,
or my existing checkout. Follow the rolling installation instructions.

Read docs/getting-started.md and install/stack/README.md first. Check that Docker
is running and Compose v2 is available; help me resolve missing prerequisites.
Use the documented stack installer with local-only access and the default
installation directory unless I specify otherwise. Preserve existing settings
and data. In a noninteractive shell, pass --yes to the documented installer.
Open the private rho console link locally; for a remote deployment, give me the
ordinary rho URL and the command ./cybros instructions to generate a fresh private
link in my terminal. Guide me through choosing a rho access password, opening
Nexus account creation from rho, automatic pairing, and rho Settings.

Let me choose the rho password, create the Nexus account and enter provider
credentials directly in the browser. Keep private console and setup links and
other secrets out of chat and shared logs; no secrets.env lookup is needed.
The fresh bundled rho connects automatically. Existing removed or revoked
registrations require the ordinary manual reconnect and browser approval.
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
- [Rolling release workflow](docs/preview-release.md): verification and public source updates.

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
