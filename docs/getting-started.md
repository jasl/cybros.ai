# Getting started

This guide starts Nexus and rho together on one Docker host and takes you through
your first conversation. Nexus stores conversations and manages model access;
rho supplies the agent and a runner for tools. The default runner works inside
the rho container.

If rho is already installed on a host, go to
[Connect a host installation](#connect-a-host-installation-to-nexus). For other
machine layouts, ports and service management, see [deployment](rho-deploy.md).

## Install the stack

You need Docker with Compose v2 already running and `curl`.
Linux amd64 and arm64 and macOS Docker Desktop are supported. The installer pulls
the product images; it does not require Ruby or JavaScript on the host.

Download and run the installer from the public repository:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh
```

Choose the installation directory, local or LAN access, and the browser ports.
The defaults are `~/.local/share/cybros`, Nexus at `http://localhost:3300` and rho
at `http://localhost:7777`. Keep the printed URLs when you select other ports or
a home-server address. The guided setup uses HTTP; use it on your own local
network, or configure your own TLS proxy as described in the
[stack guide](../install/stack/README.md#configuration-and-lan-access).

The installation directory contains private configuration and durable data.
No source checkout is needed. See the stack guide for
[unattended installation](../install/stack/README.md#install) and configuration
review without starting services.

## Create the account and connect rho

After startup, open the private rho console link printed by the installer. Its
single-use code expires after 90 seconds. To generate a fresh link, run this from
the installation directory:

```sh
cd "$HOME/.local/share/cybros"
./cybros instructions
```

Use your chosen directory if you changed the default.

1. Open the printed rho link and choose a rho access password with at least
   eight characters. Save it for later visits to the ordinary rho URL. This
   password is independent of your Nexus account password; you do not need to
   read `secrets.env`.
2. Follow rho's link to open Nexus account creation in a new tab. The page fills
   the setup secret automatically; create the first Human owner yourself. Keep
   the link private until setup is complete. Cost tracking defaults to USD;
   choose **Advanced options** before creating the account if you need another
   unit. If the account already exists, this step is skipped.
3. Return to rho. The installer's background helper detects the account and
   pairs its bundled rho Agent and private
   Runner under the first owner. No separate device-code approval is needed for
   this first connection. It leaves existing connections in place and never
   automatically restores a removed Agent or replaces revoked credentials.
4. rho opens **Settings** when the connection is ready. If you want Telegram,
   configure the bot and bind your numeric owner ID.
   This works before a model is configured; `/start` returns your ID.
5. Follow the model setup TODO to [Nexus administration](nexus-model-settings.md).
   Keep existing credentials, save an API key, complete a supported
   subscription authorization, or enable a configured credentialless endpoint.
   You can select an existing provider or add a custom connection, discover or
   enter model IDs, and configure model limits and tool support. Skip
   this section when the account is ready; if you do not administer it, ask its
   owner or administrator to enable a suitable provider and model.
6. Return to rho Settings. It discovers available text-generation models with
   tool calls, keeps a valid saved default, automatically selects a sole model,
   or asks you to choose among several. The stack's own runner and base tools
   are ready automatically; further settings are available on the same page.
   Pricing and cost estimates are optional and separate from model availability.
   Selection makes no inference request.

Provider keys and subscription authorization belong to Nexus. rho stores its own
Agent and Runner credentials and receives no Human password or Nexus session.
If automatic pairing has not finished, inspect `./cybros logs setup`. A service
failure can be retried with `./cybros up`; an existing registration needing
reconnection requires `./cybros connect` and ordinary browser approval.

One rho home (`RHO_HOME`) belongs to one installation and one Nexus. The stack
uses `http://nexus` inside Docker and its saved public URL for browser links.

Check the result from the installation directory:

```sh
./cybros status
./cybros rho status
./cybros rho models --workload text_generation
```

Service health and model discovery do not make a model request. The first
conversation below verifies actual inference and can incur provider charges.

For an optional terminal workflow, run `./cybros setup`. It offers provider
configuration, a saved default model and Telegram. Its Human login stays in the
setup process and is revoked on exit; saved settings survive interruption.
`./cybros setup model` configures the CLI default model, and
`./cybros setup telegram` configures messaging. The running daemon applies saved
settings immediately. Environment variables such as `RHO_DEFAULT_MODEL` supply
initial values; saved settings override them, and explicit launch flags take
precedence on startup.

## Open your first conversation

Open the rho browser URL displayed during installation. It is saved as
`CYBROS_RHO_URL` in the installation's `.env` and defaults to
`http://localhost:7777`. On the connection screen, enter the rho access password
you chose during setup and choose **Unlock**. After a daemon restart, unlock the
page again.

Use this browser-reachable address when accessing a home server or a custom
port. You can also run `./cybros instructions` to generate a fresh private console
link using the saved public rho URL.

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

In this terminal workflow, create an account in Nexus if needed, approve the
device code, configure Telegram, then optionally configure a provider through
cmctl's separate Human login and choose a saved default model. `rho setup` is
available in full and agent modes. A runner-only installation uses
`rho connect` to pair and serves tools to another rho; it does not choose a model
or host a conversation UI.

Start the foreground server in one terminal, then use another terminal under
the same rho home. A running service applies saved settings immediately.

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
`rho run "Say hello"` when a default model is saved. In the browser-configured
stack, use `./cybros rho run "Say hello" --model provider/model`, replacing
`provider/model` with a reference from `./cybros rho models`.
This is a normal, potentially billed model request; a successful setup or model
listing alone does not prove inference.

## Finish Telegram setup

If you do not yet know your numeric user ID, save the bot token with an empty
user list, start rho, and send `/start` privately to the bot. It returns your ID
without admitting a model request. Finish with:

```sh
rho setup telegram --finish
```

The running daemon applies the owner immediately. You can also enter the ID in
rho Settings; `./cybros setup telegram` reopens the terminal flow later.
Check `rho telegram status` or `./cybros rho telegram status` and send the first
message after your ID is allowed. See the
[Telegram guide](../agents/rho/rho-ingress-telegram/README.md) for group
participation, files, voice and access management.

A saved token overrides the configured token environment variable.
Setup reports that source without printing its value. Bot tokens belong in
the plugin's private token storage or the deployment's private environment;
do not put them in ordinary settings or command-line arguments.

## Rerun or recover

| Symptom | Next step |
| --- | --- |
| Browser setup was skipped | Run `./cybros instructions`, open the private rho link and follow its password, Nexus account and Settings steps. |
| Automatic first connection has not finished | Read `./cybros logs setup`; finish owner creation, or run `./cybros up` after a service failure or computer restart. |
| Optional terminal setup was canceled | Rerun `rho setup` or `./cybros setup`. Earlier saved steps remain saved. |
| Nexus or rho is not healthy | Run `./cybros status` and `./cybros logs`; service-specific logs accept `nexus` or `rho`. |
| No usable text models | Check provider enablement, credentials, model visibility, limits and tool support in Nexus; run `rho setup model` or `./cybros setup model`. Prices may remain unset. |
| Change the default model | Open rho Settings, or run `rho setup model` / `./cybros setup model`; the running daemon applies it immediately. |
| The connection is missing, incomplete or revoked | Run `rho connect` or `./cybros connect` and complete the displayed browser flow. |
| The console code expired | Run `./cybros instructions` for the stack or `rho console` on a host; after setup, the chosen password also unlocks the ordinary rho URL. |
| The browser session expired or the daemon restarted | In the stack, open the saved rho browser URL and unlock with the chosen password; on a host, run `rho console` again. |
| A LAN browser cannot open the printed link | Check the saved public origins, bind address and host firewall using the stack LAN guide. |
| The agent is waiting | Open its conversation and answer the pending question or approval, or inspect the reported execution failure. |
| A project is absent from the runner | Check the selected runner and bind mount; container paths refer to the container's filesystem. |
| Telegram needs a token or access-list change | Rerun the Telegram section; it preserves routes, offsets and pending deliveries. |
| Stack settings saved but health failed | Inspect `./cybros logs rho`, then use `./cybros up`. |
| Stack deployment secrets are missing | Restore `secrets.env` from the deployment backup before starting; do not generate replacement encryption keys for existing data. |

Interactive and `--yes` stack installations print the same browser setup steps;
`--no-start` requires `./cybros up` before opening the page. Reinstallation
preserves the stack's `.env`, `secrets.env`, setup helper and local Compose
customizations. Optional terminal setup saves steps across services as it goes;
an interruption does not undo earlier steps.

For deeper checks, see [rho troubleshooting](rho-usage.md#troubleshooting). Before
sharing logs, remove credentials, private setup and console links, private prompts
and file contents.

## Where configuration lives

| State | Owner |
| --- | --- |
| Provider keys, subscription authorization and enabled models | Nexus |
| Agent and Runner connection, instance identity | rho home (`RHO_HOME`) |
| rho access password, default model and Telegram access settings | Private `RHO_HOME/settings.json` |
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
Selecting an older image does not undo a database change. Record the images used
with the backup, and preserve separate backups for host projects mounted
outside the installation directory.
