# rho-webui

The browser interface for rho, packaged as a daemon extension. It provides a
conversation list, durable message history, streamed answers and reasoning,
tool results, artifacts, and execution controls through rho's control server.

Work interactions use rho's control API and the daemon's Agent API client.
Nexus's `/api/v1` serves Human personal settings and administrator system
settings. rho carries the signed-in Human's OAuth authority separately from its
Agent and Runner credentials. This page shows the Human identity and links to
Nexus administration for model configuration; local settings use rho's control API.

`rho-webui` is separate from `rho-web-tools`, the `web_fetch` tool extension.

## Use

Install this gem alongside rho. It is enabled by default in full and agent modes.
To restore a disabled WebUI, use the core manager:

```sh
rho extensions enable rho.webui
```

Start the daemon with `rho server`, then open its browser URL or run
`rho console --open`. Choose **Connect to Nexus** to sign in with your Nexus
account and approve rho. Authorization Code with PKCE returns to the same tab;
**Use a device code** provides a verification link and waits for approval.
There is no separate rho password or browser unlock code.

The served HTML contains no credential. The tab keeps its browser bearer in
`sessionStorage` and uses it with authenticated API and streaming requests.
This credential is separate from the daemon's private CLI bearer. The login
transaction is also held in that tab; callbacks from another tab are rejected.
The same tab
retains its session across daemon restarts while its Nexus authorization is valid.
An expired or revoked grant requires Nexus login again. **Sign out**
ends this browser session without removing the Agent's binding or stopping its
running work.

The extension is for full and agent daemon modes. A standalone runner does not
serve this interface. `RHO_WEBUI_ROOT` or the `webui_root` setting can select a
different static bundle, and `RHO_API_ONLY=1` disables the page.

## Settings

The bundled installation opens the ordinary rho URL first. **Connect to Nexus**
continues through Nexus first boot when no Account exists. Create the first
Human owner directly; the default installation requires no setup secret or
terminal step. Nexus requests a private secret only when the operator explicitly
configured `NEXUS_SETUP_SECRET`; the public rho page never receives it.
Creating the first Human owner signs them in,
continues the original authorization, and returns to rho after approval. An
existing Account goes straight to Nexus login and authorization.

Device login on an uninitialized Nexus shows **Open Nexus setup** and
**Continue after setup**. Complete first boot in the other tab, then continue to
create and approve the device code. No grant is created before the Account is
ready, and the installer never approves a connection on the user's behalf.

**Settings** shows the signed-in Nexus Human and their current role, optional
Telegram configuration and owner pairing, and model setup guidance linking to
Nexus. Model setup is not a login requirement. Returning from Nexus refreshes
available models. A valid saved choice stays selected, a sole eligible model is
adopted automatically, and multiple models require a choice. When the optional
Telegram plugin is disabled, choose **Enable Telegram** directly under **Connect
and pair Telegram**. Successful activation replaces the button with the bot token
and account settings in the same section. Failed activation keeps its reported
repair guidance and **Retry Telegram activation** there.
If it is absent, install `rho-ingress-telegram`; model and general settings remain usable.

**Plugins** lists installed capabilities, including disabled plugins, with a
human-readable description of what each provides. Expand a
plugin to enable or disable it, edit its schema-generated form, or edit explicit
non-secret overrides in **Advanced JSON**. Both editors share one draft. **Save
configuration** publishes a field batch through the same owner as the CLI;
**Discard** abandons the draft, and **Restore default** removes an override.
Displayed defaults are not saved unless explicitly edited. All configuration
is stored under `RHO_HOME` by the daemon; the browser keeps only its unsaved draft.

Requested enablement and the running instance are shown separately. A saved
change can still require a restart or fail to apply; the page reports that result
without retrying the write. Status refreshes preserve unsaved changes, including
edits made while a save is in progress. After a lost response, the next deliberate
save first reads the saved state. Disabling a required capability can include its
direct and transitive dependent plugins through **Also disable…**. Pending source
changes show the saved and running sources separately. Plugin startup or status
failures remain visible; an invalid description can still be disabled while its
configuration stays private. Before disabling WebUI, its section shows the core
CLI command that restores access.

Secrets have separate **Keep**, replacement and **Clear** controls. Blank input
keeps the existing value; current credentials never appear in the form or JSON
editor. Removing a named connection explicitly removes its credentials too.
Configuration is editable while a plugin is disabled, without starting its code.

**Managed packages** installs source and tests from a directory on the machine
running rho; a Docker installation needs a path inside the rho container. **Install
candidate** copies a version without running or activating it. Choose an **Installed
version**, then explicitly **Check version** or **Activate version**. Checks run that
version's Ruby test files and show their bounded output. When no test files exist,
the result states that only structure and dependencies were checked. A check can
perform the effects of the installed code, and activation does not run checks.
Check results remain in this page only.

Saved, running and previous versions are shown separately. **Activate version**
keeps and migrates existing configuration unless explicit replacement JSON is
entered under **Activation configuration (optional)**. Leave that field blank to
preserve configuration; `{}` selects defaults. Existing secrets are never loaded
into it, and closing Settings clears entered overrides. Use the ordinary Plugins
editor for the selected plugin's configuration.

**Roll back** restores the previous code and configuration. It does not restore
business data; incompatible state schemas or dependencies remain a visible refusal
from rho. **Disable package** preserves its installed versions and configuration.
A saved selection can need a restart while the old version remains running. The
page reports application, announcement and durability warnings separately and
never retries a write automatically. After an uncertain response, **Refresh
packages** reads the current state before another deliberate change.

**Working style** selects **Standard** or **Compact** and appends **Additional
instructions** without trimming whitespace or newlines. Compact shortens the
built-in guidance while retaining its policies and tool surface. Under
**Advanced prompt settings**, **Replace base prompt** accepts a complete base
replacement, including an empty one. **Restore built-in prompt** restores the
selected preset in the editor; **Save working style** applies that change and
preserves the additional instructions. The resolved prompt is limited to 64 KiB
of UTF-8. Changes apply to future materialized turns; an in-progress turn retains
its captured prompt. Named agents, personal persona and Workspace character
retain their own prompt slots. Failed saves keep the draft available for repair.

**More settings** holds core model, working-directory, runner/workspace and
connection defaults. Unchanged connections and existing conversations stay in
place when these settings change.

The code-mode plugin's default is `on`. It lets rho compose tool calls through
JavaScript; `off` uses the ordinary tool surface. Conversations that follow the
default use a saved change on their next request.

The bundled stack prepares its own Agent and private container Runner. New
conversations use those defaults until the user chooses otherwise. Provider
credentials remain in Nexus. Human OAuth, Agent member and executor transport
credentials keep their separate authority on every request.

## Conversations

Create a conversation with an available model, a runner and its working
directory. The model list comes from Nexus's configured, usable models. The
selected runner is the default for newly authored calls; an agent-only daemon can
use a separately paired runner. Opening an existing conversation displays its
default without changing it. Each accepted Runner call retains its own target. Runner default selection is available through `rho set_default_runner`; accepted tasks keep their target.

Messages, titles and archive state live in Nexus. Reopening a conversation or
refreshing the browser reads its durable history. Rename and archive operate
on that same record; archived conversations can be restored. Sending another
message defaults to **Steer current work**: Nexus keeps the instruction pending for
the next model boundary in the same turn. **Send now** (Ctrl+Enter or Cmd+Enter)
lets the model read it while supported long tools continue running. With an empty
draft, Send now promotes the latest waiting steer, keeping earlier instructions
in order without duplicating their text. An in-flight model request finishes
before it reads new instructions. Choose **Queue after current reply** to start
separate work after that reply. Pending labels reflect the
server's accepted delivery mode; waiting does not mean the model has read the
message. Neither sending mode implicitly stops tools. Drafts remain in the page
when a request fails; they are not a second conversation store.

An existing Side conversation's frozen parent context is labelled **Parent
conversation reference snapshot**. It stays readable as one immutable context
card, without duplicating the parent's prompt or treating its content as a new
answer, artifact result or execution to control.

The composer's **Code Mode** picker selects **rho default**, **On** or **Off**.
Sending saves that choice for subsequent requests in the same conversation;
**rho default** clears its override. Reopening reads the saved choice, and
background refreshes preserve an unsent selection. Existing running work keeps
its captured tools. The picker is absent for conversations answered by another
agent application.

The header's **Usage** disclosure shows cumulative recorded requests, tokens and
cost for this conversation, including retries and background work. An incomplete
cost is labeled as a known subtotal; amounts retain the Account's configured
unit. **Context** separately shows the latest successful request's reported
occupancy and actual model. Missing current context reports remain unavailable,
including after compaction or execution-detail retention. These summaries refresh
with the conversation, so background work can add usage after its reply finishes.

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
An unresolved provider context overflow points to **Nexus Settings > Model providers >
Edit model > Context and capabilities** to check the server's actual input or combined
context limit and output limit. Only one input or combined window contract should be set.
Automatic compaction and resolved or absorbed failures do not show this
repair hint. The CLI and Telegram use the same guidance from rho's English catalog.
For `web_fetch`, **Allow this site until restart** approves the held request and
remembers a literal URL prefix for the running daemon. Future initial URLs must begin
with the same scheme, host and written port followed by `/`; subdomains, `www`
variants and omitted versus explicit default ports remain separate. The page
keeps the complete tool input visible and the daemon derives the rule. **Approve**
continues to approve only the held request. Redirects retain `web_fetch`'s
same-site policy, including its `www` handling. If the current request is
approved but the site permission cannot be saved, the page reports that later
requests may ask again.
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
and upload routes, including call_tool to a separate runner. Browser file upload
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
`views.js`, `composer.js`, `controls.js`, `lifecycle.js`, `schedules.js` and the DOM-based `markdown.js` renderer. Stable file
names remain at the static root so they are revalidated instead of receiving
the daemon's fingerprinted-asset cache policy.

The active interface, document title and product names use `webui/i18n.js` and
the default English catalog in `webui/locales/en.js`. Add locale overrides through
the translator's catalog argument; interpolation remains plain text. Plugin
names, descriptions and schema field copy use keys under `plugins.<id>` with the
plugin's authored metadata as the literal fallback, keeping one source for the
default description. The static HTML title and no-JavaScript guidance remain
English because they must work before browser JavaScript runs. The default
interface language remains English.

Daemon, provider and plugin diagnostics arrive as authored text, including prerequisite
repair guidance; localization belongs to their producer. For an unresolved typed
`provider_context_overflow`, the browser catalog adds recovery guidance alongside the
existing literal diagnostic in task details. Resolved failures retain their diagnostic.
Executable names, commands and protocol identifiers remain literal when product
display names change.

Conversation queue reads use `GET /inputs?public_id=ID&host_type=conversation`.
The explicit type keeps this read independent of local followers, including
after archive removes a follower. Omitting `host_type` uses the daemon's
followed-host or backing-run resolution.

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
