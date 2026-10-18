# rho-webui

The browser interface for rho, packaged as a daemon extension. It provides a
conversation list, durable message history, streamed answers and reasoning,
tool results, artifacts, execution controls, scheduled jobs, plugin management
and settings through rho's control server — and a slot system through which
the browser modules of other rho extensions extend the same page.

Work interactions use rho's control API and the daemon's Agent API client.
Nexus's `/api/v1` serves Human personal settings and administrator system
settings. rho carries the signed-in Human's OAuth authority separately from its
Agent and Runner credentials. This page shows the Human identity and links to
Nexus administration for model configuration; local settings use rho's control API.

**Settings → System upgrade** checks and upgrades rho and Nexus through separate
cards. rho uses its installation updater; Nexus uses the signed-in Human's
existing administrator API through the daemon proxy. A check and confirmation
precede each upgrade. Nexus's database backup is enabled by default, and changing
that choice requires another check. Pending request metadata stays in this tab's
session storage so a restart or reload can recover the same receipt and key.
Progress reads never resubmit an upgrade. Unsupported installations show their
host update procedure; interrupted upgrades direct the operator to host recovery.

`rho-webui` is separate from `rho-web-tools`, the `web_fetch` tool extension.

## Use

Install this gem alongside rho. It is enabled by default in full and agent modes.
To restore a disabled WebUI, use the core manager:

```sh
rho extensions enable rho.webui
```

Start the daemon with `rho server`, then open its browser URL or run
`rho console --open`. Until rho is paired, choose **Connect to Nexus** to sign in
with your Nexus account and approve rho — Authorization Code with PKCE returns
to the same tab; **Use a device code** provides a verification link and waits
for approval. Pairing happens once.

After pairing, **Settings › General › Opening this page** decides what a
browser needs before it can use rho. **Automatic** opens the page by itself on
this machine and asks for a Nexus sign-in from other machines; **Open** opens
it for anyone who reaches the page; **Nexus sign-in** always asks for one;
**Unlock password** asks for rho's own password, set on the same card and
stored only as a salted digest. A page the gate admitted holds no Nexus
account: Settings names how it got in and offers **Sign in with Nexus**, which
Nexus account actions need; under a password it also offers **Lock**. Changing
or removing the password ends every other unlocked browser; the page that made
the change stays in. Changing the access mode to **Open** or **Unlock password**
lets the browser making the change continue under the new mode. Other browsers
unlocked under the previous mode must enter again under the current mode. Changing
to **Nexus sign-in** requires every unlocked browser, including the page making
the change, to sign in with Nexus. A browser already signed in with Nexus keeps
its Human session.

The served HTML contains no credential. The tab keeps its browser bearer in
`sessionStorage` and uses it with authenticated API and streaming requests.
This credential is separate from the daemon's private CLI bearer. The login
transaction is also held in that tab; callbacks from another tab are rejected.
The same tab retains its session across daemon restarts while its Nexus
authorization is valid. An expired or revoked grant requires Nexus login again.
Leaving the page — for the Nexus sign-in, or anywhere else — tears it down so
streams close and the daemon's followers are released; coming back through the
browser's Back button rebuilds it, whether the browser kept the document in its
back/forward cache or loads it again, and a device login in progress resumes
its wait.
**Sign out** (in Settings › General) ends this browser session without removing
the Agent's binding or stopping its running work.

The extension is for full and agent daemon modes. A standalone runner does not
serve this interface. `RHO_WEBUI_ROOT` or the `webui_root` setting can select a
different static bundle, and `RHO_API_ONLY=1` disables the page.

The page targets evergreen browsers from mid-2024 onward: it relies on
`light-dark()` colours and the Popover API for menus, tooltips and toasts.

## The page

The frame has three columns. The **sidebar** (280px, resizable 264–420px) holds
the brand row with the collapse toggle, the workspace switcher, **New
conversation**, any global panels — **Scheduled jobs**, **Bots**, **Plugins**
and the pages of plugins that bring one — the
conversation browser and **Settings**.
Every row keeps its icon on one column, so below 1024px, or by choice, it
becomes a 56px rail of the same rows in the same order — the toggle, then the
workspace's mark, then the rest — with each icon where it already stood; below
768px it hides and opens as a drawer from the button in the conversation
header.
Mod+Alt+B toggles it. The **main** column shows the conversation, or a global
panel such as **Plugins**, **Bots** or **Settings**. The **side panel** on the
right opens on demand for task output, scheduled jobs and usage; it keeps one
set of tabs per conversation, remembers its width, hangs over the conversation
when the window is too narrow for a third column, and fills the screen below
768px. Only small, self-contained steps — naming a new workspace, confirming a
removal — use a dialog.

The switcher under the brand row names the page's **current workspace**: the
one whose conversations the browser lists and where **New conversation**
starts. Its mark is the workspace's initial on a colour its id picks, so the
rail still tells workspaces apart. Its menu lists every workspace the account offers, with
rho's own, its sharing and **rho's default** noted, and **New workspace…**
creates one by name and switches to it. The choice is this browser's: it is
remembered in `localStorage` and carried in the address as `/workspaces/<id>`
when it is not rho's default, so a link opens the same workspace. It never
changes rho's default (**Settings › Defaults › Default workspace**), which the CLI
uses. Each Bot uses its own Home Workspace for new conversations. Opening a conversation from another workspace follows it
there. The URL is the page's history: Back and Forward move between panels,
conversations and workspaces exactly as the address says, and a remembered
workspace is written into the address on the first read so that Back can
return to it.

The address is the path, spelled as the resources it shows; the query string
is never routing, so it stays free for the OAuth callback and for debugging
switches, which in-page navigation carries along unchanged:

| Address | Shows |
|---|---|
| `/` | the hero, in rho's default workspace |
| `/workspaces/<id>` | the hero, in another workspace |
| `/workspaces/<id>/conversations/<id>` | a conversation, in its workspace |
| `/plugins`, `/plugins/<id>` | the Plugins panel, one plugin's page |
| `/panels/<key>` | the main page a plugin brings (its `main` slot key), such as `/panels/bots` |
| `/panels/<key>/<item>` | one item of that page: a Bot’s UUID (`/panels/bots/<public_id>`) or a new Bot (`/panels/bots/new`) |

The daemon answers an exact control route (`GET /workspaces`, `GET /telegram`)
before it serves the page, so page addresses keep to these shapes; a
plugin's own page lives under `/panels/`, never at its bare key.

Every main page is built the same way. Its header carries the title, one line
on what the page holds, and **Refresh** alone, as an icon; the things the page
lists sit in **groups** — a heading, the count, and at the heading's end the
actions that act on the group (**New bot** on Bots, **Add provider** on
Providers, **Import all** on Definition files) — and a page's forms are
**cards** named by their purpose, each with its own **Save**. A row's actions
are icons, labelled on hover. Nothing a person configures is folded away: a
form whose one Save covers several purposes groups its fields under a legend
instead. The breadcrumb of an item's page — a bot's, a plugin's — names the
page, with Refresh at the row's end.

Appearance follows the system until **Settings › General** chooses light or
dark; the content font size is adjustable from 10 to 22px. Both are display
preferences of this browser kept in `localStorage`, never credentials.

A framework-free boot page shows a spinner whose arc grows as plugin modules
load, and names any module that fails, so a broken plugin never leaves a blank
page. The page then mounts; modules that arrive later render as they register.

## Settings

The bundled installation opens the ordinary rho URL first. **Connect to Nexus**
continues through Nexus first boot when no Account exists. Create the first
Human owner directly; the default installation requires no setup secret or
terminal step. Nexus requests a private secret only when the operator explicitly
configured `NEXUS_SETUP_SECRET`; the public rho page never receives it.
Creating the first Human owner signs them in, continues the original
authorization, and returns to rho after approval. An existing Account goes
straight to Nexus login and authorization.

Device login on an uninitialized Nexus shows **Open Nexus setup** and
**Continue after setup**. Complete first boot in the other tab, then continue to
create and approve the device code. No grant is created before the Account is
ready, and the installer never approves a connection on the user's behalf.

A setup notice above the composer points to the next step until rho is ready:
connect to Nexus (Settings), choose a model for the Main Agent (Settings › Agent Presets), then
finish setting up any enabled plugin that still reports it needs
configuration. The notice names the plugin and opens its page; the shell
knows nothing about what that setup involves.

**Settings** is a main page at `/panels/settings`, opened from the sidebar's
foot or by the setup notice, which lands on the section it names. Its
sections run down the left and the chosen one fills the rest; below 768px
the sections become a row of chips over the section. The documents are
reread each time the page comes into view. Settings holds what is the
page's or the daemon's. **Settings › General** shows the signed-in Nexus Human
and their role, how this page is opened, appearance, content size, deployment
facts and **Sign out**.

**Agent Presets** owns reusable behavior. Its defaults select the Main Agent's
Preset and the Preset initially assigned to new Bots independently. The library
supports create, edit, duplicate, remove, project import, file import and Markdown
or JSON export. An editor contains name, description, literal system prompt,
model mode/default, ordered fallback policy, and separate kernel/application,
Runner and Nexus MCP tool selections. Failed writes preserve the draft for correction.

**Subagent roles** manages the delegation directory separately. Choose a Preset,
publish a role name and describe when the delegating agent should choose it.
**Edit Preset** opens its shared instructions, models and tools; the role keeps
only a reference and selection metadata. Update or unpublish a role here without
creating or removing a persistent identity. To change the referenced Preset,
unpublish the role and publish it from the new Preset. The Preset editor links
back to this role manager.

A Preset's fallback selector chooses **Inherit global fallback list**, **Custom
ordered list**, or **No fallback** (`[]`). The list is never appended to the global list. Editing a Preset
changes future accepted inputs; queued and running work retain their captured
prompt and policy. A saved edit does not create or change an Agent or Bot identity.
The Main Agent's settings action opens this shared Preset section.

**Defaults** holds the installation's default model and independent ordered
fallback list, Runner and working-location defaults. **Agent behavior** also
selects **Model adaptations** among installed rows (`GET /adaptations/rows`), with
**Automatic** and **Off** first; only the local adaptations directory is a path.
**Conversation title model** names a new conversation from its first accepted
message. **Follow current model** is the default; choose another available text
model or **None** to turn automatic titles off. The generated title updates the
conversation header and sidebar through the ordinary conversation refresh.
**Nexus tools** is one switch
per tool the kernel serves (`GET /kernel_tools`), grouped and named in plain
words with the wire name beside each; a tool the page has no copy for shows its
canonical name and the kernel's own first sentence. A saved name the kernel no
longer serves is flagged **not served**, because while it stays on, new runs get
no kernel tools at all; switch it off and save. Saving keeps the saved order of
the names that remain and appends new ones in catalog order, so an unchanged
choice is not a change. Without the catalog (disconnected), the saved names stay
switchable and the card says why the list is short. **Tools and working
location** and **Connection** keep the runner and workspace choices, the working
directory and the browser URL. Unchanged connections and existing conversations
stay in place when these settings change.

## Plugins

The **Plugins** panel lists installed capabilities by category — Interface,
Channels, Agents, Tools, Conversation, System — in a fixed order, so a switch
never moves a card. Each card carries the plugin's name with its version beside
it, a human-readable description, a switch, and a gear when the plugin has
settings; a label appears only when something needs doing (**Setup needed**,
**Failed**, **Restart required**) — a plugin that runs, or is simply off,
carries none. Open a plugin (its title or gear) for its source, tools and
commands, issues, and — when it has settings — its
**Settings**: a form generated from the plugin's schema, with separate
**Keep**, replacement and **Clear** controls for secrets, **Edit as JSON** for
explicit non-secret overrides, **Save**, **Discard** and
**Restore defaults**. A string field is typed as text, and a blank nullable one
is **Not set**. A string field whose schema carries `x-rho-choices`
(`{"source": "models", "workload": "image_generation"}`) is chosen from the
daemon's `GET /models?workload=` listing instead, with **Not set** first and a
saved reference the listing no longer has kept selectable as **unavailable**;
the compaction and image models are such fields. A plugin that ships its own
browser module replaces that generic form with its own page; **Telegram** is one
(`rho-ingress-telegram`), and its transcription and speech models are chosen the
same way from their workloads.

Requested enablement and the running instance are shown separately. A saved
change can still require a restart or fail to apply; the page reports that result
without retrying the write. Status refreshes preserve unsaved changes. After a
lost response, the next deliberate save first reads the saved state. Disabling
a capability with enabled dependents asks which of them to disable too. The
plugin that serves the page (`capabilities.page` on its `GET /extensions` row)
and whatever that plugin requires — **Ops**, whose conversation, workspace and
model routes the page is made of — cannot be switched off from the page: their
switches stay on and say why, because turning them off would end the page
itself. The terminal keeps that authority — `rho extensions disable rho.webui`,
and `rho extensions enable rho.webui` to come back. Configuration is editable
while a plugin is disabled, without starting its code.

**Managed packages**, the page's last group, installs source and tests from a
directory on the machine running rho; a Docker installation needs a path
inside the rho container. **Install candidate** copies a version without
running or activating it. Choose an **Installed version**, then explicitly
**Check version** or **Activate version**; **Activation configuration** holds
the overrides an activation may carry. Checks run that version's Ruby test
files and show their bounded output. **Roll back** restores the previous code and configuration. Activating
another installed version of a package whose module is on the page loads that
version's module in place.

The code-mode plugin's default is `on`. It lets rho compose tool calls through
JavaScript; `off` uses the ordinary tool surface. The plugin setting chooses the
initial value for new Main Agent conversations. **Defaults → Agent behavior**
similarly sets their initial **Subagent** choice. Changing either default leaves
existing conversations unchanged. Each Bot has its own Subagent setting and
keeps Code mode off.

## Conversations

The sidebar's **Conversations** list contains the Main Agent's ordinary root
conversations in the selected workspace. Active and archived pages are filtered
by the daemon before pagination; Bot conversations and child executions do not
enter this list. **New conversation** starts another Main Agent conversation.
**Bots** is a separate entry with shortcuts to each Bot's current conversation
and settings.

Create a conversation with an available model and a runner. The runner uses
its default working directory. The model list comes from Nexus's configured, usable models. The
selected runner is the default for newly authored calls; an agent-only daemon can
use a separately paired runner. Opening an existing conversation displays its
default without changing it. Each accepted Runner call retains its own target.

The composer's **Code mode** and **Subagent** buttons are highlighted when enabled.
In an existing conversation, a toggle saves immediately; while saving, the
previous value remains visible and the buttons are disabled. A failed save
keeps that value and shows an error. A new Main Agent conversation starts with the current
global defaults and saves its two choices when created. Turning **Subagent** off
omits subagent and delegated-task tools from future replies; already accepted
work retains its captured tools and may still delegate. These
settings do not change from later edits to global defaults. Bot and other
channel-owned conversations remain read-only here.

The composer's **Permissions** chip names what tool calls may do before you
are asked, in the words other agents use: **Ask before changes** (reads that
rho's rules allow run on their own; anything else asks you first — the
kernel's `ask`), **Rules only** (only what rho's rules allow runs, a rule can
ask you, everything else is refused — `rules`) and **Bypass permissions**
(every call runs without asking; rho's guard still blocks destructive
commands — `bypass`). Scheduled jobs offer the same three.

Messages, titles and archive state live in Nexus. Reopening a conversation or
refreshing the browser reads its durable history. Rename and archive operate
on that same record; archived conversations can be restored from the list's
**Show archived** view. Sending another message defaults to **Steer current
work**: Nexus keeps the instruction pending for the next model boundary in the
same turn. **Send now** (Ctrl+Enter or Cmd+Enter) lets the model read it while
supported long tools continue running. With an empty draft, Send now promotes
the latest waiting steer. An in-flight model request finishes before it reads
new instructions. Choose **Queue after current reply** to start separate work
after that reply. Pending labels reflect the server's accepted delivery mode. Neither
sending mode implicitly stops tools. Drafts remain in the page when a request
fails; they are not a second conversation store.

An existing Side conversation's frozen parent context is labelled **Parent
conversation reference snapshot** and stays readable as one immutable card.

**Memory review** in the title menu is one switch per conversation: on, a
background review of each completed reply keeps the Bot's notes about you in `speaker/review.md`
up to date (stable preferences, confirmed facts, a dated index of past work)
at one extra model call per reply; off stops future reviews. The menu line
shows the document in use and says when the last review failed. The switch
appears only while the `rho.memory_review` plugin runs; `rho memory-review`
offers the same with a chosen document and model. The plugin's page under
**Plugins** holds the default for conversations that never chose: **Review
every conversation** joins each such conversation at its first completed
reply with the configured document and model; a conversation switched off
in its menu stays off.

**Usage** in the conversation header opens the side panel with cumulative
recorded requests, tokens and cost for this conversation, including retries and
background work, and the latest successful request's reported context
occupancy and actual model. An incomplete cost is labelled as a known subtotal.

An opened conversation keeps its workspace in subsequent requests and its URL;
changing the daemon's default workspace does not move that conversation. A
failed send keeps its idempotency key for a manual retry of the same payload in
this page. Reloading the page discards these pending request keys and drafts.

Bot conversations remain read-only in the WebUI, including historical rows whose
live channel binding has moved. Continue messages and approvals through the Bot's
channel. **Stop** and attachment reads remain available. The daemon rechecks
these restrictions on every page mutation. Bot current selection, **New
conversation** and **Resume** use the Bot's own commands on its page.

Questions and tool approvals replace the composer with a card while they wait:
Enter approves and Escape denies an approval; an answer sends with Enter.
Execution can be paused and resumed; failed steps offer retry or abandon.
Stopping execution is an explicit action (the Stop circle while running,
Escape twice within a second in the composer, or **Stop all work** in the
title menu, which also ends background work that continues after a reply);
changing conversations or closing the browser only detaches the viewer. The page reconnects read streams
and reconciles durable history, but never retries a mutation automatically.
An unresolved provider context overflow points to **Nexus Settings > Model
providers > Edit model > Context and capabilities**. For `web_fetch`, **Allow
this site until restart** approves the held request and remembers a literal URL
prefix for the running daemon; **Approve** continues to approve only the held
request.

**Background tasks** in the conversation header (a list icon with the count
of what is running) opens a side-panel tab with everything this conversation
runs beyond the visible reply: busy subagents and the current turn's live
steps under **Running**, steps held for a dependency or an approval under
**Waiting**, and idle subagents, which open on click. Each row has its own
Stop: a subagent's stops that child conversation and its derived work; a
step's cancels that branch by its key, and a step that belongs to the main
reply says so and points at **Stop all work**, which the tab also carries.
Tool names arrive from the task read; the kernel's live snapshot names keys
and kinds.
Background result receipts appear in a collapsed **Background task result**
disclosure; expand it to read the original receipt while the answer and its files remain visible.

**Tools and activity** under an answer loads the recorded rounds; a call or
**Read full round** opens the task's input, output and captures as a side-panel
tab. When Nexus's retention policy has collected an old turn's execution
details, the page keeps its conversation text and labels the removed details.

Answers support basic Markdown: headings, paragraphs, lists, quotations,
fenced and inline code, emphasis and links. Raw HTML remains literal text.
Files published by a completed answer or its reported subagents appear beside
that answer with **Download**, even when the text names no file. **Preview** is
available for Markdown (`.md`, `.markdown`) and images (`.png`, `.jpg`, `.jpeg`,
`.gif`, `.webp`, `.avif`, `.svg`, `.ico`), ignoring extension case. Markdown previews
render the file's contents with the same basic Markdown support as answers.
Other formats, including ZIP archives, offer download only.
The cards follow the selected answer variant. A filename mentioned in text,
such as `README.md`, does not create a file card. Explicit paths such as
`/tmp/report.md`, `./report.md`, `../report.md` and `output/report.md` can also
offer file actions. A published file takes precedence over a same-named path
inferred from the answer text; separate uploads keep their own cards even when
their filenames match.
Runner artifacts are fetched with authentication through rho's existing file
and upload routes. Browser file upload is not provided.

## Scheduled jobs

**Scheduled jobs** in the sidebar opens the workspace overview at
`/panels/schedules`: every job of every conversation you can read in the
current workspace, grouped as **Active** (ordered by next run), **Paused** and
**Finished**. Each row names its job, prompt, rule and next run, the
conversation it reports to and its latest execution, both of which open on
click; its commands are icons at its end. **Run now** starts one execution
immediately without moving the job's clock; while the previous execution is
still working the page says so. **Pause**, **Resume** and **Cancel** act in
place. **New scheduled job**, on the Active group, asks which recent
conversation should own the job and opens that conversation's editor, because
a job inherits its conversation's model, tools and approval policy. Switching
workspaces rereads the overview.

**Scheduled jobs** in a conversation header opens the side-panel tab to list,
create, edit, run, pause, resume or cancel that conversation's delayed and
recurring tasks. Choose a one-time instant, an interval with its first run, or
a daily local time with an IANA time zone. Each occurrence works in a fresh
child conversation and reports back; **Executions** shows those children with
**Open execution**. A conflicting edit keeps the draft and asks you to refresh;
an uncertain create retains its key for a manual retry within this page.

## Bots

**Bots** in the sidebar opens `/panels/bots`. The list shows each persistent Bot
with its effective Preset and model. The sidebar's Bot name and **Open current
conversation** use the same current-selection owner; a Bot has one current
conversation. A failed request keeps its operation ID for a deliberate retry.
The actual current winner is opened even if a replay names an earlier selection.

An editable Bot's page is `/panels/bots/<public_id>`; **New bot** opens
`/panels/bots/new`. Its page contains current selection, conversation history,
Home Workspace, identity and Subagent settings, and any channel configuration contributed by
plugins. **New conversation** immediately selects a new conversation in Home and
archives the previous one without stopping it. **Resume** selects a historical
conversation in its original workspace. History offers all, unarchived and
archived pages across readable workspaces, with running and attention indicators.

Home affects only future new conversations. Clearing it prevents new creation;
existing conversations and scheduled work retain their workspace. The page never
substitutes the browser's current workspace for Home or a historical locator.

The Bot editor owns stable name, display name, description, audience,
Preset reference, Subagent choice and welcome message. **Subagent** starts on
for a new Bot, independently of the Main Agent's default. The switch controls
whether this Bot can delegate work to subagents on future inputs. Its saved
choice appears when editing; a failed save keeps the draft for retry. Bots keep
Code mode off and have no Code mode control.

**Default introduction** uses the Bot's
name and description; **Custom introduction** saves text; **No introduction**
disables it. Welcome is static text and creates no model input. **Edit selected
Preset** opens the shared configuration in Settings. A Preset change keeps the
Bot's UUID and memory. An external Bot cannot become private under the same
identity; **Duplicate** creates a fresh identity with the chosen audience and
same Preset, Subagent choice and welcome message, without copying memory,
conversations, Home or channel connections.

The Main Agent's Preset selection lives in **Settings → Agent Presets**.
Bot removal is separate from Preset deletion; a selected Preset cannot be removed.
Configuration import/export lives in the Preset library and creates no identity.

## Nexus

**Nexus**, in the sidebar's foot over Settings — the two administration
pages, kept apart from the panels and from each other — opens
`/panels/nexus`: the account's administration, apart from Settings (rho's
own) so the two are never confused. It reads and
writes Nexus's admin plane through the daemon's Human-credential proxy
(`POST /nexus/request`, `shell.nexus.request(path, { method, body })`) with
the signed-in human's session, never the Agent's credential, and does what
Nexus's own provider page does, laid flat under a **Providers** group with
**Add provider** on its head: every provider is a card with its models under
it. A provider's title row carries its name and id, a mark only when
something needs attention — **API key needed**, **Not connected**,
**Sign-in required**, a credential its models cannot use — its enabled
switch and its menu (authorize in Nexus for a subscription provider, edit
the connection, and, last, delete the connection or restore the
deployment's for a file-backed one). An API-key provider's card always
carries its **API key** field — the key is never shown; the hint says
whether one is saved — with **Save** and, while a key is saved, **Remove**;
a subscription provider that is not connected carries its sign-in. The
**Models** group's head carries **Discover model IDs** and **Add model**;
each model row shows its name, what it is and can do (workload, tools,
streaming), its id and its price, with its visibility switch and a menu —
Test (asked first; one small, possibly charged request), Edit model, Clear
invalid mark, Remove model. A row marks only the model's own trouble
(**Marked invalid**, after a discovery); that the provider is off or has no
usable credential is said once, on the provider, and a hidden model's
switch is its own mark. A removed model waits under **Removed models** with
**Configure again**. The connection and model editors open in place inside
the provider's card and write the same declaration Nexus's forms write over
the one Nexus holds, so settings they do not show keep their values. Every
write carries the provider's `lock_version`; a stale one is said and the
page rereads. A page let in by
the unlock password is asked to sign in with Nexus; a member is told
administration is the owner's; a model plane that cannot be read says so.
Members, budgets and subscription authorization stay in Nexus's own pages,
which the page links to.

## Extending the page from a plugin

A running rho extension may ship a browser module. In its `register(api)`:

```ruby
api.register_webui_module(root: File.expand_path("../../webui", __dir__))
```

The directory is served at `/modules/<plugin id>/<key>/` only while the
extension runs and the page is served; `index.js` is its entry. The key is
derived from the installed directory, so activating another installed version
loads new code without a reload. The plugin's `GET /extensions` row names the
entry as `capabilities.webui`; the page loads new modules and disposes removed
ones whenever that inventory changes — after its own plugin actions, when the
tab regains focus, and when the Plugins panel opens.

`index.js` exports `register(ui)`, which may be `async`. The `ui` handle is the
whole platform a module sees:

| Member | Meaning |
|---|---|
| `ui.id` | the plugin id |
| `ui.signal` | aborted when the module is disposed |
| `ui.slots.register(name, options, component)` | contribute to a slot; returns a disposer |
| `ui.call(path, { method, body, signal, conversation })` | the authenticated same-origin control API; a 401 signs the page out |
| `ui.translator({ en: { … } })` | a `t(key, values, fallback)` over the module's own catalog with `{rho}`/`{nexus}` brand names |
| `ui.el(tag, attrs, …children)` | element builder; text only, never HTML |
| `ui.primitives` | buttons, fields, switch, segmented, alert, tag, disclosure, section card, list, link, menus, modals, `panelRow` (a sidebar row that opens a main panel) and `page` (the scaffold of a main panel); a button's visible text is its `.btn__label` span |
| `ui.toast(text, { tone, action })` | a transient notice |
| `ui.navigate(key)`, `ui.dock.open(key, { id, params })` | open a main panel or a side-panel tab |
| `ui.inventory.refresh()` | read the plugin inventory again, after a save that changes the plugin's readiness |

A component is `component(props) → { element, update?(props), dispose?() }`.
`update` receives the owner's new props and keeps DOM state such as a draft;
without it the component is re-created on change. A throwing component costs
only its own cell and marks the module failed on its plugin page. Module-level
mutable state is forbidden: an ES module is cached per URL, so re-enabling a
plugin calls `register` again on the same instance with a fresh handle.

The slot catalog:

| Slot | Kind | Owner props | Built-in occupants |
|---|---|---|---|
| `main` | keyed; reached at `/panels/<key>` and by `ui.navigate(key)` | `{ visible }` | `conversation`, `plugins`, `schedules`, `bots`, `nexus`, `settings` |
| `sidebar.panellist` | list (`id`, `order`) | `{ current, collapsed }` | `schedules`, `bots`, `plugins` |
| `settings.section` | keyed, `label()` required | `{ document, status, identity, visible, request, save, refresh }` | `general`, `presets`, `roles`, `advanced`, `deployment` |
| `bots.item.config` | list (`id`, `order`) | `{ bot, refresh }` | channel modules contribute their own target forms |
| `plugins.item.config` | keyed by plugin id | `{ plugin, refresh }` | the generic schema form |
| `dock.tab` | keyed, `title(params)` required; `description()` lists it in the empty-panel guide | `{ conversation, params, close }` | `background`, `task`, `schedules`, `usage` |
| `conversation.header.utilities` | list, re-created per conversation | `{ conversation }` | `background`, `schedules`, `usage` |

Within a cell the lowest `priority` wins; the same priority twice is refused by
name. A `main` page stays mounted behind the other panels and is told
`update({ visible })` as they come and go; a page without `update` is
re-instantiated (hidden) each time another is shown, so one that holds state
— an open editor, a draft — implements it. Disposing a module removes every
contribution it made. Module code is
trusted installed code running same-origin with the page's bearer; there is no
sandbox. `rho-ingress-telegram` is the shipped example: its `webui/` registers
a `sidebar.panellist` row and a `main` page (`/panels/telegram`) so the plugin's
status, setup and access lists are one click from the sidebar, plus the same
body as `plugins.item.config` for `rho.ingress_telegram`. It uses its own `/telegram`
routes for connection state, `/status` and `/agents` to select an editable Bot,
and `/workspaces` plus `PUT /agents/settings` to manage that Bot's Home Workspace.
A plugin whose settings people need to find should
do the same: `panelRow` for the row, `page` for the scaffold, and the plugin's
own routes for its facts.

## Files and development

`webui/` contains plain browser ES modules, HTML and CSS. The gem ships those
files as written: no asset build, package manager, Node, Deno or server-side
JavaScript process is required. `index.html` loads `app.js` and seven
stylesheets under `styles/`:

- `kernel/` — `dom`, `api` (bearer, calls, SSE over `fetch`), `i18n`,
  `observable`, `slots` (the catalog and registry), `outlets` (list and keyed
  rendering), `handle` (the `ui` object), `modules` (loading and disposing
  plugin modules), `forms`, `theme`.
- `primitives/` — the shared controls.
- `shell/` — `frame` and `columns` (layout geometry), `sidebar`, `dock`,
  `bots` (`/agents`), `inventory` (`/extensions`), `setup` (`/settings`,
  `/settings/status`, `/auth/status`, `/status`), `router`, `boot`, `login`.
- `features/` — `conversation`, `plugins`, `settings` (its sections and the
  main page that hosts them), `bots`, `schedules`, `background`, `usage`,
  `task`; each registers through the same slot
  contract a plugin uses and never imports another feature.
- `locales/en.js` merges `locales/en/{shell,conversation,settings}.js`.
- `styles/` — `tokens` (colours, radii, elevation and motion adapted from
  DeepSeek Harness, MIT), `base`, `icons`, `primitives`, `shell`,
  `conversation`, `panels`.

Stable file names stay at the static root so they are revalidated instead of
receiving the daemon's fingerprinted-asset cache policy. The daemon reserves
`modules/` for plugin modules.

The interface, document title and product names use `kernel/i18n.js` and the
default English catalog. Plugin names, descriptions and schema field copy use
keys under `plugins.<id>` with the plugin's authored metadata as the literal
fallback. The static HTML title and no-JavaScript guidance remain English
because they must work before browser JavaScript runs.

Daemon, provider and plugin diagnostics arrive as authored text; localization
belongs to their producer. For an unresolved typed `provider_context_overflow`,
the browser catalog adds recovery guidance alongside the literal diagnostic.

Development verification requires Ruby and Bun. From this directory:

```sh
bundle install
bundle exec rake
bundle exec rake build
```

The default task runs Ruby tests, the offline browser tests with Bun
(`bun test test`, using the small DOM in `test/support/dom.js`), RuboCop and
RBS validation. Packaging tests extract the built gem into a temporary directory
and load its registration without a JavaScript runtime, then check that every
shipped file matches the checkout. Daemon authentication, static serving and
module mounting are tested in the rho project. Bun is a development dependency;
installation and serving still need only Ruby.
