# Backup and restore

All durable data of a stack installation is in its directory:

```text
cybros/
  .env
  secrets.env
  compose.yaml
  deployment.compose.yaml   managed application image and socket overlay
  updater.compose.yaml      separate upgrade-manager project
  images.env                immutable image references after activation
  cybros
  data/
    postgres/        PostgreSQL's databases
    nexus/storage/   uploaded files and other storage
    rho/home/        OAuth credentials, settings, logs and instance identity
    rho/work/        the runner's default /home/runner directory
    updater/         upgrade receipts and progress logs
    updater-ipc/     private Unix socket shared only with Nexus
```

Host projects mounted from outside this directory are not part of the backup.

## Take a backup

Finish any accepted upgrade, then stop the stack and take the snapshot. The bundled command uses the cached updater image and needs no host Ruby, `sudo` or tar:

```sh
cd "$HOME/.local/share/cybros"
./cybros stop
./cybros backup        # prints {id, created_at, size_bytes, path}
./cybros backups       # inventory of installation and database backups
./cybros up
```

Snapshots live under `backups/installations/<backup UUID>/installation/` and contain `.env`, `secrets.env`, Compose and management files, PostgreSQL files, uploaded bytes, rho home and work, and updater receipts, with owners and permissions preserved. Images are frozen to the exact Nexus, rho, PostgreSQL and updater images. The backup root is mode `0700` and contains encryption keys: copy a complete snapshot privately to another disk.

Backups exclude Docker image layers, external symlink targets and custom bind mounts outside the installation. `CYBROS_BACKUP_KEEP` in `.env` (default `3`) keeps the newest completed full snapshots and the newest pre-migration database exports independently; a failed backup never removes a good copy.

Copying a live PostgreSQL directory is not a valid backup.

## Restore

Rehearse on the same host by restoring a listed backup into a new, empty directory while the original is stopped:

```sh
./cybros stop
mkdir -m 700 "$HOME/cybros-restore-drill"
./cybros restore BACKUP_ID "$HOME/cybros-restore-drill"
# Still in the original installation: remove its stopped containers and networks.
# These retain all bind-mounted data; add no volume-delete options.
./cybros compose down
./cybros manager down
cd "$HOME/cybros-restore-drill"
./cybros up
./cybros status
```

Restore never starts the copy. Removing the original's stopped containers matters because both copies share a Compose project name until you configure another. Verify that the restored browser can sign in, read an existing conversation and read saved settings, then run a normal conversation if inference matters: file copy and HTTP health alone do not prove decrypted provider credentials or model execution. Keep the original until the rehearsal is complete.

If a migration failed, `./cybros stop` refuses unresolved recovery: inspect the receipt and the retained migration container, explicitly run `./cybros compose stop` and `./cybros manager stop`, then restore a matching earlier snapshot into an empty directory. Do not start old images against a database that may already have been migrated.

## Moving between machines and architectures

On another machine, install Docker, copy the completed snapshot with its ownership and permissions, make its frozen images available, then start the copied `installation/` directory. For a different CPU architecture or PostgreSQL major version, use a logical export and import rather than physical files:

```sh
./cybros compose exec -T db pg_dumpall -U postgres > nexus-databases.sql
```

A database export contains neither uploaded bytes nor rho credentials; it is not a full-stack point-in-time backup.

## Automatic pre-migration exports

Managed upgrades write `backups/databases/<operation UUID>.sql` after application shutdown and before migration, mode `0600`. A failed export blocks migration. The browser upgrade backs up only the database; the host `update` command's default full snapshot also preserves uploads, rho state and configuration.

## Secrets

`secrets.env` holds independent database, Rails and Active Record encryption secrets. If it is lost, restore it from a backup; never generate replacement encryption keys for an existing database. The installer refuses to invent secrets when data already exists.
