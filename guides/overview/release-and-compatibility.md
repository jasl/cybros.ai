# Release and compatibility

Cybros follows a rolling release. There is no numbered product release and no release tag you need to install.

## Channels

| Installation | What it follows |
| --- | --- |
| Docker stack | The published `latest` images for `linux/amd64` and `linux/arm64`. `./cybros update` pulls a release labeled by its UTC build minute. |
| Host installation of rho | The `main` branch of the public repository. `rho update` fast-forwards the checkout and reruns the installer. |
| Source | `main` of [jasl/cybros.ai](https://github.com/jasl/cybros.ai). |

Each published image records the source commit it was built from. Installed components may carry different release labels after a Nexus-only upgrade; installation status reports them individually.

## Compatibility expectations

- **Interfaces can change incompatibly.** The Agent API, Platform API, OAuth contract and rho's control surface are live contracts, but before a stable release a correct design wins over compatibility with a previous shape. Writers, readers, clients and documentation change together.
- **Database schemas can change incompatibly.** The pre-release stack assumes a freshly initialized database when the schema changes incompatibly. Stable public releases will keep incremental migrations for installed databases.
- **An older image is not a rollback.** Selecting an older image does not reverse a database migration. Back up before upgrading and record the images in use alongside the backup.
- **Retained public identifiers are stable.** Resource `public_id` values are UUIDv7 strings and do not change when a record is retained. A destructive rebuild creates new resources and new identifiers.

The memory collection schema requires a fresh installation and matching Nexus, rho and SDK clients.
It does not convert the former owner-scoped memory documents, execution captures or pending work. Keep the old installation's
backup separately; do not restore its database, queue or rho recovery state into the new runtime.
Initialize Nexus, reconnect rho and its executors, and recreate declarations against the current
API. An ordinary upgrade command does not perform this destructive rebuild.

## Before you upgrade

1. Stop the installation and back up the complete directory, including `secrets.env`, the databases, uploaded bytes and rho state. See [Backup and restore](../operate/backup-and-restore.md).
2. Preserve separate backups for host projects mounted outside the installation directory.
3. For a compatible schema, run the upgrade through `./cybros update` (stack) or `rho update` (host). For an incompatible schema, initialize a fresh installation and retain the old backup separately. Both upgrade commands are described in [Status, logs and upgrades](../operate/status-logs-upgrades.md).

## Verification

GitHub Actions runs smoke tests and key quality checks on the public repository. Full acceptance — complete test suites, end-to-end journeys and installation checks — runs locally before a snapshot is published. A green CI run alone does not prove that a model request works; verify with an ordinary conversation after setup.

## Licensing

Nexus is licensed under the O'Saasy license. The rest of the repository defaults to MIT; subdirectory and third-party licenses take precedence for their contents.
