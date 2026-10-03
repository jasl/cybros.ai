# rho-webui

The browser interface for rho, packaged as a daemon extension. It provides a
conversation list, durable message history, streamed answers and reasoning,
tool results, artifacts, and execution controls through rho's control server.

Work interactions use rho's control API and the daemon's Agent API client.
Nexus's `/api/v1` serves Human personal settings and administrator system
settings; browser calls to that family belong only to settings pages. This
extension does not yet provide those settings pages.

`rho-webui` is separate from `rho-web-tools`, the `web_fetch` tool extension.

## Use

Install this gem alongside rho and load its extension feature in the home's
`settings.json` when it is not already selected by the distribution:

```json
{ "extensions": ["rho/webui"] }
```

Start the daemon with `rho server`, then run `rho console --open` from another
terminal. The command opens a single-use console link. A bare browser visit
shows the connection screen; the served HTML contains no credential.

The page holds the daemon's bearer in `sessionStorage` and sends it with API
requests, including streams read through `fetch`. Console links expire after
90 seconds. Restarting the daemon requires a fresh link. The daemon continues
to own authentication, access locking, static-file serving and all control
routes. This extension registers only its static root.

The extension is for full and agent daemon modes. A standalone runner does not
serve this interface. `RHO_WEBUI_ROOT` or the `webui_root` setting can select a
different static bundle, and `RHO_API_ONLY=1` disables the page.

## Conversations

Create a conversation with an available model, a runner and its working
directory. The model list comes from Nexus's configured, usable models. The
runner is where tools execute; an agent-only daemon can use a separately paired
runner. Opening an existing conversation displays its binding without changing
it. Runner handoff remains an explicit CLI operation.

Messages, titles and archive state live in Nexus. Reopening a conversation or
refreshing the browser reads its durable history. Rename and archive operate
on that same record; archived conversations can be restored. Sending another
message queues input on the selected conversation. Drafts remain in the page
when a request fails; they are not a second conversation store.

An opened conversation keeps its workspace in subsequent requests and its URL;
changing the daemon's default workspace does not move that conversation. New
conversations use the current default. A failed send keeps its idempotency key
for a manual retry of the same payload in this page, including a create's
original workspace. Reloading the page discards these pending request keys and
drafts; check durable history before resubmitting an uncertain send after reload.

A conversation currently bound to an ingress such as Telegram identifies that
channel and is read-only here. Continue messages and approvals in that channel;
Stop remains available. Starting a new conversation in the channel releases its
previous current conversation. The daemon also rechecks this restriction on
page mutations, so a stale tab cannot bypass it. This is a channel interaction
rule, not a change to Nexus permissions or to ordinary CLI operations.

Questions and tool approvals appear alongside the work. Execution can be paused
and resumed; failed steps offer retry or abandon. Stopping execution is an
explicit action; changing conversations or closing the browser only detaches
the viewer. The page reconnects read streams and reconciles durable history,
but never retries a mutation automatically.
Stop also covers background work after a reply has finished. A regenerated or
selected variant is followed as its own execution. If access is refused or the
conversation becomes unavailable, stale controls and automatic retries stop;
the page keeps the draft and any readable history. Use Refresh after restoring
access to read the current state again.

When Nexus's retention policy has collected an old turn's execution details,
the page keeps its conversation text and labels the removed details. It does
not request a transcript that the server has already marked as unavailable.

Answers support basic Markdown: headings, paragraphs, lists, quotations,
fenced and inline code, emphasis and links. Raw HTML remains literal text.
Runner artifacts are fetched with authentication through rho's existing file
and upload routes, including relay to a separate runner. Browser file upload
is not provided in this increment.

## Scheduled jobs

Open **Scheduled jobs** in a conversation to list, create, edit, pause, resume
or cancel delayed and recurring tasks. Choose a one-time instant, an interval
with its first run, or a daily local time with an IANA time zone. One-time and
interval instants include `Z` or an explicit offset. The form starts with the
conversation's selected model and approval mode.

Each occurrence works in a fresh child conversation and reports back here.
**Executions** shows those children with their actual execution status and an
**Open execution** control. A `completed` one-time schedule can still have a
running child. Pause and cancel affect future occurrences; use the ordinary
Stop control inside an execution to stop its current work.

A conflicting edit keeps the draft and asks you to refresh and reopen Edit.
An uncertain create retains its key for a manual retry of the same payload
within this page; reloading discards that request state. The panel keeps the
original workspace, and ingress-bound conversations remain read-only.

## Files and development

`webui/` contains plain browser ES modules, HTML and CSS. The gem ships those
files as written: no asset build, package manager, Node, Deno or server-side
JavaScript process is required. The browser loads `console.js`, with `api.js`,
`views.js`, `controls.js`, `lifecycle.js`, `scheduled_jobs.js` and the DOM-based `markdown.js` renderer. Stable file
names remain at the static root so they are revalidated instead of receiving
the daemon's fingerprinted-asset cache policy.

Conversation queue reads use `GET /inputs?public_id=ID&host_type=conversation`.
The explicit type keeps this read independent of local followers, including
after archive removes a follower. Omitting `host_type` uses the daemon's
followed-host or backing-loop resolution.

Development verification requires Ruby and Bun. From this directory:

```sh
bundle install
bundle exec rake
bundle exec rake build
```

The default task runs Ruby tests, offline browser lifecycle tests with Bun,
RuboCop and RBS validation. Packaging tests
extract the built gem into a temporary directory and load its registration
without a JavaScript runtime, then check the page and its referenced assets.
Daemon authentication and control-server tests live in the rho project.
Run `bundle exec rake test_js` to check only the browser request and lifecycle
logic with offline HTTP responses. Bun is a development dependency; installation
and serving still need only Ruby.
