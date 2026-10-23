# Rho

Rho is an agent for Nexus with browser, Telegram and editor entry
points, plus a CLI for service management and single requests. It uses the
`cybros_agent` SDK and extensions to connect model work to local or remote
runner tools. `rho server` starts its daemon.

Start with [installation](../../../install/README.md),
[first setup](../../../docs/getting-started.md), and
[daily use](../../../docs/rho-usage.md). This page is the detailed configuration
and behavior reference; the [extension index](../../../docs/README.md#extend-rho) links each integration.

The CLI is one surface among PEERS: it, the page the daemon serves (the
WebUI), ACP and the IM integrations are all thin consumers of one
body, `Rho::Core` (`lib/rho/core.rb`) — the primitives every surface
composes, each ONE capability over ONE route: connect and status, open a
conversation, say, stop, a run's row and its event stream, its result,
approve and deny, an input's edit, over the daemon's control routes and the
kernel; no printing, no polling, no exit code lives there. Among the peers
the CLI is the special one: its role is the CONTROL PLANE — the daemon
(`server`), the connection (`connect`, `disconnect`, `status`), the install
(`version`, `doctor`, `update`, `uninstall`) and the shipped gems'
management verbs (`mcp …`, `agents`, `env`, `runner`, `processes`, …) —
which is why it is the one surface every install carries. Its single
conversational courtesy is `rho run`: a prompt run to its end on this
machine, the answer printed, the exit code the outcome. Every other verb
that operates a conversation from a terminal — open one and return its ids,
a second turn, a run watched, repaired or decided — is `rho-dev`'s, a
development gem the distribution never carries, for the orchestrator, e2e
and other agents to test and debug through. See the [rho-dev manual](../rho-dev/README.md).

Rho has a code-owned product identifier:

```ruby
Rho::AGENT_IDENTIFIER # => "rho"
```

The registration sent to Nexus combines this constant with the per-home
instance ID: `rho.<instance_id>`. The ID is created when the home is prepared
and remains stable across upgrades and reconnects. A separate home gets a
separate registration. Neither part is a CLI identity selector; changing the
human-readable display name preserves the Agent:

```sh
rho server --display-name "rho on workstation"
rho connect
```

## Settings and terminal setup

Open rho's ordinary public URL and choose **Sign in with Nexus**. The browser
uses Authorization Code with PKCE S256; **Use a device code** supports terminals
and browsers that cannot use the configured callback. The first login connects
this installation's Agent. Full mode announces Runner capability on that same application address. Later logins
reuse that runtime connection. The page never asks for a separate rho password.

If Nexus has no account yet, its authorization page continues through owner
creation, then returns to the same authorization. The default installation
requires no setup secret; Nexus requests one only when the operator explicitly
configured `NEXUS_SETUP_SECRET`. Device login instead offers the Nexus setup page and
starts a new code after setup. The installer prints rho's public URL and keeps
its callback registration consistent with that URL. Nexus accepts HTTP or HTTPS
`/auth/callback` on any valid port at loopback, `localhost`, literal private IPv4
or IPv6 unique-local addresses by default. DNS names and public addresses need
an explicit exact callback list, which replaces those defaults.

Open **Nexus** to configure providers and models with the logged-in Human's
current Nexus permissions, **Agents › rho** to choose the default model, and
pair Telegram on the **Plugins** page. Personal
settings require a live Human; system settings require the current owner/admin
role. Provider and Human OAuth credentials remain server-side. Returning from
Nexus refreshes model availability without inference. An existing valid default
stays selected; a sole usable text model with tools becomes the default; multiple
models require a choice.

All rho configuration lives in `<RHO_HOME>/settings.json`: core deployment and
model choices are root fields, and each plugin owns
`plugins[ID].configuration`. The document has `settings_version: 1`; each plugin
entry has its own `configuration_version`. A plugin's private data directory is
`<RHO_HOME>/plugins/<ID>/`; local T3 keeps its native state there. The home is
private, and the settings writer publishes its file atomically with mode 0600.
Keep the home when replacing a container.

GUI and CLI edits use the same serialized settings owner. Supported changes
apply immediately, retaining unchanged connections, conversations and processes.
Existing Nexus runs retain their captured definitions; a removed tool follows the
normal failed-tool result path. Plugins with exclusive process state, including
local T3, save changes for the next restart and keep their current instance active.
That successful save returns HTTP 200 with `saved: true`, `applied: false`,
`published: false` and `restart_required: true`. Registration/startup failures and
publication failures remain separate errors; inspect their saved/applied state
before retrying.

Core environment variables seed the corresponding root fields; saved fields
override those seeds — a saved `null` unsets a seeded value — and explicit
launch flags take precedence on startup. Plugin values come from their schema
defaults and saved overrides; a credential a plugin needs at runtime is a saved
write-only field (the T3 bearer, the Telegram bot token), not an environment
variable, so it can be set, replaced or cleared while rho runs.
Process role and listener options — `RHO_HOME`, the Nexus the home is bound to,
`mode`, `bind`, the port, `api_only`, `webui_root`, `public_url` — are shown as
deployment information, not editable application fields: they are what a process
needs before it can read its settings. `rho settings` reads core settings; `rho extensions list` reads all plugin
descriptions, saved configuration, active state and readiness without requiring a
plugin to be enabled. Core management and authentication remain available when
every optional plugin, including WebUI, is disabled.

Current-format files use field-level fallback: a malformed plugin field produces
a diagnostic and uses its default when one exists; unknown fields are ignored
with a diagnostic. Valid siblings remain effective. Interactive edits reject
invalid changed fields. Forms preserve
untouched overrides and write-only secrets; `unset` removes an override so the
schema default applies. Startup converts the previous root format once, then
migrates enabled plugins forward through their declared configuration versions.
Explicit configure/enable operations can migrate a disabled plugin. A plugin
whose migration fails remains unavailable with a diagnostic while core recovery
and unrelated plugins remain usable. A newer root format is refused; no runtime
reader keeps aliases for previous top-level plugin keys.

Browser sessions use independent Human OAuth lineages stored privately under
`RHO_HOME/browser_sessions`. Logging out revokes only that browser's Human
lineage; Agent and Runner execution continues. Browser control requests check
live Human authority, including account removal and role changes, with Nexus.
The CLI's per-boot announcement bearer remains local and separate.

Pairing with Nexus happens once; `webui_access` (`RHO_WEBUI_ACCESS`) decides
what a browser needs afterwards to open the page: `open` nothing, `password`
rho's unlock password, `nexus` a Nexus sign-in. Unset, the gate is open on a
loopback bind and asks for Nexus elsewhere. The page sets both under
**Settings › General › Opening this page**; `POST /auth/unlock` is the gate and
`POST /auth/password` (`{"password": "…"}` or `null`) sets or clears the
password from an authenticated page, which is kept only as a salted scrypt
digest in `RHO_HOME/webui_password.json`. A browser the gate admitted holds an
unlock session with no Human credential: the settings proxy answers
`403 human_login_required` until it signs in with Nexus, which every mode accepts.
Changing or clearing the password ends every other unlocked session.

Run `rho setup` for guided first-run configuration, or `rho setup model` to
revisit provider configuration and the default model. An unbound installation
asks for the Nexus URL. Existing homes keep their Nexus binding and connection:

```sh
rho setup --nexus-url https://nexus.example
rho server
rho status
rho run "Say hello"
```

Create the first Human owner through the displayed Nexus setup page if needed.
The terminal uses the same application Device Flow. Its Human credential is
stored separately in `operator_credentials.json`; the optional administrator
step reuses that Human through cmctl's setup flow without asking for a Nexus
password. A live runtime connection is retained during later Human login.
Non-administrators can skip provider configuration and use models already enabled
by an administrator. The model picker lists available text models with tool calls;
pricing information is optional. Selection itself makes no model request; `rho run` is a normal,
potentially billed request. A saved choice overrides the `RHO_DEFAULT_MODEL`
initial value. Missing models leave a setup TODO and preserve other settings.

For Docker, use `./cybros setup` from the joint installation directory. It supplies
the internal API URL and public browser URL separately, preserves the connection,
and applies changes to the running daemon. `--public-url` saves the browser URL
used by settings links; it never changes the bound API or credential authority.
Native installs start `rho server` if it is not running. Setup requires a terminal and
is unavailable in runner-only mode, where `rho connect` is the pairing command.

`rho setup telegram` creates or updates a shared Telegram Connection. It validates
the BotFather token with `getMe`, shows the physical account for confirmation, and
saves the write-only token under `configuration.connections[CONNECTION_UUID].token`
in the Telegram plugin's private `<RHO_HOME>/settings.json` configuration (mode 0600).
The token has no environment-variable fallback. With the daemon running, setup
then selects an existing Bot with a Home Workspace and asks for its fixed chat ID,
optional group topic ID and numeric owner ID. It confirms the target before saving.
Offline setup saves only the Connection. Start rho and create a Bot with a Home
Workspace, then bind it in **Bots → Telegram target**, or run
`rho setup telegram --finish` to select a saved enabled Connection without entering
its token again. Setup neither discovers chat IDs nor polls updates or sends messages.
Main has no implicit Telegram target. Several Bots can share a Connection when
their targets differ. Personal Bots serve their owner in a private chat; External
requests Bots also admit the people and groups selected in their access settings.
See the [Telegram guide](../rho-ingress-telegram/README.md).

## Identity and credentials

A connected Rho identity has two credential planes:

- a member credential for the Agent and `/profile`;
- an executor transport credential for the Agent's delivery
  address and `/executor`.

The profile's `user_public_id` selects the local identity root, while the
mandatory `executor_public_id` records the paired delivery address. Rho
considers the Agent fully active only while both planes are live.

Removing or disabling the Agent fences both planes and its refresh grant.
In full mode, the independent Runner keeps its credentials and continues
running. An Agent-only reconnect restores the Agent; canceling that ceremony
keeps the Runner connected.

The identifier rho presents is the program's name plus a per-home INSTANCE
part — `rho.3f9a2c1e`, and `rho-runner.3f9a2c1e` in runner mode — derived at
the home's first boot into `RHO_HOME/instance.json` and never typed, so several
installs of one program pair under one steward as separate rows; `rho status`
prints it as `instance:`. Identity is the home: an explicit reconnect of the
SAME home presents the same identifier, and Nexus re-pairs the existing Agent
and fences the previous device; a soft-removed Agent is restored.
An upgrade is "replace the checkout,
restart" and a rollback "restart the old checkout" — the file stays, so neither
re-pairs. A home from before the instance file derives one at its next boot and
pairs as a NEW row at its next ceremony; revoke the old row through the
console, or start from a fresh home.

Do not copy an old `RHO_HOME`, access token, refresh token, credential document,
or attempt state to move a registration: a copied home answers the original's
instance id, so its pairing FENCES the original on the one live row per
(steward, identifier). Independent copies are outside the local boot-lock
domain and are an unsupported deployment.

## Execution

Coding tools run on the runner role, and rho plays it in one of three modes —
`rho server --mode full|agent|runner` (settings `mode`, `RHO_MODE`; default
full). Full connects one Agent Executor, announcing `agent`
for application tools and `runner` for Coding, Processes and environment tools.
Both roles share one transport credential, inbox subscription and execution pool.
The member bearer never reaches a claim. Local resolves to this application's
Executor UUID before work is accepted. Its Main, Bots and Subagents can use that
runner capability; another application under the same Human cannot. Switching
between agent and full modes replaces the services announcement on the same
address and credentials, without another pairing ceremony.
Agent names a runner (`rho run … --runner`, the `runner`
setting). Runner serves tools alone — the container runs
`RHO_MODE=runner rho server` with `RHO_HOME` on a volume and an optional
`RHO_DISPLAY_NAME`; `rho connect` prints the pairing code and URL.
Standalone Runner access remains the Human-private or account-wide scope chosen
at connection.
It constructs no member plane (no
`run`; the Ops routes are not in the runner set, and rho-dev is never
named on a runner home). `rho disconnect` revokes and
forgets. Rho creates its own private, dedicated workspace when none is
selected. `rho workspaces` lists its dedicated workspaces and visible shared
workspaces; `rho workspaces create NAME` creates another dedicated workspace,
and `rho workspaces use ID` persists the default in `settings.json`. Selection
only affects new conversations. Existing conversations, background results and
recovered followers stay in their original workspace, independent of their
runner and working directory. An unavailable selection fails explicitly;
discovery and existing work remain accessible so another workspace can be chosen.

`rho server --workspace ID` and `RHO_WORKSPACE` override the saved default for
that boot. Remove an explicit override before using `rho workspaces use`.
A per-conversation `rho run --workspace ID` or
`Core.open_conversation(workspace_public_id: ID)` overrides the default for
that new conversation without changing settings. It may name
this agent's own dedicated workspace or a visible undedicated workspace; Nexus
continues to judge access and dedication on every request.

`rho runners` lists the Runners this Agent may address, with presence for
display and `default for:` hosts (`default_hosts` on the local API).
`rho runners use ID|--none` selects the default for new conversations.
`rho set_default_runner HOST_ID EXECUTOR_ID` changes an existing host's default;
use `none` to clear it. This changes the environment and discovery default for
future turns. Every accepted
Runner task retains its original target through dispatch, retry and completion.
The command does not copy files or move environment records.

rho declares its kernel tool whitelist, ordered candidate Runner UUIDs and
Agent-provided custom tools or compact aliases. Nexus imports the selected
Runner's model tools when creating work, then freezes their concrete targets
and schemas. Candidate Runners are not merged into that tool surface. A child
can select another Runner at creation; omission inherits the parent's Runner,
and explicit `null` selects no Runner. A Run may still contain tasks explicitly
addressed to different Runners; each accepted task keeps its original target.
Runner, MCP, editor-provider and skill-loading schemas are deferred: the default kernel tool
pair discovers their exact names and schemas, then invokes them under the
same frozen authority and approval rules. Code mode can call the discovered
names too. Approval rules match the explicit callable for Nexus MCP tools, either
the served or captured callable name for Runner routes, and the resolved execution
name for kernel aliases. A served-name deny or ask still governs a Runner alias allow.
Discovery returns the frozen skill catalog with the relevant loader.
The Agent's `code` stays visible; named Agents can use `code` when their selected
Runner serves it. Code and delegated work inherit the accepted tool surface.
If a narrowed tool selection omits either discovery or invocation, Nexus shows
that selected tool set directly. Listing Runners refreshes creation candidates
without importing every candidate's tools into existing work.

Raw standalone runs keep their environment in the system field across
compaction, behind stable guidance. A changed environment still interrupts
their shared prefix at that point; assembled conversations put current Runner
facts, skills and the Agent roster after history.

Environment records are keyed by conversation and Runner. `rho call_tool`
(rho-dev) executes one announced tool on the named Runner without changing a
host's default. Rewind and regeneration restore each affected Runner using its
own first-write checkpoint, reporting per-Runner results and partial failures.

## Starting work

Discover models through the connected rho home before choosing one. A running
daemon owns the request; without one, rho reads the same member catalog using the
saved connection under the home boot lock:

```sh
rho models --workload text_generation
rho models --json
```

The listing contains only the models the account can currently use. `--json` prints the complete
`{"models": [...]}` document, including capabilities and pricing. The same authenticated control
read is `GET /models`, with an optional `workload` query parameter. It uses rho's member identity.
Provider lane and key changes, and diagnostics for unavailable models, belong to the separate
operator CLI, `cmctl`.

```sh
rho run "find the failing test and fix it" --model openrouter/qwen3-coder
rho run -p "summarize this repository"          # the final answer alone
rho run "run the tests" --output-format json    # one result object at the end
                                                # (stream-json: one object per event, then it)
echo "explain this code" | rho run              # the prompt from stdin (`rho run -` too)
rho run "make the suite pass" --until "bin/rails test" --attempts 3 --timeout 1800
                           # the check runs on the conversation's runner when the model ends its
                           # turn; exit 0 completes the run, anything else hands the model the
                           # output and another attempt; --timeout stops the run after 1800 s
rho run "what is this?" --attach diagram.png   # files beside the words (repeatable)
rho run "summarize this report" --attach report.pdf
                           # the daemon stages the bytes on its member plane as rho's own user and
                           # prints `attached: diagram.png (image/png, 184 KiB)`
rho run "…" --dir ~/src/billing --runner <id> --agent @lark --instructions "…"
                           # a directory described to the model, the runner whose tools serve the
                           # conversation, who answers (a member agent of the workspace), the lead
```

`--until` accepts the first check and its hold atomically with the first model
round. An immediate model reply therefore still runs the check; a refusal to accept
those steps blocks the input instead of reporting unchecked completion. Restart restores the
gate on its original Run without creating another check. Later inputs and
regenerated variants do not inherit the old goal.

`rho run` opens a CONVERSATION in the connected workspace, says the prompt
on it, follows the turn the kernel materializes — an agent run backed by
the tools THIS machine declared — to its end, and prints the answer. In
`text` mode it prints the three ids first (`conversation:`, `turn:`,
`run:` — `pending:` until the kernel has materialized the turn, the run
id on the first frame that carries it), `adaptations:` (the model adaptation
row and its source), `until:` when a check was given, then
the tasks as they move, `ASKING` lines, and the reply as it
streams behind a `│` gutter — every structured line (`run:`, `status:`, a
task row) still starts where it always did, and a status line breaks the
block first; the gutter is what keeps a reply containing a line that begins
like a table row readable to a person and to a script — then `status:` and
the answer whole (`(none — this run resolved no deliverable)` when the
run resolved none). `-p` prints the answer alone. `--output-format json`
prints one result object at the end; `stream-json` prints one object per
event as it lands, in the daemon's own vocabulary (`snapshot`,
`text_delta`, `progress`, `task_status`, `round_result`,
`attention_required`, `turn_status`, `closed`, …), then the result object.
The structured modes carry every error inside the object and never also
print a human line.

An input receipt can identify a new turn before the daemon's follower has
caught up. If the stream closes on an earlier turn, the client checks the
requested turn's durable status and rejoins while it is still active, using
the original timeout budget. In `stream-json`, `closed` ends that subscription;
the final `result` object ends the command.

```json
{"type":"result","subtype":"success","is_error":false,"status":"completed","reason":null,
 "duration_ms":1234,"denied_calls":0,
 "conversation_id":"…","turn_id":"…","run_id":"…","result":"…the answer…"}
```

`subtype` is `success | failed | canceled | needs_person | timeout`;
`status` the turn's terminal word (or the status at the moment the run
stopped the run); `reason` the failure reason, the attention reason or
`timeout`; `result` the deliverable's output, null when the run resolved
none; `denied_calls` how many parked calls this run refused. A consumer
ignores unknown fields; a field is never removed within the shape. The exit
code is the outcome:

| exit | when | the run it opened |
| --- | --- | --- |
| 0 | the turn completed | settled |
| 1 | the turn failed on a terminal run; someone else canceled it; the daemon refused (`rho run: <sentence>` on stderr); a usage error | as the kernel left it |
| 2 | the run could not finish on its own: the model put a question to a person (`awaiting_human`), a turn-shaped hold that only a retry or an answer reopens, a park with no key to deny, or `--timeout` | STOPPED by the run, first; stderr says `rho run: needs a person (awaiting_human — r2c1); the run stopped it` / `rho run: timed out after 1800 s; the run stopped it` (text and `-p`; the structured modes carry it in the object alone) |
| 130 | SIGINT / SIGTERM | stopped the same way; never a backtrace |

`run` is FAIL-CLOSED on approvals — reasonix's letter, adapted: it carries
no `--approval`, so the turn runs under rho's own rules (bypass: the guard's
denies stand, a rules row with verdict `ask` parks the call), and a call
that parks for an approver is DENIED by the run — in a non-interactive run
there is no prompt to answer — with one sentence the model reads next
(`  REFUSED r1c1 — non-interactive run` on the terminal, `denied_calls`
counts it), and the run goes on to the turn's own end. The kernel's `ask`
is not withheld: a model that asks ends the run at 2, and the conversation
with its transcript stays readable on the page. What `run` does not carry
is rho-dev's: `--approval ask|rules`, `--no-stream`,
`--restricted`, and every second word on a conversation.

New Main and Bot conversations generate a short title in the background after the
first accepted reply input. In Settings, **Conversation titles** follows the
model selected for that input by default; choose a text model or **None** to turn
it off. The saved `conversation_title_model` value is `"follow_current"`, a model
reference, or `null`. Explicit titles and later manual renames take precedence.
Each new conversation gets one attempt; failure does not delay its reply or retry
on later messages. Existing conversations, forks, Side and Subagent conversations
are not backfilled.

`--model` chooses an explicit provider/model route. When omitted, a new Main
conversation uses the selected Main Preset's model, falling back to the
installation's `default_model` (`settings.json` or `RHO_DEFAULT_MODEL`). A new
Bot conversation uses its selected Preset with the same installation fallback.
The daemon refuses an input when no model can be selected.

Later automatic inputs resolve the selected Preset again; a conversation's
explicit choice persists until cleared. Subagent conversations use their
captured declaration and model defaults. rho's model-facing `spawn` chooses a
published role, as described under [Bots and reusable Presets](#bots-and-reusable-presets).
A turn the kernel has not materialized within the daemon's 30 s bound prints
`pending` and the run keeps following it; an input the kernel BLOCKS at
materialization — an unknown model, a refused selection — is a refusal in
one line, `rho run: the kernel blocked the input (unknown_model) …`, exit 1,
read off the feed the moment the block lands. Input receipts retain the input
ID and the durable feed position from before submission. Both the initial
wait and a pending continuation match that input's materialization to its
Turn and backing run; another sender's reply or a compaction summary cannot
supply those IDs. The `run` field is an asynchronous follower snapshot and
can lag the receipt. A reader joining after the next turn starts recovers
its own status and sealed answer without rendering or approving another turn
or candidate's run.

`fallback_models` in `settings.json` is an ordered list independent of
`default_model`; its initial value is `[]`. Each Preset inherits that list when
its field is `null`, replaces it with a supplied list, or disables recovery with
`[]`. Nothing implicitly adds the default model to the list.

Each accepted input captures its agent configuration, selection intent and
fallback list. The kernel advances through available, intent-compatible routes
on classifier refusal or after bounded retries exhaust a transient provider
failure. Disabled routes and missing credentials are skipped before provider IO
without spending an attempt. Rate limits retain their wait policy; content
blocks and terminal request errors do not trigger fallback. A route explicitly
chosen in the picker remains pinned unless its selection intent authorizes an
alternative. Cross-provider model-only substitution requires exact catalog
model-version identity.

A switched mainline stays switched for the remainder of that turn; a branch
switch affects that branch. The next automatic input resolves the current Preset
again, while an explicit conversation choice retains the original intent.
The UI shows the actual answering route separately from that choice.
`rho status` prints `model:` and `fallback:` as the kernel holds
them; `rho run` puts every switch in the result object's `model_switches`
and every declined round in `refusals`, prints both in the table, and under
`-p` says each switch once on stderr (`rho run: r2 switched from
anthropic/claude-opus-5-5 to … (model_refused: cyber)`). A mode `runner`
home refuses the key: it declares no profile.

`--agent @handle|<public-id>`
names WHO ANSWERS: the daemon resolves it through the workspace's
principals listing (unknown → `principal_unknown`, naming the handles it
knows) and sends it as the create's `answering_user_public_id`; the kernel
judges standing (`answerer_not_eligible` prints as is — in a dedicated
workspace no one but rho is eligible). A conversation answered by ANOTHER
profile gets the person's words without rho's default tool subset or
environment lead. A later `core.say` can explicitly name `tool_names` and
`approval_mode`; the kernel judges those against the addressed profile.
The answer prints `agent: @handle (id)`. An agent is ADDRESSED, never woken:
B's turn opens at A's boundary, and an agent's `send` into the conversation
it is answering in reaches the conversation's default answerer. In the
model's history another agent's reply is one wrapped `<message from=@handle
kind=agent user=…>` and the person's own words stay bare; the follower
prints `sent` with `from:` under a peer's row. A run has one answerer.

THE SECOND WORD on a conversation — the PERSON's `send` (a steer at the
running turn's next model boundary, an explicit `steer_now` while supported tools
keep running, or a queued turn), `--to` naming who
answers one turn (group chat), a word scheduled for a time, a picture on a
later turn — and the END of a turn before its time are the page's,
ACP's, an IM integration's, or rho-dev's `say` and `stop`; `rho run` stops
what it opened only when it cannot finish. The side conversations (a
question beside the work, answered from its context; a side with ordinary tool
access by default and an explicit read-only option), the input queue (what is queued or parked on a
conversation, and the unblock path) and the run verbs (watch, follow,
result, transcript, retry, approve, …) are described with their verbs in
`agents/rho/rho-dev/README.md`, with the two mock lanes that drive the
whole spawn surface and the group chat through them
(`e2e/test/rho_spawn_test.rb`, `e2e/test/group_chat_test.rb`) and the paid
`cd e2e && E2E_LIVE=1 rake live_spawn`.

The `code` tool, supplied by `rho-codemode`, is enabled by default in every rho mode,
including `api_only`. It runs a JavaScript async function body over the frozen tool
declarations and task-scoped model, ask and graph helpers. The host records accepted
operations and observations while retaining the same VM and claim across waits.
The executor extends the ordinary task deadline while it owns the work; a lost VM
or expired claim does not resume by replaying the source.
Source can select a small final answer with `text()` instead of returning every child
result to the caller's model. See the [code tool guide](../rho-codemode/README.md) for
the authoring surface, Promise semantics and runtime bounds.

`code_mode` and `subagent` are boolean Main conversation choices. New Main root
conversations capture their initial state from
`plugins["rho.codemode"].configuration.default` (`on` by default) and the core
`subagent_default` setting (`true`). Change the code-mode default in plugin settings
or with `rho extensions configure rho.codemode '[{"op":"set","path":["default"],"value":"off"}]'`.
Later global edits affect new conversations only. Side and fork copy the source's
choices. Historical missing or null choices use the fixed initial value `true`.

The composer offers separate **Code mode** and **Subagent** buttons. Clicking either
saves the current conversation immediately. Control clients pass `code_mode: true|false`
and `subagent: true|false` on open or reply; omission preserves an existing choice,
and `null` is invalid. The CLI's `--code-mode` and `--no-code-mode` select code mode.
`core.conversation_modes(id)` reads both choices;
`core.update_conversation_modes(id, code_mode: false)` changes one without sending
input; `subagent:` works the same way. The local control route is
`GET|PATCH /conversations/modes`, addressed by `public_id` and optional
`workspace_public_id`. PATCH accepts one or both boolean fields and returns
`{ "modes": { "code_mode": true, "subagent": true, "available": true,
"code_mode_available": true } }`. `available` is false for an unrelated answerer;
`code_mode_available` additionally reflects whether the plugin is enabled.

Subagent off removes role spawn and bounded task delegation from new inputs,
including explicit tool lists. Existing workers can finish and report; send,
status and cancel remain available. Explicit native coding harness tools keep their
own configuration. Human-authored schedules capture the conversation's current
selection; later mode changes do not rewrite accepted schedules or work.

Off withholds `code` and its authoring hint from new rho-authored turns on either
a local or remote runner. An explicit tool list cannot add it back while off;
an explicit code-mode choice can override the global default. The full profile
declaration and executor registration remain available, so switching does not
change a captured turn or interrupt accepted work. Regeneration replays the
original request and its original tool list. Extension-owned named profiles use the
same switch within their own tool declarations. Bot main conversations always use
Code Mode off and read Subagent from their own Bot settings. A request addressed to an
unrelated Agent uses that Agent's tool policy; the rho switch does not govern
other Agents or add a setting to Nexus's general orchestration API.
Disabling `rho.codemode` withdraws the plugin's registrations and authoring
contributions altogether; use `rho extensions enable rho.codemode` to restore it.

A conversation-lifetime result not explicitly consumed comes back as kernel mail
after the original reply, even if it finishes early. The next turn reads the
receipt first; rho-dev's `watch` prints `background:` while the work runs,
then `delivered` when its result lands. The follower snapshot records those
receipts in `delivered_results`. `delegate_task` runs in the background by
default — the call answers at once with the started key(s); a call with
`wait: true` holds the turn until the result is in. The kernel's four
conversation verbs are declared beside them by default (`kernel_tools`):
`spawn` selects an exact published `role` and opens a child conversation
under the caller's identity with that role's captured Preset, whose reply
comes back as mail `origin: child`; `send`, `status` and `cancel` keep
talking to it, read it, and stop it. The kernel cancels derived work by its
originating request; independent later requests in a reused child conversation
survive. `session_search` and `session_read` are also declared by default:
they search readable Chinese/English conversation history in the current
workspace and read a bounded text window, including retained history whose
execution details have been collected. `session_read` with `include_execution: true`
also reads the status of unfinished turns and persisted model/tool previews; see the
[history reference](../../../guides/reference/agent-api/conversation-history.md).
Both are allowed as read operations in
rho's approval rules. Nexus owns the index and authorization; rho keeps no local
history index. Account administrators configure execution-detail retention in
Nexus or with `cmctl account retention [DAYS|off]` (90 days by default). Conversation
text stays readable; old details and regeneration report `execution_details_pruned`
when collected.

rho's instructions prefer at most three agent levels in total. The main agent
owns communication, coordination and reporting; a direct subagent owns its
assigned outcome and may delegate focused implementation, checks or review to a
third-level worker. Each parent receives and synthesizes its children's results.
Delegation briefs carry the worker's role, level, constraints and deliverables.
Short work can stay with the main agent, and deeper work can use the same generic
mechanism when needed. This is a soft application default, not a depth or security
limit. Native coding agents keep their own nesting policy.

Temporary model assignments belong to the requested task or stage. Use the
delegated task's explicit `model` selection for a temporary rho worker. The
read-only `nexus.models.list` tool resolves names against the available Nexus
catalog without requiring a Runner or daemon connection. Where the execution
environment can reach this rho's local daemon, `rho models --json` reads the same model directory.
Having a rho binary on an arbitrary remote Runner does not provide that access.
Without a discovery path, request an exact model reference or report an unresolved
name; do not guess an ID. An explicit model or coding-agent choice must resolve to
an available, supported selection or be
reported as unavailable; it is never silently replaced. These assignments do not
edit the parent conversation's continuing model, global settings or a named
agent's profile. Results identify the model that actually executed the work.

For ordered implementation and review, the review starts only after the requested
implementation has succeeded. The parent hands over its actual result, source or
diff access, check results and artifacts, then performs the requested final review
or synthesis. Merely ordering two tasks does not transfer the first task's result.
A failed or canceled implementation stays a failure or cancellation until the
parent decides how to proceed.

The default `kernel_tools` list includes `nexus.models.list` for available model
references, identities, capabilities and pricing, with optional query and paging.
It also includes `nexus.runners.list`, which returns
the current Runner and the eligible candidates supplied by rho, so the model
can choose an environment before creating a child. These candidates come from
Agent-visible Runner discovery, including Runners not used by a followed host.
Remove the canonical name from `kernel_tools` to omit this optional tool;
an empty list disables all kernel tools, and so does a configured name the
kernel does not serve, which the daemon logs as `kernel_tools_unavailable`.
`GET /kernel_tools` lists every tool the kernel currently serves — canonical
and wire names, the kernel's description and effect profile — and the WebUI's
**Settings › Defaults** offers `kernel_tools` as one switch per listed tool.
`GET /adaptations/rows` lists the adaptation pack's rows the same way for the
`adaptations` knob. There is no model tool for changing an existing
conversation's Runner. The operator's `set_default_runner` command continues
to affect only future work.

In an ordinary conversation — the WebUI, the terminal, any surface where the
person watches the work — rho's default guidance does the work in that
conversation and reports when it is done, the way a coding assistant works in
front of you. Delegation serves the work rather than ending the reply early:
independent subtasks that can run in parallel, a focused worker with its own
model or coding agent, or a long verification go to subagents whose results
the reply waits for. Persistent background work with conversation lifetime
is for an explicit request to work in the background; after such a launch the
main conversation says what started and stays available, later changes go to
the same child, and its returned result is checked and reported there. A
messaging channel adds its own delivery policy as a lead before each request
(`Rho::ExecutionPolicy::MESSAGING`): the person there sees messages, not
work, so quick questions and small tasks are answered directly while
sustained work starts one background worker, is acknowledged at once with
what started and roughly how long it should take, and returns as a later
message. `rho-ingress-telegram` applies that lead when the Bot's Subagent setting
is on. With Subagent off, its lead asks the Bot to complete the work directly and
wait for the result.
Rho's profile uses an assembly template that places the current conversation kind
beside the turn's input, after history: ordinary conversation, child, scheduled
execution or side conversation. The shared system prefix stays the same when a
side forks. A child or scheduled execution carries out its assignment
and returns the requested result. It must not pass the whole request onward and
substitute a launch acknowledgement for completion. Independent subtasks remain
available; results needed for the current delivery use turn lifetime or an
explicit wait. Explicitly requested persistent background work remains available.
Rho's standalone `assembly` requests receive their kind through that template.
An explicit `default` request uses the kernel's built-in template, so rho places
its known standalone context in the input lead. Raw standalone requests render
that context in their default instructions; custom raw instructions remain the
caller's policy. Operator-authored named-agent prompts and templates remain their
own policy.

When a result returns, rho's guidance uses that receipt's source, execution time
and original qualifications. It does not infer one-time or recurring work from a
nearby task. A job's editable current rule does not establish a past execution's
rule; an unknown schedule type is described as "this execution". This is model
guidance over the available tools, not an automatic router or a guarantee of
correct delegation and wording from every model.

rho's default implementation guidance asks for a complete usable result before
optional restructuring, including requested supporting files and run instructions.
New dependencies should be written and checked before the entry point is changed
to use them. A supplied deadline travels with delegated work, with time reserved
for relevant checks and a truthful final report. This is agent guidance, not an
atomic filesystem transaction or an automatic restore to a verified version.
Named Agents supply their own system prompt and can state a different
delivery policy.

HOW A MODEL IS SPOKEN TO is the SDK's, not rho's: `cybros_agent` ships a MODEL-ADAPTATIONS
PACK — a documented YAML format under `lib/cybros_agent/model_adaptations/`
(`sdks/ruby/README.md`, "Model adaptations") — whose rows are matched by
model PATTERNS over the kernel's model reference (`z-ai/glm-5.3`,
`claude-*`; the lane segment dropped, the most specific entry answering)
and carry, each text measured before it lands and the floor never tuned for: the
spellings (`tool_style`: `nexus` the plain names; `claude` `Agent` (= `delegate_task`;
`run_in_background`, default true, `false` waits), `AskUserQuestion` (=
`ask`) and `Skill` (= `skill`); `codex` `spawn_agent` (= `spawn`, always in
the background) and `send_message` (= `send`; `target` is the kernel's
`to`)), description variants
(`tool_descriptions`, renamed aliases only), a `summarizer_prompt`, per-turn
`lead_hints`. Each spelling is an ALIAS on
the declaration: the kernel routes and records the call under its own
`delegate_task`/`ask`/`spawn`/`send`, so rho's rules written against
`delegate_task` match a call made as `Agent`; a preset's text is the kernel's own
template served on `GET /tools` with ONE anchored re-cut, rendered at
declare — rho copies no kernel text, and a moved anchor refuses the
declaration by the entry's name (`adaptations.anchor_moved` in the log),
never a silent fallback. The names are Claude Code's and Codex's; the WHEN
word is ours. Background results wake a new reply by default; `wake: "passive"`
records the result without starting one. Nexus also offers `nexus.graph.wait`
for an explicit later wait on an existing task, including an earlier turn in
the same conversation. Add it to `kernel_tools` to expose it; rho's default
tool selection remains unchanged. These choices are independent of tool naming
and task lifetime; see [orchestration](../../../docs/orchestration.md).

The optional `plugins["rho.lifecycle_hooks"].configuration` object declares external tools at
`turn_start`, `pre_compact`, `post_compact`, and `stop`. The default is `{}`.
Each entry names `tool` and `timeout_ms`; Stop also sets `max_continuations`.
Only Stop can request another round with feedback. Hook tools need not be in
the model's tool list, but must be served by a connected executor. The full
configuration and result protocol are in [lifecycle hooks](../../../docs/lifecycle-hooks.md).

rho's policy on top is ONE knob in `settings.json`: `"adaptations"` (or
`RHO_ADAPTATIONS`) — `auto` (the default) applies the pack's row for a
model, the `claude`/`codex` preset rows for the models they cover included;
`off` declares the kernel's plain set; a row id (`"adaptations": "claude"`)
pins that row for every model, the one lane-specific choice (a row's
entries never see the lane) — plus LOCAL rows under
`"adaptations_dir"` (default `<home>/adaptations/`, no environment
spelling): whole rows in the pack's format for a model no gem row covers,
or in place of the gem's row of the same id (a local row that replaces
none answers before every gem row, so a local `z-ai/*` takes
`z-ai/glm-5.3` too; every text field the operator's; printed `local`). A local
row owns the per-model tool spellings and texts. THE BOOT ROW IS THE UNIVERSE:
the profile declares once, under the pinned row, else the row of
`default_model` (none → `default`), and every turn sees the whole
declaration; `rho run --model X` on a model whose row spells tools
differently runs under the BOOT row's spellings and says so
(`adaptations: kimi-k3 (gem; boot row glm-5.3)`), while X's row still
decides the per-turn `lead_hints` that ride the developer-role lead
after the tool lines. A row change is a boot (the declaration is the front
of the cached prefix), as a `kernel_tools` change is. rho-dev's `rho
adaptations [--model M]` prints the row M resolves to from the files alone
— its entries and the one that matched M, spellings, recut anchors,
summarizer and hints, the boot row when M's differs — then the kernel's
facts for M (`tool_calls true (catalog)`) through the daemon, `(no daemon)`
without one; `rho status` prints the default model's row; `rho run` prints
the turn's row after the turn ids.

Nexus executes context compression from the accepted agent configuration. The
`rho.compaction` plugin configures the optional summary `model`; without one,
Nexus uses the current turn's model. Disabling the plugin declares compaction off.
Rho supplies its coding-conversation summary prompt through the existing
`summarizer` document. A pinned adaptation row, or the row for an explicitly
selected summary model, can override that text with `summarizer_prompt`. Without
an explicit summary model, the prompt follows the configured default model's row.
A Preset's explicit compaction model selects its own adaptation row. A row without
custom text uses Rho's default summary instructions. Under `adaptations: off`,
Rho leaves the document absent and Nexus uses its default prompt. No summarizer
callback to the Rho process is needed.

Rho declares its tool sources on the Agent when the daemon adopts its
workspace: kernel tools and aliases, custom tools, Runner candidates and the
Runner tool allowlist. At acceptance, Nexus assembles the selected Runner's
current announced model tools through those sources. Each turn freezes that
assembled declaration and its concrete routes.

The shared guidance lives in the Agent's `system_prompt` document,
inside the assembled request's stable prefix. A turn's developer-role lead
carries the current runner environment, tool guidance and model adaptation
hints; caller-supplied instructions are appended to that lead.

## Agent Presets and instructions

**Settings › Agent Presets** owns reusable prompts, models, ordered fallback
lists and tool selections. The Main Agent and each Bot select a Preset by UUID.
Changing a Preset does not change their identity, conversations or memory owner.
The default Preset for new Bots is independent of the Main Agent's selection.

The authored system prompt preserves whitespace and newlines and is composed
with rho's shared runtime guidance. The combined text must fit within 64 KiB of
UTF-8. Human persona and Workspace character retain their own prompt slots.
Standalone raw runs use the selected Main Preset; an explicit per-run
`instructions` value retains its replacement behavior.

rho resolves a Preset for each accepted input and sends the compiled declaration
to Nexus. Later edits affect future inputs, including inputs in an existing
Conversation. Queued and running inputs, their retries and regeneration retain
the captured declaration. Nexus validates policy grammar and prompt macros at
its execution boundary. A publication refusal is reported and the saved Preset
can be corrected; it is not silently replaced with another configuration.

## Personal persona

`rho persona show` reads the persona of the Human signed in through `rho connect`.
Use `rho persona set persona.md` to replace it from a UTF-8 file, or pipe text to
`rho persona set -`; `rho persona reset` removes it. Add `--json` for a document
including its version and content. Documents are bounded to 64 KiB and use the
existing prompt macros such as `{{user}}` and `{{agent}}`.

The document lives in Nexus under that Human, so a daemon restart or rho upgrade
preserves it. The command works through the daemon's Human Platform proxy when
running, or through the saved Human login when stopped. It never borrows the
Agent credential or replaces rho's `system_prompt` guideline. Future assembled
personal turns read the persona live; already accepted requests keep their
captured prompt. Shared/group profiles that omit personal slots keep doing so.

## Remembering and recalling

The default assistant prompt asks rho to retain useful preferences, confirmed
facts, decisions and corrections during ordinary work through Nexus memory
tools. It reads existing notes before changing them, merges related facts and
removes duplicates, and uses focused listing, search and reads when an answer
depends on earlier context. Routine chatter and requests with no useful memory
need no extra calls. A statement that something was saved or forgotten requires
a successful tool result.

Notes stay in Nexus database documents. `conversation/` holds task notes;
`speaker/` holds the answering Bot's notes about the current person; `agent/`
holds the Bot's own experience; `workspace/` or `group/` holds shared knowledge.
Private and external Bots resolve Speaker memory for the person attached to
each input. External Bots have no `agent/` or `user/` root and read-only `workspace/`. The current bindings
and their read-only rules still govern every call. Inspect and edit the same
documents with `rho memory CONVERSATION_ID ls|read|write|edit|grep|delete`.
Add `--speaker SPEAKER_UUID` to any action to select an unbound `speaker/` root.
Without it, a conversation answered by the Main Agent uses the owner's Speaker;
other conversations require an explicit selector for unbound Speaker notes.

Foreground memory policy runs within the current model turn. It does not promise
that every model selects or recalls facts correctly. Injected notes are budgeted
and text search is bounded. Named Agents keep their own prompt; the
Telegram answering profile explicitly includes this policy.

Optional background review keeps small stable notes and a dated past-work index
in one selected memory document:

```sh
rho memory-review CONVERSATION_ID enable --path speaker/review.md --model provider/model
rho memory-review CONVERSATION_ID status --json
rho memory CONVERSATION_ID read speaker/review.md
rho memory-review CONVERSATION_ID disable
```

Choose a writable root already bound to the conversation. An External requests
Bot can use `conversation/review.md`; its `workspace/` root is read-only.
Review never adds a private root or changes a binding. Other conversations with
access to the same document can retrieve it through ordinary memory tools.
Enabling adopts or creates the selected document
and starts after the existing conversation history. It does not extract old
sources. Omit `--model` to use each completed reply's model. The review model
must accept `max_output_tokens: 2048`; an incompatible model leaves an inspectable
review error and does not change memory.

The `rho.memory_review` plugin's configuration carries a default for
conversations that never chose: with **Review every conversation**
(`auto_enable`) on, such a conversation joins at its first completed reply —
that reply included — with the configured document (`path`, `speaker/review.md`
by default) and optional `model`. A conversation that cannot join (a side, or
no writable root for the selected document) is recorded as off once rather than asked at every reply,
and a conversation explicitly switched off stays off. The WebUI offers the
same switch per conversation in its title menu and the default on the
plugin's page.

Each new completed visible reply may open a dedicated side conversation. The
fork inherits the source conversation's access rules; its raw model request,
Run, tasks and output stay behind those rules. It uses the existing shared
history boundary without copying the source transcript. The raw request selects
no tools and receives only at most 16 KiB of the source prompt and answer plus
the selected document. Its output limit is 2,048 tokens, and the ordinary Nexus
model deadline and cancellation apply. Review asks for concise content below
4 KiB to leave room for its summary and JSON; the resulting document is capped
at 6 KiB. An existing larger document is left unchanged and its review skipped.
Truncated or invalid output also leaves the document unchanged. A work entry
keeps its date and conversation, turn and Run identifiers so source detail can
be retrieved on demand. These are historical references; use live execution
state for current work and fresh evidence for changing observations. No vector
database, skill synthesis or executable automation is involved.

A completed formal result in Nexus triggers review independently of terminal
rendering or Telegram notification retries. Review failure leaves that result
complete. The review side stays separate from the person's interactive Side and sends
no reply to the parent. Inspect its conversation and final Run identifiers with
`status --json`. Notes and the index share one conditional write: a newer
correction or request to forget makes the entire stale review skip. It does not
reread the new version and merge the old source again. A consumed source position
is never automatically reconsidered. Deleting or recreating the selected
document stops automatic writes until an explicit `enable` adopts a document
again; deleting memory does not delete the original conversation.

The source conversation's scoped store preserves the exact unfinished fork and
input submission across restart. Its normal follower handles completion and
recovery. Replay or a later completed reply resumes the same submission with its
saved idempotency keys. `rho memory-review CONVERSATION_ID resume` performs that
recovery explicitly; it never reruns an already finished review. A model failure
held for attention is canceled through the same follower, preserving the previous memory.
Only one review is pending per source conversation: replies completed while it
is busy are skipped, not queued for later extraction. On recovery, an unfinished
snapshot older than 23 hours is discarded and any known side execution is canceled, so unknown
acceptance cannot become duplicate work after the kernel's 24-hour key window.
Disabling review stops new selection, removes its queued input and cancels its
known side. No local file owns this business state.

## Scheduled jobs

Use a scheduled job for delayed or recurring work that should report back to
this conversation. Nexus stores the schedule and starts each occurrence in a
fresh child conversation with its own ordinary input and turn. The child's
result returns to the original conversation. A job outlives the turn that
created it; no local daemon timer or sleeping tool call keeps it alive.

```sh
rho jobs CONVERSATION_ID list
rho jobs CONVERSATION_ID create once in 30m Check the build and report here
rho jobs CONVERSATION_ID create once at 2030-01-02T09:00:00+08:00 Prepare the morning report
rho jobs CONVERSATION_ID create every 2h Review incoming changes
rho jobs CONVERSATION_ID create daily 09:00 Asia/Shanghai Summarize progress
rho jobs CONVERSATION_ID show JOB_ID
rho jobs CONVERSATION_ID edit JOB_ID prompt Summarize progress and blockers
rho jobs CONVERSATION_ID edit JOB_ID daily 10:00 Asia/Shanghai
rho jobs CONVERSATION_ID pause JOB_ID
rho jobs CONVERSATION_ID resume JOB_ID
rho jobs CONVERSATION_ID history JOB_ID
rho jobs CONVERSATION_ID run JOB_ID
rho jobs CONVERSATION_ID cancel JOB_ID
```

`run JOB_ID` starts one execution now without moving the job's clock: a
recurring job still runs at its next occurrence and a paused job stays paused.
While the previous execution is still queued or working the request is refused
as `execution_in_progress`. The daemon's `GET /workspaces/schedules` lists the
jobs of every readable conversation in a workspace; the WebUI's **Scheduled
jobs** page reads it.

`--workspace ID` keeps the operation in the conversation's original workspace;
`--model PROVIDER/MODEL` selects the model for creation, and `--json` prints the
resource document. The shared chat and CLI grammar resolves relative times
once before creating the job. Daily rules retain the named IANA time zone.
`list AFTER` and `history JOB_ID AFTER` follow the opaque cursor printed by a
page with more results. Editing reads the current version and submits that
version once; a concurrent edit is reported as a conflict.

Creation applies the conversation's effective code mode to the job's tool
selection, including explicit `tool_names`. Updating `tool_names` applies that
same policy; edits that omit it retain the job's existing selection. Changing
rho's global or conversation choice does not rewrite accepted jobs.

Pause and cancel stop future occurrences. They do not claim to stop a child
that is already working. Open its conversation and use the ordinary Stop
control when needed. A one-time job can be `completed` while its latest
execution remains `pending` or `running`; execution history reports the
child's own status. The model tools `read_schedules` and
`manage_schedule` use this same durable resource.

The Core methods are `schedules`, `schedule`,
`schedule_executions`, `create_schedule`, `update_schedule`,
`pause_schedule`, `resume_schedule` and `cancel_schedule`.
Create requires a caller-owned `idempotency_key`; update requires
`expected_lock_version`. The daemon serves reads under
`/conversations/schedules` (`/detail` and `/executions`) and commands
under `/create`, `/update`, `/pause`, `/resume` and `/cancel`. Every request
names the owning conversation in `public_id`, optionally its
`workspace_public_id`, and a job-specific request names `job_public_id`.

Core creation and update, and the corresponding control routes, accept
independent `reasoning_enabled` and `reasoning_effort` fields. A control-only
update can pass `reasoning_enabled: false` without a new model reference.
The model tool preserves both controls from its declaring model round when
it creates a job. The InferenceRequest control route and failed-task retry route also
forward these fields independently; Nexus resolves their effective values.

## Browser interface

The separate `rho-webui` gem supplies the browser page. The host installer, Docker image
and checkout bundle include it. Use the repository's installation guide for the
supported installation path. Full and agent modes load `rho/webui` by default. The daemon
continues to own the control API, authentication and static-file serving.

Run `rho console --open` after starting `rho server`. `RHO_API_ONLY=1` disables the page;
runner mode is always headless. `webui_root` in settings or `RHO_WEBUI_ROOT` overrides the
plugin's static directory. If the plugin is absent or its bundle is incomplete, the daemon
continues with its control API; extension load failures appear in `rho runner`.

The shipped page uses browser ES modules without a build step. Serving it requires Ruby
only, with no Node.js or Deno process. Linux and macOS deployments use the same assets;
see [deployment](../../../docs/rho-deploy.md) for portable installation and containers.

## Extensions

rho ships a described default set. Each built-in, installed gem, selected local
file and managed package has a static descriptor with its id, display name, human-readable description,
configuration schema/version, defaults, supported modes and dependencies.
Disabled plugins stay visible and configurable without loading their Ruby code,
starting children or connecting to a service. Enablement is separate from
configuration completeness: an enabled plugin can be active but not ready.
Web tools are enabled by default in full and runner modes; explicit disabled
settings remain disabled. Browser, MCP, ACP client, Telegram and T3 require
explicit enablement. Their descriptions and schemas remain visible in the core manager.
Environment-dependent plugins check prerequisites before becoming active. Browser
checks that its configured Playwright driver can launch Chromium, then closes that
temporary browser. A failed check leaves the plugin inactive and returns repair
guidance while core settings remain available. Saved and active state stay separate:
repair the installation or configuration and enable the plugin again to retry.

Save only overrides under `plugins`; installed gem and built-in sources are
discovered from their metadata. A local file needs an explicit source and a
sibling JSON descriptor, such as `/opt/team/rho-ops.json` for the file below:

```json
{
  "settings_version": 1,
  "plugins": {
    "rho.web_tools": { "enabled": true, "configuration_version": 1, "configuration": {} },
    "team.ops": {
      "enabled": true,
      "source": { "kind": "path", "path": "/opt/team/rho-ops.rb" },
      "configuration_version": 1,
      "configuration": {}
    }
  }
}
```

The descriptor's `id` must match the saved key and the registered owner. A gem
declares its JSON descriptor through `rho_extension_manifest` metadata and its
require feature through `rho_extensions`. Factories read the current effective
value through `api.configuration`; `api.describe_status` may report local readiness
without probing providers or making model calls.

The core manager is available even with no optional registrations:

```sh
rho extensions list
rho extensions configure rho.coding '[{"op":"set","path":["bash_timeout_seconds"],"value":90}]'
rho extensions configure rho.coding '[{"op":"unset","path":["bash_timeout_seconds"]}]'
rho extensions disable rho.webui
rho extensions enable rho.webui
```

`GET /extensions` exposes descriptors, redacted overrides, effective values,
diagnostics, active capabilities and readiness. `PATCH /extensions/ID/configuration`
accepts an `operations` array of explicit `set`/`unset` field paths; arrays are
replaced as a field, not merged by position. `POST /extensions/ID/enable` and
`POST /extensions/ID/disable` change enablement. Required plugins are not silently
disabled: name dependent ids explicitly with `--dependents` when disabling their
dependency. CLI settings and plugin commands also work without a daemon, under
the home's existing writer lock, so `rho extensions enable rho.webui` can recover
a headless installation (`rho.webui` requires `rho.ops`, so that comes first when
it is off as well).

A page extension calls `api.register_webui(root: "/path/to/static/files")`. Only successful
extension registrations are mounted. A second page registered by the same extension is a
registration error; two committed extensions claiming the page refuse startup and name both
owners. `webui_root` is the operator's explicit directory override. A standalone runner
logs page registration as unavailable, as it does other daemon-only capabilities.

Any extension may also add browser code to that page with
`api.register_webui_module(root: "/path/to/webui")`: one directory per extension, entered
at its `index.js`. Only while the extension runs and the page is served, the daemon serves
that directory at `/modules/<id>/<key>/` with `Cache-Control: no-cache`; the key follows the
installed directory, so activating another version gives the page a new URL. `GET /extensions`
names the entry as the plugin row's `capabilities.webui`, or `null` without a running module,
and marks the one running owner of the page itself with `capabilities.page: true`; the page
reads that to keep its own switch, and the switches of what that owner requires, locked —
`rho extensions disable rho.webui` in the terminal remains the way to turn the page off.
The `modules/` prefix is reserved in every page root. Module files are public like the page's
own scripts and run with the page's authority: they are trusted installed code, with no sandbox.
A second module, an empty root or a directory without `index.js` is a registration error; a
standalone runner logs the call as unavailable.

An extension may register a `Rho::Agents::Definition` with
`api.register_agent(definition)`. Its profile is declared alongside Bot profiles,
including when no environment root is set. Only successful registrations
contribute definitions; duplicate profile names from extensions refuse loading.
Importing a local file creates a Preset and does not replace an extension-owned
profile.

Ruby extensions use `api.on` (`tool_call` before a handler, `tool_result` after it).
External lifecycle tool hooks are configured separately by `rho.lifecycle_hooks`.

Each registration owns its shutdown callbacks and background tasks. Startup hooks
run before initial credential adoption can announce tools; an owner that fails
startup is cleaned up and omitted. Background tasks start after adoption and must
also handle a disconnected daemon. Reload prepares and starts a candidate before
publishing it, so registration or startup failure preserves the previous owner.
Removing an owner stops new calls, then waits for its already-running tool,
document, daemon callback and route handlers before cleanup. Cleanup failures are reported; queued retirement
is distinct from completed cleanup. An extension holding exclusive process-wide
state calls `api.restart_only`; replacement or removal is saved as pending restart
while the current instance keeps running.

Local publication precedes remote announcements. An announcement failure reports
the error while keeping the ready local implementation; an explicit refresh
retries publication to Nexus. This is not a distributed transaction. Calls frozen
against a removed served tool name fail normally rather than executing another
implementation. A streaming route owns any resource lifetime beyond returning
its response; the route-handler lease ends when that handler returns.

`api.on(:configuration_change) { |config| ... }` observes settings after local
publication. Its failures are logged and do not block other callbacks or undo
publication. Validation that must reject a candidate belongs in registration or
`:startup`.

### Managed personal packages

Develop a personal extension in a writable work directory, with an `extension.rb`
that defines one module responding to `register(api)`, and a `rho-extension.json`:

```json
{
  "name": "personal-notes",
  "id": "personal-notes",
  "display_name": "Personal notes",
  "description": "Personal note tools",
  "configuration_version": 1,
  "configuration_schema": { "type": "object", "properties": {}, "additionalProperties": false },
  "category": "tools",
  "default_enabled": false,
  "modes": ["full", "agent"],
  "requires": [],
  "restart_only": false,
  "state_schema": "notes-v1",
  "dependencies": { "json": ">= 2" }
}
```

The manifest name is a local package identifier; `id` is the plugin's stable
configuration and registration identity. `category` places the plugin on the
Plugins page — one of `interface`, `channels`, `agents`, `tools`,
`conversation`, `system`; a manifest that names none is listed under `other`,
and any other word refuses the description. `configuration_schema` describes its
settings, while `state_schema` describes the business-state format the code can
read; omit it only for stateless packages
(the default is `none`). The schema is JSON Schema 2020-12 with one editor
annotation: a string field may carry `"x-rho-choices": {"source": "models",
"workload": "<workload>"}` so that a settings editor offers the account's usable
models for that workload (`GET /models?workload=`) instead of a text box. The
value stays a plain string — a typed or saved reference the listing no longer has
remains valid — and a misspelled annotation refuses the schema at load. The core
compaction and image models declare it. Dependencies are RubyGem requirements in rho's existing
Ruby environment. Install dependencies there explicitly; the manager does not
fetch gems or isolate different gem versions in one process. A requirement that
conflicts with an already loaded gem requires a compatible installation and
restart.

With the daemon running:

```sh
rho extensions install /absolute/work/personal-notes
rho extensions packages
rho extensions check personal-notes FULL_VERSION_DIGEST
rho extensions activate personal-notes FULL_VERSION_DIGEST --configuration ./notes.json
rho extensions disable personal-notes
rho extensions rollback personal-notes
```

Install copies the source and tests into `<RHO_HOME>/extensions/managed/` without
executing Ruby. Its SHA-256 version identifies those copied bytes; it is not a
publisher identity or trust proof. Tests are conventional `test/**/*_test.rb`
files. Explicit `check` runs them with this Ruby runtime, `lib` and `test` on the
load path, a 60-second limit, and the last 64 KiB of output. No test files means
only structure and dependency checks passed. Activation does not run tests.
Packages are trusted installed code, and checks can perform the same effects as
that code. Symlinks are refused so each installed version contains its own files.

The optional configuration file supplies schema-validated overrides exposed as
the effective `api.configuration`. An omitted configuration retains the plugin's
saved overrides. Successful activation saves the selected source, code version
and configuration in `settings.json` and keeps the previous selection for rollback.
Selecting the identical pair preserves that previous pair. Candidate registration
or startup failure leaves the old selection active.
Restart loads the saved selection. Tool names include the selected code version;
accepted calls to a removed name fail normally. Use `api.tool_name("my_tool")`
when a package needs to refer to its served name.

Disable retires the package's registrations and preserves its configuration and
selected source for re-enabling. Every replacement, including an explicitly named
older version, must match the retained `state_schema`. Code selection never migrates or restores
business state. An incompatible change requires the operator to recover that
state and its saved assembly configuration together. A package with process-wide
exclusive state must call `api.restart_only`; a replacement or disable remains
pending until restart. Configuration migration is independent of business-state
compatibility: a plugin can declare forward configuration migrations, and an
unsupported configuration version is reported rather than read as current data.

The model can use `list_extensions` and `manage_extension` through the same owner.
Management is an open, destructive write effect under the existing approval
policy; it is the supported route from a writable development area into the
protected installation. Local bearer authentication protects the equivalent
`GET` and `POST /extensions/packages` control routes. The operator owns backups
of package source, versions and assembly configuration; Nexus stores user
business data, not this local installation. A publication warning means the
local selection was applied and must not be retried as if it failed.

The [household coordination example](examples/household-ledger/README.md) supplies
a complete package with tests, local configuration, Nexus-backed business state,
reminder schedules and captured completion evidence. Its observations and
notification adapter are explicit fixtures; use it as a starting point for a
personal workflow, with real integrations verified separately.

The `rho.images` plugin selects the image model and enables the Nexus image
capability. Its model is captured as `image_model` in the agent configuration;
without a model or when the plugin is disabled, Rho does not declare the image
tool. `image_generate` (`imagegen` with the Codex tool style) runs in Nexus and
returns persistent upload resource links. Reference images must be existing Nexus
uploads; use Runner file transfer to upload local pictures or download generated
ones. The tool does not accept local paths or infer images from recent messages.
Nexus owns inference, cancellation and durable image results, without downloading
and re-uploading through Rho.

The `rho.schedules` plugin enables Nexus's `read_schedules` and `manage_schedule`
tools. The existing `rho jobs` commands and WebUI/Telegram schedule controls remain
application interfaces to the same Nexus resources. Nexus captures the execution
configuration and owns scheduled delivery and execution. The captured tools and
hooks determine whether that work needs the Rho process online.

Ordinary execution can continue after its submitting application goes offline if
its tools and hooks are all supplied by Nexus and independent execution services.
Rho Code Mode and `--until` remain application capabilities requiring their serving
Rho process: Code Mode retains a live JavaScript VM, and `--until` advances checks
and retries. Automatic memory review is also Rho-owned post-processing. Reconnecting
clients read existing execution state; disconnecting never revokes authority or
cancels accepted work.

`rho/mcp` is the MCP client, an extension gem beside `rho/browser`: it runs
the servers in `plugins["rho.mcp"].configuration.servers` — a stdio server as a child in its own
process group with a REPLACED, scrubbed environment (rho's credentials and
every `*_KEY`/`*_TOKEN`-shaped variable withheld; the row's `env` added), a
streamable-HTTP server over the official client's own HTTP stack — reads
each connection's initial tool list, and announces the ones you named under
`mcp__<server>__<tool>` with the server's own description and schema, byte
for byte, and the WORST-CASE effect profile (a write that may destroy and
reach outside this machine) — a server's `annotations` are its own testimony
and are never read; `effect_profiles` is where YOU say a tool is a read.
`tools` is required: name the tools, or `["*"]` to take every one; a server
with no list is listed down at boot and `rho mcp probe NAME` prints what it
would have declared and the bytes; every boot logs each server's declaration
bytes and warns past rho's own toolset's 4,971. A stdio server serves the
runner address, an http server the agent's (`serves` overrides; a mode that
serves neither lists that server down). Prompts and resources with a
description are announced as documents (`<server>-<name>`) and loaded
through the same `skill` tool a checkout's skills use. `rho mcp` prints every
server, its tools and their declaration bytes; `rho mcp probe NAME` connects
from the CLI and prints what a server would announce, non-printables
escaped, before you trust it. `${NAME}` in `env` and `headers` reads the
daemon's environment; values are never logged or printed, and every expanded
value is redacted from anything a model or a log reads. A streamable-HTTP
server that asks for OAuth is logged in to ONCE with `rho mcp login NAME`
(your browser, a loopback callback); the tokens live in
`RHO_HOME/mcp/credentials/NAME.json` and the daemon sends them as the
`Authorization` header, refreshing them itself; a row that needs a login is
listed down and its calls fail naming the verb. Successful login refreshes a
running daemon so a previously down server can connect and announce its tools;
unchanged connected servers keep their connections and tool lists, and disabled
servers stay disabled. Without a daemon, the next boot reads the credentials.
A failed daemon refresh is reported separately and leaves the saved login intact.
`rho mcp logout NAME` forgets the credentials. `rho
console --open` and `rho mcp login` open your browser through `$BROWSER`
when it is set. The OAuth path is driven through this binary by
`e2e/test/mcp_oauth_test.rb` on the mock (group 2 of the gate: the login with a stubbed `$BROWSER` and with `--no-browser` + the pasted redirect, the live announcement refresh, credential reuse after restart, silent renewal, a renewal failure, a refusal, re-login and step-up, `rho mcp` and `rho mcp probe` with no daemon, the config faults and an unreadable credential file) and the manual paid
`cd e2e && E2E_LIVE=1 E2E_MCP_OAUTH_URL=<url> rake live_mcp_oauth` (a real
public OAuth server, your own consent click). A stdio server runs
one call at a time; a call that times out stops that server (its process
group is killed) and the next call restarts it and says so; a server that
dies is restarted once at the next call and the call says so. These call retries
keep the published tool list. Settings changes reconnect changed server rows;
settings or login refresh retries down rows, reading a new list when they
connect. Restarting the daemon re-lists every enabled server.

```json
{
  "settings_version": 1,
  "plugins": {
    "rho.mcp": {
      "enabled": true,
      "configuration_version": 1,
      "configuration": {
        "servers": {
          "fx": {
            "transport": "stdio",
            "command": "ruby",
            "args": [
              "/opt/fx/server.rb"
            ],
            "cwd": "/opt/fx",
            "env": {
              "FX_TOKEN": "${FX_TOKEN}"
            },
            "tools": [
              "echo",
              "lookup"
            ],
            "timeout_ms": 60000,
            "effect_profiles": {
              "lookup": {
                "kind": "read_only",
                "destructive": false,
                "effect_scope": "open",
                "idempotency": "intrinsic",
                "reconciliation": "none"
              }
            }
          },
          "remote": {
            "transport": "http",
            "url": "https://mcp.example.com/mcp",
            "headers": {
              "Authorization": "Bearer ${REMOTE_TOKEN}"
            },
            "tools": [
              "*"
            ],
            "serves": "agent"
          }
        }
      }
    }
  }
}
```

`rho/web-tools` is a web reader, an extension gem beside `rho/browser` and `rho/mcp`: one tool, `web_fetch {url}`, that
GETs an http:// or https:// URL, converts HTML to markdown, returns other text as-is and saves an image or other
binary to a file the model can `read`. The result is bounded like every runner read — 2 000 lines or 50.0KB,
whichever first — and a page over the bound is saved whole to the runner's artifacts directory with bash's own
footer naming it, so the model pages the rest with `read`. It refuses a URL with credentials or a host not written
in lowercase ASCII (your approval rules match the URL exactly as the model wrote it, so only canonical spellings
run), reads at most 5.0MB, gives up after 30 s, follows up to three redirects on the same site and REPORTS a
redirect to another site (call again with the new URL). Hosts that resolve to a loopback, private or reserved
address are refused; `plugins["rho.web_tools"].configuration.allow_private_network: true`
lifts loopback and RFC 1918 only — unique-local,
link-local (the cloud metadata endpoints) and every other reserved range stay refused. It is a `read_only` tool on
the OPEN world: it runs under `bypass`, parks under `ask` and is refused under `rules` until a rule allows it; a
deny on `url` binds under every mode. The daemon's log names the host, never the URL. `rho web fetch URL` fetches
from the CLI and prints what the model would read, whole (`--raw` for the bytes as rendered).

```json
{
  "settings_version": 1,
  "plugins": {
    "rho.web_tools": {
      "enabled": true,
      "configuration_version": 1,
      "configuration": {
        "allow_private_network": false
      }
    }
  }
}
```

## The page

`rho console` prints the ordinary login URL; the page it opens is the same control
surface these verbs drive. The `rho-webui` plugin lists conversations, creates
them with an available model and runner, reads durable history, streams the
current answer and opens tool activity. Conversations can be renamed, archived
and restored. Questions, approvals and execution controls stay with the work.

Its composer sends input to the selected conversation through `/say`. Sending
while work is running queues the next input; an idle conversation starts its
next turn. Reopening a conversation reads Nexus's history. Closing the page
does not stop execution; the Stop action does. See the
[WebUI guide](../rho-webui/README.md) for the browser workflow and current scope.

The page is plain ES modules and plain CSS, vendored into the gem. There is no
build step, so a machine with no JavaScript toolchain and no network still
serves its own UI.

## Native coding delegation

The optional `rho.t3` plugin delegates coding work to an available native agent,
such as Codex or Claude Code. Its `server` configuration chooses `host` (an explicit
service URL) or `local` (one rho-owned T3 process on loopback, port 3773 by default).
The Docker image includes T3, Codex and Claude Code; it needs no T3 sidecar or
published T3 port. T3 can run without its UI. rho keeps the delegating Nexus task, questions, Stop and
returned artifacts; `delegate_coding` starts or continues work and `coding_work`
observes, steers or stops it. Ordinary background work keeps the main conversation
available while the native assignment runs.

Use `coding_work {action: "agents"}` to discover the available coding agents and
their supported models. An explicit `agent` and `model` on `delegate_coding` apply
to that new work. Unavailable or unsupported selections are reported instead of
being replaced. Without an explicit choice, rho can work directly or choose a
suitable coding agent. The optional `plugins["rho.t3"].configuration.default_agent` setting is a
preference after rho chooses to delegate; it does not force all coding work onto
one agent. Use `rho extensions configure rho.t3` with explicit field operations
to change its configuration. Host-mode changes apply to future work immediately;
local process replacement or removal waits for restart. Each new assignment resolves its selection against
that agent's current directory.

Enable the extension and configure its service, project and optional preference
through the [T3 package guide](../rho-t3/README.md). The client uses rho's Ruby
runtime; rho itself still boots without a running host T3 service. A local T3 can
start before its project or bearer is configured, but coding tools appear only
when configuration is complete. Local server, Codex and Claude state are kept in
`<RHO_HOME>/plugins/rho.t3/`; `rho t3 login codex|claude` uses those same native
directories and uid. The T3 bearer is separate from native provider login. Use
`rho t3 projects` and `rho t3 project ID`, or explicitly create a project with
`rho t3 create /absolute/path`. `rho t3 check` checks the service protocol, selected
project and agent directory without running a model. Host mode owns no native
process or credentials. Stopping one coding assignment does not kill the shared
T3 service. The native workspace
is independent of the conversation's Runner; continuing a work ID retains its original agent,
model and workspace. A new stage using a different model starts new work with
the previous stage's actual result, source or diff and checks supplied in its brief.
The native harness owns its internal action policy. Identified approval callbacks
pass through rho's Guard and one-shot Human decisions, while native actions without
callbacks remain under the harness's policy. This integration does not promise
complete translation of Nexus per-action approval rules.

## Editors and ACP

An editor that speaks the Agent Client Protocol spawns `rho-acp`, the exe of
the `rho-acp` gem (`agents/rho/rho-acp`), and talks JSON-RPC over its stdin and
stdout; every ACP session is a conversation in the connected workspace, said,
followed and relayed through the same `Rho::Core` primitives the CLI and the
page use, so the daemon owns the conversation and the editor only speaks for
it. The home must be connected first — `rho-acp connect` (the ceremony on
plain stdio; exit 0 at once when the daemon already reports the home
connected) or `rho connect` — else `session/new` answers -32000 naming the
auth methods.

```
rho-acp [--mode bypass|ask|rules] [--model MODEL] [--runner EXECUTOR_ID]
rho-acp connect
```

The flags are the defaults for new sessions: the mode (`bypass`, rho's own
posture; an editor that wants prompts passes `--mode ask`), the model (else the
home's `default_model`), the runner-kind executor an agent-mode rho names for
the session's tools. Zed's `agent_servers`:

```json
{ "agent_servers": { "rho": { "command": "rho-acp", "args": ["--mode", "ask"], "env": {} } } }
```

JetBrains' ACP agent settings take the same three fields; `acpx --agent
'rho-acp --mode ask' --format json "…"` drives it from a terminal. From a
checkout the exe runs under its own bundle (`cd agents/rho/rho-acp && bundle
exec rho-acp …`, so `command` is a wrapper naming the three Bundler variables —
the e2e lane's shape); under the installer's prefix it is
`$RHO_PREFIX/current/agents/rho/rho-acp/exe/rho-acp`, run the way `bin/rho`
runs the CLI — the prefix's Ruby with `-rbundler/setup` under the app's
Gemfile (the evals image's `rho-acp-launch` spells that line; the installer
writes no `rho-acp` wrapper). What the editor gets: `session/new {cwd,
additionalDirectories, mcpServers}` opens a conversation whose root set is the
editor's, its `mcpServers` bound as the conversation's tool sources; the
editor's own buffers served to the daemon through the `fs/*` port when the
editor advertised it; the three modes and a model picker as config options;
`/retry`, `/abandon`, `/compact` and the checkout's skills as slash commands;
`session/load` replaying the conversation one exchange per turn; a park as
`session/request_permission` with allow / always / reject; the model's ask as
an elicitation form (or a held question); `session/cancel` stopping the turn.
`agents/rho/rho-acp/README.md` has the document and the codes.

rho is NOT in the ACP registry: a
submission's `agent.json` names a public distribution — an `npx`/`uvx`
package or per-platform archives under `distribution` — which the
build-from-checkout install does not provide. The benchmark door uses an
INLINE entry instead: `harbor run -a acp:rho` over a `local` distribution
whose `cmd` is the evals image's `/opt/rho/libexec/rho-acp-launch`
(`e2e/evals/docker/rho-acp-launch`; `cd e2e && rake "evals_harbor_acp[dry]"`
prints the entry, the command and the pairing sidecar's plan).

The other direction is the optional `rho.acp-client` plugin: another ACP agent in
`plugins["rho.acp-client"].configuration.agents` is delegated to by the model through one runner tool, `delegate_agent
{agent, prompt, session?, workdir?}`, its permission requests answered by
rho's own floor (the nine refused command shapes and the protected roots) and
then the row's policy — never parked, no proxy approval; `allow_always` is
never answered, because a standing grant is your `rho rules`. The first row is
Codex under the ChatGPT login, the second `opencode
acp` on OpenRouter, the model-neutral one:

```json
{
  "settings_version": 1,
  "plugins": {
    "rho.acp-client": {
      "enabled": true,
      "configuration_version": 1,
      "configuration": {
        "agents": {
          "codex": {
            "command": "npx",
            "args": [
              "-y",
              "@agentclientprotocol/codex-acp@1.12.0"
            ],
            "env": {
              "CODEX_HOME": "/home/me/.codex",
              "NO_BROWSER": "1",
              "INITIAL_AGENT_MODE": "read-only"
            },
            "description": "Codex under the ChatGPT login",
            "model": "gpt-6-astra"
          },
          "opencode": {
            "command": "opencode",
            "args": [
              "acp"
            ],
            "env": {
              "OPENROUTER_API_KEY": "${OPENROUTER_API_KEY}"
            },
            "description": "OpenCode, a coding agent on OpenRouter"
          }
        }
      }
    }
  }
}
```

The other registry lines: `npx -y @google/gemini-cli@0.59.0 --acp` and `npx
-y @agentclientprotocol/claude-agent-acp@0.78.0`. A row's keys are `command
args env description permissions timeout_ms auth_method model enabled`; a key
is lowercase letters, digits and single hyphens, at most 32 characters.
`command` and `description` are required — the description is your words in
the roster AND the model's text, the tool invents no sentence in the agent's
mouth. `${NAME}` in `env` expands once from the daemon's environment and is a
secret (an unset name is that row's fault, named by the key); a literal under a
credential-shaped key is a secret too; every secret is erased from the result,
the progress lines, the capture and the log. `permissions` is `allow` (the
default) or `reject`; `timeout_ms` the one clock (default 600000, at most the
runner's park ceiling); `auth_method` an agent-type method id of the child;
`model` a value set through `set_config_option` when the child lists a
`category: "model"` option; `enabled` the switch (absent is on). The core manager
reports schema diagnostics and preserves valid sibling fields. A row with an
unusable command or configuration is listed `down: config:` without stopping
other rows; no enabled usable row, no tool. `rho
acp-agents` prints the rows (the launch line redacted, the env names masked)
and the daemon's live children; `rho acp-agents probe NAME` spawns one from
here and prints what it declares; `enable|disable NAME` save the row's switch
through the shared plugin owner; `sessions`, `kill SESSION`, `logs SESSION` read and end the
daemon's children; `GET /acp` answers `{agents, sessions}`.
`agents/rho/rho-acp-client/README.md` has the tool's shape and the child's
lifecycle.

## Where the tools work

```json
{ "tools_root": "~/src" }
```

Before a run's first write-kind call the runner captures the root — the
whole tree, `.gitignore` honoured — into its SQLite store under the work
root (`<RHO_WORK_DIR>/checkpoints/<digest>/checkpoints.sqlite3`), so
rho-dev's `rewind` can put the files back to where a turn found them. For
this daemon's runner, rewind and regenerate refuse before forking or restoring
if a process this daemon started is live in the conversation's current root.
An actual restore also checks the checkpoint's original root; `--keep-checkpoints` skips
that extra check. Remote runners do not consult this daemon's process table.
If the historical-root check refuses a rewind, the child already exists and
is returned with a `failed/process_live` result for that Runner in `restoration.runners`.
`plugins["rho.checkpoints"]` owns enablement and the capture policy, with these defaults:

```json
{
  "settings_version": 1,
  "plugins": {
    "rho.checkpoints": {
      "enabled": true,
      "configuration_version": 1,
      "configuration": {
        "retention_days": 7,
        "max_file_bytes": 2097152,
        "max_tree_bytes": 268435456,
        "capture_timeout_seconds": 30
      }
    }
  }
}
```

An untracked file over `max_file_bytes` is left out and named. The
`max_tree_bytes` budget counts candidate bytes in this scan, including files whose
stat or mode changed; unchanged tracked files do not spend it again. A capture
over that budget or its deadline is skipped and reports the reason. `rho doctor`
prints the stores' size and record count; the plugin entry's `enabled: false` opens no store and announces nothing.

Captures keep complete manifests and deduplicated file bytes. The first capture
for a run is create-only; every restore commits a fresh undo before changing
files. Cancellation can leave a partial restore, with that undo still available.
Startup and checkpoint configuration changes apply retention and reclaim
unreferenced content through the store's existing maintenance path. There is no
watcher or background service. Git is used only for ignore rules and source
checkout metadata; no checkpoint Git objects, refs or index are written. Restore
preserves captured file bytes without running repository attributes or filters.
Old Git checkpoint stores are not imported or read; their hashes are unavailable
for restoration. Ordinary conversations and stored execution results are unchanged.

```sh
rho console                # print this daemon's Nexus login page
rho console --open         # …and launch a browser at it

rho env                    # where are the tools pointed?
rho env ~/src/billing      # point them there
rho env --clear            # back to settings.json

rho processes              # the dev servers and watchers runs started (alias: procs)
rho logs p3 --tail 50      # a process's latest output, and where its log is (the exit too, once it is gone)
rho kill p3                # end one: TERM, then KILL — the run is told on its next result
rho runner                 # what can this machine do, and what failed to load
```

The verbs that operate a conversation from a terminal — `do`, `say`, `stop`,
`watch`, `follow`, `result`, `transcript`, `retry`, `approve`, `rewind`, … —
are `rho-dev`'s, a development gem the distribution never carries
(`agents/rho/rho-dev/README.md` lists them, and how a home names it). A
product install has `rho run`, which follows its own turn to the end.

The daemon also checks durable events through REST, so a missed final socket
notification cannot leave a followed run waiting indefinitely. Active turns
are checked about once per second; a conversation retained after its turn
settles is checked once per minute. Socket delivery continues throughout
those waits. An outstanding idle wait is not interrupted, so REST recovery
can take up to the minute interval, plus network latency or rate-limit backoff.

Conversation model and extension policy are stored in Nexus. The
local `tmp/hosts/<Agent UUID>.json` file is only a bounded follower cache;
deleting it loses automatic following until a conversation is attached again,
but does not remove its policy. Attach restores the policy, default Runner and answerer
before following or accepting another input. If Nexus policy cannot be read,
rho refuses that operation. Active followers recover an evicted cache row when
they next need its policy. Side reuse and idle cleanup discover their records
from Nexus even when their follower rows are gone.

At attach, restart or later reconnect, an expired event prefix is recovered
from the existing Turn and Run reads. A known Turn uses its direct read;
its running candidate is distinct from the still-selected answer during
regeneration. The events watermark survives
expiry, so the follower can detect missed progress even when no events remain.
The first empty replay also reads state once: a fork can already have a copied
answer before its own stream has any events. Recovery uses the same event
consumer and restores execution state, tasks and the visible settled answer
before live following resumes. Repeated empty reads
at the same watermark do not repeat those state reads or completion callbacks.

Pending input receipts use the SDK's materialization tracker. The receipt
names the exact Turn, variant and optional Run produced by that input;
messages and direct inference can materialize without a Run. If events have
expired, the original execution is recovered through Nexus's retained input
materialization read. The CLI shares that read through
`Core#input_materialization` (`GET /conversations/input_materialization`),
and follows the original execution even if the same Turn has since regenerated.
A kernel-created fallback continues that execution through its recorded origin;
a manual regeneration and its fallback never replace the original answer.
An absent or concealed original is never replaced with an unrelated candidate.

Recovery explicitly includes hidden turns in its management read. A hidden held
turn remains discoverable after its active pointer clears, with its controls
available and its body hidden. If no readable execution remains, the follower
clears its previous execution and text. Historical event notifications still
have Nexus's 30-day retention window. The timeline and retained conversation
text remain readable; task outputs are available only until execution details
are cleaned up under the account's retention policy (90 days by default).

Changing a host's subscription switches its actual events stream between
full and lifecycle-only delivery while preserving the replay cursor. Narrowing
also closes transcript and progress streams, including subscriptions whose
confirmation arrives after the change. Local stop does not wait for the
network's best-effort unsubscribe notification.

Hiding or concealing the current turn clears its text and progress from the
follower's snapshot while keeping a live run available for cancellation and
adjudication. Restoring its view recovers the settled answer; exclusion from
model context alone does not hide it. Undo clears the deleted turn and run
from the remembered host, without ending the conversation's follower.

Followed hosts and running task clients read the current access token from
their original OAuth owner on every REST request. Normal renewal therefore
keeps existing followers and runners working after the previous token expires;
reconnecting as another identity does not lend its credential to old work.

The executor inbox listener retries transient connection failures every five
seconds while its original client still belongs to the active lineage. The
existing Runner and HTTP polling continue across that reconnect.

**A process follows its conversation.** A `start_process` entry is owned by
the CONVERSATION of the run that started it (`rho processes` shows the run
beside it): every later turn of that conversation may read and stop it, another
conversation's run is refused by name, the person never is. Whose it is comes
from the inbox row the kernel wrote (`conversation_public_id`, null for a
standalone run), never from a lookup of the daemon's own. When the
conversation is deleted (the kernel narrates
`conversation_ended` with reason `tombstoned`; its next poll reads 404),
or a standalone run becomes terminal — the daemon
kills the group (TERM, a grace, KILL) and removes the entry. Changing the default Runner
does not stop existing processes. Their progress retains the source Task’s claim proof. A group that died leaves the
table the moment its pipe closes; a `read_process`/`stop_process` against its
id answers the exit and "the entry is gone — start_process again gives a new
id", `rho logs` still answers the remembered exit, and the log file's last line
keeps it. A periodic validity sweep on the daemon is the fallback for a group
that died unnoticed. A restart resurrects nothing: the state file names only
live groups, and the next boot reaps them. A runner-mode rho owns an entry by
the same row's conversation but follows no conversation's feed, so there an
entry ends only by the sweep, a kill, or the daemon's shutdown.

Archive keeps local following, processes and result delivery for accepted work.
The archived Conversation remains readable, and its historical archive event
does not end a new follower either. Ending local following does not issue Nexus
Stop or establish that kernel work has finished. A refused read ends following;
a refused write alone does not.

**Watching a reply arrive.** `rho run` prints the model's words in their own
block behind a `│` gutter, each delta as it lands and flushed per delta, so a
long answer scrolls; every structured line (`run:`, `status:`, `  check
1/3:`) still starts where it always did — a status line breaks the block
first. The gutter is what keeps the two apart: rho's task table is indented
too, and a reply containing a line that begins like a table row would
otherwise be unreadable to a person and to a script. A retry prints one
`(restarted — the text above was discarded)` line and starts over, and when
the turn settles only the part that was not already shown is printed. The
reasoning channel, the poll-shaped follower, a follower with no delta
(`--no-stream`, a daemon following without a socket) and reading a settled
turn back are rho-dev's `watch`, `follow`, `result` and `transcript`, and
the page's — `agents/rho/rho-dev/README.md`, "Watching a reply arrive".

`rho status` lists the calls held for you under `approvals:` and names the
one shipped surface that decides them (`console:   answer and decide them on
the console: rho console`); `rho run` prints `ASKING approval_required — key`
once and DENIES the call (above). Approving a held call, denying it
with a reason the model reads, and a grant for the rest of the daemon's
life (`--always`, `--match PREFIX`) are the page's and rho-dev's `approve`,
`deny` and `rules`; rho-dev's README carries the grant's exact rules. A grant
is gone when the daemon is stopped and started again. Nothing is written to
`settings.json`.

For `web_fetch`, `--always` grants paths beneath the held URL's literal
`scheme://host[:port]/` prefix. `--match SITE` accepts that same site with
an optional trailing slash. Another host, subdomain, scheme, port or raw
spelling needs approval again, as does a bare site URL without `/` (including
a bare query). The held call itself is approved once even in that form.
The page offers **Allow this site until restart**; the grant and the tool's
existing redirect behavior are described in
[rho-web-tools' approval rules](../rho-web-tools/README.md#approval).

rho's own
turns run under `bypass` — its guard list rides its profile as deny rules, so `rm -rf /`
and a force push are refused by the kernel before any runner sees them. So is
rho editing ITSELF: a `write` or `edit` under its own checkout (the directory
the running daemon loads from, and the runner gem's) or under `RHO_HOME`, and a
`bash`/`start_process` command that names either, are refused for its own model
under every approval mode. The refusal directs personal capability changes through
managed extensions and core changes through a separate rho successor. The rules anchor
on the RESOLVED root and read the call's raw text: a relative or symlinked
spelling, `~` or `$RHO_HOME` in a command escape them, and nothing tightens
that — a grant only ever widens, `--approval ask|rules` is a turn's mode and
not a rule list, and the profile's rules are declared whole at every boot,
so a rule written on the kernel's side is replaced by the next declaration;
the escapes are accepted, the container is the fence. A command that merely
names the checkout is refused too, coarse on purpose, while reading its own
source through `read`/`grep` is not touched.


Pointing the tools at a directory is what makes "you are working in X"
TRUE rather than a request the model has to remember — measured: told
where it was and asked to use absolute paths, a real model wrote a
relative one anyway. `{"root": null}` clears back to the settings file.
Refused while a tool call is running: moving the ground under one is the
one thing an explicit switch must not do.

`tools_root` supplies the default captured for future requests. Each accepted
request carries its concrete Executor context, including its working root. Unset, it is a scratch directory under `RHO_HOME`,
which is right for a daemon nobody gave a project to and wrong for every
daemon anybody did. Anything outside it is reached by absolute path; every
tool here accepts one, because there is deliberately no path confinement —
rho reads and writes your real files, and isolation is the runner role
plus containers, not a check inside this process.

`bash` takes `workdir` per call rather than needing `cd`.

Nothing is discovered and auto-loaded from an installed-gem sweep: these
tools run shell commands on this machine on behalf of a remote model, so a
gem arriving as somebody's transitive dependency must never become one.

An extension is a module answering `register(api)`:

```ruby
module MyExtension
  NAME = "rho.mine"

  class Ping
    NAME = "ping"                    # a wire name — no dots; providers refuse them
    DESCRIPTION = "Ping a host"
    SCHEMA = { "type" => "object", "properties" => {} }.freeze
    EFFECT_PROFILE = {
      "kind" => "read_only", "destructive" => false, "effect_scope" => "open",
      "idempotency" => "none", "reconciliation" => "none"
    }.freeze
    def initialize(env:) = @env = env
    def call(args) = Rho::Runner::Result.ok("pong")
  end

  def self.register(api)
    api.register_tool(Ping)
    api.on(:tool_call) { |name, args, tool| nil }  # veto or rewrite; fail-closed
    # An operator verb: `rho hello WHO --loud`, listed under "Extension rho.mine:"
    api.register_command("hello", usage: "hello WHO", description: "Say hi",
      options: { loud: { type: :boolean, default: false, desc: "Shout" } }) do |cli, (who), options|
      cli.out.puts "hi #{who}#{options[:loud] ? "!" : ""}"
    end
    # A flag on a core verb whose request is a JSON body — today `rho run`
    # (rho-dev's `do` declares the same flags itself and folds the same way).
    api.register_flags("run", region: { type: :string, desc: "Where" }) do |body, options|
      options[:region] ? body.merge("region" => options[:region]) : body
    end
  end
end
```

Two more verbs on the handle announce DOCUMENTS — the skill-shaped catalog
lines a turn's `skills` block carries — and answer their loads, each on an
address: `api.describe_documents(serves:) { |env| [{name, description}] }`
lists them, `api.load_document(serves:) { |name, env| body }` answers one
(a `Rho::Runner::Result`, or nil to let the next loader on that address
try). An extension that announces documents on an address must serve
`skill` there (Coding does on the runner's; rho/mcp does on the agent's):
each catalog entry names its source and callable. A Runner’s callable carries its
concrete target, so equal document names on different Runners remain distinct.
The address's `skill` walks only that address's loaders in registration order.

An ingress can register `api.on(:conversation_binding) { |public_id| ... }` on
rho's daemon handle. Return nil for an unbound conversation, or a string-keyed
Hash with `channel` and a user-readable `label`, plus channel details such as
`chat_id` and `topic_id`. Derive this from the ingress's existing route state.
Every conversation projection — the list's rows as well as the detail — exposes
these as `ingresses` (empty when none), adding each hook's registered
`extension` name; the hook is called once per projected row. WebUI marks a
bound row in its sidebar, shows the source and allows reading and Stop; its
writes carry `X-Rho-Viewing-Conversation` and are refused with
`409 ingress_bound` while bound (attach and Stop remain available). This
coordinates rho surfaces without changing Nexus permissions or CLI authority.

Background extensions can register `api.on(:member_connection) { |connection| ... }`.
The daemon supplies a `MemberConnection` with `user_public_id` and a member API
`client` bound to the adopted credential lineage, or nil on disconnect, Agent
authority loss, or before replacing that lineage. Credential rotation keeps that
lineage; reconnecting supplies a
fresh handle, including when the Agent is unchanged. Callbacks run
serially on the daemon reactor, and connection operations wait for them. Retire
the previous worker before returning from the nil callback; replacement
credentials become visible only after it finishes. Load the new Agent's state
through the next supplied client. A boot-time adoption arrives after startup hooks
and before background tasks; retain the handle until the background task starts. Independent Runner changes do not emit
this event. A callback failure is logged without preventing other callbacks or
undoing a published package selection. The ordinary `:shutdown` hook still owns daemon shutdown.

`api.on(:turn_settled) { |settlement, context| ... }` observes a published
direct-reply Turn outcome. Its `Rho::TurnSettlement` carries the workspace,
conversation, Turn and optional Run identifiers, Turn `status`, model and memory
context. Status is `completed`, `failed` or `canceled`; a failed Turn can still
have a Run held for attention. Inherited turns are excluded. Replay can deliver
the same outcome again, so durable writes must account for the supplied identifiers.
The daemon schedules these observers independently of terminal or IM delivery and
retains their extension owner until they return. An observer failure is logged
without revoking the published result or stopping other observers.

A command's handler is handed the terminal (`Rho::Cli::Terminal`): `core`
— the `Rho::Core` primitives, one capability over one route each
(`open_conversation`, `say`, `stop`, `follower_row`, `follower_events`, `result`,
`approve`, `deny`, …, plus `running_daemon`, `require_daemon`, `parse` and
`get`/`post`/`put` for the extension's OWN routes); `out` — the stream
printer; `home`; and the renderers of `Rho::Cli::Reporting` (`report_turn`,
`report_tasks`, `print_task`, …) mixed in — with the words after the verb
and the parsed options. It prints through `cli.out`, reaches the daemon
through `cli.core` and never through a raw HTTP call
(`test/code_style/core_surface_test.rb`), and raises `Rho::Error` for a
refusal (one sentence, exit 1). Every verb above the "Where the tools work"
line that is not one of the management verbs — `version`, `doctor`,
`update`, `uninstall`, `connect`, `disconnect`, `status`, `server` — or
`run` is registered this way by one of rho's own extensions — `rho help`
lists them under their owner; rho-dev's are registered the same way and
listed under `Extension rho.dev:` on a home that names it.

`core.runs(status:, attention:)` reads retained Nexus executions through `GET /runs`.
`core.followers(side:)` reads this daemon's local host followers through `GET /followers`;
`core.follower_row(id)` resolves a host or one of its observed Run IDs. A follower
snapshot names its current execution as `run_public_id`, its observed executions
as `run_public_ids`, and the execution status as `run_status`.

`core.open_conversation(..., idempotency_key: key)` and
`core.say(id, text, idempotency_key: key)` let a surface retry a lost response
with the same key and request. An open uses that key for both the conversation
and its first input, in separate Nexus receipt scopes; a promptless open only
creates the conversation. Omitting the key keeps independent random keys.
Nexus rejects changed request semantics under an existing key; rho does not
replace the key to retry a conflict. Receipts expire after 24 hours, so this
does not replace a channel's durable delivery progress.

`core.inputs`, `core.update_input` and `core.delete_input` accept
`host_type: "conversation"` with `workspace_public_id:` for a known conversation,
including one no longer present in the daemon's followed set. Without the host
type, they retain the ordinary followed-host or run lookup. Queue writes name
the input's public ID; its displayed queue position is not a stable identity.
Editing or deleting an input has no idempotency receipt, so a channel must not
automatically repeat a write after an ambiguous response.

For files already uploaded through rho's member SDK, pass
`upload_public_ids: [id, ...]` to `core.open_conversation` or `core.say`.
Keep those IDs with the same input key when retrying; this route does not
upload them again. The kernel validates and binds them through its ordinary
attachment contract. This option cannot be combined with local `attachments:`
paths, and attachments require queue delivery. A file without a caption is
valid (`text: ""`, or no open prompt); an open with neither text nor files
still creates only the empty conversation. Only locally staged files add
staging descriptors to the daemon's response; prepared IDs remain in the
durable turn's attachment projection.

Images and PDFs retain native placement when the selected model supports them.
Other files, including PDFs for models without native PDF input, appear with
their filename, type, size and `nexus://uploads/...` reference.
The model calls `file_import` to obtain a working path on the assigned runner,
then uses `read` for text or native image/PDF input, or the installed workspace
tools for document parsing when native input is unavailable.
`file_publish` selects a local result for the ordinary upload capture path and
returns a durable resource link; mentioning a path in prose does not publish it.
Reply surfaces also collect publications from the exact worker results accepted
by that reply's callbacks. Later worker edits and regeneration do not replace
those files. The parent does not need to publish a worker's file again.

`GET /conversations/artifacts?public_id=CONVERSATION&turn=TURN&variant=VARIANT`
returns `published_artifacts`, with each upload's `public_id`, `filename`,
`content_type` and `byte_size`; `workspace_public_id` selects another workspace.
The required variant must still be the displayed answer, otherwise the route
returns `409 stale_variant`. Only completed, retained execution details contribute
files. The route follows accepted callback results, including nested results,
and omits unreadable or pruned sources. It collects successful `file_publish`
captures and image-generation captures, deduplicated by upload ID. Ordinary
history reads do not scan tool results. Bytes use `GET /uploads/bytes` with the
returned upload ID and the existing member read authority.

`core.say(id, text, mode: "queue", wait: false)` returns the accepted input
without waiting for a turn to materialize. A channel can pass a registered
`speaker_public_id` for attribution. `kind: "message"` records a visible
user message as context without requesting a model reply; it requires queue
delivery and rejects model, tool, approval, addressing and scheduling overrides.

`core.say(..., tool_names: ["read"], approval_mode: "rules")` sends an explicit
tool subset and approval tightening for the addressed profile, including a
group profile. Use its declared callable names, including any collision-qualified names returned by the tool assembly projection. `tool_names: []` means no tools. The kernel validates both
fields against that profile. For rho's own turns, `code_mode: false`
removes `code` and `subagent: false` removes kernel delegation from an explicit list; other explicit names retain the kernel's
ordinary validation. Omission keeps the existing defaults: rho's selected tools for its own
turns, the addressed profile's declaration for another answerer. Side
conversations allow an explicit subset to narrow their posture's tools further,
including `[]`, and accept ordinary per-turn approval tightening while rejecting
tool expansion. Side supports `read` and `write` (the default).
Standalone run messages cannot change the running turn's tools or approval.

`core.inputs` preserves a queued worker callback's `callback_result` reference.
`core.turns` preserves each turn's recorded `input_public_id` and its
`callback_sources`, including every consumed worker result in a parent summary.
Each result names an exact conversation, input, turn and variant. Use
`core.variants(conversation_id, turn_id, workspace_public_id:)` to read that
variant's content and producing run; a later active variant is a separate sample.

`core.activate_variant(conversation_id, turn_id, variant_id)` selects a settled
candidate through `POST /conversations/activate` (body: `public_id`, `turn`,
`variant`; response: `variant`). The kernel owns cancellation of the replaced
candidate's unfinished work. `core.variant(..., concealed:)` remains the separate
visibility operation.

`core.stop(id, task_key = nil, force: true, host_type: "conversation")` addresses
a conversation by default. Use `host_type: "run"` for an exact run or its
task, including one from a previous turn or candidate. `POST /stop` accepts the
same fields; explicit types bypass local host inference. An untyped raw request
can address only an already-followed host and returns `host_not_followed` for an
unknown ID, rather than guessing that it is a conversation. Conversation stopping
delegates all unfinished-work cancellation to Nexus; rho does not scan background
tasks. Force/graceful applies only to run stopping.

RETURN vs RAISE is the axis to get right: returning `Result.error` means
the tool RAN and the model reads why and self-corrects; raising means it
could not run at all and the task takes its own failure policy. One
instance per tool is shared by every worker thread, so keep no mutable
instance state.

A `tool_call` / `tool_result` handler takes `(tool_name, arguments | result,
tool)` — the third the `Toolset::Tool` being run, whose `effect_profile` is
the profile the tool announced; a block may ignore what it does not name
(`|name, args|` keeps working). The chain runs on the worker, inside the
call's own park: a hook may block (the checkpoint capture does) and never
stalls the daemon's reactor.

`GET /runner` reports what loaded and what failed to.

### Bots and reusable Presets

A Bot is a persistent Agent identity with its own display name, description,
audience, welcome message, Home Workspace, Subagent setting and selected Preset UUID. Its Nexus
User owns identity and memory; the Preset owns reusable behavior. Two Bots may
use the same Preset while keeping separate histories and memories. Editing a
Bot's Preset selection keeps its UUID. Duplicating a Bot creates a fresh identity
that shares the selected Preset and copies the Subagent setting, without copying memory, conversations or channel
connections. An external Bot cannot become private under the same identity;
duplicate it to create a private Bot. Removed names remain reserved.

The Bots page edits these identity fields through `PUT /agents` and
`PUT /agents/settings`. The **Edit Preset** action opens the shared configuration
in Settings. A Bot's standing Nexus configuration is a projection refreshed from
that Preset; it is not an independent configuration editor. Persistent Bots are
not included in the Subagent role catalog.

Bot **Subagent** defaults to on and is saved with the Bot's other settings in
`rho.bots`. Both `PUT /agents` and `PUT /agents/settings` accept the boolean
`subagent`; omission preserves an existing value, and null is invalid. The Bot
listing and detail expose `subagent`. Changing it applies to future inputs in the
current conversation as well as new, resumed and forked Bot conversations.
It does not inherit Main's global or per-conversation modes. Bot main conversations
always use Code Mode off as rho product policy. With Subagent off they complete
work directly and wait for the result; already accepted work and child declarations
keep their captured policy. Published workers retain their own Code Mode tools.
`GET /conversations/modes` reports the Bot's effective values; PATCH and input-level
mode overrides return `bot_modes_managed`, directing clients to the Bot settings.

Presets live in the declaring profile's Nexus Store. A fresh catalog seeds
Probius, Adjutant, worker, planner, explorer and reviewer once. The first two are
initial Main Agent and new-Bot defaults; names may be edited and are not kernel
roles. Role publication adds a selection name and description to the same Preset.
It does not create another configuration object or a User.

Settings exposes these publications under **Subagent roles**, with a link to
edit the selected Preset. Each accepted parent captures the published directory;
editing or withdrawing a role changes future accepted parents. A role chooses
its own initial model or follows the calling task's current actual model, while
an explicit model for one delegation takes precedence without changing the
Preset. Each role retains its own ordered fallback list.

The child stores its declaration, model intent and fallback defaults on its
Conversation. Later unqualified inputs, prompt previews and forks use those
defaults even after the parent Run or first input has been reclaimed. rho's
model-facing spawn alias requires an exact role and omits the kernel's identity
selector; Main Agent and Bots cannot be spawned by UUID or handle. Child memory
is limited to its own Conversation, with subtree conversation reach and no
automatic owner persona, Speaker notes or parent transcript. The task brief
supplies the context and evidence needed for the assigned work.

Portable Presets use Markdown frontmatter plus a prompt body, or JSON with
`name`, `description` and `configuration`. They contain no identity, audience,
connection credentials or endpoints, conversation or memory fields. MCP tool
selections retain references to existing Nexus connections. Import creates a new Preset UUID;
export and duplication do not copy role publication. Directory imports scan
`.agents/agents/`, then `.claude/agents/`, at one level under rho's environment
root. Unsupported fields are reported; unknown models are retained for later
availability checks, without substituting a global default.

```markdown
---
name: reviewer
description: Review a supplied change for concrete defects.
model: provider/model
runner_tool_names: [read, grep, find, bash]
---
Read the supplied diff and its surrounding code. Report actionable findings with evidence.
```

`tools` selects kernel canonical names, declared aliases and application
callables. `runner_tool_names` independently narrows the installation's Runner
allowlist. `null` inherits each list and `[]` permits none. The selected Runner's
current announcements determine the concrete imported tools when work is
accepted. The declaring application serves a Bot's selected application tools
through its existing executor address. The Bot remains the execution principal,
with its own identity and memory. Installation deny rules remain the floor, and
external Bots retain their restricted audience policy even when they select a
broad Preset.

`mcp` controls Nexus-managed and rho-hosted MCP connections together. Main Agent
and Bots, including external Bots, default to all currently available MCP tools.
Presets save only exclusions:

```json
{
  "mcp": {
    "disabled_connections": [
      { "source": "nexus", "connection_public_id": "019b1000-0000-7000-8000-000000000001" }
    ],
    "disabled_tools": [
      { "source": "executor", "executor_public_id": "019b1000-0000-7000-8000-000000000002",
        "server_key": "notes", "tool_name": "write" }
    ]
  }
}
```

Both arrays default to empty. New connections and catalog tools are enabled for
future work unless their connection is disabled. The ordinary `tools` and
`runner_tool_names` selectors do not also govern MCP. Nexus connections are
available through the answering Agent's current Human steward, without separate
grants. rho-hosted connections retain executor eligibility and any conversation
scope imposed by their editor integration.

A Subagent inherits its direct parent's captured MCP tools and applies its role
Preset's exclusions. The generic delegation `inherited_tool_names` mechanism
copies only tools present in that parent, so nested children cannot re-enable
disabled tools. Non-MCP role tools remain independent. External Bots use the same
MCP selection while retaining their `rules` approval stage and matching deny/ask
rules. A selected `ask` mode asks for every MCP call; `rules` narrows authored allows
to selected MCP callables; `bypass` allows those callables unless a deny or ask matches.
Private `rho approve --always` session grants do not pass to external Bots or their Subagents.
Their memory and ordinary Local-environment restrictions remain in force.

Use the Preset's **MCP connections and tools** switches for individual tools or
whole connections. The Nexus management link opens connection credentials and
catalog discovery. rho-mcp keeps its local stdio, HTTP/OAuth and ACP transports
and credentials. Executor announcements identify MCP sources with
`mcp: {server_key, tool_name}`; automatic default-Runner imports exclude these
tools, and rho compiles explicit routes instead. Stable callable names distinguish
same-name tools on different connections. Already accepted work retains its exact
connection, schema and tool selection.

```sh
rho presets                          # UUID, name, defaults and role publication
rho presets import                   # import project files as fresh Presets
rho presets import reviewer          # select a file by its authored name
rho presets import-file helper.json
rho presets export PRESET_UUID md
rho presets duplicate PRESET_UUID reviewer-copy
rho presets rm PRESET_UUID            # refuses a selected or Bot-referenced Preset
rho agents                           # persistent Bot identities and their Presets
rho agents duplicate helper helper-copy owner
rho agents rm helper
rho bots current helper               # ensure and select the current conversation
rho bots new helper                   # create and select a conversation in Home
rho bots history helper               # includes each conversation's recorded Workspace
rho bots history helper --after CURSOR --limit 20
rho bots resume helper CONVERSATION_ID --workspace WORKSPACE_ID
```

`bots` accepts a Bot name, `@handle` or public UUID from this rho instance.
Set the Bot's Home Workspace in its settings before its first conversation.
New conversations use Home; Resume uses the history row's recorded Workspace,
including after Home changes. New and Resume do not stop work already accepted
in the previous conversation. History never opens or selects a conversation.
See [Bot conversations](../../../guides/use/conversations.md#bot-conversations)
for the archive behavior of New and Resume.

Generic rewind and Side refuse Bot conversations. Use the Bot's Fork operation
to branch its history and select that branch through the same current-conversation switch.

Current, New and Resume print their operation ID before requesting the switch.
Retry an interrupted command with the same arguments and `--operation-id ID`.
A replay reports its original selected conversation and, if another command has
since changed it, the current conversation. An ID cannot be reused with different
arguments or another switching verb.

The installation's existing Guard still applies to every Runner task. A Preset
cannot expand the installation's available tools, Runner candidates or protected
path policy. A project selected only through `rho run --dir` is not the import
root; `rho env DIR` selects the daemon's environment root.

## Remote access

Loopback is the default. A wider bind requires one explicit transport assertion
per boot: `--expect-external-encryption` when a TLS reverse proxy or VPN fronts
the socket, or `--unsafe-plaintext` to acknowledge bare plaintext. Neither is
remembered between boots; rho does not terminate TLS itself.

Configure the browser-reachable rho origin and Nexus URL separately from the
machine connection URL:

```json
{
  "bind": "0.0.0.0",
  "public_url": "https://rho.example",
  "nexus_public_url": "https://nexus.example"
}
```

`RHO_PUBLIC_URL` and `RHO_NEXUS_PUBLIC_URL` provide deployment defaults. Register
exactly `https://rho.example/auth/callback` in Nexus's application OAuth redirect
configuration for this DNS-based deployment. Without an explicit callback list,
Nexus accepts HTTP or HTTPS `/auth/callback` on any valid port at loopback,
`localhost`, literal RFC 1918 IPv4 and IPv6 unique-local addresses. An explicit
list replaces those defaults. With a loopback bind, an omitted public URL uses the local endpoint;
wider binds require the browser URL before code login. Device login needs no
callback. See [application login](../../../guides/reference/oauth/application-login.md).

The public page contains no bearer. Successful Nexus login issues a separate
browser session; the private local announcement remains the CLI's authority.
`{"api_only": true}` omits the page while retaining authenticated control APIs.

### System upgrade

**Settings → System upgrade** has separate rho and Nexus cards. The rho card
uses the enclosing installation's updater when `RHO_DEPLOYMENT_SOCKET` is set.
It checks and upgrades only rho, without a Nexus restart, database backup or
migration. The distributed image packages the updater's request helper; only
the installation manager holds Docker authority. Source checkouts, unmanaged
containers and native installs show their existing update procedure instead.

The Nexus card uses the signed-in Human's Platform API through `/nexus/request`.
A current Nexus owner or administrator can check and upgrade Nexus and its
workers. The database-backup checkbox starts enabled; changing it requires a
new check. rho remains running during a Nexus upgrade. Nexus owns authorization
and exposes only its own installation receipts and logs.

Both cards require an explicit check and confirmation, retain the exact pending
request across a page reload, and reconnect to the updater's saved receipt after
a restart. A lost response never automatically submits another upgrade. Recovery
remains an explicit operation on the deployment host; see the
[upgrade guide](../../../guides/operate/status-logs-upgrades.md).

The rho-only authenticated local routes are `GET /deployment`,
`POST /deployment/check` (`tag`, default `latest`), `POST /deployment/upgrade`
(`candidate` and UUIDv7 `idempotency_key`), `GET /deployment/receipt?operation_id=…`
and `GET /deployment/log?operation_id=…&cursor=…`. Status/check return the
installation projection; check also returns a fresh key for the selected
request. Upgrade returns the accepted receipt with status 202. Reads preserve
the updater's bounded opaque-cursor log windows and refusal codes. There is no
scope, Docker-command, repository, path or recovery selector on this surface.

## Installing

```
bash install/install.sh
```

One readable file that runs from the checkout it sits in, no sudo: Homebrew's portable Ruby 4.0.9
(sha256-pinned) and the rho gems into a prefix you own (`~/.local/share/rho`), rg and fd beside them (jq
and uv in the default `full` profile; Node, playwright-core and the Chromium shell in `dev`), a launcher
at `~/.local/bin/rho`. `--profile dev` for browsing. Then `rho doctor`; `rho update` = `git pull
--ff-only` in that checkout + the pulled `install.sh` re-run (`--dry-run` shows the commits it would pull
and the script it would run; `--rollback` keeps the previous (ruby, gems) pair); `rho uninstall`. The
checkout is the host installer's source; `rho update` follows that checkout's
configured upstream without switching branches. Container releases have their own image tags.
See the [installation guide](../../../install/README.md) for layout, profiles and verification.

For the joint Docker stack, use the [public installer](../../../install/stack/README.md#install);
no source checkout is needed.
It uses `docker.io/jasl123/cybros-rho` and `docker.io/jasl123/cybros-nexus`, with
persistent bind mounts under the installation's `data/` directory. The guided
setup runs inside the rho container, so the host needs no Ruby. Later use
`./cybros setup` from that installation directory. See the
[stack guide](../../../install/stack/README.md) and
[deployment guide](../../../docs/rho-deploy.md) for ports, paths and standalone
container configuration.

## Development

```sh
bin/setup
bundle exec rake   # full tests + rubocop + RBS validation/conformance + installer rendering check
bundle exec rake smoke rubocop rbs:validate install:check  # short CI gate
RUBYLIB=$PWD/../rho-dev/lib bundle exec exe/rho do "…" --model dev/mock-text
                   # enable the described rho.dev plugin in this home and put rho-dev's lib
                   # on the load path (never in this gem's bundle); see ../rho-dev/README.md
```

The smoke task reuses the existing control/authentication, credential ownership,
connection lifecycle, turn admission, tool declaration and result-handling tests.
The full default task also covers all CLI, extension, recovery and concurrency
scenarios and repeats the complete suite under runtime RBS checks. Run it locally
for complete package verification; `rake rbs:conformance` runs that instrumented
suite separately. Cross-project journeys and installation acceptance remain in
the [E2E suite](../../../e2e/README.md).

### Captured directories and Until recovery

rho captures selected directories before submitting work. Runner tasks carry
`executor_context["rho.environment"]` with `root`, `directories` and optional
`anchor`; the Runner applies this before hooks and handlers. A missing or unusable
captured directory fails explicitly. Changing defaults or restarting a Runner does
not redirect accepted tasks. No environment-binding tool or replay message is needed.

Until recovery scans the member API's bounded Run candidates independently of the
follower cache. It verifies the original Run and saved policy, including an input
accepted before rho recorded its Run identifier, then uses the ordinary Gate to
advance. Completed checks are consumed once. Paused, stopped and expired work retain
their existing state; lost in-memory tool runtimes are not recreated.
