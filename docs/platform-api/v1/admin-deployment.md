# Nexus deployment administration

Deployment resources require a currently active Human owner or administrator.
The [Platform authentication rules](../v1.md#authentication) apply: bearer
credentials authorize writes; a same-origin browser Session cookie authorizes
only safe reads. Nexus's HTML `/admin/deployment` page submits its writes to
CSRF-protected HTML controllers. Agent/member-plane and executor credentials do
not authorize either management surface. Authentication and administrator
authority are checked again for later reads and during progress streams.

Nexus delegates fixed commands to the installation's private Unix socket,
configured by `NEXUS_DEPLOYMENT_SOCKET`. It has no Docker socket, registry
credentials, deployment database table, or background upgrade job. The separate
installation owner retains accepted work while Nexus is stopped or restarted.
Every command and read is fixed to Nexus. This surface neither manages agent
application releases nor exposes combined-installation receipts or logs. Joint
upgrades belong to the installation CLI; the browser has no scope selector.
The [Docker stack guide](../../../install/stack/README.md#status-logs-and-upgrades)
describes installation, image repositories, backups and CLI recovery.

## Resources

```text
GET /api/v1/admin/deployment
POST /api/v1/admin/deployment/release_check
POST /api/v1/admin/deployment/upgrades
GET /api/v1/admin/deployment/upgrades/{id}
GET /api/v1/admin/deployment/upgrades/{id}/log?cursor=...
GET /api/v1/admin/deployment/upgrades/{id}/stream?cursor=...
```

| Method and path | Result |
| --- | --- |
| `GET /api/v1/admin/deployment` | `200 {"deployment": ...}`; local observation only |
| `POST /api/v1/admin/deployment/release_check` | `200 {"deployment": ...}` with an explicit release and installation preflight report, including blocked results |
| `POST /api/v1/admin/deployment/upgrades` | `202 {"upgrade": ...}` and `Location` of the durable receipt |
| `GET /api/v1/admin/deployment/upgrades/{id}` | `200 {"upgrade": ...}` |
| `GET /api/v1/admin/deployment/upgrades/{id}/log?cursor=...` | `200 {"log": ...}`; bounded log window |
| `GET /api/v1/admin/deployment/upgrades/{id}/stream?cursor=...` | Bounded SSE observation window; reconnect to the same operation |

An unset socket returns a deployment with `supported: false`, empty `sources`,
and null installed/candidate/preflight/operation fields. A configured but unreachable
owner returns `503 updater_unavailable`. Neither case enables an upgrade by
another route. A manager that returns a combined-application image list is also
unavailable to this client; update the independent installation manager before
using Nexus-only administration. Non-Nexus upgrade selections are rejected
locally before IPC. Responses are not cacheable.

## Check and select

The optional check body is `{"release_check":{"tag":"latest","backup":true}}`.
Omission selects `latest` and enables the database backup. Set `backup: false`
to check an upgrade that skips the backup. A published release uses exactly ten digits in UTC
`yyMMddHHmm` format (`%y%m%d%H%M`), for example `2610080750` for
2026-10-08 07:50 UTC. The year is `2000 + yy`; the calendar date, hour and minute
must be valid. The installation updater validates the selector and returns
`400 invalid_request` for an invalid tag. Unix-second and fourteen-digit tags
are not supported.
Checks have a bounded registry deadline and do not pull image layers or stop
services. They also inspect the installation's upgrade prerequisites. Nexus
allows up to 120 seconds for this check through the installation socket; its
browser waits up to 130 seconds for the response. Ordinary
deployment reads only return saved observations and local backup availability;
they never run Docker or perform a registry check.

A deployment contains:

- `supported`: whether this Nexus has an installation updater configured.
- `sources`: `{name, reference}` entries for Nexus's configured image repositories.
- `installed`: the known Nexus release and image references, or null when unavailable.
- `candidate`: the release resolved by the latest check, or null if registry
  resolution failed; a blocked installation preflight retains a resolved candidate.
- `preflight`: the latest explicit preflight report, or null before a check.
- `active_operation` and `last_operation`: Nexus-only receipt objects or null.

A release has `release` and `images`, where each image has `name` and
`reference`. Installed release metadata may be unknown for older images.
A candidate additionally has `checked_at`, nullable `source_revision`, and
nullable `source_url`. Its image references are immutable native-platform
manifest digests, such as `registry.example/nexus@sha256:...`. These images
serve Nexus and its workers only. In the Docker stack this is one `nexus` image;
its `org.opencontainers.image.version` identifies the selected release.
Agent applications may run a different release and never enter this selection.

A preflight contains required `checked_at`, `ready`, `backup`, and `checks` fields.
The boolean `backup` records the choice used by that check.
Each check has required `name`, `status`, `message`, `next_step`,
`available_bytes`, and `required_bytes` fields. Status is `passed`, `blocked`,
or `warning`; `next_step` and both byte counts are nullable. Byte counts are
nonnegative integers. Names identify the installation owner's fixed, bounded
set of checks; Nexus does not interpret product-specific names.

The installation checks the native-platform Nexus image, Compose
configuration, running database, and active or unresolved upgrade work. When
backup is selected, it also checks database size and enough free space for the
backup on the installation filesystem. Skipping backup omits those backup-only
checks. Docker image-store capacity
is a manual-check warning. Warnings can coexist with `ready: true`; a blocked
report has `ready: false`. A completed check returns `200` even when blocked,
so callers can read the reasons and next steps. The browser disables upgrade
until a report is ready and its backup choice matches the checkbox. The checkbox
is initially checked; changing it requires a matching release check. The installation owner enforces that condition and
checks again before executing an upgrade; a saved report is not a guarantee that
later conditions remain unchanged.

To start, send a fresh UUIDv7 `Idempotency-Key` header and the selected candidate:

```json
{
  "backup": true,
  "candidate": {
    "release": "2610080750",
    "images": [
      {"name": "nexus", "reference": "registry.example/nexus@sha256:<64 hex digits>"}
    ]
  }
}
```

Copy the complete `release` and `images` returned by the check; the example
illustrates the Docker adapter's Nexus selection. The optional top-level
`backup` boolean defaults to `true` and must match the checked preflight. The browser cannot supply scope,
agent application selectors, shell commands,
paths, repository overrides, environment values or Compose arguments. Nexus
sets the initiating Human public ID from its authenticated principal.

Acceptance is durable before `202`. While its receipt is retained, exact replay
of the same key, Human, selection and backup choice returns the existing operation; a changed envelope returns
`409 idempotency_conflict`. A different active operation returns
`409 upgrade_in_progress`, with `error.operation_id` only for another Nexus-only
operation. A combined installation operation also blocks admission, but its
receipt and logs remain installation-owned. Unresolved interrupted or
failed lifecycle work returns `409 recovery_required`. A candidate that no
longer matches the checked selection returns `409 candidate_changed`.
Absent, blocked or backup-mismatched preflight returns `409 preflight_failed`. Read the saved
report and complete its next steps before explicitly checking again.

A dropped connection or unavailable response does not prove rejection. Inspect
the active/latest receipt and correlate its idempotency key; if needed, explicitly
retry the same key, selection and backup choice. The browser retains those exact
request fields in session storage until it can identify the accepted operation
or the request is refused. Never create a new key merely because Nexus
restarted. Observing or reconnecting never resubmits the mutation.

## Receipt and progress

A receipt has UUIDv7 `id`, `idempotency_key`, nullable `actor_public_id` (null for
CLI), `target`, nullable `previous`, `phase`, `status`, `accepted_at`, `updated_at`,
nullable `completed_at`, nullable `error`, nullable `recovery`, nullable
opaque `log_cursor`, required boolean `backup`, and required nullable `database_backup`.
The `backup` decision is frozen at acceptance and retained when the installation
resumes interrupted work. A false value means the backup was deliberately skipped;
`database_backup` remains null. A true value with null metadata means no completed
backup has been recorded yet, including a failure before backup completion.
Error objects carry stable `code` and `message` fields.

When present, `database_backup` has exactly `created_at` (ISO8601), `size_bytes`
(a nonnegative integer), and `available` (boolean). The receipt ID identifies
the backup to the installation CLI. Availability reports whether its local file
is still retained; it does not claim a restore rehearsal succeeded. Metadata
remains readable after retention removes the file. The projection includes no
file path, download URL, database content, or restore control. Administration
authority does not grant export or restoration of members' business content.

Phases are `accepted`, `preparing`, `stopping`, `backing_up`, `migrating`, `activating`,
`verifying`, and `completed`. Status is `running`, `succeeded`, `failed`, or
`interrupted`. A failed or interrupted receipt retains the last reached phase;
it is not evidence that migration or activation finished.

A log window contains `entries: [{cursor, text}]`, `next_cursor`, and
`operation` (the current receipt). Omit the cursor to start at the beginning.
Entries are controlled operation summaries, not raw Docker output or environment
values. Full migration diagnostics remain in the named container's Docker log.
Use the returned opaque cursor for the next window without parsing it. An empty
window retains a cursor for subsequent observation. Windows contain at most
64 KiB of requested log bytes and may be smaller to keep the JSON response
bounded. The installation retains at most 1 MiB of log per operation and the
latest 20 receipts with their logs; an expired receipt returns `404 not_found`.
Idempotency keys have that same retention lifetime. Do not replay an expired
operation; check current installation state and deliberately select a new upgrade.

Streams use the same receipt and log presenter as REST. A stream's initial
request and subsequent emissions require live Human administrator authority.
`deployment.progress.v1` carries `{entries, next_cursor, operation}` and uses
`next_cursor` as its SSE event ID. Terminal status is part of that operation.
`deployment.error.v1` carries `{code, message, operation_id?}` and closes the
window. A query `cursor` takes precedence over `Last-Event-ID`. Each connection
observes at most ten times, one second apart, within a ten-second window; an
already-started local IPC read may take up to five additional seconds.
After a service restart or stream-window end, reconnect with the same operation
ID and last cursor. A browser logout or closed tab stops observation, not the
accepted upgrade. The CLI's `upgrade-status` and `upgrade-log` remain available
when Nexus cannot start.

Preparation pulls the frozen Nexus image before stopping Nexus and its workers. The installation
then saves a database-only backup before migration when the accepted `backup`
choice is true. A false choice proceeds directly to migration. That backup excludes uploaded
files, application files, configuration and encryption keys; complete installation
backup and restoration belong to the installation tools. The same backup metadata
is included in receipt, log and progress responses.

Migration
uses one named retained container; activation does not launch another migration.
Success requires Nexus's expected image identity, HTTP health and required worker
processes. The updater never resets a database or performs automatic rollback.
Agent application containers and images remain unchanged; their Nexus connection
is unavailable during the restart. Failed or uncertain migration keeps Nexus and
its workers stopped and requires explicit
operator recovery. An older image cannot reverse a database migration.

## Refusals

Usual authentication failures are `401`; an authenticated non-administrator is
`403`. Invalid consumed input is `400 invalid_request` (Rails shape errors use
the normal Platform envelope), an unknown or non-Nexus receipt is `404 not_found`, the
conflicts above are `409`, and unavailable metadata is `503 release_unavailable`.
Transport failures may be non-JSON. Upgrade execution failures are recorded in
the receipt; they are not a reason to replay an accepted command automatically.
