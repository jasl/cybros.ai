# Monitor and troubleshoot

## Is the runner connected?

```sh
rho status                         # on the runner
docker exec rho-runner rho status  # in a container
rho runners                        # from the agent's installation: eligible runners
```

In the Nexus browser, **Runners** lists each runner you manage with its presence (`online` while an inbox subscription is open, `offline` with `last_seen_at`, `not_yet_seen`) and credential state. Presence is display only; Nexus addresses work by eligibility, never by presence, so an offline runner simply accumulates addressed rows until it returns or the task deadline settles them.

`last_seen_at` means only "current-epoch address contact" — not health, not readiness, not that a task will succeed.

## Nothing is executing

| Check | What to look at |
| --- | --- |
| Is the runner selected? | The conversation's runner, or `rho runners use`. A call with no target fails `runner_target_required`; a call addressed to an ineligible runner fails explicitly rather than moving to another runner. |
| Is the call parked for approval? | The conversation shows it; a runner only sees granted calls. |
| Does the runner announce the tool? | `GET /agent_api/v1/executors/{id}` shows `services.runner.tools`. A name nobody serves fails `tool_not_served`. |
| Is the credential live? | `rho status`; reconnect with `rho connect` after revocation, expiry or a replaced pairing. A `401` is never explained. |
| Is the runner eligible for the agent? | Check its [assignment scope](deploy.md#identity-and-scope) or application ownership for a Local environment. |

Another rho instance's bundled Runner is absent from `rho runners`, even when the same Human manages both instances. Local capability follows application ownership. Connect an independent Runner when those instances should share an execution environment. The Nexus **Runners** page lists the Human's managed registrations; that management list is broader than one Agent's eligible Runner list.

## A task expired

A claimed call that passes its deadline with no result is settled by the sweep from its frozen effect profile: a replayable call fails `tool_timeout` and may retry; a non-replayable call becomes `uncertain` and waits for a person's `retry` or `abandon` because its effect may already have happened. Long tools extend their own deadline; a runner that cannot extend in time should commit partial results rather than go silent.

## Stop cleanly

Give containers a 30-second grace period. rho handles termination, stops the process groups it owns and lets a claimed call commit or expire by its own deadline. Nexus claim fencing, expiry and result integrity remain authoritative whatever the runner does.

## Logs and diagnostics

- `docker logs rho-runner`, or the service manager's log on a host.
- `rho doctor --strict` checks the installed runtime and tools (Playwright, document tools) without making a model request.
- `./cybros logs rho` for the stack's runner.

Before sharing logs, remove credentials, private setup links, private prompts and file contents.

## Manage an address

Open the Runner name to inspect its saved tools, documents, environment and related
readable Runs. Empty capability lists are saved facts, not proof that the program
never announced. Related Runs use retained Task targets or current claimants;
collected execution details and unclaimed provider pool work supply no association.
The counts describe Run states, not the machine's current load.

**Revoke credentials** ends authentication for all existing credentials but retains
the address. Re-pair the program, or issue a new application executor key.
**Revoke runner** permanently ends that address; a later connection creates a new one.
Both actions return to the original details so you can inspect its resulting state.
Revoking one static application key leaves other keys alone.
Only the current Human manager can manage the Runner, including account-wide Runners.

Revocation does not prove that remote processes stopped or files were rolled back.
Already-started work retains its deadline and effect handling. Choose a Runner for
new work in the application or SDK; this console does not switch a running Conversation's
Runner, migrate its files or manage the deployed program's upgrades.
