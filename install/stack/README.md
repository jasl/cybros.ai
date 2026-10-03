# Nexus + rho on Docker

This installs Nexus, PostgreSQL and a full-mode rho on one Docker host. It uses
published `jasl123/cybros-nexus` and `jasl123/cybros-rho` images for
`linux/amd64` and `linux/arm64`. Linux Docker Engine with Compose v2 and macOS
Docker Desktop are supported. The installer downloads images rather than
building the application. No host Ruby or JavaScript runtime is required.
Docker must already be installed and running; the installer checks it and
never installs Docker or runs `sudo`.

## Install

From the root of this repository, run:

```sh
sh install/stack/install.sh
```

The installer asks you to choose:

1. **Installation directory:** configuration and persistent data live together
   here. The default is `~/.local/share/cybros`.
2. **Where you will use it:** this computer, or a home server accessed from
   another device on your local network. For a home server, enter its hostname
   or IPv4 address as your browser will reach it.
3. **Ports:** Nexus defaults to `3300` and rho to `7777`.
4. **Review:** check the directory and browser URLs before installation starts.
5. **Agent setup:** once the services are healthy, continue with provider access,
   the default model, device pairing and optional Telegram.

To choose the directory on the command line:

```sh
sh install/stack/install.sh --dir "$HOME/cybros"
```

Prompts read from `/dev/tty`, so they do not consume a piped script. Use the
repository script above until a public installer URL is published.

The installer checks Docker and Compose, creates private configuration, pulls
the images, runs database preparation and waits for Nexus and rho HTTP health.
Background workers must be running; this health check does not make a paid model
call or claim that a provider has been configured. A failure returns nonzero,
prints a diagnostic command and leaves configuration and data available.

For an unattended installation, use `--yes`. It accepts the defaults and any
configuration supplied through the environment without asking questions. It does
not open the agent setup wizard; run `./cybros setup` later. A fresh
installation without a terminal requires this option:

```sh
sh install/stack/install.sh --yes --dir "$HOME/cybros"
```

Use `--no-start` to prepare configuration without pulling images or starting
services. It can be combined with `--yes`:

```sh
sh install/stack/install.sh --yes --no-start
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
`secrets.env`, `compose.yaml` and the local management script. It prints a
preservation notice and does not replace customizations. An interactive run then
opens the rerunnable agent setup wizard; `--yes` skips that step. If only one of the
two environment files remains, installation stops rather than inventing new
secrets for an existing database. Restore the missing file from backup.
It also refuses to create secrets when a nonempty `data/` directory remains,
even if both environment files are missing. An empty pre-created `data/` is fine.

## First account and agent setup

After the services become healthy, an interactive installation continues into
`./cybros setup`. If you used `--yes`, `--no-start`, or stopped partway through,
run it from the installation directory:

```sh
cd "$HOME/.local/share/cybros"
./cybros setup
```

1. Open the printed public Nexus `/setup` URL and create the first Human account
   using `NEXUS_SETUP_SECRET` from the private `secrets.env` file. Existing
   accounts can continue. The wizard never creates an account in the background
   or prints the setup secret.
2. Optionally sign in as an owner or administrator to configure a provider and
   its API key or supported subscription authorization. Browser account creation
   normally configures USD; a cost-unit question appears only if it remains unset.
   The setup login is kept only in memory. The wizard revokes it on exit; if
   revocation fails, it tells you to remove the session in Nexus settings.
   Provider credentials are sent to Nexus, not saved in rho settings.
3. Approve rho's device connection in your browser and select an available model.
   Full mode pairs its Agent and Runner through the existing connection flow.
   Availability is checked without making a paid model request.
4. Optionally configure Telegram. The wrapper reloads rho through Compose; when
   the first allowed user is still missing, it asks you to send `/start` to the
   running bot, enter the reported numeric ID, and reloads the saved access list.

`./cybros setup model` repeats provider/model configuration, and
`./cybros setup telegram` repeats messaging configuration. Saved choices are
kept unless you change them. After a successful setup, the wrapper recreates
only rho and waits for health; it never starts a second daemon in the container.
Cancellation keeps already saved settings and prints a command to resume.

The container uses `http://nexus` for API calls and the saved
`CYBROS_NEXUS_URL` for browser links. No host Ruby is needed: rho setup and cmctl
share the installed portable Ruby and locked bundle. Advanced management remains
available through `./cybros cmctl`; its explicit `login` command stores its own
session under `data/rho/home/cmctl`, separate from rho's Agent credentials.

`./cybros rho status` reports connection state; `./cybros rho models` lists usable
models. Open the saved `CYBROS_RHO_URL`, enter `RHO_ACCESS_PASSPHRASE` from the
private `secrets.env`, and choose **Unlock**. Start a normal conversation to
verify real inference after configuration; the
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
| `CYBROS_IMAGE_TAG` | `latest` | Same tag for both product images; releases also have a Unix timestamp tag |
| `CYBROS_BIND` | `127.0.0.1` | Host address on which both HTTP ports are published |
| `CYBROS_NEXUS_PORT` | `3300` | Nexus host port |
| `CYBROS_RHO_PORT` | `7777` | rho host port |
| `CYBROS_NEXUS_URL` | `http://localhost:3300` | Browser-reachable Nexus origin used in pairing links |
| `CYBROS_RHO_URL` | `http://localhost:7777` | Browser address displayed by the installer |

The guided setup's home-server choice asks for an address reachable from your
browser. For an unattended LAN installation, supply it explicitly:

```sh
CYBROS_BIND=0.0.0.0 \
CYBROS_NEXUS_URL=http://home-server.local:3300 \
CYBROS_RHO_URL=http://home-server.local:7777 \
sh install/stack/install.sh --yes
```

The first version publishes HTTP directly. It does not set up a domain,
certificate or reverse proxy. Keep a direct HTTP installation on your own local
network. For an operator-managed TLS proxy, change the public origins and bind
addresses in `.env` and configure the proxy separately. Nexus derives its SSL
defaults from the public `BASE_URL`; do not suppress those defaults just because
the proxy-to-container connection uses HTTP. rho's internal listener retains its
explicit plaintext assertion and passphrase requirement.

rho reaches Nexus at `http://nexus` on the Compose network. This internal address
is deliberately different from `CYBROS_NEXUS_URL`: pairing links must be usable
by the person's browser. Do not set the public origin to `http://nexus`.

For an existing installation, edit `.env`, then run `./cybros up`. Files use
Compose dotenv syntax, not shell syntax; the management script never executes
them. Keep the generated single-quoted values when editing. `secrets.env` holds
independent database, Rails, Active Record encryption, setup and rho secrets.
Never regenerate the encryption keys while retaining the database.

## Optional Telegram bot

Run `./cybros setup telegram` and provide a BotFather token when asked. Setup
validates it with `getMe`, asks for explicit allowed user and optional group IDs,
and enables the existing Telegram extension. It sends no message and never
polls updates; the daemon remains the only polling process.

By default the token is stored privately under
`data/rho/home/telegram/token.json`, separate from ordinary `settings.json` and
channel delivery state. A nonempty `RHO_TELEGRAM_BOT_TOKEN` in the stack's private
`.env` takes precedence; setup keeps that source and tells you to change or unset
it if you want a different token. Custom `token_env` names require a matching
rho environment entry in `compose.yaml`.

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
    rho/home/        pairing credentials, settings, logs and instance identity
    rho/work/        the runner's default /home/runner directory
```

There are no named data volumes. The one-shot `data_init` container runs the
existing Nexus image as root to create and assign the Nexus/rho directories to
UID/GID 1000. PostgreSQL's official entrypoint handles its own directory owner.
The application containers continue running as their normal non-root users.
The initialization command also works after a restore; recursive ownership
correction can take time on a large restored tree.

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
./cybros instructions          # show browser URLs and setup commands again
./cybros logs                  # last 100 lines from each service
./cybros logs nexus
./cybros compose logs -f rho   # ordinary Compose for follow/tail options
./cybros stop                  # preserves every data directory
./cybros up
./cybros update                # pull the configured tag, start, wait for health
./cybros update 1790624221      # select the same timestamp for Nexus and rho
./cybros update latest
```

`latest` moves; a timestamp selects one published release. Back up before
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
Use a PostgreSQL 18 image and the matching product timestamp for the first start.
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
directory and its four top-level configuration/management files to the new
operator. `data_init` fixes the application data owners; PostgreSQL fixes its
own. Do not copy a live PostgreSQL data directory as a valid backup.

For an online database-only logical export:

```sh
./cybros compose exec -T db pg_dumpall -U postgres > nexus-databases.sql
```

That file does not include uploaded bytes or rho credentials, and its separate
database snapshots are not a full-stack point-in-time backup. Use the stopped
directory backup when moving the complete personal installation.

## Development verification

Edit `compose.yaml`, `cybros` or `bootstrap.sh`, then run:

```sh
sh install/stack/render.sh
sh install/stack/test.sh
```

`render.sh` embeds the templates into the delivered `install.sh`;
`render.sh --check` catches drift. The offline tests use a temporary mock Docker,
test piped invocation, configuration preservation, secret handling, upgrades and
failure paths, and never start a service or use real provider credentials.
The test suite needs ShellCheck and Python 3; its terminal tests exercise the
wizard while the script itself arrives through a pipe. Neither is needed to run
the delivered installer.
Set `CYBROS_TEST_COMPOSE_CONFIG=1` to additionally parse the generated files with
an installed Docker Compose; this is read-only and does not contact the daemon.

The opt-in [stack installation E2E](../../e2e/test/stack_installation_test.rb)
targets a fresh, disposable installed stack. It exercises account setup, the
container's `cmctl`, pairing, model discovery and the shipped WebUI using a
synthetic provider key. It performs no inference or real provider IO. See the
[E2E run instructions](../../e2e/README.md#docker-stack-installation) for the
explicit environment variables and command. The test does not create or tear
down the supplied stack; never point it at a personal installation.
