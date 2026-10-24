# Runners and tool providers

A runner is an execution environment's delivery address. It serves tools bound to a machine — files, shell commands, processes, a browser, MCP servers — and executes them where the files live: a workstation, a server, a container. A tool provider is the same protocol for tools served by name from a pool rather than a specific environment.

Independent Runners and tool providers are **executors**: they hold a transport credential, announce what they serve, and take work from their own inbox. Those registrations are not account members and receive no member credential. An Agent application can also serve the Runner role on its existing Executor; its separate member credential remains on the member plane.

## Implement a Runner in your Agent

Any Agent application can implement its own Runner service in any language that
can use the executor HTTP protocol. Nexus requires neither rho nor the
`rho-env` Ruby gem. The application chooses its tools and execution machinery;
Nexus owns task addressing, claims, approvals and result settlement.

1. Connect your Agent and obtain its application Executor transport credential
   through [Agent connection](../build/credentials-and-planes.md).
2. [Announce](tools-and-announcements.md) both `services.agent` and
   `services.runner` on that address, keeping `agent` even when its tools are empty.
   Put your environment tools in the Runner service.
3. Serve the shared [inbox](claims-and-results.md) with that transport credential.
   Dispatch by the task's addressed role and tool name, and implement claims,
   cancellation, deadlines and result commits for your handlers.
4. Import the Runner tools with the application's concrete Executor UUID as their
   target. Announcing a tool alone does not select it for an execution.

This built-in service keeps the application's existing address and transport
lifecycle. It creates no independent Runner registration or second credential
family. Its owning Agent and eligible named Agents can use it; other applications
cannot, even under the same Human. See the [Executor contract](../reference/agent-api/executor.md#agent).
Choose an [independent Runner](deploy.md#identity-and-scope) when several
applications need to share an environment.

rho implements this contract with `Rho::Env` from `rho-env` and calls its
built-in environment **Local**. The gem provides reusable execution machinery;
`Rho::Env::Executor` owns its inbox loop. The complete rho application owns
credentials, connection lifecycle and environment selection. There is currently
no separately deployable first-party Runner application. Other applications may
embed the library or implement the protocol themselves.

## Passive by construction

A runner dials out and is never dialed into. It can sit on an intranet with no public address, because nothing in Nexus ever needs to reach it:

- The **executor plane is the only plane it holds.** Its inbox, claims and commits ride the transport credential.
- **What it serves is registered by announcement.** Nexus addresses a call to a runner only by that announcement, so every row in its inbox is one it announced.
- The **HTTP inbox recovers available work**; the realtime push (`work_available`, `work_canceled`) is latency only and carries nothing executable.
- **Claiming is the fetch.** A granted claim answers with the executable row, so the happy path is push → claim → run → commit with no listing at all. The list is the truth and the recovery path.

If you have run a self-hosted sandbox worker for a hosted agent platform, this is the same shape.

## Kernel and environment are separate

Nexus never executes a shell command or touches a file. The round driver decides *that* a tool is called and the approval stage decides *whether*; the runner decides *how*, on its own machine, under its own permissions. Working directories, processes, local files, browser sessions and MCP server processes are executor-local state. A working directory is a starting location for tools, not a sandbox: give a runner the host permissions and mounts appropriate for its work.

This split is what lets one run use several runners — a laptop and a build server, say — with each task recording its target, and what keeps the kernel free of any knowledge of what `bash` means.

## What a runner does for a run

| Step | Mechanism |
| --- | --- |
| Declares its tools | `PUT /agent_api/v1/executor/announcement`: tool names, effect profiles, optional schemas, environment facts and loadable documents (skills) |
| Is selected | A conversation's default runner, or an explicit target on a tool declaration |
| Receives a call | An inbox row addressed to its UUID, frozen with the agent whose authority it runs under |
| Executes | Claims the row exclusively, runs the tool, extends the deadline if needed |
| Answers | Commits a write-once result: text content, optional structured content, resource links to captures |
| Records effects | Claimed writes are recorded per runner so a rewind can restore each runner's checkpoint independently |

Tools that need a person's decision pause in Nexus, not on the runner: the approval stage parks the call before it is ever addressed, and the runner only sees calls that were granted.

## Local execution capacity

rho's Runner reserves startup capacity before claiming a task. An extension can
also share a local resource limit across tools:

```ruby
api.register_tool(DeviceWrite, resource: "shared_device", concurrency: 1)
api.register_tool(DeviceRead, resource: "shared_device", concurrency: 1)
```

Tools without a resource declaration use the ordinary worker pool. A full resource
leaves the task unclaimed, so shared-device operations serialize while independent file
and process tools can proceed. All tools sharing one resource must declare the
same positive limit. This metadata stays local; it is not an executor announcement
or a Nexus lock.

A resource permit stays held until the handler and result hooks exit, even when
cancellation or a timeout has already returned control to the caller. rho shares these permits
across replacement pools. Releasing capacity after a busy admission or reconnecting
the executor socket wakes the same paginated inbox scan; periodic HTTP recovery
continues when notifications are lost.

## Pages in this section

- [Quickstart](quickstart.md) — the stack's runner, and a runner on your own host
- [Deploy a runner](deploy.md) — hosts, containers, LAN machines, several runners
- [Tools and announcements](tools-and-announcements.md) — what a runner declares and how a run imports it
- [Claims and results](claims-and-results.md) — the inbox protocol
- [Captures and files](captures-and-files.md) — publishing output files and reading bytes
- [Tool providers](tool-providers.md) — serving a pool of tools by name
- [Security model](security-model.md) — what the runner sees, what Nexus stores, who is responsible for what
- [Monitor and troubleshoot](monitor-and-troubleshoot.md)
