# rho-runner

Takes tool work a Nexus agent loop parked for a runner, executes it on this
machine, and answers.

## Passive by construction

It dials out and is never dialled into. A runner is expected to sit on an
intranet with no public address, so nothing in this gem listens, and nothing
in Nexus ever needs to reach it:

- the **executor plane is the only plane it holds** — its inbox, claim and
  commit ride the transport credential, and no member bearer ever reaches
  the runner half;
- **what it serves is registered by announcement** — the address announces
  its tool names to Nexus, which addresses a call to it only by that
  announcement, so a row in its inbox is one it announced and there is no
  local "is this mine?" gate before a claim;
- the **HTTP inbox recovers available work**; while executing, the runner
  also reads its original claim to recover a missed cancellation;
- the **realtime push is latency only** — `work_available` names a loop, a
  task key and a tool name and carries nothing executable; `work_canceled` reaches the claimant so a
  stopped row's handler stops with it;
- **claiming is the fetch** — a granted claim answers with the executable row,
  so the happy path is push → claim → run → commit, with no listing at all;
- **a tools provider is this same loop on a pool row** — a process connected
  as `executor_kind: tools_provider` announces its names and its inbox lists
  the pool rows for them, listed for every eligible provider until the first
  claim wins (the e2e sample provider, `e2e/support/executor_process/main.rb`
  with `--kind tools_provider`, is exactly `Rho::Runner` on such a credential).

## Two axes on every answer

A tool that RAN and returned an error is `completed` with `is_error: true` —
data the model reads and self-corrects from. Only a tool that could not run at
all is `failed`, which takes the task's own failure policy. Collapsing the two
costs the model its chance to fix its own call.

## One clock, and it is the server's

A park carries a deadline minted by Nexus, and there is no heartbeat to send:
the one thing a runner may do to that deadline is ask Nexus to move it (the
executor plane's `extend`, bounded by the tool's announced park or the
kernel's hour, narrated on the loop's stream) — and it asks only for a handler
with no clamp of its own, once at half the park and again at each half while
the handler runs; a tool that clamps itself (`bash`) never asks, and one
refusal ends the asking. Handlers are cancelled early enough
to leave room to submit, because a result computed and never delivered is the
same as no result — and the pool enforces it: a handler that never checks its
context is cancelled at the deadline, its process group killed, its worker
replaced, and the task is answered `completed` with `is_error: true` ("timed
out"), data the model reads. A claim left unanswered is the sweep's
`uncertain`, reserved for a runner that died. Arguments are validated against
the tool's declared `inputSchema` before the handler runs, and a mismatch is
answered the same way (`invalid_tool_arguments: …`).

A credential-read failure while posting progress or requesting an extension
ends that ancillary operation. The handler keeps its original deadline and
its admission ticket until execution ends; such a failure does not submit a
tool failure on behalf of a worker that is still running.

Claim status is read on the existing control wait every five seconds, first
checked one interval after claim. A custom Pool uses
`max(5.0, worker_count / 5.0)` seconds. Only an inactive claim, missing task,
or `not_claimant` stops that original execution; paused work remains active.
Unknown HTTP and credential failures retain the worker and deadline, and a
429 schedules the next read after Retry-After without blocking the wait.
Cable and HTTP recovery share one cancellation transition and count it once.

Control HTTP retains its finite request timeout. A request or credential
refresh may finish after the task deadline; cancellation and deadline
handling resume when it returns. This best-effort overlap never renews the
task by itself or releases the worker's ticket early.

## Why it is a separate gem

The flagship `rho` daemon composes it. It is packaged apart so a runner can
also be installed and run alone, on a machine with no daemon, no control
server and no console.

## Discovering workspace tools

`file_import` reads a `nexus://uploads/...` input reference under the executing
task's claim. The runner uses only its executor transport credential and that
claim's token to fetch the descriptor and stream the bytes. It writes a complete
working copy to the existing artifacts directory and returns its path; partial
downloads never become imported files. The daemon's member bearer is not needed.

Importing leaves the durable attachment in Nexus. `read` handles local text;
`bash` and the workspace tools handle PDF, Office, spreadsheets and archives.
`file_publish` selects an existing local file for the normal result capture
upload and resource link. A failed required upload is a tool error, and a plain
local path or incidental read capture does not request delivery to an IM user.

The runner announces project skills from `.agents/skills` and `.claude/skills`.
When `/usr/local/share/cybros/workspace-tools.md` is installed, it also announces
`workspace-tools`, the prepared environment's coding and document-tool guide.
Models see its name and description in the normal skills catalog and load its
body through the existing `skill` tool. The guide is optional; its absence adds
no dependency or startup requirement to a bare-metal runner.

A project skill named `workspace-tools` takes precedence. A conversation bound
to another directory still loads skills from the runner's announced root.
Remote agents and children using that runner receive the same document catalog
when they declare the `skill` tool and their prompt template includes skills.
Installing browser software does not enable browser tools; the browser
extension remains a separate setting.
