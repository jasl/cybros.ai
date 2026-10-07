# Household coordination example

This small personal extension exercises rho's package lifecycle and Nexus's
business-state, schedule and artifact APIs. All observations are supplied fixture
events and all notices are explicitly simulated. It connects no camera, worker
tracking service or messaging account.

The workflow is a sourced observation, explicit triage, one outstanding cleaning
assignment, a simulated notice, acknowledgement and separate completion evidence.
Observing an untidy room never dispatches a worker on its own. Repeated events or
ordinary retries do not create another outstanding assignment or another notice
for the same delivery key. Acknowledgement is not completion.

## Install, check and activate

Copy this directory into rho's writable work root before editing it. Install
Minitest 6 or later in the same Ruby environment as rho if it is not already
available; the manifest declares this dependency for the example's check suite.
With the connected daemon running:

```sh
rho extensions install /absolute/work/household-ledger
rho extensions check household-ledger FULL_VERSION_DIGEST
rho extensions activate household-ledger FULL_VERSION_DIGEST \
  --configuration /absolute/work/household-ledger/configuration.json
rho extensions list
```

Use the full version from the installation result. Installation copies the
source and tests; activation selects that version and configuration. Both stay
local to rho and survive a restart. The user controls their backup. The installed
tool name is `household_cleaning_<version prefix>`; use the exact announced name.

The package name is `household-ledger`; its static runtime id is
`personal.household-ledger`. The manifest describes its configuration without
loading the extension. Selection, sparse configuration and the previous complete
code/configuration pair live together in `RHO_HOME/settings.json` under that id.
Disabling the plugin keeps its selected version and configuration for re-enable.
Its schedule capability depends on the enabled `rho.schedules` plugin.

`configuration.json` starts with `enabled: false`, the fixture's permission to
send simulated notices. This field is separate from enabling the plugin itself.
Set it to `true` only after
choosing the public rooms and each room's recipient, accepted observation/check-in
sources, working weekdays (`0` is Sunday), daytime interval and UTC offset. The
example uses one daily interval and a fixed offset, not an IANA/DST calendar.
Re-activate the same installed version with the changed configuration to apply it.

At most 16 rooms are configured. `fresh_for_seconds` must be 60–86400 and
`remind_every_seconds` 60–604800. Changing a rule does not rewrite an existing
assignment's assignee or its accepted reminder interval; complete/cancel the old
assignment's reminder and create future work under the new rule as needed.

## Fixture workflow

Call the announced tool from the household's conversation. Supply the real current
timestamp for a fixture event when trying it interactively:

```json
{"action":"observe","room":"hall","event_id":"spill-1","source":"fixture-observer","observed_at":"2026-10-07T10:00:00+08:00","finding":"untidy"}
```

Then explicitly triage the observation:

```json
{"action":"triage","room":"hall","reason":"The reported spill needs cleaning before the room is used."}
```

Triage is suppressed while disabled or outside working periods, and refuses
stale/clear observations. It returns a cleaning work ID, an `assigned` state and
the fixture notification receipt. A repeated triage reconciles an outstanding
assignment. A completed assignment is not reopened from its old observation;
a new sourced observation is required.

Use that work ID for subsequent evidence:

```json
{"action":"acknowledge","room":"hall","work_id":"WORK_ID","worker":"fixture-worker","source":"fixture-worker-report","note":"Accepted the assignment."}
```

```json
{"action":"complete","room":"hall","work_id":"WORK_ID","worker":"fixture-worker","source":"fixture-worker-report","note":"Spill removed and floor inspected."}
```

Completion requires the prior acknowledgement, records separate source/time/note
evidence, cancels the reminder schedule and returns a JSON artifact through the
normal tool-result capture path. The task result retains those bytes; the store
does not pretend that an embedded upload UUID would retain them. These are
reported observations and evidence, not physical verification of cleaning.

`status` returns a purpose-specific room projection. `check_in` records an agreed
worker report using `event_id`, `source`, `observed_at`, `worker` and
`reported_room`. Status always includes its source/time and calls it
`recent_report` or `stale_report`; it never presents a last-seen location as a
verified current location. Private rooms and unconfigured sources are refused.

## State, reminders and delivery

One `household.cleaning` conversation-store entry per room holds its latest
observation/check-in and current assignment. The existing 64-entry host limit and
1 MiB value bound still apply across namespaces. This is bounded current state;
completed result artifacts and conversation history retain earlier evidence.
The public tool omits raw store coordinates, locking fields, pending-delivery
data and schedule-authoring policy. It does not inject this state as memory.
Copied fork records cannot operate their source conversation's assignment.

Nexus owns reminder timing. Triage creates an ordinary interval schedule with the
calling round's model, tools and approval policy through rho's schedule owner.
The accepted request is retained until an ambiguous create can be reconciled
with the same idempotency key and payload. No daemon timer is the durable owner.
When a scheduled child calls `remind`, its source conversation is accepted only
if it is the direct parent and that schedule identifies the child as its latest
execution. The reminder then reads and updates the original assignment, rather
than creating private state in each scheduled child.

Disabling the configuration suppresses future triage and notices, including due
reminders. `cancel_reminders` with `room` and `work_id` explicitly cancels an
outstanding schedule. Already-running calls follow normal Nexus cancellation;
disablement does not undo a notice already accepted. If disabling the entire
package, cancel its outstanding schedules first so they do not keep attempting
an unavailable tool. Installing different code produces a different served tool
name; old accepted schedules do not silently execute replacement code. Cancel
and recreate those schedules deliberately when upgrading a live workflow.

`FixtureNotifier#deliver(idempotency_key:, recipient:, message:)` is the
replaceable delivery boundary. Its deterministic receipt says `simulated: true`
and performs no outbound IO. A real adapter must use its receiving service's
idempotency/reconciliation feature for that key, finite timeouts and explicit
delivery receipts. If a destination cannot deduplicate, report ambiguous delivery
instead of claiming exactly-once sends. The example tests a lost response after
acceptance with an authored idempotent sink; it does not qualify a real service.

## Verification

From the rho project directory:

```sh
bundle exec ruby examples/household-ledger/test/household_test.rb
```

The package's `rho extensions check` runs the same self-contained tests after
installation. They cover repeated observations, separate acknowledgement and
completion, lost schedule/notice responses, restart with persisted state,
completion racing schedule creation, freshness, scope and disabled rules. The
actual package loader and normal completion capture are exercised too. The E2E
journey `e2e/test/rho_household_test.rb` drives the package through a connected
rho and real Nexus APIs with the local fake model provider. Device, notification
provider and semantic triage quality remain separate checks.
