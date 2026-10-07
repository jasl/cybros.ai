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
  as `executor_kind: tool_provider` announces its names and its inbox lists
  the pool rows for them, listed for every eligible provider until the first
  claim wins (the e2e sample provider, `e2e/support/executor_process/main.rb`
  with `--kind tool_provider`, is exactly `Rho::Runner` on such a credential).

## Two axes on every answer

A tool that RAN and returned an error is `completed` with `is_error: true` —
data the model reads and self-corrects from. Only a tool that could not run at
all is `failed`, which takes the task's own failure policy. Collapsing the two
costs the model its chance to fix its own call.

## Tool operations and execution capacity

Every claimed tool receives `ExecutionContext.current.orchestration`. It can ask
through `ask(key:, prompt:, options:)`, or host a language runtime with
`run(program:, runtime:)`. Nexus validates each child operation against the task's
frozen tools and model context. An ordinary standalone task with no declarations
acquires no additional authority from this bridge.

A language runtime keeps its execution state while yielding `request` or `observe`
to the bridge; it returns `finished` or `failed`. The control reactor accepts
operations and records observations under the same claim. Unknown submit or
observation responses can be read through their existing durable receipts, without
resubmitting effects or restarting source. A lost VM is not reconstructed: its
invocation fails, and owner loss follows Nexus's ordinary effect-aware expiry.

Handlers run as Async fibers on fixed native worker threads. Startup admission
reserves at most one not-yet-started job per worker. Its ticket is returned when
that handler first yields or exits; a waiting parent retains its live execution
and extension leases while its child can start on the same worker. Async schedules
resumed fibers. Waiting contexts grow with accepted work; native thread count and
startup backlog do not grow with nested waits. CPU work or a blocking native call
can delay other fibers on that worker, while the separate control reactor keeps
claim renewal, cancellation and final delivery available.

`ExecutionContext.current` is fiber-local. Extension resources stay leased until
both the real handler and its result hooks exit, including when a caller has
already stopped waiting for a non-cooperative handler.

Final answers use `Runner::Result`, preserving content blocks and resource links.
`structured_content_present: true` preserves explicit JSON null; false, an empty
collection and an absent field remain distinct values.

## One renewable claim deadline

Nexus grants a claim deadline. Queued handlers do not renew before starting.
A started handler without `INTERNAL_CLAMP = true` requests
an extension at half the remaining grant. Requests respect the kernel's one-hour
extension bound, and every new grant determines the next renewal time. Renewal
requires no output or CPU activity. A tool with its own hard timeout, such as bash,
keeps that limit. One refused extension ends renewal, leaving the granted deadline
unchanged. The local handler deadline preserves room for final delivery.

Cancellation reaches the existing context and resource callbacks. After the grace
window, an uncooperative handler that still yields may finish separately on its
existing worker. Only an unresponsive native worker is replaced, using one
reactor acknowledgment within that same grace window. Its other contexts are
canceled too; the old thread is never killed mid-write, and its resources stay
leased until actual exit. A deadline returns `completed, is_error: true`; a lost
claim without a result expires according to the task's effect profile. Invalid
arguments are rejected before the handler runs as `invalid_tool_arguments`.

A credential-read failure while posting progress or requesting an extension ends
that ancillary operation. It does not answer for the still-running handler or
change its existing deadline. Startup admission follows the actual worker yield,
independently of those control requests.

Claim status is read on the control wait every five seconds, first checked one
interval after claim. A custom Pool uses `max(5.0, worker_count / 5.0)` seconds.
Only an inactive claim, missing task or `not_claimant` stops that original
execution; paused work remains active. Unknown HTTP and credential failures retain
the execution and deadline. A 429 schedules a later read after Retry-After without
blocking the wait. Cable and HTTP recovery share one cancellation transition.

Control HTTP retains its finite request timeout. A request or credential refresh
may finish after the task deadline; cancellation and deadline handling resume when
it returns. That overlap cannot renew a task by itself.

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

Importing leaves the durable attachment in Nexus. `read` handles local text and
attaches images or PDFs whole through the normal capture path. Nexus places a PDF
natively when the selected model supports it; otherwise its attachment reference
remains available for tool-based processing. Use `bash` and the workspace tools
to parse PDFs for those models, or to handle Office, spreadsheets and archives.
`file_publish` selects an existing local file for the normal result capture
upload and resource link. A failed required upload is a tool error, and a plain
local path or incidental read capture does not request delivery to an IM user.

The runner announces project skills from `.agents/skills` and `.claude/skills`.
When `/usr/local/share/cybros/workspace-tools.md` is installed, it also announces
`workspace-tools`, the prepared environment's coding and document-tool guide.
Models see its name and description beside its callable and Runner UUID in the
skills catalog. They load its body through that callable, which rho declares as
`skill__<digest>` with the Runner's concrete target. The guide is optional; its absence adds
no dependency or startup requirement to a bare-metal runner.

A project skill named `workspace-tools` takes precedence. A conversation bound
to another directory still loads skills from the runner's announced root.
Remote agents and children using that runner receive the same document catalog
when they declare its routed skill callable and their prompt template includes skills.
Installing browser software does not enable browser tools; the browser
extension remains a separate setting.
