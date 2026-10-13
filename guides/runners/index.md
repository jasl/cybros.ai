# Runners and tool providers

A runner is an execution environment's delivery address. It serves tools bound to a machine — files, shell commands, processes, a browser, MCP servers — and executes them where the files live: a workstation, a server, a container. A tool provider is the same protocol for tools served by name from a pool rather than a specific environment.

Both are **executors**: they hold a transport credential, announce what they serve, and take work from their own inbox. Neither is a member of the account, and neither ever holds a member credential.

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

## Pages in this section

- [Quickstart](quickstart.md) — the stack's runner, and a runner on your own host
- [Deploy a runner](deploy.md) — hosts, containers, LAN machines, several runners
- [Tools and announcements](tools-and-announcements.md) — what a runner declares and how a run imports it
- [Claims and results](claims-and-results.md) — the inbox protocol
- [Captures and files](captures-and-files.md) — publishing output files and reading bytes
- [Tool providers](tool-providers.md) — serving a pool of tools by name
- [Security model](security-model.md) — what the runner sees, what Nexus stores, who is responsible for what
- [Monitor and troubleshoot](monitor-and-troubleshoot.md)
