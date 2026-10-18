---
title: Manage scheduled work
description: Inspect saved schedules, manage their clock, and follow the exact result of each occurrence.
---

# Manage scheduled work

Open **Workspaces → Work → Schedules** to inspect scheduled jobs in that Workspace. Use this view to check the next occurrence, pause future work, start an
extra occurrence, or trace an occurrence to its accepted input and result.

Create and edit job instructions and rules in the application or SDK. The
[schedule contract](../reference/agent-api/schedules.md) defines captured policy,
rule bounds, idempotency and concurrency. Nexus runs the persistent clock and
provides the following browser management and reading paths.

## Find a job

Filter by schedule status within the Workspace. Opening **Schedules** from a
Conversation lists only that Conversation's jobs. The list uses your current conversation access, including
when you are an administrator.

Open a job to read its saved prompt, answerer, model, rule, next occurrence, and
last dispatch error. Expand **Saved configuration** for the captured execution
settings. The page shows when it was read; use **Refresh** to update the clock
and execution state. Returning from detail preserves the originating list and
its filters.

The job clock and its child execution have different states:

| Schedule state | Meaning |
| --- | --- |
| Active | The clock can dispatch future occurrences |
| Paused | Future occurrences are paused |
| Canceled | Future occurrences are canceled |
| Completed | A one-time clock has dispatched |

A completed one-time clock can still have a queued, running, blocked, or failed
child. A failed child does not cancel a recurring job.

## Manage occurrences

Commands require write access to the parent conversation. The detail page
shows commands available for the job's current state.

| Command | Effect |
| --- | --- |
| Pause | Pause future occurrences; leave accepted work alone |
| Resume | Schedule the next future occurrence |
| Run now | Start one extra occurrence using the saved instructions |
| Cancel | Cancel future occurrences and remove the last scheduled input if still queued |

**Run now** leaves the regular clock and job status unchanged. It is available
for active and paused jobs. An unfinished earlier occurrence prevents another
execution; the page reports the refusal and retains the current job state.

Canceling a completed one-time job can still remove its queued input. Once the
input has become a turn, canceling the job leaves that execution running. Open
the child conversation or Run to use its ordinary stop controls.

An archived conversation in a live workspace still permits pause,
resume and cancel with write access, but refuses **Run now**.
An archived or archiving workspace refuses these writes. Administrator status
does not bypass conversation access.

If a **Run now** response is lost, inspect the execution history before deciding
to try again. This command has no creation receipt and is not automatically retried.

## Follow an occurrence

The detail page shows the latest execution when its child is readable. Open
**Execution history** for earlier occurrences. Each row separates the nominal
scheduled time from the actual child creation time.

For a queued or blocked occurrence, **View input** opens its exact accepted
input. Once materialized, **View result** opens the scheduled candidate,
including its automatic provider fallback. A later manual regeneration or
activation in that child does not replace this result.

**View Run** appears when a Run identity is available. The Run applies its own
read permission, so access to a result does not guarantee access to execution
details. A tool-less reply can have a readable result without a Run.

Child conversations and results use their current access rules. A deleted or
unreadable child is omitted from history. An unavailable latest child leaves
the latest-execution section empty without removing readable older history.
A hidden turn, concealed candidate, or deleted result cannot be opened from an
older link.

## Next

- Read the [schedule contract](../reference/agent-api/schedules.md) for clock,
  dispatch, callback, and pagination rules.
- Read [conversation turns](../reference/agent-api/conversation-turns.md) for
  exact candidate reads and inherited conversation views.
