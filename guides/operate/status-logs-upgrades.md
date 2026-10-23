# Status, logs and upgrades

Commands run from the stack's installation directory.

```sh
./cybros status
./cybros instructions          # browser URLs and setup steps
./cybros logs                  # last 100 lines from each service
./cybros logs nexus
./cybros manager logs          # upgrade-manager diagnostics
./cybros compose logs -f rho   # ordinary Compose for follow and tail options
./cybros stop                  # preserves every data directory
./cybros up
```

## Upgrade the stack

```sh
./cybros check                 # explicit preflight; accepts nothing
./cybros update                # full backup, matching manager, then application upgrade
./cybros update 2610080750     # select the 2026-10-08 07:50 UTC release
./cybros update --no-backup    # skip the full snapshot and database export
./cybros upgrade-status        # latest accepted upgrade, including after interruption
./cybros upgrade-log           # the latest upgrade's bounded progress window
./cybros upgrade-resume ID     # resume a safe recorded phase without repeating migration
```

`update` resolves and pulls the matching manager release, checks that execution is idle before its offline snapshot, stops the installation, creates the snapshot, replaces the manager and requests the application upgrade. The updater pulls the selected images, drains active Nexus execution, stops the application services (PostgreSQL keeps running), writes a private database export when selected, performs one migration, starts the new images and checks their health and worker processes. Release labels are UTC `yyMMddHHmm`; `latest` resolves once to a concrete release, and accepted upgrades freeze image digests in `images.env`.

A failed pull leaves the running application alone. A failed database export prevents migration and keeps the application stopped for explicit recovery. A failed or uncertain migration leaves services stopped and records recovery guidance; the updater never resets a database, retries an uncertain migration or silently rolls back. `upgrade-resume` can repeat preparation before migration began, and can continue activation afterward only when the migration is proven successful; otherwise inspect the retained migration container and restore a matching backup.

::: warning Pre-release databases
This pre-release assumes a freshly initialized database when the schema changes incompatibly.
The memory collection schema requires that rebuild and has no conversion for the previous data
model. Follow the [compatibility policy](../overview/release-and-compatibility.md) before choosing
an upgrade path. Stable releases will keep incremental migrations. An older image never reverses a migration.
:::

### Nexus-only upgrade from the browser

An active administrator can open **System upgrade** in the Nexus admin area or **Settings → System upgrade → Nexus** in Rho, review current and candidate image references and preflight checks, and confirm. **Back up the database before upgrading** starts checked. This replaces Nexus and its worker processes only; rho's image and process are unchanged, and its connection is unavailable while Nexus restarts. The page follows a durable receipt and reconnects after the restart; closing the tab does not cancel. Only one upgrade runs at a time, from either the CLI or the browser. Standalone Nexus installations without the updater show the feature as unsupported. Rho sends Nexus upgrades through the existing administrator API and retains the exact request and idempotency key if acceptance is uncertain.

Before stopping Nexus, the updater closes execution admission and waits up to five minutes for active model requests, claimed Runner tools, running kernel tools and provider authorization exchanges to finish. Nexus stays online for their result commits. A drain timeout restores admission and refuses the upgrade before stopping services. Waiting work retains its execution clocks across maintenance, and work paused by a user remains paused. After migration and healthy startup, admission resumes and the existing loops continue.

An older Nexus release without this maintenance mechanism must be idle for its first upgrade; active work is refused before services stop. The host's full installation snapshot is also an offline operation requiring idle execution.

### Rho-only upgrade from the browser

Open **Settings → System upgrade** in Rho to check the configured image
repository, review the candidate and preflight checks, and upgrade Rho. The page
follows the same durable receipt through the restart; closing it does not cancel
accepted work. This replaces only Rho, without stopping Nexus, backing up its
database or running a migration. Use the host commands above for a complete
installation upgrade and backup. A Rho installation without the managed updater
shows the appropriate host or image upgrade instructions.

### The manager

The separate updater container owns installation lifecycle operations and the Docker socket; it publishes no HTTP port. Nexus and Rho receive only its private Unix socket and request upgrades for their own application. To add the manager to an older stack or refresh its scripts, rerun the installer with `--upgrade-manager --no-start`, then `./cybros up`. `./cybros update-manager` updates only the manager image while no application upgrade is active.

## Host installations

`rho update --dry-run` previews; `rho update` fast-forwards the installation's checkout and reruns its installer, with `--rollback` returning to the saved runtime and gem pair. Restart through the service manager that owns rho. Inside a container, `rho update` refuses: replace the image instead.

## Health is not inference

`./cybros status`, `rho status` and `rho doctor --strict` report service and connection state. None of them makes a model request. After an upgrade, verify with a normal conversation against a configured model.
