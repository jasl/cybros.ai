# Nexus + rho on Docker

This installs Nexus, PostgreSQL and a full-mode rho on one Docker host. It uses
published `jasl123/cybros-nexus`, `jasl123/cybros-rho` and `jasl123/cybros-updater` images for
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
| `--upgrade-manager` | Refresh `cybros` and its managed deployment overlays; preserve the base Compose file, settings, secrets and data |
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
| `CYBROS_NEXUS_IMAGE_REPOSITORY` | `jasl123/cybros-nexus` | Complete Nexus image repository path, without a tag or digest |
| `CYBROS_RHO_IMAGE_REPOSITORY` | `jasl123/cybros-rho` | Complete rho image repository path, without a tag or digest |
| `CYBROS_UPDATER_IMAGE_REPOSITORY` | `jasl123/cybros-updater` | Complete upgrade-manager image repository path, without a tag or digest |
| `CYBROS_IMAGE_TAG` | `latest` | `latest` or a UTC `yyMMddHHmm` release tag shared by both product images |
| `CYBROS_UPDATER_TAG` | Initial `CYBROS_IMAGE_TAG` | Independently selected manager tag; application upgrades do not replace the running manager |
| `CYBROS_BIND` | `127.0.0.1` | Host address on which both HTTP ports are published |
| `CYBROS_NEXUS_PORT` | `3300` | Nexus host port |
| `CYBROS_RHO_PORT` | `7777` | rho host port |
| `CYBROS_NEXUS_URL` | `http://localhost:3300` | Browser-reachable Nexus URL used for login and setup |
| `CYBROS_RHO_URL` | `http://localhost:7777` | Browser address used by the installer and exact OAuth callback |
| `CYBROS_OAUTH_ALLOW_HTTP` | `true` for direct HTTP URLs; otherwise `false` | Explicit local/LAN HTTP OAuth deployment mode |

Repository values use the same path as `docker pull`: for example,
`CYBROS_NEXUS_IMAGE_REPOSITORY='ghcr.io/jasl/cybros-nexus'`. The selected release
tag is appended when checking updates; accepted upgrades freeze each reference
to its immutable digest. On an existing installation, edit these values in its
`.env`, then run `./cybros update-manager` so the manager receives the new sources. The Web
UI displays deployment sources; it does not change registry configuration.
Release tags use UTC `yyMMddHHmm`: `2610080750` means 2026-10-08 07:50 UTC,
with years interpreted as 2000–2099. `latest` remains the rolling release selector.

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
  deployment.compose.yaml  managed application image/socket overlay
  updater.compose.yaml     separate upgrade-manager project
  images.env               immutable application image references after activation
  cybros
  data/
    postgres/        PostgreSQL's databases
    nexus/storage/   uploaded files and other Rails storage
    rho/home/        OAuth credentials, settings, logs and instance identity
    rho/work/        the runner's default /home/runner directory
    updater/         private durable upgrade receipts and bounded progress logs
    updater-ipc/     private Unix socket shared only with Nexus
```

There are no named data volumes. The one-shot `data_init` container runs the
existing Nexus image as root to create and assign the Nexus/rho directories to
UID/GID 1000. PostgreSQL's official entrypoint handles its own directory owner.
The application containers continue running as their normal non-root users.
The initialization command also works after a restore; recursive ownership
correction can take time on a large restored tree.

The separate updater container owns installation lifecycle operations and the
Docker socket. It has no published HTTP port. Nexus receives only the private
Unix socket; rho receives neither socket. The updater's installation bind uses
the same absolute path inside the container and on the Docker host so Compose
resolves data mounts correctly, including installation paths containing spaces.

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
./cybros manager logs          # separate upgrade-manager service diagnostics
./cybros compose logs -f rho   # ordinary Compose for follow/tail options
./cybros stop                  # preserves every data directory
./cybros up
./cybros check                 # explicit preflight JSON; does not accept an upgrade
./cybros update                # full backup, matching manager, then application upgrade
./cybros update 2610080750      # select the published 2026-10-08 07:50 UTC release
./cybros update --no-backup     # explicitly skip the full snapshot and database export
./cybros upgrade-status        # latest accepted upgrade, including after interruption
./cybros upgrade-log           # latest upgrade's bounded progress window
./cybros upgrade-resume ID     # resume a safe recorded phase without repeating migration
```

In Nexus, an active Human administrator can open **System upgrade** in the admin
area, review Nexus's current and candidate image references and preflight checks,
and confirm its upgrade. **Back up the database before upgrading** starts checked;
changing this choice requires another preflight check. This replaces Nexus and its jobs/model-runner workers
only. It does not inspect candidate rho releases, pull rho images or restart rho.
rho's connection to Nexus is unavailable during the restart; its process and
image remain unchanged. Agent application management belongs to its application
or installation tools, not Nexus administration.

The page follows its Nexus-only durable receipt and reconnects after Nexus
restarts. Closing the tab does not cancel the operation. CLI and browser commands
use the same installation owner and only one upgrade runs at a time. The CLI
commands above retain whole-installation upgrades and can inspect or recover
either kind of operation. Nexus shows only Nexus upgrade receipts and logs.
Standalone Nexus installations without an updater socket show this feature as
unsupported.

The CLI check resolves both native-platform images without pulling their layers,
and requires matching, valid UTC `yyMMddHHmm` release labels. The Nexus browser
check resolves only the Nexus image and validates its release label. Both check local
Compose configuration, PostgreSQL, installed images, and pending
recovery. A blocked check explains the required manual step and prevents
confirmation. When backup is selected, the free-space estimate is twice the database size plus 256 MiB;
SQL expansion and later writes can exceed this estimate. Docker's separate image
storage capacity remains a manual check, shown as a warning. Checks are explicit;
routine status and progress polling do not contact a registry. Confirming freezes those exact digests.
The updater pulls the selected images before stopping the selected application
services, leaves PostgreSQL running, writes a private database export when selected, performs
one migration, starts the selected application images, and checks their health
and required worker processes. Configuration, secrets,
uploads, conversations and rho state keep their existing storage owners.
Browser progress contains bounded operation summaries. Full migration output
stays in the named Docker container for operator diagnosis and is not forwarded
to the browser log.

The host `update` command first resolves and pulls the matching manager release,
stops the installation and manager, and creates a full snapshot using the previous
cached manager image. It starts the existing application containers by identity
before replacing the
manager and requesting the application upgrade. A snapshot failure attempts to
restart those services and exits without accepting an upgrade. A manager readiness
failure retains the new manager selection and state for diagnosis and retry;
the existing applications remain running and no application upgrade is accepted.
It does not automatically restart an older manager against potentially newer state.
`latest` resolves once to a
concrete release; the manager and applications use that same tag. Only the manager
tag and image pin change in `.env`; secrets, custom Compose and other settings
remain intact. `--no-backup` skips both the full snapshot and SQL export.

When selected, database backup free space is checked again before and after
image pulls, before stopping applications. A failed pull on a fresh upgrade leaves
the running application alone. Failed database export prevents migration and
keeps applications stopped for explicit recovery.
Failed or uncertain migration leaves application services stopped and records
recovery guidance. The updater never resets a database, retries an uncertain
migration, or silently rolls back. Before migration begins, `upgrade-resume` can
repeat preparation and stopping. Once migration begins, it can continue activation
only when the existing migration is proven successful; otherwise diagnose the
retained migration container and restore a matching backup if necessary.
Ordinary `up`, `install` and manager replacement refuse an active operation or
unresolved recovery. Explicit `./cybros compose` remains available for operator
repairs; avoid running manual lifecycle commands during a managed upgrade.
An older image alone is not a database rollback. Ordinary `./cybros up` uses
`images.env` after activation. A Nexus-only upgrade preserves rho's actual
immutable image reference in that file, including when creating it for the first
time. Installed components may therefore have different release tags; installation
status reports their individual versions and leaves the combined release null
until they match. A later explicit whole-installation upgrade selects both images.

To add the manager to an older stack or refresh its shipped scripts, rerun the
installer with `--upgrade-manager --no-start`, then run `./cybros up`. This
preserves the locally edited `compose.yaml`, `.env`, `secrets.env` and all data,
and replaces the owned manager and overlays. Set the three full repository
paths in `.env` if using custom images. An installation that already has the
manager can adopt a new wrapper and perform its upgrade in one command:

```sh
sh /path/to/new/release/install/stack/cybros --dir /path/to/installation update 2610080750
```

The wrapper replaces the installed `cybros` only after its default full snapshot
succeeds. Its existing managed overlays must already support the updater.
To update only the manager image, choose
`CYBROS_UPDATER_TAG` in `.env` and run `./cybros update-manager` while no
application upgrade is active. The service never replaces the manager executing
an accepted application upgrade; the host command replaces it before acceptance.
A manager returning combined-application state cannot
serve the Nexus-only administration page; refresh the manager before using that
page. A restored installation may also have a complete
`CYBROS_UPDATER_IMAGE` pin in `.env`; this takes precedence over repository/tag.
For `update-manager`, explicitly change or remove that pin when choosing a new
manager release. Whole-installation `update` uses `CYBROS_UPDATER_IMAGE_REPOSITORY`
as its release source and replaces the installed image pin with the selected digest.
`CYBROS_POSTGRES_IMAGE` similarly pins the PostgreSQL image for a restored stack.
An image pinned by local `sha256:` config ID must already be cached on that Docker
host; it cannot be pulled from a registry. Use `up` with those local images;
`install` and `update-manager` explicitly pull their selected references.

This pre-release version assumes a freshly initialized database; existing
development databases are rebuilt when the schema changes incompatibly. Stable
public releases will retain incremental Rails migrations for installed databases;
the pre-release reset assumption is not the public upgrade policy. New
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

For a consistent complete backup, finish any accepted upgrade, then stop the
stack and its updater. The bundled backup command uses the updater image already
cached locally; it needs no host Ruby, `sudo`, or tar implementation:

```sh
cd "$HOME/.local/share/cybros"
./cybros stop
./cybros backup                # prints {id, created_at, size_bytes, path} as JSON
./cybros backups               # installation and database backup inventory
./cybros up
```

Snapshots live under `backups/installations/<backup UUID>/installation/`, with a
private sibling `snapshot.json`. They contain `.env`, `secrets.env`, Compose and
management files, PostgreSQL files, uploaded bytes, rho home/work and updater
receipts. File owners, permissions and symlinks are preserved. Snapshot images
are frozen to the actual Nexus, rho, PostgreSQL and updater container images,
using a registry digest when available and otherwise a cached local config ID.
Creating a backup never changes the active installation's image settings.

The backup root is mode `0700` and contains credentials and encryption keys. Copy
the complete snapshot privately to another disk for protection against disk
loss. Backups do not contain Docker image layers, external symlink targets, or
custom bind-mounted directories outside the installation. Back those up
separately and preserve image availability. Known runtime sockets, temporary
files and the `backups/` tree itself are excluded. Backup and restore refuse
running managed services or a retained running migration container. A running
updater holds the same lock and must also be stopped.
Operator-created `compose run` jobs are outside managed service ownership; finish
or stop any such job that writes installation data before taking a snapshot.

`CYBROS_BACKUP_KEEP='3'` in `.env` controls retention; choose a positive integer.
The newest three completed full snapshots and the newest three completed
pre-migration database exports are retained independently. Older tool-owned
outputs are removed only after a new backup of that kind succeeds. Failed
backups do not remove a good copy, and unrelated files are not retention targets.
The backup destination needs the estimated source size plus 256 MiB of free
space; errors leave the original installation intact.

To rehearse recovery on the same Docker host, stop the original installation
and restore a listed backup into a new, empty directory. Replace `BACKUP_ID`
with the UUID from `backup` or `backups`:

```sh
./cybros stop
mkdir -m 700 "$HOME/cybros-restore-drill"
./cybros restore BACKUP_ID "$HOME/cybros-restore-drill"
# Still in the original installation: remove its stopped containers and networks.
# These commands retain all bind-mounted data; do not add volume-delete options.
./cybros compose down
./cybros manager down
cd "$HOME/cybros-restore-drill"
./cybros up
./cybros status
```

Restore prints `{id, directory, started:false}` and never starts the copy. Removing
the original stopped containers matters: both copies initially use the same
Compose project name, and an existing manager container would still mount the
old directory. Alternatively, configure a separate project name, ports and
browser URLs before starting an independent copy. Verify that the restored
browser can sign in, read an existing conversation and read saved settings; then
check a normal conversation against a configured model if inference is needed.
Successful file copy or HTTP health alone does not verify decrypted provider
credentials or model execution. Keep the original directory until rehearsal is
complete. On Linux, give the top-level restored directory and management files
to the new operator if their UID differs; the container entrypoints prepare
application and PostgreSQL data ownership.

If a migration failed, `./cybros stop` intentionally refuses unresolved recovery.
Inspect the receipt and retained migration container first. Once that container
is confirmed stopped, explicitly run `./cybros compose stop` and
`./cybros manager stop`, then restore a matching earlier full snapshot into an
empty directory using the procedure above. Do not start old images against a
database that may already have been migrated. A failed restore can leave a
partial destination; inspect it and choose a fresh empty directory before retrying.

For migration across CPU architectures or PostgreSQL major versions, use a
logical database export/import instead of assuming physical database files are
portable. Host bind mounts make the files accessible; they do not change
PostgreSQL's physical-format compatibility requirements.
On another machine, install Docker, copy the completed snapshot preserving its
ownership and permissions, and make its frozen images available before starting
the copied `installation/` directory. A local image-ID pin requires transferring
that image separately or explicitly selecting a proven matching registry digest.
Do not copy a live PostgreSQL data directory as a valid backup.

Managed upgrades default to creating `backups/databases/<operation UUID>.sql`
after application shutdown and before migration. The private mode-0600
`pg_dumpall` export is written and flushed before its completed name is published.
A failed export blocks migration; resuming adopts an already completed export.
The browser receipt exposes only creation time, byte size and current
availability. SQL and filesystem paths never enter browser progress. An old
receipt can report an unavailable backup after retention removes its file.
The browser checkbox or CLI `--no-backup` can disable this export and its storage
checks. The boolean choice is frozen in the accepted receipt, including retries
and explicit recovery. Nexus browser upgrades back up only the database; the host
CLI's default full snapshot also preserves uploads, rho state and configuration.

For an online database-only logical export:

```sh
./cybros compose exec -T db pg_dumpall -U postgres > nexus-databases.sql
```

That file, like the automatic pre-migration export, does not include uploaded bytes or rho credentials, and its separate
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
