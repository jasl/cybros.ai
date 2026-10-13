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

After startup, open the rho URL printed by the installer and choose **Connect
to Nexus**. To display the URLs and browser setup steps again:

```sh
cd "$HOME/.local/share/cybros"
./cybros instructions
```

Use your chosen directory if you changed the default.

1. rho opens Nexus login and authorization. On a new installation, Nexus first
   asks you to create the Account and preserves rho's authorization request.
   The default installation requires no setup secret or terminal step.
2. Create the first Human owner. Nexus signs you in immediately and continues
   the original authorization. Cost tracking defaults to USD; choose
   **Advanced options** during first boot if you need another unit. An existing
   Account skips first boot and uses your ordinary Nexus login.
3. Approve rho. This login binds a new rho instance to your Human account and
   connects its Agent and bundled private Runner. Later logins by the same
   Human reuse the binding. Another Human cannot take over that instance.
   Nexus returns to rho automatically; there is no separate rho password.
4. rho opens **Settings** when a model still needs configuration. Optional
   Telegram setup and owner binding work before any model is configured;
   `/start` returns your numeric ID.
5. Follow the model setup link to [Nexus administration](nexus-model-settings.md).
   Configure a provider with an API key, a supported subscription authorization
   or a credentialless endpoint, and enable a model. If you do not administer
   the Account, ask its owner or administrator to configure an eligible model.
6. Return to rho Settings. It keeps a valid saved default, selects a sole
   eligible model, or asks you to choose among several. The stack's Runner and
   base tools are already ready. Pricing is optional; model selection makes no
   inference request.

If the operator explicitly configured `NEXUS_SETUP_SECRET`, first boot also
asks for that private secret. `./cybros instructions` then displays its value
and an optional private setup link. See the
[stack guide](../install/stack/README.md#first-account-and-agent-setup) for that
deployment option.

**Use a device code** is an alternative complete login. If Nexus is not yet
initialized, open its setup page and finish first boot, then choose **Continue
after setup** in rho. Open the device verification link, check its code and
approve. Keep rho's original tab open; it continues when approval arrives.
Device login needs no callback, SSH tunnel or browser on the server.

Provider credentials stay in Nexus. rho receives OAuth authority for the
signed-in Human separately from its Agent and Runner credentials; it never
receives the Human password. Models are configured after login, not as a
prerequisite for connecting rho.

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
configuration, a saved default model and Telegram. It reuses rho's saved Human
OAuth login, or asks you to approve a device code when needed. The terminal login
and saved settings remain after setup exits.
`./cybros setup model` configures the CLI default model, and
`./cybros setup telegram` configures messaging. The running daemon applies saved
settings immediately. Environment variables such as `RHO_DEFAULT_MODEL` supply
initial values; saved settings override them, and explicit launch flags take
precedence on startup.

## Open your first conversation

Open the rho browser URL displayed during installation, saved as
`CYBROS_RHO_URL` in `.env` and defaulting to `http://localhost:7777`. Choose
**Connect to Nexus** when no browser session exists. The same tab stays signed
in across daemon restarts while its Nexus grant is valid. **Sign out** ends the
browser session while the Agent's
binding and running work remain.

Use the saved LAN address when accessing a home server from another computer.
The explicit local/LAN HTTP mode does not require SSH or certificates; it
permits the configured callback while leaving network traffic unencrypted.
Use an HTTPS reverse proxy for encrypted browser access.

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
schedules, Telegram and noninteractive CLI runs.

## Connect a host installation to Nexus

Install rho using the [host installation guide](../install/README.md#rho-directly-on-the-host),
then run this in an interactive terminal, replacing the example with your Nexus
address:

```sh
rho setup --nexus-url https://nexus.example
```

In this terminal workflow, create an account in Nexus if needed, approve the
device code, configure Telegram, then optionally configure a provider through
the same Human OAuth login and choose a saved default model. rho saves this
terminal login for later setup commands. `rho setup` is available in full and
agent modes. A runner-only installation uses
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

The console command opens rho's public URL. Choose **Connect to Nexus**, or
**Use a device code**, to establish the browser session.
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
| Browser setup was skipped | Open the rho URL and choose **Connect to Nexus**; `./cybros instructions` displays the URLs and setup steps. |
| First login has not finished | Complete Nexus account creation and authorization in the same browser tab. For device login, finish setup, choose **Continue after setup**, then approve the displayed code. |
| Optional terminal setup was canceled | Rerun `rho setup` or `./cybros setup`. Earlier saved steps remain saved. |
| Nexus or rho is not healthy | Run `./cybros status` and `./cybros logs`; service-specific logs accept `nexus` or `rho`. |
| No usable text models | Check provider enablement, credentials, model visibility, limits and tool support in Nexus; run `rho setup model` or `./cybros setup model`. Prices may remain unset. |
| Change the default model | Open rho Settings, or run `rho setup model` / `./cybros setup model`; the running daemon applies it immediately. |
| The connection is missing, incomplete or revoked | Run `rho connect` or `./cybros connect` and complete the displayed browser flow. |
| Login or device code expired | Start a new Nexus login from the rho page. |
| The Nexus authorization expired or was revoked | Open the saved rho URL and choose **Connect to Nexus** again. |
| A LAN browser cannot open the printed link | Check the saved public origins, bind address and host firewall using the stack LAN guide. |
| The agent is waiting | Open its conversation and answer the pending question or approval, or inspect the reported execution failure. |
| A project is absent from the runner | Check the selected runner and bind mount; container paths refer to the container's filesystem. |
| Telegram needs a token or access-list change | Rerun the Telegram section; it preserves routes, offsets and pending deliveries. |
| Stack settings saved but health failed | Inspect `./cybros logs rho`, then use `./cybros up`. |
| Stack deployment secrets are missing | Restore `secrets.env` from the deployment backup before starting; do not generate replacement encryption keys for existing data. |

Interactive and `--yes` stack installations print the same browser setup steps;
`--no-start` requires `./cybros up` before opening the page. Reinstallation
preserves the stack's `.env`, `secrets.env` and local Compose
customizations. Optional terminal setup saves steps across services as it goes;
an interruption does not undo earlier steps.

For deeper checks, see [rho troubleshooting](rho-usage.md#troubleshooting). Before
sharing logs, remove credentials, private setup links, private prompts
and file contents.

## Where configuration lives

| State | Owner |
| --- | --- |
| Provider keys, subscription authorization and enabled models | Nexus |
| Agent and Runner connection, instance identity | rho home (`RHO_HOME`) |
| Default model and Telegram access settings | Private `RHO_HOME/settings.json` |
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
