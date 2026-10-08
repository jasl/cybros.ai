# Installation updater

This independent service owns the Docker installation's lifecycle. Its host CLI
upgrades the combined installation; Nexus administration upgrades only Nexus and
its workers. Both use the same execution lock, receipts and recovery owner. It
keeps PostgreSQL and itself running while it replaces the selected services.
Nexus authorizes Human administrators before sending Nexus-only Unix-socket requests;
the updater accepts no shell commands, paths or deployment configuration from HTTP.
Only Nexus receives the IPC directory. The Docker socket belongs to the updater.

The service uses `CYBROS_INSTALL_DIR` as the actual absolute host installation path,
`CYBROS_NEXUS_IMAGE_REPOSITORY` (default `jasl123/cybros-nexus`),
`CYBROS_RHO_IMAGE_REPOSITORY` (default `jasl123/cybros-rho`), and
`CYBROS_UPDATER_SOCKET` (default `/run/cybros-updater/updater.sock`).
Repository settings accept complete Docker Hub or other registry paths, such as
`ghcr.io/jasl/cybros-nexus`, without tags or digests. Its default state directory is
`<installation>/data/updater`, overridable with
`CYBROS_UPDATER_STATE_DIR`. The state directory is private; the IPC directory is
root:1000 mode 0750 and its socket is mode 0660. Mount the IPC directory, not a
socket inode. Host and updater paths must identify the same bind-mounted files.
`CYBROS_BACKUP_KEEP` is a positive integer (default 3); installation snapshots and
pre-migration database exports each retain that many successful backups.

Compose reads `.env`, optional `images.env`, then `secrets.env`, with
`compose.yaml` and `deployment.compose.yaml`. Upgrades atomically publish both
immutable references in `images.env`, preserving `.env`'s owner and using mode 0600.
Nexus-only upgrades merge the selected Nexus reference with the observed current
rho reference, even when creating `images.env` for the first time. An unselected
component never falls back to a mutable tag.
Ordinary host management must read the same image file. Custom configuration,
secrets, PostgreSQL, storage and rho home/work files are retained.

## Private IPC

Each connection carries one newline-terminated JSON request and response. Requests
are limited to 16 KiB and responses to 128 KiB. The envelope is
`{"status":200,"data":...}` or
`{"status":409,"error":{"code":"...","message":"...","operation_id":"..."}}`.
`operation_id` appears on conflicts that identify an existing receipt.

Requests use the closed `scope` vocabulary `installation` (the CLI default when
omitted) or `nexus`. Nexus's client fixes every request to `nexus`; HTTP input has
no scope parameter. Installation scope can inspect and recover every operation.
Nexus scope returns only Nexus sources, installed version, checked candidate,
preflight and Nexus-only operations. A receipt's exact target image names define
its operation range; there is no second persisted lifecycle. Other receipt/log
reads return `404 not_found`, and conflicts with installation operations omit
their operation ID. All operations still share the same admission/recovery lock.

| Request | Data on success |
| --- | --- |
| `{"operation":"status"}` | Deployment view; no registry request |
| `{"operation":"check","tag":"latest","backup":true}` | Deployment view with preflight report and candidate when resolution succeeded; blocked checks still return 200; tag may also be a UTC `yyMMddHHmm` release tag |
| `{"operation":"upgrade","candidate":{...},"idempotency_key":"UUIDv7","actor_public_id":"UUIDv7","backup":true}` | Durable receipt, status 202; CLI actor is null |
| `{"operation":"receipt","operation_id":"UUIDv7"}` | Receipt |
| `{"operation":"log","operation_id":"UUIDv7","cursor":null,"limit":65536}` | Bounded log window |
| `{"operation":"resume","operation_id":"UUIDv7"}` | Explicit CLI-only recovery; no Nexus HTTP endpoint |
| `{"operation":"assert_idle"}` | CLI-only guard before normal application start or updater restart |
| `{"operation":"refresh_installed"}` | CLI-only observation after ordinary application start; no registry request |

A release selection is `{"release":"2610080750","images":[{"name":"nexus",
"reference":"jasl123/cybros-nexus@sha256:..."},{"name":"rho",
"reference":"jasl123/cybros-rho@sha256:..."}]}`. Image names belong to the
installation adapter. A Nexus-only selection contains just the `nexus` entry.
Candidate metadata adds
`checked_at`, `source_revision` and `source_url` (nullable). Submit only the release
and images fields. Release tags are valid UTC `yyMMddHHmm` dates and times, with
`yy` interpreted as 2000–2099; `2610080750` means 2026-10-08 07:50 UTC.
For installation scope, both selected native manifests must have the same release tag in
`org.opencontainers.image.version`. Mutable tags are resolved once, and later
reads and pulls use only the frozen digests. Nexus scope resolves only its own
manifest and does not require a matching rho release.

The deployment view has `supported`, `sources` (configured repository paths as
generic name/reference pairs, without registry access), nullable `installed`, nullable `candidate`, nullable `preflight`,
nullable `active_operation`, and nullable `last_operation`. An unknown installed
release is null. Observed images include nullable `version` from their OCI labels;
a mixed installation has `installed.release: null` while retaining each component's
version and immutable reference. The Nexus projection derives its release from
its own image, independently of the other installed components.
A receipt has `id`, `idempotency_key`, nullable `actor_public_id`,
`target`, nullable `previous`, `phase`, `status`, `accepted_at`, `updated_at`,
nullable `completed_at`, nullable `error` (`code` and `message`), nullable `recovery`
(text), nullable `log_cursor`, `migrator_name`, boolean `backup`, and nullable `database_backup`.
The latter contains `created_at`, `size_bytes`, and `available`; availability is
checked against the local completed file on each read. No SQL or host file path
is exposed by the IPC or HTTP protocol. Receipt identities are UUIDv7.
Phases are `accepted`, `preparing`, `stopping`, `backing_up`, `migrating`, `activating`,
`verifying`, `completed`; status is `running`, `succeeded`, `failed`, or
`interrupted`. A failed receipt retains the phase that failed.

Preflight has `scope`, `backup`, `checked_at`, `ready`, and `checks`. An omitted scope means
`installation`, matching the request default. Scope records which
components were checked even if release resolution failed. The owner retains
one candidate/report; a later check through another scope replaces it, so a stale
selection must be checked again before acceptance. Every check contains `name`,
`status` (`passed`, `blocked`, or `warning`), `message`, nullable `next_step`, and
nullable integer `available_bytes` and `required_bytes`. Explicit checks inspect
native release manifests, installed images, Compose configuration, PostgreSQL,
backup free space, and pending upgrade/recovery state. Database backup space is
estimated as twice the current database bytes plus 256 MiB; this is headroom,
not a bound on SQL size. Docker image-store free capacity is reported as a
manual warning because it may reside outside the installation filesystem.
Preparation repeats backup-space checks before and after pulling images, before
stopping applications. Ordinary status, receipt, log and browser polling read
the saved report and local files; they do not query Docker or a registry.

Check and upgrade requests accept `backup` as a boolean, defaulting to true. The
accepted choice must match the checked report (`preflight_failed` otherwise) and
is frozen in the receipt. False omits database-size and backup filesystem checks,
both preparation space rechecks, and the `backing_up` phase/export; PostgreSQL
reachability and every other lifecycle gate still apply. Saved reports and
receipts from before this option retain their original mandatory-backup meaning.

A log window has `entries:[{"cursor":"opaque","text":"..."}]`,
`next_cursor` and `operation` (the current receipt). Cursors are opaque base64
offsets; the next cursor is retained at the current end so observers can poll for
more output. Browser logs contain controlled phase/action summaries, not raw
Docker stderr, Compose configuration or migration output. Inspect a retained
migration container's complete output with the host Docker CLI. Logs are capped
at 1 MiB per operation; the latest 20 receipts and their logs are retained.
Idempotent replay is guaranteed while that receipt is retained; keys have no
permanent ledger beyond this retention window. Registry checks have a 60-second budget. Ordinary local
IPC clients use a five-second budget; check clients allow 120 seconds (the browser
allows 130 seconds) for registry and bounded local preflight checks.

Errors include `invalid_request` (400), `not_found` (404),
`idempotency_conflict`, `upgrade_in_progress`, `recovery_required`,
`candidate_changed`, `preflight_failed` (409), `release_unavailable`,
`backup_failed`, `insufficient_space` and `updater_unavailable` (503).
An exact idempotent replay returns its existing receipt even after completion.
Changing the actor, selection or backup choice under that key is a conflict. Disconnecting or
closing the browser never cancels accepted work.

## Execution and recovery

A lifetime file lock excludes a second updater. Acceptance and every effectful
phase are persisted with file fsync, atomic rename and directory fsync. The
updater pulls the frozen selected images. A combined upgrade then stops rho,
jobs, model runner and Nexus; a Nexus-only upgrade stops only jobs, model runner
and Nexus, which are the database writers. rho remains running with its existing
image and temporarily loses its Nexus connection. With PostgreSQL still running,
the updater by default writes a private `pg_dumpall` export to
`backups/databases/<operation UUID>.sql`, then runs one named, retained migration
container and starts only the
application services with `--no-deps`. Completion requires the expected image
identities, selected application health and worker process survival. Nexus-only
activation and verification never recreate, restart or require rho readiness.
No command resets the
database or removes deployment data. The host wrapper defaults to a complete
stopped-installation snapshot before replacing the manager and submitting the
application upgrade; Nexus administration defaults to a database-only export.
There is no automatic database rollback. Database export stdout goes directly
to a mode-0600 file, independently of the bounded command-output channel. It is
flushed and atomically published before migration; its contents and raw stderr
never enter receipts or browser logs. Failed exports remove their temporary
output and prevent migration. Export retention removes only completed,
tool-named exports after a new export succeeds; receipts can outlive their files.

After interruption, a receipt is marked interrupted and further upgrades are
blocked when services or data may have changed. A stop-phase failure can resume
preparation and quiescing of the already frozen target before its first migration.
The receipt stays in `stopping` during this re-preparation, so a failed pull or
space check cannot release the recovery guard. A `backing_up` resume repeats an
incomplete export or adopts its already published file after interruption; it
does not overwrite a completed export if metadata persistence was interrupted.
After migration starts, `resume` only continues activation
when the existing migration container has exited successfully, or the receipt
already reached activation/verification. It never restarts or recreates a
migration. Missing, running or failed migration containers require explicit
operator inspection and repair through the normal Docker/Compose tools. Starting
old images does not undo a migration. Updater failures leave the private receipt
and logs available even when Nexus cannot start.

The image provides these commands for `docker compose exec -T updater ruby
/app/updater.rb ...`:

```text
serve
request                         # one request JSON on stdin, envelope on stdout
check [TAG] [--no-backup]       # preflight JSON; default latest; does not accept
update [TAG] [--no-backup]      # check, accept, stream log, wait; default latest
status                          # deployment JSON
receipt [ID]                    # receipt JSON; defaults to latest
log [ID] [CURSOR]                # bounded log-window JSON
resume ID                       # explicit recovery and wait
assert-idle                     # refuse normal start when upgrade/recovery is pending
refresh-installed               # refresh the local installed snapshot after normal start
```

Offline commands run in a one-off updater container after stopping the stack
and manager, using the same installation lock:

```text
backup                          # full stopped-installation snapshot; JSON metadata
backups                         # JSON installations/databases lists and keep setting
restore BACKUP_ID DIRECTORY      # copy into an existing empty absolute directory
```

The host wrapper adds the restore destination bind at its actual host path.
Backup and restore preserve owners, modes and symlinks without following external
link targets, and refuse running managed services or retained migrators. The
snapshot freezes Nexus/rho references in its `images.env` and PostgreSQL/updater
references in its `.env`, using registry digests or a cached local image ID.
It excludes the backup tree, updater IPC, known rho temporary files and atomic
write temporaries; it includes secrets and application data. It does not include
Docker image layers or custom external bind-mount data. Restore never starts
services or deletes a nonempty target. See the [restore rehearsal](../README.md#back-up-and-restore)
for container-project handling, image availability and physical PostgreSQL limits.

`update` prints the accepted operation ID immediately and exits zero only after
successful readiness. Interrupting this waiting CLI leaves the service executing
the accepted operation. The host wrapper resolves one release, takes its optional
full snapshot with the cached previous manager, restarts the previous services,
and replaces the manager before submitting the application upgrade. Its
`--no-backup` option skips both this snapshot and the service's database export.
Explicit resume uses the receipt's saved choice. See the enclosing installer
documentation for bootstrap of an older host wrapper and pre-acceptance recovery.

Run the offline behavior tests with
`ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'`
from this directory. Real Docker release-transition acceptance belongs to the enclosing
installer and is separate from these command-seam tests.
