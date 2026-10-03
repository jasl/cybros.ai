# Getting started

This guide starts Nexus and rho together on one Docker host and takes you through
your first conversation. Nexus stores conversations and manages model access;
rho supplies the agent and a runner for tools. The default runner works inside
the rho container.

If rho is already installed on a host, go to
[Connect a host installation](#connect-a-host-installation-to-nexus). For other
machine layouts, ports and service management, see [deployment](rho-deploy.md).

## Install the stack

You need Docker with Compose v2 already running and a copy of this repository.
Linux amd64 and arm64 and macOS Docker Desktop are supported. The installer pulls
the product images; it does not require Ruby or JavaScript on the host.

From the repository root:

```sh
sh install/stack/install.sh
```

Choose the installation directory, local or LAN access, and the browser ports.
The defaults are `~/.local/share/cybros`, Nexus at `http://localhost:3300` and rho
at `http://localhost:7777`. Keep the printed URLs when you select other ports or
a home-server address. The guided setup uses HTTP; use it on your own local
network, or configure your own TLS proxy as described in the
[stack guide](../install/stack/README.md#configuration-and-lan-access).

The installation directory contains private configuration and durable data.
It is separate from the source checkout. See the stack guide for
[unattended installation](../install/stack/README.md#install) and configuration
review without starting services.

## Create the account and connect rho

After startup, the installer continues into the interactive setup wizard.
Resume it at any time from the installation directory:

```sh
cd "$HOME/.local/share/cybros"
./cybros setup
```

Use your chosen directory if you changed the default.

1. Open the printed Nexus `/setup` URL. Read `NEXUS_SETUP_SECRET` from the private
   `secrets.env` file and create the first Human owner. No rho command creates
   the account or prints this secret. Cost tracking defaults to USD; choose
   **Advanced options** before creating the account if you need another unit.
   Nexus's Dashboard then links to provider settings and Agent connection.
   If the account already exists, use it.
2. Optionally sign in as a Human owner or administrator to configure a provider
   through cmctl. Keep existing credentials, save an API key, complete a supported
   subscription authorization, or enable a configured credentialless endpoint.
   You can select an existing provider or add a custom connection, discover or
   enter model IDs, and configure model limits and tool support. Settings saved
   in [Nexus administration](nexus-model-settings.md) are available here. Skip
   this section when the account is ready; if you do not administer it, ask its
   owner or administrator to enable a suitable provider and model.
3. Open the verification URL and approve the displayed device code in Nexus.
   rho saves its own Agent connection and, in full mode, its Runner connection.
4. Choose an available text-generation model that supports tool calls.
   Pricing and cost estimates are optional and separate from model availability.
   Selection makes no inference request. `RHO_DEFAULT_MODEL`, when set, overrides
   the saved default and must also name a usable model.
5. Optionally configure Telegram with a BotFather token and explicit numeric user
   and group allowlists. Setup checks the token with `getMe`; it does not start
   another update consumer or send a bot message. Let setup reload rho afterward.

Provider keys and subscription authorization belong to Nexus. The temporary
Human login is used only for setup; the wizard attempts to revoke it on exit
and prints recovery guidance if that fails. The daemon receives its own paired
device credentials, never that Human session.

One rho home (`RHO_HOME`) belongs to one installation and one Nexus. Setup asks
an unbound home for its Nexus address; an existing home retains its binding and
connection. The stack uses `http://nexus` inside Docker and its saved public URL
for browser links. Setup's `--public-url` changes displayed links only; it does
not change where credentials or API requests go.

The stack wrapper recreates only rho through Compose after saving settings.
Check the result:

```sh
./cybros status
./cybros rho status
./cybros rho models --workload text_generation
```

Service health and model discovery do not make a model request. The first
conversation below verifies actual inference and can incur provider charges.

## Open your first conversation

Open the rho browser URL displayed during installation. It is saved as
`CYBROS_RHO_URL` in the installation's `.env` and defaults to
`http://localhost:7777`. On the connection screen, enter
`RHO_ACCESS_PASSPHRASE` from the private `secrets.env` and choose **Unlock**.
Keep the passphrase private. After a daemon restart, unlock the page again.

Use this browser-reachable address when accessing a home server or a custom
port. A console link generated inside the container uses its internal bind
address and port; it may not be reachable from your browser.

Create a conversation, choose an available model and the stack's runner, and use
`/home/runner` as the working directory. Start with a small request such as:

> Tell me which working directory you can use. List its files without changing them.

Read the answer and tool results. Answer questions and review any tool approval
requests in the conversation. For a first file operation, use a disposable
directory and request a small file whose contents you can inspect.

The default `/home/runner` directory maps to `data/rho/work` under the installation
directory. To work on an existing host project, first configure its bind mount
and permissions using the [stack data guide](../install/stack/README.md#data-and-permissions).
To work on a different machine, connect a separate runner and select it. The
runner's directory does not confine shell commands or replace OS permissions.

Closing the page detaches the viewer; it does not stop work. Use **Stop** when
you want to stop the conversation's execution. Reopen a conversation to read its
durable history. Continue with [Using rho](rho-usage.md) for questions, approvals,
scheduled jobs, Telegram and noninteractive CLI runs.

## Connect a host installation to Nexus

Install rho using the [host installation guide](../install/README.md#rho-directly-on-the-host),
then run this in an interactive terminal, replacing the example with your Nexus
address:

```sh
rho setup --nexus-url https://nexus.example
```

Follow the account, provider, pairing and default-model steps above. `rho setup`
is available in full and agent modes. A runner-only installation uses
`rho connect` to pair and serves tools to another rho; it does not choose a model
or host a conversation UI.

Start the foreground server in one terminal, then use another terminal under
the same rho home. If a service manager already owns rho, restart that service
after setup changes instead of starting another server.

```sh
# Terminal 1
rho server

# Terminal 2
rho status
rho models --workload text_generation
rho console --open
```

The console command opens a link with a single-use code valid for 90 seconds.
Create a browser conversation with an available model and runner, and choose
a working directory on that runner. The browser lets you answer questions and
decide tool approvals. For a quick noninteractive text check, use
`rho run "Say hello"` or, in the stack, `./cybros rho run "Say hello"`.
This is a normal, potentially billed model request; a successful setup or model
listing alone does not prove inference.

## Finish Telegram setup

If you do not yet know your numeric user ID, save the bot token with an empty
user list, start rho, and send `/start` privately to the bot. It returns your ID
without admitting a model request. Finish with:

```sh
rho setup telegram --finish
```

Then restart the host service. The combined stack wizard handles its reload
and finish prompts; `./cybros setup telegram` reopens that section later.
Check `rho telegram status` or `./cybros rho telegram status` and send the first
message after your ID is allowed. See the
[Telegram guide](../agents/rho/rho-ingress-telegram/README.md) for group
participation, files, voice and access management.

A nonempty configured token environment variable overrides the saved token.
Setup reports that source without printing its value. Bot tokens belong in
the plugin's private token storage or the deployment's private environment;
do not put them in ordinary settings or command-line arguments.

## Rerun or recover

| Symptom | Next step |
| --- | --- |
| Setup was skipped or canceled | Rerun `rho setup` or `./cybros setup`. Earlier saved steps remain saved. |
| Nexus or rho is not healthy | Run `./cybros status` and `./cybros logs`; service-specific logs accept `nexus` or `rho`. |
| No usable text models | Check provider enablement, credentials, model visibility, limits and tool support in Nexus; run `rho setup model` or `./cybros setup model`. Prices may remain unset. |
| Change the default model | Run `rho setup model` or `./cybros setup model`, then restart the host service if needed. |
| The connection is missing, incomplete or revoked | Run `rho connect` or `./cybros connect` and complete the displayed browser flow. |
| The console code expired | Run `rho console` again, or unlock with the configured passphrase. |
| The browser session expired or the daemon restarted | In the stack, open the saved rho browser URL and unlock again; on a host, run `rho console` again. |
| A LAN browser cannot open the printed link | Check the saved public origins, bind address and host firewall using the stack LAN guide. |
| The agent is waiting | Open its conversation and answer the pending question or approval, or inspect the reported execution failure. |
| A project is absent from the runner | Check the selected runner and bind mount; container paths refer to the container's filesystem. |
| Telegram needs a token or access-list change | Rerun the Telegram section; it preserves routes, offsets and pending deliveries. |
| Stack settings saved but health failed | Inspect `./cybros logs rho`, then use `./cybros up`. |
| Stack deployment secrets are missing | Restore `secrets.env` from the deployment backup before starting; do not generate replacement encryption keys for existing data. |

The interactive installers enter setup after installation. Unattended installs,
`--yes`, and `--no-start` print the command to run later. Reinstallation preserves
the stack's `.env`, `secrets.env` and local Compose customizations. Setup saves
steps across services as it goes; an interruption does not undo earlier steps.

For deeper checks, see [rho troubleshooting](rho-usage.md#troubleshooting). Before
sharing logs, remove credentials, console links, private prompts and file contents.

## Where configuration lives

| State | Owner |
| --- | --- |
| Provider keys, subscription authorization and enabled models | Nexus |
| Agent and Runner connection, instance identity | rho home (`RHO_HOME`) |
| Default model and Telegram access settings | `RHO_HOME/settings.json` |
| Saved Telegram token | Private `RHO_HOME/telegram/token.json` |
| Conversation history, memory and schedules | Nexus |
| Working files and project dependencies | The selected runner's environment |

Preserve rho's home when upgrading the same installation. Use a new home for
each additional installation; copying a connected home duplicates its identity
and a later pairing can replace the original connection.

## Keep your data

Before upgrading, back up the complete stopped installation directory, including
`secrets.env`, the databases, uploaded bytes and rho state. Follow the
[backup and restore procedure](../install/stack/README.md#back-up-and-restore);
copying a live PostgreSQL directory is not a valid backup.

Pre-release schema changes may require a new database or an explicit migration.
Selecting an older image does not undo a database change. Keep a matching image
tag with the backup, and preserve separate backups for host projects mounted
outside the installation directory.
