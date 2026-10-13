# Install the stack

The combined Docker stack installs Nexus, PostgreSQL and a full-mode rho on one Docker host. rho supplies the agent and a runner for tools; the default runner works inside the rho container. Linux amd64 and arm64 and macOS Docker Desktop are supported. The installer pulls published images and needs no Ruby or JavaScript on the host.

## Prerequisites

- Docker with Compose v2, already installed and running. The installer checks for it and never installs Docker or runs `sudo`.
- `curl`.

## Run the installer

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh
```

The installer asks for:

1. **Installation directory** — configuration and persistent data live together here. Default `~/.local/share/cybros`.
2. **Where you will use it** — this computer, or a home server reached from another device on your local network. For a home server, enter the hostname or IPv4 address your browser will use.
3. **Ports** — Nexus defaults to `3300`, rho to `7777`.
4. **Review** — check the directory and the browser URLs before installation starts.

It then creates private configuration, pulls the images, prepares the database and waits for Nexus and rho to report healthy. Keep the printed URLs if you chose other ports or a LAN address.

::: tip Options
`--dir DIRECTORY` chooses the directory on the command line. `--yes` accepts defaults without questions (required for a fresh installation without a terminal). `--no-start` writes configuration without pulling images; run `./cybros up` later. Re-running the installer preserves `.env`, `secrets.env`, `compose.yaml` and the management script.
:::

Guided setup uses HTTP. Use it on your own local network, or put your own TLS proxy in front of it.

## Create the account and connect rho

Open the rho URL the installer printed and choose **Connect to Nexus**. To show the URLs and the browser steps again:

```sh
cd "$HOME/.local/share/cybros"
./cybros instructions
```

1. rho opens Nexus login and authorization. A new installation first asks you to create the Account and keeps rho's authorization request waiting. No setup secret or terminal step is needed by default.
2. Create the first human owner. Nexus signs you in and continues the authorization. Cost tracking defaults to USD; open **Advanced options** on this form if you need another unit, because it cannot be changed later.
3. Approve rho. This binds a new rho instance to your Human account and connects its Agent and bundled Runner. That Runner is reserved for this rho instance; another rho you manage cannot discover or use it. Later logins by the same Human reuse the binding; another Human cannot take the instance over. Nexus returns to rho automatically. There is no separate rho password.
4. rho shows a setup notice while a model still needs configuration. Open **Settings › Defaults › Default model**, then follow the model setup link to Nexus administration. Configure a provider with an API key, a supported subscription authorization or a credentialless endpoint, and make a model visible. See [Models and providers](../operate/models-and-providers.md).
5. Return to rho. The model setup keeps a valid saved default model, selects a sole eligible model, or asks you to choose. The stack's runner and base tools are already available.

**Use a device code** is an alternative login for terminals and browsers that cannot complete the callback: finish first boot in Nexus if needed, choose **Continue after setup**, open the verification link, check the code and approve.

Provider credentials stay in Nexus. rho receives OAuth authority for the signed-in human separately from its Agent and Runner credentials and never sees your password.

## Check the result

```sh
./cybros status
./cybros rho status
./cybros rho models --workload text_generation
```

Service health and model discovery do not make a model request. Your first conversation is the real check, and it can incur provider charges.

Optional terminal setup: `./cybros setup` offers provider configuration, a saved default model and Telegram through the same human login, and `./cybros setup model` or `./cybros setup telegram` run one section. The running daemon applies saved settings immediately.

## Where configuration lives

| State | Owner |
| --- | --- |
| Provider keys, subscription authorization and model visibility | Nexus |
| Agent and Runner connection, instance identity | rho home (`data/rho/home`) |
| Default model and Telegram access settings | rho's private `settings.json` |
| Conversation history, memory and schedules | Nexus |
| Working files and project dependencies | The selected runner's environment (`data/rho/work` for the stack runner) |

Preserve rho's home when upgrading the same installation. Copying a connected home duplicates its identity, and a later pairing can replace the original connection.

## Next

- [Your first conversation](first-conversation.md)
- [Install with an agent](install-with-an-agent.md) if you would rather have a coding agent do the above
- [Deployment layouts](../operate/deployment-layouts.md) for separate runners, hosts and containers
- [Build your own agent](build-an-agent.md) when rho is not the agent you want, or you want to add one beside it
