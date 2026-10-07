# Nexus + rho on Docker

This installs Nexus, PostgreSQL and a full-mode rho on one Docker host. It uses
published `jasl123/cybros-nexus` and `jasl123/cybros-rho` images for
`linux/amd64` and `linux/arm64`. Linux Docker Engine with Compose v2 and macOS
Docker Desktop are supported. The installer downloads images rather than
building the application. No host Ruby or JavaScript runtime is required.
Docker must already be installed and running; the installer checks it and
never installs Docker or runs `sudo`.

## Install

With `curl` available, run the installer from the public repository:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh
```

No source checkout is needed. The URL follows `main`, and new installations use
the rolling `latest` images. From an existing checkout, you can also run
`sh install/stack/install.sh`.

The installer asks you to choose:

1. **Installation directory:** configuration and persistent data live together
   here. The default is `~/.local/share/cybros`.
2. **Where you will use it:** this computer, or a home server accessed from
   another device on your local network. For a home server, enter its hostname
   or IPv4 address as your browser will reach it.
3. **Ports:** Nexus defaults to `3300` and rho to `7777`.
4. **Review:** check the directory and browser URLs before installation starts.

Once services are healthy, open the ordinary rho URL and choose **Connect to
Nexus**. A new Nexus installation guides you through first boot before returning
to authorization. Create the first owner directly; the default installation has
no setup secret or terminal step. Creating the owner also signs them in; approval
binds rho and its bundled Runner and returns to rho. Configure models afterward in
Settings. A local interactive installation opens rho when a browser launcher
is available. A remote installation prints the browser-reachable URLs; people
using a LAN deployment need no SSH tunnel or local certificates.

To choose the directory on the command line:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh -s -- --dir "$HOME/cybros"
```

Prompts read from `/dev/tty`, so they do not consume the piped script.

The installer checks Docker and Compose, creates private configuration, pulls
the images, runs database preparation and waits for Nexus and rho HTTP health.
Initialization and authorization happen in the browser after startup; the
installer does not approve Agent or Runner credentials.
Background workers must be running; this health check does not make a paid model
call or claim that a provider has been configured. A failure returns nonzero,
prints a diagnostic command and leaves configuration and data available.

For an unattended installation, use `--yes`. It accepts the defaults and any
configuration supplied through the environment without asking questions. It
prints the same rho URL and browser setup steps. A fresh installation
without a terminal requires this option:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh -s -- --yes --dir "$HOME/cybros"
```

Use `--no-start` to prepare configuration without pulling images or starting
services. It can be combined with `--yes`:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | sh -s -- --yes --no-start
cd "$HOME/.local/share/cybros"
./cybros up                    # uses local images when present; no explicit pull
```

| Option | What it does |
| --- | --- |
| `--dir DIRECTORY` | Select the installation directory |
| `--yes` | Skip interactive questions; use defaults and environment settings |
| `--no-start` | Write configuration only; do not pull images or start services |
| `--help` | Show the available options |

Re-running the installer skips the installation questions and preserves `.env`,
`secrets.env`, `compose.yaml` and the local management script. It
prints a preservation notice and does not replace customizations. Both
interactive and `--yes` installations print the browser steps. If only one of
the two environment files remains, installation stops rather than inventing new
secrets for an existing database. Restore the missing file from backup.
It also refuses to create secrets when a nonempty `data/` directory remains,
even if both environment files are missing. An empty pre-created `data/` is fine.

## First account and agent setup

Open the printed rho URL and choose **Connect to Nexus**. To display the
installation's browser addresses and setup steps again:

```sh
cd "$HOME/.local/share/cybros"
./cybros instructions
```

1. rho starts Nexus Authorization Code login with PKCE. If Nexus has no Account,
   it opens first boot and preserves this authorization request. The default
   installation requires no setup secret or terminal step.
2. Create the first Human owner. Cost tracking defaults to USD; **Advanced
   options** allows another unit. Nexus signs in the owner and continues the
   pending authorization without asking for the password again. Existing
   Accounts skip first boot.
3. Approve rho's login and connection. A new instance binds to this Human; an
   instance already bound to the same Human is reused. A different Human cannot
   take over that instance. Nexus returns to rho and the original tab finishes
   login. There is no separate rho password or pairing step.
4. Open rho **Settings**. Configure optional Telegram and follow the Nexus model
   settings link to configure a provider and enable a model. Provider keys stay
   in Nexus. See [Model settings](../../docs/nexus-model-settings.md).
5. Return to rho. A sole eligible model is selected automatically; choose a
   default when several are available. The bundled Runner and base tools are
   ready. Model selection makes no inference request; your first conversation
   is a normal, potentially billed request.

The default installation allows a visitor who can reach Nexus to create the
first owner until the Account exists. To require a private secret for this step,
the operator may set `NEXUS_SETUP_SECRET` in `secrets.env` and run `./cybros up`.
Only when that option is set does `./cybros instructions` display the private
secret and a `/setup#setup_secret=…` link. The link fills the secret and clears
its fragment; after creating the Account through that separate link, return to
rho and choose **Connect to Nexus** again. The public rho page never receives
the configured secret.

**Use a device code** is also a complete Nexus login. On an uninitialized
installation, open the displayed Nexus setup link, finish first boot, then
choose **Continue after setup**. rho then displays a code and **Open Nexus to
approve** link, and waits for approval in the original tab. Device login does
not need a callback reachable from the browser. Both flows use the same Human
authorization and Agent binding rules.

Signing out ends the browser session without changing the Agent's owner.
The same tab retains its session across rho restarts while its Nexus grant is
valid. A new tab, expired grant or revoked authorization requires Nexus login. A removed or revoked
registration must be restored or reconnected through its ordinary Nexus
workflow; the installer never silently reverses that decision.

### Optional terminal setup

`./cybros setup` remains available for provider configuration, a saved default
model and optional Telegram from an interactive terminal. It reuses rho's saved
Human OAuth login, or asks you to approve a device code when needed. This terminal
login remains after setup exits and is separate from browser sessions and the
Agent and Runner credentials.

`./cybros setup model` configures the provider and saved default model, and
`./cybros setup telegram` configures messaging. Saved choices are
kept unless you change them. Saved application settings apply to the running
daemon immediately, without recreating the container.
Cancellation keeps already saved settings and prints a command to resume.
For Telegram, the wrapper asks you to send `/start` to the running bot when the
owner is missing, then saves the reported numeric ID and applies access immediately.

The container uses `http://nexus` for API calls and the saved
`CYBROS_NEXUS_URL` for browser links. No host Ruby is needed: rho setup and cmctl
share the installed portable Ruby and locked bundle. Advanced management remains
available through `./cybros cmctl`; its explicit `login` command stores its own
session under `data/rho/home/cmctl`, separate from rho's saved Human login and
runtime credentials.
Standalone `./cybros cmctl setup` uses a temporary Human session and revokes it
when that command exits. If revocation fails, the command identifies the session
to remove in Nexus settings.

`./cybros rho status` reports connection state; `./cybros rho models` lists usable
models. The current browser tab remains signed in across daemon restarts while
its Nexus grant is valid. `./cybros instructions` displays the saved browser URLs. The
[first-conversation guide](../../docs/getting-started.md#open-your-first-conversation)
walks through the runner and working directory.
For configuration ownership and recovery, see [Getting started](../../docs/getting-started.md#where-configuration-lives).

## Configuration and LAN access

Environment variables can supply setup defaults. An explicit directory, port,
or network setting skips the corresponding question. Stack settings are saved
only when creating a fresh `.env`; `CYBROS_INSTALL_DIR` selects the directory
for each invocation:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CYBROS_INSTALL_DIR` | `~/.local/share/cybros` | Installation directory; `--dir` takes precedence |
| `CYBROS_PROJECT_NAME` | `cybros` | Compose project name; choose a distinct name for another installation |
| `CYBROS_IMAGE_NAMESPACE` | `jasl123` | Docker Hub namespace |
| `CYBROS_IMAGE_TAG` | `latest` | Rolling tag shared by both product images |
| `CYBROS_BIND` | `127.0.0.1` | Host address on which both HTTP ports are published |
| `CYBROS_NEXUS_PORT` | `3300` | Nexus host port |
| `CYBROS_RHO_PORT` | `7777` | rho host port |
| `CYBROS_NEXUS_URL` | `http://localhost:3300` | Browser-reachable Nexus URL used for login and setup |
| `CYBROS_RHO_URL` | `http://localhost:7777` | Browser address used by the installer and exact OAuth callback |
| `CYBROS_OAUTH_ALLOW_HTTP` | `true` for direct HTTP URLs; otherwise `false` | Explicit local/LAN HTTP OAuth deployment mode |

The guided setup's home-server choice asks for an address reachable from your
browser. For an unattended LAN installation, supply it explicitly:

```sh
curl -fsSL https://raw.githubusercontent.com/jasl/cybros.ai/main/install/stack/install.sh | \
  CYBROS_BIND=0.0.0.0 \
  CYBROS_NEXUS_URL=http://home-server.local:3300 \
  CYBROS_RHO_URL=http://home-server.local:7777 \
  sh -s -- --yes
```

The first version publishes HTTP directly. It does not set up a domain,
certificate or reverse proxy. Keep a direct HTTP installation on your own local
network. For an operator-managed TLS proxy, change the public origins and bind
addresses in `.env` and configure the proxy separately. Nexus derives its SSL
defaults from the public `BASE_URL`; do not suppress those defaults just because
the proxy-to-container connection uses HTTP. rho's internal listener retains its
explicit plaintext transport assertion; Nexus login authenticates browser access.
For HTTPS public URLs, set `CYBROS_OAUTH_ALLOW_HTTP='false'`. The internal
Compose connection to Nexus may remain HTTP. The registered OAuth callback is
exactly `CYBROS_RHO_URL/auth/callback`; update it together with the public rho URL.

rho reaches Nexus at `http://nexus` on the Compose network. This internal address
is deliberately different from `CYBROS_NEXUS_URL`: login and device-approval links must be usable
by the person's browser. Do not set the public origin to `http://nexus`.

For an existing installation, edit `.env`, then run `./cybros up`. Files use
Compose dotenv syntax, not shell syntax; the management script never executes
them. Keep the generated single-quoted values when editing. `secrets.env` holds
independent database, Rails and Active Record encryption secrets, plus an optional
operator-configured `NEXUS_SETUP_SECRET`.
Never regenerate the encryption keys while retaining the database.

## Optional Telegram bot

Configure Telegram in rho Settings, or run `./cybros setup telegram` and provide
a BotFather token when asked. Setup validates it with `getMe` and asks for your
numeric bot owner ID. Send `/start` privately to the bot to find that ID; the
owner can then manage allowed people and groups in rho Settings or through the
bot's `/access` command. Setup sends no message and never polls updates; the
daemon remains the only polling process.

The token is a write-only field at
`plugins["rho.ingress_telegram"].configuration.token` in the private
`data/rho/home/settings.json` (mode `0600`). Settings and the control API expose
only whether it is set. Channel delivery state remains in Nexus.
A saved token takes precedence over
`RHO_TELEGRAM_BOT_TOKEN` from the stack's private `.env`. Change the saved token
in rho Settings or terminal setup; no environment-file edit is needed. The
environment supplies a default only when no token is saved. Custom `token_env`
names require a matching rho environment entry in `compose.yaml`.

The wizard preserves unrelated settings, routes and update offsets. It denies
ordinary messages until users are explicitly allowed. For group behavior,
commands, approvals and the execution boundary, see the
[Telegram extension guide](../../agents/rho/rho-ingress-telegram/README.md).

## Data and permissions

All durable data is in the installation directory:

```text
cybros/
  .env
  secrets.env
  compose.yaml
  cybros
  data/
    postgres/        PostgreSQL's databases
    nexus/storage/   uploaded files and other Rails storage
    rho/home/        OAuth credentials, settings, logs and instance identity
    rho/work/        the runner's default /home/runner directory
```

There are no named data volumes. The one-shot `data_init` container runs the
existing Nexus image as root to create and assign the Nexus/rho directories to
UID/GID 1000. PostgreSQL's official entrypoint handles its own directory owner.
The application containers continue running as their normal non-root users.
The initialization command also works after a restore; recursive ownership
correction can take time on a large restored tree.

The rho container receives the internal Nexus API URL, browser-visible Nexus
URL and its own browser URL. It never receives `NEXUS_SETUP_SECRET`, a mounted
setup-status file or a background approval helper. First boot and OAuth remain
owned by Nexus, and login is the only browser connection ceremony.

The runner's `RHO_TOOLS_ROOT` and container working directory are `/home/runner`;
rho state remains at `/var/lib/rho`, and the OS user's `HOME` remains `/home/rho`.
Full mode still runs the agent and runner in the same process as UID 1000.

To work on an existing host project, edit the source of rho's `/home/runner` bind in `compose.yaml`
and arrange that directory's write permission for container UID 1000. That
project is then outside the installation backup and needs its own backup.
For a separate machine's files, deploy a separate rho runner and select it with
`./cybros rho runners use <id>`; the joint stack defaults to an in-container
runner, not the host's entire filesystem.

## Status, logs and upgrades

```sh
./cybros status
./cybros instructions          # show browser URLs and setup steps
./cybros logs                  # last 100 lines from each service
./cybros logs nexus
./cybros compose logs -f rho   # ordinary Compose for follow/tail options
./cybros stop                  # preserves every data directory
./cybros up
./cybros update                # pull the configured tag, start, wait for health
```

The default `latest` tag follows the rolling release. Use `./cybros update latest`
if an existing installation was configured with another tag. Back up before
upgrading. A failed pull leaves the configured tag unchanged. Startup or
migration failure does not delete data and is not silently rolled back.
Selecting an older image is not a database rollback: restore a matching backup
if the newer release changed the database incompatibly. Updating images does
not replace the installer or edited Compose template.

This pre-release version assumes a freshly initialized database; existing
development databases are rebuilt when the schema changes incompatibly. New
titles and completed messages are indexed as they are saved. Chinese
tokenization and English stemming run inside Nexus and PostgreSQL; no separate
search container is needed.

## Back up and restore

Conversation execution details are retained for 90 days after completion by
default. Nexus keeps the conversation text, including additional user messages,
for reading and keyword search. An owner or administrator can change this under
**Administration → Retention**, or with the bundled CLI:

```sh
./cybros cmctl account retention        # read the current setting
./cybros cmctl account retention 180    # retain details for 180 days
./cybros cmctl account retention off    # disable automatic detail cleanup
```

The background jobs service must be running for cleanup. Already removed tool
traces, requests and checkpoints cannot be restored by increasing the setting;
restore a matching backup if those details are needed. This setting concerns
conversation executions; standalone loops and one-shots retain their existing
lifecycle.

The event feed keeps its separate 30-day replay window. Choosing a shorter
execution-detail period does not also shorten that event window.

The PostgreSQL image keeps its default autovacuum configuration. Deleted space
becomes available for database reuse; the host's `data/postgres/` directory will
not necessarily shrink immediately. Do not schedule `VACUUM FULL` as routine
cleanup: it rewrites and locks tables. See the
[PostgreSQL space-recovery guidance](https://www.postgresql.org/docs/18/routine-vacuuming.html#VACUUM-FOR-SPACE-RECOVERY).

For a consistent complete backup, stop the stack and archive the installation
directory, including `secrets.env`, PostgreSQL data, uploaded files and rho home:

```sh
cd "$HOME/.local/share/cybros"
./cybros stop
sudo tar -czpf "$HOME/cybros-backup.tar.gz" -C "$HOME/.local/share" cybros
./cybros up
```

Root permission may be needed to read PostgreSQL-owned files on Linux. Store
the archive privately: it includes account credentials and encryption keys.
Restore while the stack is stopped, preserving file ownership and permissions.
Use a PostgreSQL 18 image and product images matching the backup's database schema
for the first start.
For migration across CPU architectures or PostgreSQL major versions, use a
logical database export/import instead of assuming physical database files are
portable. Host bind mounts make the files accessible; they do not change
PostgreSQL's physical-format compatibility requirements.
On another machine, install Docker, extract the directory, then run:

```sh
cd "$HOME/.local/share/cybros"
./cybros compose run --rm --no-deps data_init
./cybros up
```

If the restored installation's host-user UID differs, give the installation
directory and its top-level configuration and management files to the new
operator. `data_init` fixes the application data owners; PostgreSQL fixes its
own. Do not copy a live PostgreSQL data directory as a valid backup.

For an online database-only logical export:

```sh
./cybros compose exec -T db pg_dumpall -U postgres > nexus-databases.sql
```

That file does not include uploaded bytes or rho credentials, and its separate
database snapshots are not a full-stack point-in-time backup. Use the stopped
directory backup when moving the complete personal installation.

## Optional coding agents

The rho image includes T3, Codex and Claude Code; the coding plugin is disabled
until selected. To run its service inside the same rho container:

```sh
./cybros t3 local
./cybros t3 login codex
# Or: ./cybros t3 login claude
./cybros t3 create /home/runner
./cybros t3 check
```

Open the native login URL on your own browser and enter any returned code in the
terminal. For an existing T3 service instead, use
`./cybros t3 host http://host.docker.internal:3773` and supply its dedicated bearer
at the hidden prompt. The host service must be reachable from the container.
`./cybros t3 projects` lists native project IDs; `./cybros t3 project ID` selects
one. A project path is in the service's execution environment.

Local T3, Codex, Claude and private environment credentials are all retained in
`data/rho/home/plugins/rho.t3/`. Setup runs as the same container UID as rho and
keeps `rho.env` private (`0600`); it is not copied into `secrets.env`.
Setup and startup refuse a credential file owned by another UID or readable by
group/others. Inspect any exposure and explicitly restore `chmod 600` before
retrying; neither path silently repairs the file.
`./cybros t3 secret ANTHROPIC_API_KEY` supports a hidden prompt or stdin for API
access. `./cybros t3 login codex --api-key` reads a Codex API key from stdin.
Local setup and project selection restart rho to apply their saved configuration;
before restart the result says `saved: true`, `applied: false` and
`restart_required: true`. A failed save does not restart the container.
Ordinary assignment Stop does not stop T3. Back up the entire rho home together
with its native login state.

`status` is an offline configuration check; `check` verifies T3 authentication,
protocol, selected project and the reported provider directory without invoking
a model. A successful coding assignment remains a separate verification step.
See [rho-t3](../../agents/rho/rho-t3/README.md#docker-setup) for the full setup and
standalone Compose commands.

## Development verification

Edit `compose.yaml`, `cybros` or `bootstrap.sh`, then run:

```sh
sh install/stack/render.sh
sh install/stack/test.sh
```

`render.sh` embeds the templates into the delivered `install.sh`;
`render.sh --check` catches drift. The offline tests use a temporary mock Docker,
test piped invocation, service startup, configuration preservation,
public rho links, optional private setup links, terminal setup, upgrades and
failure paths, and never start a service or use real provider credentials.
The test suite needs ShellCheck and Python 3; its terminal tests exercise the
wizard while the script itself arrives through a pipe. Neither is needed to run
the delivered installer.
Set `CYBROS_TEST_COMPOSE_CONFIG=1` to additionally parse the generated files with
an installed Docker Compose; this is read-only and does not contact the daemon.

The opt-in [stack installation E2E](../../e2e/test/stack_installation_test.rb)
targets a fresh, disposable installed stack. It exercises browser account setup,
Nexus OAuth login and Agent/Runner connection, provider configuration, model discovery and a
WebUI conversation against a local fake provider using a synthetic key. No
external model provider is called. See the
[E2E run instructions](../../e2e/README.md#docker-stack-installation) for the
explicit environment variables and command. The test does not create or tear
down the supplied stack; never point it at a personal installation.
