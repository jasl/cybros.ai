# Rho

Rho is an agent application for Nexus with browser, Telegram and editor entry
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
conversation, say, stop, a loop's row and its event stream, its result,
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
a second turn, a loop watched, repaired or decided — is `rho-dev`'s, a
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
human-readable display name preserves the Agent Profile:

```sh
rho server --display-name "rho on workstation"
rho connect
```

## Settings and terminal setup

The combined Docker installer starts with a private rho console link, valid for
one use within 90 seconds. Choose your rho access password, then open Nexus
account creation from rho in a new tab. The setup secret is filled automatically.
Return to rho while the bundled Agent and private Runner connect; rho then opens
Settings. Later visits use the ordinary rho URL and your chosen password.
`./cybros instructions` generates a fresh console link using the deployment's
saved public rho URL.

Open **Settings** in the existing conversation page to connect Nexus, configure
and pair Telegram, then follow the model setup TODO to Nexus administration.
The stack connects its Agent and private Runner automatically after the first
account is created. Its runner executes inside the rho container and announces
the default tools without a separate selection step.

Returning from Nexus refreshes model availability. An existing valid default
stays selected; a sole usable text model with tools becomes the default; multiple
models require a choice. These checks make no inference request. Advanced agent,
tool, runner, working-directory, MCP and external-agent settings are on the same
page. Provider credentials and the administrator session stay in Nexus.

Saved application settings apply immediately through the daemon's shared
settings owner. Existing Nexus loops retain their captured definitions; a tool
removed meanwhile follows the normal failed-tool result path. Unchanged MCP and
external-agent connections, conversations and running processes are retained.
Environment variables seed settings; saved fields override those seeds, and
explicit launch flags take precedence on startup. Process role and listener
options are shown as deployment information, not editable application fields.

For joint deployments, `installation_file` in settings or `RHO_INSTALLATION_FILE`
names the helper's private installation-status JSON file. Independent installations
leave it unset. Authenticated `GET /installation` returns `enabled`,
`password_required`, `nexus_ready`, `setup_url` and `error`. The setup URL is
available only after a rho password is saved and before the Nexus account exists.
`nexus_ready` is `null` while the helper has not published its first status;
connection readiness comes from the ordinary `/status` credential planes. This
read-only projection grants no Nexus member or Platform authority and carries no
pairing credentials. The deployment helper uses rho's private local announcement
authority and the existing device-authorization flow for initial pairing.

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
The optional administrator step uses cmctl's setup flow and revokes its temporary
Human session on exit; the daemon only receives its own device connection.
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

`rho setup telegram` configures the optional Telegram channel. It validates the
bot token with `getMe`, saves it in the private `<RHO_HOME>/telegram/token.json`,
and asks for an explicit numeric owner ID. A saved token takes precedence over
the environment seed. When your ID is unknown, save the token, send `/start` to
the running bot, then enter the returned ID in Settings or run
`rho setup telegram --finish`. No agent messages are accepted until the owner is
configured, and setup never starts another update poller.
See the [Telegram guide](../rho-ingress-telegram/README.md).

## Identity and credentials

A connected Rho identity has two credential planes:

- a member credential for the Agent Profile and `/profile`;
- an executor transport credential for the Agent application's delivery
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
SAME home presents the same identifier, and Nexus re-pairs the existing Profile
and fences the previous device; a soft-removed Profile is restored.
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
full). Full pairs ONE grant that registers both addresses: the agent's
(announcing `summarize_history`) and a private runner (announcing Coding's,
Processes' and the browser's tools with the environment document); its runner
follows the executor inbox on the runner credential, and the member bearer
never reaches a claim. Agent names a runner (`rho run … --runner`, the `runner`
setting). Runner serves tools alone — the container runs
`RHO_MODE=runner rho server` with `RHO_HOME` on a volume and an optional
`RHO_DISPLAY_NAME`; `rho connect` prints the pairing code and URL.
It constructs no member plane (no
`run`; the Ops routes are not in the runner set, and rho-dev is never
named on a runner home). `rho disconnect [--runner]` revokes and
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

Switching runner is an explicit handoff: `rho runners` lists the
runners this profile may address (discovery, with the kernel's presence word
for display — online, offline with last seen, not yet seen — never a reason
to choose), `rho runners use ID|--none` selects the one new conversations
start on (written to `settings.json` by the CLI, read fresh by the daemon), and
`rho handoff HOST_ID EXECUTOR_ID` moves a followed host: Nexus records it,
re-addresses the calls nobody has claimed and never retargets started work; a
running call settles where it started, the next turn opens with the new
runner's announced environment and its tool names. It is a RECOVERY verb, for
a runner that died or was replaced — a conversation ordinarily keeps the
runner it was created with (`rho run … --runner` names it; the kernel infers none). A
handoff replays nothing and syncs no tree: the transcript is in Nexus and the
code moves by git, so rho compares the old and new runners' announced root,
branch and worktree and prints one `warning:` line when they differ — never a
refusal. The profile's declaration
is the UNION over every runner bound to a followed host or selected, narrowed
per turn to the host's runner; a target announcing a name in different bytes
is refused (`declaration_conflict`), and a handoff a person made through the
SDK to such a runner is reported (`rho runners` says `conflict:`), never
refused. `rho run` (and rho-dev's `do`/`say`) prints a `runner:` line when none
is bound or the bound one is not online; `rho ps` names the hosts whose processes live on
another runner.

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
                           # turn; exit 0 completes the loop, anything else hands the model the
                           # output and another attempt; --timeout stops the loop after 1800 s
rho run "what is this?" --attach diagram.png   # files beside the words (repeatable)
                           # the daemon stages the bytes on its member plane as rho's own user and
                           # prints `attached: diagram.png (image/png, 184 KiB)`
rho run "…" --dir ~/src/billing --runner <id> --agent @lark --instructions "…"
                           # a directory described to the model, the runner whose tools serve the
                           # conversation, who answers (a member agent of the workspace), the lead
```

`rho run` opens a CONVERSATION in the connected workspace, says the prompt
on it, follows the turn the kernel materializes — an agent loop backed by
the tools THIS machine declared — to its end, and prints the answer. In
`text` mode it prints the three ids first (`conversation:`, `turn:`,
`loop:` — `pending:` until the kernel has materialized the turn, the loop
id on the first frame that carries it), `compose:` (the tier the
conversation runs in and its source), `until:` when a check was given, then
the tasks as they move, the checklist, `ASKING` lines, and the reply as it
streams behind a `│` gutter — every structured line (`loop:`, `status:`, a
task row) still starts where it always did, and a status line breaks the
block first; the gutter is what keeps a reply containing a line that begins
like a table row readable to a person and to a script — then `status:` and
the answer whole (`(none — this loop resolved no deliverable)` when the
loop resolved none). `-p` prints the answer alone. `--output-format json`
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
 "conversation_id":"…","turn_id":"…","loop_id":"…","result":"…the answer…"}
```

`subtype` is `success | failed | canceled | needs_person | timeout`;
`status` the turn's terminal word (or the status at the moment the run
stopped the loop); `reason` the failure reason, the attention reason or
`timeout`; `result` the deliverable's output, null when the loop resolved
none; `denied_calls` how many parked calls this run refused. A consumer
ignores unknown fields; a field is never removed within the shape. The exit
code is the outcome:

| exit | when | the loop it opened |
| --- | --- | --- |
| 0 | the turn completed | settled |
| 1 | the turn failed on a terminal loop; someone else canceled it; the daemon refused (`rho run: <sentence>` on stderr); a usage error | as the kernel left it |
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
is rho-dev's: `--approval ask|rules`, `--no-stream`, `--compose`,
`--restricted`, and every second word on a conversation.

`--model` is optional when `settings.json` names a `default_model` (or
`RHO_DEFAULT_MODEL`); the daemon refuses when neither does. `default_model`
is also rho's OWN model as the kernel knows it: the daemon declares it on
its profile (the `default_model` fact), so a turn another agent
addresses to rho — a `spawn` or `send` naming `@rho` — runs on it, and on
the initiator's model only when it is unset; a later turn on a conversation
this daemon only attached rides it too, else the addressed turn's model off
the loop projection, and is refused only when neither states one. A turn
the kernel has not materialized within the daemon's 30 s bound prints
`pending` and the run keeps following it; an input the kernel BLOCKS at
materialization — an unknown model, a refused selection — is a refusal in
one line, `rho run: the kernel blocked the input (unknown_model) …`, exit 1,
read off the feed the moment the block lands. Input receipts retain the input
ID and the durable feed position from before submission. Both the initial
wait and a pending continuation match that input's materialization to its
Turn and backing loop; another sender's reply or a compaction summary cannot
supply those IDs. The `run` field is an asynchronous follower snapshot and
can lag the receipt. A reader joining after the next turn starts recovers
its own status and sealed answer without rendering or approving another turn
or candidate's loop.

`fallback_model` in `settings.json` (or `RHO_FALLBACK_MODEL`; a catalog ref)
is the model a step rho answers is re-run on ONCE when a provider's
classifier DECLINED it (`finish_quality: refused`) or the provider was
OVERLOADED on every attempt of its budget (`provider_overloaded`): the daemon declares it
on its profile beside `default_model`, and the kernel moves the declined
step there, so the answer comes from the fallback rather than never; a
one-shot rho creates (the delegate summarizer's) runs once more on it the
same way. It is
never used for an unavailable model, a rate limit or an error, and never
for a content block (`finish_quality: blocked`), which is re-sent to no
model. Unset, a declined step FAILS `model_refused` (an overloaded one
`provider_overloaded`) and the model reading its result is told who
declined it and that nothing re-ran it. It may equal
`default_model` (a turn on `--model X` then falls back home). For a Claude
refusal the vendor's own recommendation is another Claude model — its
classifiers are calibrated per model; a model of another vendor is this
setting's choice, and it carries the declined step's whole context, tool
results included, to that vendor. A switched main line stays switched for
the rest of the turn, and rho remembers the model the turn ENDED on for the
conversation's next `say` (a compose member's switch moves only that
member). `rho status` prints `model:` and `fallback:` as the kernel holds
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
prints `sent` with `from:` under a peer's row. A loop has one answerer.

THE SECOND WORD on a conversation — the PERSON's `send` (a steer at the
running turn's next model boundary, or a queued turn), `--to` naming who
answers one turn (group chat), a word scheduled for a time, a picture on a
later turn — and the END of a turn before its time are the page's,
ACP's, an IM integration's, or rho-dev's `say` and `stop`; `rho run` stops
what it opened only when it cannot finish. The side conversations (a
question beside the work, answered from its context; a read-only side to
keep talking in), the input queue (what is queued or parked on a
conversation, and the unblock path) and the loop verbs (watch, follow,
result, transcript, retry, approve, …) are described with their verbs in
`agents/rho/rho-dev/README.md`, with the two mock lanes that drive the
whole spawn surface and the group chat through them
(`e2e/test/rho_spawn_test.rb`, `e2e/test/group_chat_test.rb`) and the paid
`cd e2e && E2E_LIVE=1 rake live_spawn`.

`compose` — the kernel tool that lets a model author a round as a graph —
has a switch of its own, because a weak model may not drive it.
`settings.json` decides: `"compose": "on" | "off" | "auto"` (or
`RHO_COMPOSE`; `auto`, the default) and, under `auto`, the model's
adaptation row's `compose` word (the SDK pack's row, or a local one under
`adaptations/` — see below; `compose: on (row glm-5.3)` on `rho run`), a
model whose row says nothing being on; rho-dev's `do --compose` grants it
to one conversation and `--no-compose` withholds it (`rho run` carries no
flag). The profile's declaration stays whole; a turn whose tier is off
names every tool but `compose` and its aliases on its input, matching their
canonical `nexus.graph.compose` identity, and a conversation keeps its
tier for its whole life (every later turn inherits it), so its cached
prefix never moves. The flat `ask` and `task` verbs stay either way: a
model without compose can still put a question to you and still start a
branch. Tool exposure is rho's policy: use the switch or a model's adaptation
row when its workflow authoring is unreliable. Nexus provides the same graph
mechanisms regardless of model family. A program can execute correctly while
using unnecessary sequential steps; basic executability and scheduling quality
are separate considerations when deciding whether to expose compose.

The kernel's texts tell the model which of the three to use: plain calls
in one message for a few reads, greps or commands; `task` when it will read
the answers itself; `compose` when the answers must go on to further steps
without passing through it.

A conversation-lifetime result not explicitly consumed comes back as kernel mail
after the original reply, even if it finishes early. The next turn reads the
receipt first; rho-dev's `watch` prints `background:` while the work runs,
and every follower `mailed` when it lands. `task` and `compose` run in the background by
default — the call answers at once with the started key(s); a call with
`wait: true` holds the turn until the result is in. The kernel's four
conversation verbs are declared beside them by default (`kernel_tools`):
`spawn` opens a conversation with another agent — a fresh copy of rho (a
subagent) or, with `agent`, a peer member of the workspace — whose reply
comes back as mail `origin: child`; `send`, `status` and `cancel` keep
talking to it, read it, and stop it. The kernel cancels derived work by its
originating request; independent later requests in a reused child conversation
survive. `session_search` and `session_read` are also declared by default:
they search readable Chinese/English conversation history in the current
workspace and read a bounded text window, including retained history whose
execution details have been collected. Both are allowed as read operations in
rho's approval rules. Nexus owns the index and authorization; rho keeps no local
history index. Account administrators configure execution-detail retention in
Nexus or with `cmctl account retention [DAYS|off]` (90 days by default). Conversation
text stays readable; old details and regeneration report `execution_details_pruned`
when collected.

For a person's request needing sustained implementation, research, or artifact
production, rho's default guidance prefers one persistent child conversation with
conversation lifetime and no launch-time wait. After a successful launch, the
main conversation acknowledges the work and stays available for questions; later
changes go to the same child, and its returned result is checked and reported in
the main conversation. Quick questions and simple reads stay in the main
conversation, and an explicit preference for synchronous work takes precedence.
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
Named agent definitions supply their own system prompt and can state a different
delivery policy.

HOW A MODEL IS SPOKEN TO is the SDK's, not rho's: `cybros_agent` ships a MODEL-ADAPTATIONS
PACK — a documented YAML format under `lib/cybros_agent/model_adaptations/`
(`sdks/ruby/README.md`, "Model adaptations") — whose rows are matched by
model PATTERNS over the kernel's model reference (`z-ai/glm-5.3`,
`claude-*`; the lane segment dropped, the most specific entry answering)
and carry, each text measured before it lands and the floor never tuned for: the
spellings (`tool_style`: `nexus` the plain names; `claude` `Agent` (= `task`;
`run_in_background`, default true, `false` waits), `AskUserQuestion` (=
`ask`) and `Skill` (= `skill`); `codex` `spawn_agent` (= `spawn`, always in
the background) and `send_message` (= `send`; `target` is the kernel's
`to`); `workflow` `Workflow` (= `compose`)), description variants
(`tool_descriptions`, renamed aliases only), a `summarizer_prompt`, per-turn
`lead_hints`, and a `compose` recommendation. Each spelling is an ALIAS on
the declaration: the kernel routes and records the call under its own
`task`/`ask`/`spawn`/`send`/`compose`, so rho's rules written against
`task` match a call made as `Agent`; a preset's text is the kernel's own
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

Optional `lifecycle_hooks` in `settings.json` declares external tools at
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
row IS the per-model override — there is no `tool_style`, no
`tool_styles_by_model`, no `compose_models`. THE BOOT ROW IS THE UNIVERSE:
the profile declares once, under the pinned row, else the row of
`default_model` (none → `default`), and every turn sees the whole
declaration; `rho run --model X` on a model whose row spells tools
differently runs under the BOOT row's spellings and says so
(`adaptations: kimi-k3 (gem; boot row glm-5.3)`), while X's row still
decides the per-turn fields — its `lead_hints` ride the developer-role lead
after the tool lines, and its `compose` word is the compose switch's
`auto` rung (`compose: on (row glm-5.3)`; rho-dev's flag, then the `compose`
setting, beat it). A row change is a boot (the declaration is the front
of the cached prefix), as a `kernel_tools` change is. rho-dev's `rho
adaptations [--model M]` prints the row M resolves to from the files alone
— its entries and the one that matched M, spellings, recut anchors,
summarizer, hints and compose rung, the boot row when M's differs — then the kernel's
facts for M (`tool_calls true (catalog)`) through the daemon, `(no daemon)`
without one; `rho status` prints the default model's row; `rho run` prints
the turn's row directly after `compose:`. THE SUMMARIZER SLOT: a row's
`summarizer_prompt` is the kernel-mode compaction summarizer's text for
this profile — rho writes it into the profile's `summarizer` prompt
document at declare, beside the guideline and under the same digest tuple
(`[identity, tool bytes, summarizer text | absent]`), from the SLOT ROW:
the pinned row, else the row of `compaction.model || default_model`.
An explicit `compaction.model` also selects the kernel summary's model;
without it the summary inherits the current turn's model, while the
profile-wide prompt stays on the boot default's row even after `--model`
selects another model for a turn. Under `adaptations: off`, a text-less
row or `compaction.mode: delegate` (rho's own `summarize_history` keeps its
own text) the slot is deleted instead, the kernel's 404 on an absent slot
counting as landed — `profile.declared` says `summarizer=written|deleted`.
The `compaction` settings object is `{mode, model}`: `mode` `kernel`
(default) or `delegate`; `model` the summary's model (required under
`delegate` when `default_model` is unset; `RHO_COMPACTION` spells the mode
alone). The adaptation row determines the extra model-specific text. Local
rows may override shipped rows; the default row adds no text.

Rho declares its model-visible tools on the Agent Profile when the daemon
adopts its workspace. The executor announcement separately tells Nexus where
to route calls. These are distinct inputs: each turn freezes the profile's
declaration, while routing uses the executor's current announcement.

The shared guidance lives in the Agent Profile's `system_prompt` document,
inside the assembled request's stable prefix. A turn's developer-role lead
carries the current runner environment, tool guidance and model adaptation
hints; caller-supplied instructions are appended to that lead.

## Remembering and recalling

The default assistant prompt asks rho to retain useful preferences, confirmed
facts, decisions and corrections during ordinary work through Nexus memory
tools. It reads existing notes before changing them, merges related facts and
removes duplicates, and uses focused listing, search and reads when an answer
depends on earlier context. Routine chatter and requests with no useful memory
need no extra calls. A statement that something was saved or forgotten requires
a successful tool result.

Notes stay in Nexus database documents. `conversation/` holds task notes;
`user/` or `person/` holds personal preferences when bound; `workspace/` or
`group/` holds knowledge intended for that shared context. The current bindings
and their read-only rules still govern every call. Inspect and edit the same
documents with `rho memory CONVERSATION_ID ls|read|write|edit|grep|delete`.

This policy runs within the current model turn. It adds no background extraction
job or separate model call, and it does not promise that every model selects or
recalls facts correctly. Injected notes are budgeted; text search is bounded,
with no semantic ranking or special index document. Named agent definitions keep
their own prompt; the Telegram answering profile explicitly includes this policy.

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
rho jobs CONVERSATION_ID cancel JOB_ID
```

`--workspace ID` keeps the operation in the conversation's original workspace;
`--model PROVIDER/MODEL` selects the model for creation, and `--json` prints the
resource document. The shared chat and CLI grammar resolves relative times
once before creating the job. Daily rules retain the named IANA time zone.
`list AFTER` and `history JOB_ID AFTER` follow the opaque cursor printed by a
page with more results. Editing reads the current version and submits that
version once; a concurrent edit is reported as a conflict.

Pause and cancel stop future occurrences. They do not claim to stop a child
that is already working. Open its conversation and use the ordinary Stop
control when needed. A one-time job can be `completed` while its latest
execution remains `pending` or `running`; execution history reports the
child's own status. The model tools `read_scheduled_jobs` and
`manage_scheduled_job` use this same durable resource.

The Core methods are `scheduled_jobs`, `scheduled_job`,
`scheduled_job_executions`, `create_scheduled_job`, `update_scheduled_job`,
`pause_scheduled_job`, `resume_scheduled_job` and `cancel_scheduled_job`.
Create requires a caller-owned `idempotency_key`; update requires
`expected_lock_version`. The daemon serves reads under
`/conversations/scheduled_jobs` (`/detail` and `/executions`) and commands
under `/create`, `/update`, `/pause`, `/resume` and `/cancel`. Every request
names the owning conversation in `public_id`, optionally its
`workspace_public_id`, and a job-specific request names `job_public_id`.

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

rho ships a default set and integrates it; `settings.json` adds to it, and
`RHO_HOME/extensions/*.rb` is the operator's own directory.

```json
{ "extensions": ["rho/web-tools"], "extension_paths": ["/opt/team/rho-ops.rb"] }
```

A page extension calls `api.register_webui(root: "/path/to/static/files")`. Only successful
extension registrations are mounted. A second page registered by the same extension is a
registration error; two committed extensions claiming the page refuse startup and name both
owners. `webui_root` is the operator's explicit directory override. A standalone runner
logs page registration as unavailable, as it does other daemon-only capabilities.

An extension may register a `Rho::Agents::Definition` with
`api.register_agent(definition)`. Its profile joins the same declaration and
sync as local named definitions, including when no environment root is set.
Only successful registrations contribute definitions; duplicate profile names
from extensions refuse loading, and a local file cannot replace an extension-owned name.

Hooks are Ruby extensions through `api.on` (`tool_call` before a handler,
`tool_result` after it); there is no config-file hook interface.

`rho/todo` is the todo tracker: one tool on the agent's own address,
`todo_write {todos: [{content, status}]}`, which writes the list whole as
the conversation's memory document `conversation/todo.md` — the model sees
it again in every later turn's memory block, the webui reads the same door.
`rho run` prints the checklist as it changes while it follows (rho-dev's
`watch` and `follow` too); rho-dev's `task <id> <key>` prints the call. A
standalone loop has no conversation and the tool says so. The tool reads the current
document at execution and submits that identity/version pair once through the SDK's
conditional write or delete. This protects the read-to-write interval, not the model's
earlier reasoning; a `stale_object` conflict is returned without an automatic retry.
An absent list is created with null conditions, and clearing an absent list succeeds
without a delete. The model sends only the list and receives a counts-only receipt.

`rho/images` is the image tool: one tool on the agent's own address,
`image_generate {prompt, referenced_image_paths?, num_last_images_to_include?}` (`imagegen` under a boot row whose `tool_style`
names `codex` — rho's own spelling switch, since the kernel's alias grammar
takes kernel canonicals only), which places one `image_generation` OneShot
on the model `settings.json` names as `image_model` (or `RHO_IMAGE_MODEL`; a catalog ref such as `openai_api/gpt-image-2.5-sunburst-2026-09-08` — a setting, never a hardcoded id), keyed by the call, fetches the bytes
through the SDK's download route and writes them under the environment
root as `generated_images/<call key>.<ext>` — the result names the path
and captures the file, so the image re-enters the transcript as `read`
attaches one. No `image_model`, no tool: the extension registers nothing;
a model the account cannot run on that workload is the kernel's refusal
at the call, as text. A write on the open world: it parks under `ask` and
is refused under `rules` until a rule allows it. Refused under mode
runner, which opens no member plane.

For an edit, supply local `referenced_image_paths` in source order, or
`num_last_images_to_include` (1–5) for recent user image attachments. The latter
reads the latest 50 turns in the execution's original workspace and stops at
its source turn; it refuses if the requested images or source turn are outside
that window. It never selects a later message's pictures. Generated tool
captures are not user attachments: edit them using the saved local path.
The two reference options are mutually exclusive. Transparent-background
configuration is not yet exposed by the public image workload. Stopping an
active image tool requests cancellation of its known OneShot; a network failure
is logged, and the provider's already completed effects cannot be undone.

`rho/mcp` is the MCP client, an extension gem beside `rho/browser`: it runs
the servers `mcp_servers` names — a stdio server as a child in its own
process group with a REPLACED, scrubbed environment (rho's credentials and
every `*_KEY`/`*_TOKEN`-shaped variable withheld; the row's `env` added), a
streamable-HTTP server over the official client's own HTTP stack — lists
their tools ONCE at boot, and announces the ones you named under
`mcp__<server>__<tool>` with the server's own description and schema, byte
for byte, and the WORST-CASE effect profile (a write that may destroy and
reach outside this machine) — a server's `annotations` are its own testimony
and are never read; `effect_profiles` is where YOU say a tool is a read.
`tools` is required: name the tools, or `"*"` to take every one; a server
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
listed down and its calls fail naming the verb; a row that was down at boot
is announced by the next boot. `rho mcp logout NAME` forgets them. `rho
console --open` and `rho mcp login` open your browser through `$BROWSER`
when it is set. The OAuth path is driven through this binary by
`e2e/test/mcp_oauth_test.rb` on the mock (group 2 of the gate: the login with a stubbed `$BROWSER` and with `--no-browser` + the pasted redirect, the silent refresh, a renewal failure, a refusal, a re-login recovering at the next call, a step-up, `rho mcp` and `rho mcp probe` with no daemon, the config faults and an unreadable credential file) and the manual paid
`cd e2e && E2E_LIVE=1 E2E_MCP_OAUTH_URL=<url> rake live_mcp_oauth` (a real
public OAuth server, your own consent click). A stdio server runs
one call at a time; a call that times out stops that server (its process
group is killed) and the next call restarts it and says so; a server that
dies is restarted once at the next call and the call says so; the list is
never re-read until the next boot.

```json
{
  "extensions": ["rho/mcp"],
  "mcp_servers": {
    "fx": {
      "transport": "stdio",
      "command": "ruby", "args": ["/opt/fx/server.rb"], "cwd": "/opt/fx",
      "env": { "FX_TOKEN": "${FX_TOKEN}" },
      "tools": ["echo", "lookup"],
      "timeout_ms": 60000,
      "effect_profiles": { "lookup": { "kind": "read_only", "destructive": false, "world": "open",
                                       "idempotency": "intrinsic", "reconciliation": "none" } }
    },
    "remote": {
      "transport": "http",
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer ${REMOTE_TOKEN}" },
      "tools": "*",
      "serves": "agent"
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
address are refused; `"web": {"allow_private_network": true}` lifts loopback and RFC 1918 only — unique-local,
link-local (the cloud metadata endpoints) and every other reserved range stay refused. It is a `read_only` tool on
the OPEN world: it runs under `bypass`, parks under `ask` and is refused under `rules` until a rule allows it; a
deny on `url` binds under every mode. The daemon's log names the host, never the URL. `rho web fetch URL` fetches
from the CLI and prints what the model would read, whole (`--raw` for the bytes as rendered).

```json
{ "extensions": ["rho/web-tools"], "web": { "allow_private_network": false } }
```

## The page

`rho console` prints a single-use link; the page it opens is the same control
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

The other direction is `rho-acp-client`, an extension: another ACP agent you
name is delegated to by the model through one runner tool, `delegate_agent
{agent, prompt, session?, workdir?}`, its permission requests answered by
rho's own floor (the nine refused command shapes and the protected roots) and
then the row's policy — never parked, no proxy approval; `allow_always` is
never answered, because a standing grant is your `rho rules`. The first row is
Codex under the ChatGPT login, the second `opencode
acp` on OpenRouter, the model-neutral one:

```json
{
  "extensions": ["rho/acp-client"],
  "acp_agents": {
    "codex":    {"command": "npx", "args": ["-y", "@agentclientprotocol/codex-acp@1.12.0"],
                 "env": {"CODEX_HOME": "/home/me/.codex", "NO_BROWSER": "1", "INITIAL_AGENT_MODE": "read-only"},
                 "description": "Codex under the ChatGPT login", "model": "gpt-6-astra"},
    "opencode": {"command": "opencode", "args": ["acp"], "env": {"OPENROUTER_API_KEY": "${OPENROUTER_API_KEY}"},
                 "description": "OpenCode, a coding agent on OpenRouter"}
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
`category: "model"` option; `enabled` the switch (absent is on). A bad row is
listed `down: config:` with its sentence and costs the others nothing; only a
table that is not rows refuses the extension; no enabled row, no tool. `rho
acp-agents` prints the rows (the launch line redacted, the env names masked)
and the daemon's live children; `rho acp-agents probe NAME` spawns one from
here and prints what it declares; `enable|disable NAME` write the switch (read
at the next boot); `sessions`, `kill SESSION`, `logs SESSION` read and end the
daemon's children; `GET /acp` answers `{agents, sessions}`.
`agents/rho/rho-acp-client/README.md` has the tool's shape and the child's
lifecycle.

## Where the tools work

```json
{ "tools_root": "~/src" }
```

Before a loop's first write-kind call the runner captures the root — the
whole tree, `.gitignore` honoured — into a shadow git store under the work
root (`<RHO_WORK_DIR>/checkpoints/<digest>/`, never inside the project), so
rho-dev's `rewind` can put the files back to where a turn found them. For
this daemon's runner, rewind and regenerate refuse before forking or restoring
if a process this daemon started is live in the conversation's current root.
An actual restore also checks the checkpoint's original root; `--keep-world` skips
that extra check. Remote runners do not consult this daemon's process table.
If the historical-root check refuses a rewind, the child already exists and
is returned with a `failed/process_live` world outcome. The `checkpoints` row
in `settings.json` is the policy, with these defaults:

```json
{ "checkpoints": { "enabled": true, "retention_days": 7, "max_file_bytes": 2097152,
                   "max_tree_bytes": 268435456, "capture_timeout_seconds": 30 } }
```

An untracked file over `max_file_bytes` is left out and named; a tree over
`max_tree_bytes`, or a capture past the wall clock, is skipped and the loop's
record says so — never a stall. `rho doctor` prints the stores' size and
record count; `enabled: false` opens no store and announces nothing.

```sh
rho console                # open this daemon's page (mints a single-use link, 90s)
rho console --open         # …and launch a browser at it

rho env                    # where are the tools pointed?
rho env ~/src/billing      # point them there
rho env --clear            # back to settings.json

rho processes              # the dev servers and watchers loops started (alias: procs)
rho logs p3 --tail 50      # a process's latest output, and where its log is (the exit too, once it is gone)
rho kill p3                # end one: TERM, then KILL — the loop is told on its next result
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

Conversation model, compose and extension policy are stored in Nexus. The
local `tmp/hosts/<Profile UUID>.json` file is only a bounded follower cache;
deleting it loses automatic following until a conversation is attached again,
but does not remove its policy. Attach restores the policy, runner and answerer
before following or accepting another input. If Nexus policy cannot be read,
rho refuses that operation. Active followers recover an evicted cache row when
they next need its policy. Side reuse and idle cleanup discover their records
from Nexus even when their follower rows are gone.

At attach, restart or later reconnect, an expired event prefix is recovered
from the existing Turn, variant and Loop reads. The events watermark survives
expiry, so the follower can detect missed progress even when no events remain.
The first empty replay also reads state once: a fork can already have a copied
answer before its own stream has any events. Recovery uses the same event
consumer and restores execution state, tasks and the visible settled answer
before live following resumes. Repeated empty reads
at the same watermark do not repeat those state reads or completion callbacks.

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
follower's snapshot while keeping a live loop available for cancellation and
adjudication. Restoring its view recovers the settled answer; exclusion from
model context alone does not hide it. Undo clears the deleted turn and loop
from the remembered host, without ending the conversation's follower.

Followed hosts and running task clients read the current access token from
their original OAuth owner on every REST request. Normal renewal therefore
keeps existing followers and runners working after the previous token expires;
reconnecting as another identity does not lend its credential to old work.

The executor inbox listener retries transient connection failures every five
seconds while its original client still belongs to the active lineage. The
existing Runner and HTTP polling continue across that reconnect.

**A process follows its conversation.** A `start_process` entry is owned by
the CONVERSATION of the loop that started it (`rho processes` shows the loop
beside it): every later turn of that conversation may read and stop it, another
conversation's loop is refused by name, the person never is. Whose it is comes
from the inbox row the kernel wrote (`conversation_public_id`, null for a
standalone loop), never from a lookup of the daemon's own. When the
conversation ends here — archived or deleted (the kernel narrates
`conversation_ended`; a tombstone's next poll reads 404),
a standalone loop's terminal, its tools handed to another runner — the daemon
kills the group (TERM, a grace, KILL) and removes the entry. A group that died leaves the
table the moment its pipe closes; a `read_process`/`stop_process` against its
id answers the exit and "the entry is gone — start_process again gives a new
id", `rho logs` still answers the remembered exit, and the log file's last line
keeps it. A periodic validity sweep on the daemon is the fallback for a group
that died unnoticed. A restart resurrects nothing: the state file names only
live groups, and the next boot reaps them. A runner-mode rho owns an entry by
the same row's conversation but follows no conversation's feed, so there an
entry ends only by the sweep, a kill, or the daemon's shutdown.

Ending local following does not issue Nexus Stop or establish that kernel work
has finished. Readable archived history remains available. Explicitly attaching
a restored conversation starts a new follower; historical archive events are
checked against its current archive state so they cannot immediately stop that
new follower. A refused read ends following; a refused write alone does not.

**Watching a reply arrive.** `rho run` prints the model's words in their own
block behind a `│` gutter, each delta as it lands and flushed per delta, so a
long answer scrolls; every structured line (`loop:`, `status:`, `  check
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

rho's own
turns run under `bypass` — its guard list rides its profile as deny rules, so `rm -rf /`
and a force push are refused by the kernel before any runner sees them. So is
rho editing ITSELF: a `write` or `edit` under its own checkout (the directory
the running daemon loads from, and the runner gem's) or under `RHO_HOME`, and a
`bash`/`start_process` command that names either, are refused for its own model
under every approval mode with one sentence — "an agent never edits its own
checkout or home; develop a successor as a separate install". The rules anchor
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

`tools_root` is where a bare relative path lands — the one environment
fact this daemon holds. Unset, it is a scratch directory under `RHO_HOME`,
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
      "kind" => "read_only", "destructive" => false, "world" => "open",
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
the kernel routes a `skill` load to whichever announcer listed the name,
and the address's `skill` walks its loaders in registration order.

An ingress can register `api.on(:conversation_binding) { |public_id| ... }` on
rho's daemon handle. Return nil for an unbound conversation, or a string-keyed
Hash with `channel` and a user-readable `label`, plus channel details such as
`chat_id` and `topic_id`. Derive this from the ingress's existing route state.
The conversation detail response exposes these as `ingresses`, adding each
hook's registered `extension` name. WebUI shows the source and allows reading
and Stop; its writes carry `X-Rho-Viewing-Conversation` and are refused with
`409 ingress_bound` while bound (attach and Stop remain available). This
coordinates rho surfaces without changing Nexus permissions or CLI authority.

Background extensions can register `api.on(:member_connection) { |connection| ... }`.
The daemon supplies a `MemberConnection` with `user_public_id` and a member API
`client` bound to the adopted credential lineage, or nil on disconnect, Agent
authority loss, or before replacing that lineage. Credential rotation keeps that
lineage; reconnecting supplies a
fresh handle, including when the Agent Profile is unchanged. Callbacks run
serially on the daemon reactor, and connection operations wait for them. Retire
the previous worker before returning from the nil callback; replacement
credentials become visible only after it finishes. Load the new Profile's state
through the next supplied client. A boot-time adoption may arrive before background tasks
start; retain the handle until startup. Independent Runner changes do not emit
this event. The ordinary `:shutdown` hook still owns daemon shutdown.

A command's handler is handed the terminal (`Rho::Cli::Terminal`): `core`
— the `Rho::Core` primitives, one capability over one route each
(`open_conversation`, `say`, `stop`, `loop_row`, `loop_events`, `result`,
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
type, they retain the ordinary followed-host or loop lookup. Queue writes name
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

Images retain native placement when the selected model supports them. Other
files appear with their filename, type, size and `nexus://uploads/...` reference.
The model calls `file_import` to obtain a working path on the assigned runner,
then uses `read` for text or the installed workspace tools for document parsing.
`file_publish` selects a local result for the ordinary upload capture path and
returns a durable resource link; mentioning a path in prose does not publish it.

`core.say(id, text, mode: "queue", wait: false)` returns the accepted input
without waiting for a turn to materialize. A channel can pass a registered
`speaker_actor_public_id` for attribution. `kind: "message"` records a visible
user message as context without requesting a model reply; it requires queue
delivery and rejects model, tool, approval, addressing and scheduling overrides.

`core.say(..., tool_names: ["read"], approval_mode: "rules")` sends an explicit
tool subset and approval tightening for the addressed profile, including a
group profile. `tool_names: []` means no tools. The kernel validates both
fields against that profile; rho does not filter explicit names through its
own model tier. Omission keeps the existing defaults: rho's tier for its own
turns, the addressed profile's declaration for another answerer. Side
conversations allow an explicit subset to narrow their posture's tools further,
including `[]`, but reject tool expansion and approval overrides;
standalone loop messages cannot change the running turn's tools or approval.

`core.inputs` preserves a queued worker callback's `callback_result` reference.
`core.turns` preserves each turn's recorded `input_public_id` and its
`callback_sources`, including every consumed worker result in a parent summary.
Each result names an exact conversation, input, turn and variant. Use
`core.variants(conversation_id, turn_id, workspace_public_id:)` to read that
variant's content and producing loop; a later active variant is a separate sample.

`core.activate_variant(conversation_id, turn_id, variant_id)` selects a settled
candidate through `POST /conversations/activate` (body: `public_id`, `turn`,
`variant`; response: `variant`). The kernel owns cancellation of the replaced
candidate's unfinished work. `core.variant(..., concealed:)` remains the separate
visibility operation.

`core.stop(id, task_key = nil, force: true, host_type: "conversation")` addresses
a conversation by default. Use `host_type: "agent_loop"` for an exact loop or its
task, including one from a previous turn or candidate. `POST /stop` accepts the
same fields; explicit types bypass local host inference. An untyped raw request
can address only an already-followed host and returns `host_not_followed` for an
unknown ID, rather than guessing that it is a conversation. Conversation stopping
delegates all unfinished-work cancellation to Nexus; rho does not scan background
tasks. Force/graceful applies only to loop stopping.

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

### Named sub-agents

A checkout can define the agents rho hands work to. Each is one markdown
file at the daemon's environment root — `.agents/agents/<name>.md`, then
`.claude/agents/<name>.md`, at one level (the skills' two directories, the
skills' one frontmatter parser) — and rho registers it in Nexus as a named
definition of its own instance: an Agent Profile with the handle `@<name>`
(`-2` past a collision), the identifier `rho.<instance>/<name>`, no
credential and no address. The model then names it in `spawn {agent:
"@reviewer"}` or `send {agent: …}` exactly as it names any peer.

```markdown
---
name: reviewer
description: Reviews a diff for defects and reports only what matters; use it after a change lands, before a commit.
tools: read, grep, find, bash
model: openrouter/z-ai/glm-5.3
---
You are a code reviewer. Read the diff the spawner names, then the files it touches …
```

`name` is optional (the basename when absent; normalized to the handle
grammar). `description` is required — one line, at most 1024 characters —
because the spawner chooses by it. `tools` is an exact allowlist over the
whole set rho declares, kernel names (`spawn`, `send`, `task`, `ask`,
`memory_*`) included: absent means the whole set, `[]` none, a name the
set does not hold is dropped with a log line; names announced on rho's
agent address (`skill`, MCP servers with `serves: :agent`, `todo_write`)
are never in the set, because a named row has no address to serve them.
`model` is a catalog ref, the row's `default_model` (it beats the initiator's; `inherit` and absent mean the initiator's).
`fallback_model` is the row's fallback on refusal (the setting above): a
file that names no `model` runs on the initiator's line and inherits rho's
own `fallback_model`; one that names its own `model` declares its own
`fallback_model` or none, because rho's was chosen for rho's model; a
file's own `fallback_model` is its word either way. The body is
the row's `system_prompt`. Optional `prompt_template` is a Nexus assembly
template object: when present, the profile uses the `assembly` mechanism
instead of `default`. Nexus validates its blocks and ordering. This lets a
shared-context definition omit personal slots and automatic memory/skills.
Every other key is logged as ignored
(`agents.ignored_keys {path, keys}`), never refused — a definition written
for another harness loads with what matches. What each would map to, and
why it does not:

| key | it would mean | here |
| --- | --- | --- |
| `permissionMode`, `permission`, `disallowedTools` | a posture of its own | the rules are the parent's whole list; `tools:` narrows, nothing widens |
| `mcpServers`, `skills`, `hooks` | servers, documents, hooks of its own | a named row has no address to serve them; the runner's and the parent's stand |
| `memory` | a memory of its own | a spawned child inherits the parent's frozen memory bindings; its relative conversation root follows the child, while explicit shared roots stay shared. Default bindings include the workspace and controlling human |
| `model` aliases (`sonnet`), `effort`, `temperature` | a model by nickname, sampling knobs | a catalog ref or nothing (an alias is the kernel's `agents.declaration_failed`); effort rides the turn |
| `maxTurns`, `background`, `isolation`, `mode`, `color` | ceilings, a worktree, a look | no ceilings; the child runs where its runner runs; the console's |

The row's approval mode and rules are rho's own, whole — a file cannot
widen the posture; a `delegate` compaction policy lowers to the kernel's.

The definitions are read at every declare edge — boot, a handoff that
moves the tool set, `rho env DIR`, `rho agents sync` — under the same
digest as the declaration, so an unchanged set writes nothing; a file that
goes removes its row (reversibly — the same file back restores the same
row, same handle, same public id). The roster the spawner reads is written
into rho's own `system_prompt` slot beside the guideline: one line per
agent, `- @reviewer: <description> (tools: …)`, present on every runner,
local or remote, stable per boot.

```
$ rho agents                     # instance/ (the files), nexus/ (published), skipped: — each row's model: and fallback:
$ rho agents sync                # re-read the files, declare them, remove the stale rows
$ rho agents publish reviewer    # persist the row in Nexus for every agent of the steward
$ rho agents rm reviewer         # remove this instance's row (the file, if it stays, returns it)
```

`publish` flips the SAME row's scope to the steward's: it survives its
file and its instance, every agent of the steward sees it in `rho agents`
under `nexus/` and in its roster (an own definition of the same name
shadows it there), and the human's agents page lists and removes it like
any stewarded profile. The publisher keeps it fresh while its file exists;
once the file goes it stays as last declared — a snapshot of the
publisher's tool set and rules, served by whichever runner the spawning
conversation is bound to.

THE FLOOR: because a published row runs under the PUBLISHER's rules, rho's
Guard vetoes, on every task this runner serves, a `write`/`edit` whose
`path` resolves under one of this install's protected roots (the checkout,
the runner gem, the install prefix, `$RHO_HOME`) and a `bash`/
`start_process` whose command names one — the same roots and shapes as the
incubation denies, as data the model reads (`blocked by rho.guard: write
under /home/me/.rho is refused: an agent never edits its own checkout or
home; …`). A definition in a project reached only through `rho run --dir`
is not read: the root is the daemon's (`rho env DIR` points it). The
model itself may author, publish and remove definitions — the checkout is
no protected root — bounded by its own universe and rules (it can only
mint a narrower peer); a removal is reversible on the agents page.

## Remote access

Loopback is the default and needs no configuration. A wider bind — rho on a
home server, reached from elsewhere — needs two things, and they answer
different questions:

- **one per-boot transport assertion**, because the daemon cannot observe
  what fronts its socket: `--expect-external-encryption` when a TLS reverse
  proxy (Caddy, nginx) or a VPN transport (WireGuard, Tailscale) is in
  front, or `--unsafe-plaintext` to acknowledge bare plaintext. Neither is
  remembered between boots. rho terminates no TLS itself.
- **an `access_passphrase`**, always — including under the encrypted-front
  assertion. A passphrase is not transport encryption: the assertion says
  nobody can read the traffic, the passphrase says not everyone who can
  reach the port is the operator.

```json
// RHO_HOME/settings.json
{ "bind": "0.0.0.0", "access_passphrase": "at least eight characters" }
```

`RHO_ACCESS_PASSPHRASE` supplies an initial value for a systemd unit or container;
a saved `access_passphrase` takes precedence and survives restarts. Changing the
saved password applies immediately. There is deliberately no CLI flag for it: an argument
is in the shell history and readable in `ps` by every user on the host.

Locked, the daemon serves its page WITHOUT the per-boot bearer — that
document is the one surface that would hand a stranger a credential, and
every other control route already demands it. A caller exchanges the
passphrase for the bearer at `POST /unlock`; every miss arms a doubling
window that a correct passphrase also waits out, because a throttle a right
answer walks past is one an attacker walks past on the guess that matters.

`{"api_only": true}` skips the page entirely: `/unlock` and the control
routes are unaffected.

## Installing

```
bash install/install.sh
```

One readable file that runs from the checkout it sits in, no sudo: Homebrew's portable Ruby 4.0.7
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
                   # a dev home: `{"extensions": ["rho/dev"]}` in its settings.json and rho-dev's
                   # lib on the load path (never in this gem's bundle); `rho help` then lists the
                   # conversation verbs under `Extension rho.dev:` — agents/rho/rho-dev/README.md
```

The smoke task reuses the existing control/authentication, credential ownership,
connection lifecycle, turn admission, tool declaration and result-handling tests.
The full default task also covers all CLI, extension, recovery and concurrency
scenarios and repeats the complete suite under runtime RBS checks. Run it locally
for complete package verification; `rake rbs:conformance` runs that instrumented
suite separately. Cross-project journeys and installation acceptance remain in
the [E2E suite](../../../e2e/README.md).
