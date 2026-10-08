# rho-ingress-telegram

Telegram messaging ingress for rho. The extension runs in rho's Ruby daemon; no
Node service or inbound webhook server is required.

## Enable the extension

Use the rho distribution, which includes this gem. Run the daemon in `full` or `agent` mode;
runner-only mode cannot host Telegram. Agent mode needs a connected runner for
environment tools. Core plugin management is available even while Telegram is disabled, including in
API-only mode. Telegram-specific commands and routes register only when enabled. You can
configure Telegram before choosing a model; agent replies need a connected Nexus
workspace and an available text model.

The guided path is `rho setup telegram` (or `./cybros setup telegram` in the Docker
stack). It validates the token with `getMe`, asks for the explicit numeric bot owner
ID, and preserves unrelated settings. The token is saved privately as
`plugins["rho.ingress_telegram"].configuration.token` in
`<RHO_HOME>/settings.json` (file mode 0600). The token is a write-only field: the
WebUI and control API expose only whether one is set.
A saved token takes precedence over an environment token. Setup applies changes
to the running daemon immediately; without a running daemon it saves them for
the next start. Setup itself never polls updates or sends a chat message.

If you do not yet know your numeric ID, save the token without an owner ID.
Start rho if it is stopped, send `/start` privately to the bot, then run
`rho setup telegram --finish` and enter the ID it returns. No agent messages are
accepted until an owner is bound. The joint Docker wizard guides this finish
sequence without restarting rho. Rerunning `--finish` when access is already configured
is a quiet no-op. Native installs manage their own `rho server` process.

For manual configuration, create a bot with [BotFather](https://core.telegram.org/bots/features#botfather).
You can instead supply its token through the daemon's environment, using your service manager or
private environment file. The default variable is `RHO_TELEGRAM_BOT_TOKEN`.
Keep the settings file private; never put the token in command arguments or source control.
Use one polling daemon per bot; an existing Telegram webhook must be removed
before long polling can receive updates.

Merge this example into `<RHO_HOME>/settings.json` (the default home is `~/.rho`),
preserving other settings and existing entries in `plugins`:

```json
{
  "default_model": "provider/model",
  "plugins": {
    "rho.ingress_telegram": {
      "enabled": true,
      "configuration": {
        "token_env": "RHO_TELEGRAM_BOT_TOKEN",
        "owner_id": "123456789",
        "stale_after": 600,
        "transcription_model": "openai_api/gpt-4o-mini-transcribe-2025-12-15",
        "speech_model": "openai_api/gpt-4o-mini-tts-2025-12-15"
      }
    },
    "rho.images": {
      "configuration": {
        "model": "codex_subscription/gpt-image-2"
      }
    }
  }
}
```

Replace the example model with an available model reference and the IDs with
your own Telegram numeric IDs. Usernames and display names are not authorization
identifiers. `owner_id` is bound locally through setup or the console's Telegram
settings and takes effect immediately. Hand edits to `settings.json` load on the
next start. The owner is always allowed and cannot be removed or ignored by a bot
command. Telegram group administrators gain no bot management permission.
Mutable allowlists and the ignore list live in the Agent-owned Telegram state in Nexus Store;
they are initially empty. The former settings lists and `managers` are no longer
accepted. After binding an owner, use the owner's private bot chat:

```text
/access users add 234567890
/access chats add -1001234567890
/access users list
/access users remove 234567890
/ignore add 234567890
/ignore remove 234567890
```

`/access chats list|remove ID` and `/ignore list` are also available. These changes
apply immediately and survive daemon restarts. Ignore takes precedence over allow:
new messages, commands, observations and media from that user are not accepted.
Existing accepted work and history remain; use a task-specific `/stop` to stop work.
Removing an allowed group also disables delivery to that group. Keep the group
list empty for a private-only bot.
`token_env` can name another environment variable. Its value is used only when no
token is saved. Enabling without a token saves the requested state and reports that configuration
is incomplete; polling begins once a token is available. The setup wizard verifies
a supplied token with Telegram before saving it.

Start or restart `rho server` with that environment. Send `/start` in the bot's
private chat: a person not yet allowed receives their numeric user ID and an
instruction to contact the owner. The owner can allow that ID with `/access users add ID`.
Group chat IDs must be supplied explicitly with `/access chats add ID`.

Inspect the running daemon from the same rho home:

```sh
rho telegram status
```

This reports connection state, bot ID, consumed update offset, bound chat/topic
count and uncertain or refused deliveries, together with configuration, token
presence/source, and the current access lists. It does not print the token. There
is no `rho telegram allow` command; use the console's Telegram settings or
owner-only `/access` and `/ignore` in the bot chat.
The CLI loads the extension's command without starting polling.

The authenticated local control API exposes `GET /telegram`,
`POST /telegram/configuration`, and `POST /telegram/access`. Configuration accepts
`enabled`, `token`, and the fields in the `telegram` object above. Omit `token` to
keep it, send a nonempty string to replace it, or send `null` to clear the saved
value and use the environment fallback. If neither source will contain a token,
disable the channel in the same request. Configuration returns `{"saved":true}`;
read `GET /telegram` again for the current runtime status. Validation failures
save nothing; an application failure after persistence reports
`settings_apply_failed` with `saved:true`.

Access accepts `list` (`allowed_users`, `allowed_chats`, or `ignored_users`),
`action` (`add` or `remove`), and one numeric `id`. The same access mutation is
used by bot commands and the console. Access remains editable while polling is
disabled, but requires a connected Agent profile; unavailable lists are `null`,
never fabricated empty lists. Owner/media edits keep the current poller, while
token replacement and channel disable retire the old worker before another starts.

## Docker stack configuration

For the joint installer, run commands from its installation directory (by default
`~/.local/share/cybros`). Run `./cybros setup telegram` for the guided flow and
immediate application. The following steps are the manual alternative. Its rho home is the bind mount `data/rho/home`, so merge
the settings above into `data/rho/home/settings.json`. Keep the file owned and
readable by the container's UID 1000 and preserve its existing settings.

Edit the installer's private `.env` file and add the default token variable:

```dotenv
RHO_TELEGRAM_BOT_TOKEN='replace-with-your-BotFather-token'
```

The template passes only this optional variable to rho; it does not enable the
extension or send the token to Nexus, workers or PostgreSQL. Leave `token_env`
at its default unless you also add your custom variable explicitly to rho's
Compose `environment`. The management script reads installation files rather
than inheriting this token from your interactive shell.

After editing both files, recreate rho so the new environment takes effect:

```sh
cd "$HOME/.local/share/cybros"   # or your selected installation directory
chmod 600 .env
./cybros compose up -d --no-deps --force-recreate rho
./cybros rho telegram status
```

A plain container restart does not load an edited Compose environment. The
installer preserves an existing `compose.yaml`: if it predates Telegram support,
add `RHO_TELEGRAM_BOT_TOKEN: "${RHO_TELEGRAM_BOT_TOKEN:-}"` under **rho's**
`environment` before recreating it. See the [stack guide](../../../install/stack/README.md)
for installation and pairing. The standalone `install/docker/compose.yml` maps
the same variable only to its `rho-full` service; use its explicit `--env-file`
and recreate `rho-full` after changing the private environment file.

## Conversations and controls

Private messages from allowed users start or continue a conversation. A group
or forum topic keeps a separate execution conversation per requester. Mention the
bot for your own request. Reply to a known original request, task receipt or formal
answer to continue that task, including after `/new` and restart. Only its requester
or the bot owner can continue or control it; another member starts their own request.
Replying to a known proactive message starts your own request. Other unknown bot
replies require a fresh mention rather than guessing a task.
The default `assistant` mode responds to explicit requests. With observation enabled,
background messages enter a separate passive conversation; each new task input takes at most 20 recent
messages, 2,000 characters per message and 8,000 characters in total, as user-level
context with speaker identities. Background attachments are labelled without being
downloaded. Observation never becomes an automatic steer. Requests from one person
queue within their selected conversation; another person's held task does not block them.
Ordinary text waits for `input_debounce_seconds` without another message from that
requester (2 seconds by default; integer values from 0 to 10). Zero sends each
message immediately; positive values wait for follow-up text.
Each following message extends that window. Consecutive text with the same
speaker, chat/topic, selected conversation, model and quoted context becomes one
input in the original order. In a group, a follow-up inside this window does not
need another mention. Different requesters and topics keep independent windows;
changing the selected conversation or model starts another batch. A later batch
still queues after an already running response; explicit `/steer` keeps its
current execution target and next-model-boundary behavior.

The channel saves every source message and its deadline in Nexus Store before
advancing the Telegram offset. Restart resumes the remaining window. Once
admission starts, the input body and retry key stay fixed; later messages cannot
change an uncertain submission. Every source message remains linked to the
accepted task, so replying to any member of a batch selects that same work.
Commands, question answers and approvals bypass the window. Before admission,
replying to an original message with `/stop` removes only that message; `/new`,
`/resume` and a workspace switch discard that requester's unadmitted inputs.
Attachments and voice preparation use the same ordered admission queue, with
separate inputs rather than text batching. Another requester remains independent.

Change **Telegram options and access → Message grouping delay** in the WebUI, or
use the shared plugin settings command:

```sh
rho extensions configure rho.ingress_telegram '[{"op":"set","path":["input_debounce_seconds"],"value":3}]'
```

The setting applies to newly received messages without restarting the poller.
An already saved deadline survives restart or settings changes; the next message
in that burst extends it using the current setting.

The in-process gateway owns the slash registry and handlers. Telegram projects
that registry into its menu; rho's WebUI keeps its own command system.

The owner can enable `active` mode for one group or forum topic. It uses the same
limited observed context to decide whether to stay quiet or send a short plain-text
reply. Observation must also be on; turning it off pauses active participation.
Enabling either setting considers future messages only. The bot waits for five
seconds without a new message, judges at most once every 30 seconds, and waits
60 seconds after a successful proactive reply. Formal work already running in
that room takes priority.

Proactive replies use rho's default text model and have no tools or attachments.
They do not execute a member's task or use that member's conversation settings.
The observation conversation keeps its original workspace; a new one uses rho's
default workspace. Only successfully sent proactive replies enter that context,
and they cannot trigger another proactive reply by themselves. This is a limited
background view, not a copy of every task or the complete Telegram history.
Replying to a known proactive message includes its quoted text in your request,
even while its history record is pending or observation is off.

New messages or changed participation/access settings discard an unsent stale
reply. A candidate also expires after `telegram.stale_after` seconds from observation
acceptance (600 by default), so a later restart cannot post an old interjection.
An uncertain Telegram send is never automatically repeated. Restart resumes
a known request; an unknown create or history-append result is not retried beyond
its 24-hour replay window. A model failure, truncated output or invalid decision
stays quiet until another eligible message arrives.

Allowed users other than the configured bot owner have read-only model tools in
both private chats and groups. This includes Telegram group administrators.
Each request uses Nexus's tool assembly for the isolated answerer and the
conversation's selected Runner, then keeps its `read`, `ls`, `find`, `grep`,
`file_import`, `file_publish`, `web_fetch`, and bounded `delegate_task`, `code`, `wait`,
and `ask` tools, including aliases of those kernel tools. The six database memory
tools operate only through explicit bindings: requesters can change their own
`conversation/` and private `person/` notes; their `group/` binding is read-only.
Child model work inherits these tool and memory boundaries. Shell, edits to
working files, process control, browser automation, cross-conversation work, and
other extension tools are unavailable. File import stages an accepted attachment
and publication returns an existing artifact; this does not restrict which
existing files can be read.
The owner's requests retain the normal tools of the selected profile.

Text, media, acceptance retries and resumed sessions apply the same policy.
Steering and answers to a model question require proof from that execution's
frozen tools. An execution with broader or unavailable tool facts asks the
member to start a new request or ask the owner to continue it. Editing a queued
request likewise requires its original explicit read-only subset. Existing
request ownership still governs these controls, including Stop and queue cancel.

| Command | Behavior |
| --- | --- |
| `/start`, `/help` | Explain the available controls. |
| `/status [TASK_ID]` | Show the current conversation and recent task IDs, or the exact task input and original execution status. |
| `/destinations` | Owner-only list of known allowed group/topic destinations and the owner's private chat. |
| `/deliver TASK_ID DESTINATION` | Owner-only selection of where that task's future results arrive; copy its latest completed formal result once there. |
| `/settings` | Show shared group behavior separately from your conversation's workspace, model, voice and new message age limit. |
| `/new` | Start a new conversation in this chat/topic. Earlier work continues reporting here. |
| `/sessions [PAGE]` | List this chat/topic's saved main conversations, ten per page. |
| `/resume ID` | Select an unarchived conversation from this chat/topic for subsequent messages. |
| `/search TEXT`, `/search next` | Search only this requester's saved conversations in this chat/topic; continue through bounded search windows. |
| `/history [before POSITION]` | Read the latest or an older history window with stable turn IDs and positions. |
| `/rename TITLE`, `/archive [ID]`, `/restore [ID]` | Rename the selected conversation, or archive/restore a saved conversation in this chat/topic. |
| `/fork [POSITION]`, `/regenerate [POSITION]` | Fork at a selected turn or generate another tail answer. Omission selects the latest turn. Both keep current files. |
| `/variants POSITION`, `/variant POSITION ID [hide\|restore]` | List candidates, select one, or change a candidate's visibility. |
| `/edit POSITION TEXT`, `/undo` | Add an edited tail candidate, or physically delete the newest turn. Earlier content requires a fork before editing. |
| `/history hide\|show\|exclude\|include\|delete\|restore TURN_ID` | Change retained history's visibility or concealment through Nexus view-state; concealment of the unpinned newest turn requires `/undo` instead. |
| `/task pause\|resume\|retry\|abandon [TASK_ID] [TASK_KEY]` | Control the selected execution; retry/abandon may name a failed task key. `/resume ID` still selects a conversation. |
| `/transcript [TASK_ID] [branch PREFIX] [before CURSOR]` | Read execution rounds and tool branches with pagination. |
| `/context`, `/compact` | Preview the next request's context or request compaction. |
| `/queue` | Show the current conversation's waiting inputs and their selection numbers. |
| `/queue edit N TEXT` | Replace the selected waiting input's text, keeping its attachments and delivery time. |
| `/queue reschedule N in 20m` | Change when a waiting input becomes due; also accepts `at TIME` or `now`. |
| `/queue cancel N` | Cancel the selected waiting input. |
| `/remind in 20m TEXT` | Schedule a one-time reminder in this conversation; also accepts `at TIME`. |
| `/job list`, `/job show ID`, `/job history ID` | Inspect independent scheduled jobs and each execution's task ID. |
| `/job create once in 20m TEXT`, `/job create every 1h TEXT`, `/job create daily 09:00 Asia/Shanghai TEXT` | Save a one-time or recurring job in Nexus; `once at TIME` also accepts an explicit UTC offset. |
| `/job edit ID prompt TEXT`, `/job edit ID every 2h` | Update the job prompt or rule; `once in`, `once at` and `daily` use the create grammar. |
| `/job pause ID`, `/job resume ID`, `/job cancel ID` | Change future scheduling for that exact job. |
| `/workspace`, `/workspace list`, `/workspace current` | Show the current workspace; `list` also shows available workspaces. |
| `/workspace use ID` | Choose an available workspace by public ID or exact name and start a new conversation. |
| `/workspace create NAME` | Create a named workspace and start a conversation in it. |
| `/stop [TASK_ID]` | Stop the selected original execution and its derived background work. An explicit waiting task ID cancels only that input; reply to a media request to cancel preparation before admission. Unrelated requests continue. |
| `/steer [TASK_ID] TEXT` | Add TEXT at the original execution's next model step. An ended, delivered or changed execution is refused; instructions never redirect to a child or later task. |
| `/model` | List currently available text models. |
| `/model provider/model` | Choose the model for subsequent requests. |
| `/codemode [on\|off\|default]` | Read or change Code Mode for the selected conversation; `default` follows rho's global setting. |
| `/mode`, `/mode status` | Show assistant/active mode and whether observation has paused participation. |
| `/mode assistant`, `/mode active` | Owner-only change to this group/topic's participation mode. |
| `/observe`, `/observe status` | Show the shared observation setting and its exact group/topic scope. Available to allowed members. |
| `/observe on`, `/observe off` | Owner-only change to the current group/topic's background context. |
| `/voice off`, `/voice voice_only`, `/voice all` | Disable spoken replies, speak replies to voice messages, or speak every answer. Text is always retained. |
| `/approve ID`, `/deny ID` | Decide the exact pending tool approval. |
| `/answer ID your answer` | Answer the exact pending question. Replying to its message also works. |
| `/access users\|chats list\|add\|remove [ID]` | Owner-only private-chat allowlist management. |
| `/ignore list\|add\|remove [ID]` | Owner-only private-chat ignore management. |

Commands use these English names, including when conversation text is in another
language. `/command@bot_username` is accepted for this bot; commands addressed to
another bot are ignored. Model/workspace/voice settings, mode/observation changes and approvals
require the bot owner; allowed members can read `/settings`, `/mode status` and `/observe status`.
Allowed members can use `/codemode` on their own conversation after opening it
with `/new`. The choice survives restarts and affects subsequent requests;
running work keeps its captured tools. Enabling Code Mode does not expand that
member's permitted tool set.
Task controls and ask answers require the task requester or
owner in the same chat/topic. After `/deliver`, the owner can also use an explicit
task ID with `/status`, `/stop` or `/steer` in its exact saved destination.
A user's queue selection numbers are private to that user's command context;
only the input's requester or owner can edit/cancel it. Approval buttons retain the
original loop/task identity. Large requests and requests addressed to another agent
still direct the operator to the owning CLI.
Clarification questions from the group profile can be answered here even though
that profile has no separate executor; they keep the original task and workspace,
and the same requester/owner and read-only continuation checks apply.

Workspace selection belongs to one requester in one chat/topic. A new chat starts with rho's
current default; selecting a workspace here does not change that default or
other chats. Use the public ID when several workspaces share a name. Switching
keeps earlier conversations under their original workspace: background replies
still arrive here, and their pending questions and approvals remain actionable.
Each tracked conversation retains that scope across restarts, changes to the daemon
default and archive ending the local follower.
`/new` keeps this chat's selected workspace. Workspace creation and the new
conversation reuse their original idempotency keys after a lost response.
If the selected workspace becomes unavailable, `/workspace list` still shows
the available choices. Choose another with `/workspace use ID`; rejected messages
do not block these recovery commands or silently move into another workspace.

`/sessions` lists only conversations already associated with this exact
chat/topic and requester. It does not expose other participants' sessions, other private chats, other topics
or every conversation in a workspace. Copy a full ID into `/resume ID` to select
it. The selection restores that conversation's workspace and keeps this chat's
model setting for new requests. It does not restart stopped work or resend old
answers. Use `/restore ID` before selecting an archived conversation. Earlier work
continues reporting to its original chat/topic after a switch or daemon restart.

History commands use the selected conversation and its saved workspace. Search
results are restricted to this chat/topic and requester even when several saved
conversations share a workspace with unrelated work. An empty search window can
still offer `/search next`; no unseen workspace result is rendered.

Regeneration retains the source execution's tools and approval policy. Non-owner
resume, retry and regeneration require verified read-only execution facts. A new
candidate's task receipt names its variant ID, while the original input's task ID
continues to address the original execution. Without an ID, task controls select
the most recent accepted execution. Candidate replies at an existing turn position
are delivered once under their own identity without replaying older answers.

Fork retries reuse the saved command key and turn. Other history and execution
writes use the ordinary control recovery rule: if the response is lost, the change
is reported as uncertain and is not repeated automatically. `/history`, `/variants`
and `/status` let the requester inspect the resulting state. Editing preserves the
original candidate; mid-history removal changes view-state, while `/undo` removes
only the tail. These controls do not restore working-directory files.

Queue numbers refer to your most recent `/queue` list in this chat/topic. They
remain bound to the listed inputs even if another client changes the queue's
order. An input that has started or disappeared cannot redirect the command to
a newer input; run `/queue` again when the selection is stale. Pending and blocked
inputs can be edited or canceled. An instruction already waiting for a model
step can only be canceled, and internal result messages cannot be changed.
`/stop` without an ID retains ordinary queued inputs; use `/queue cancel N` or
`/stop TASK_ID` for a specific waiting request. If that input starts concurrently,
the cancellation is refused without stopping another execution.
If a queue write's response is lost, the bot reports uncertainty and does not
repeat it automatically. Check `/queue` before issuing another command.

One-time reminders use the same waiting inputs and reply delivery as other
requests. For example, `/remind in 20m Submit the report` or
`/remind at 2026-10-03T09:00:00+08:00 Submit the report` schedules a brief reminder.
Durations use whole `s`, `m`, `h` or `d` units (`1d` means 24 hours). Absolute times
must include `Z` or an explicit UTC offset; the bot does not infer a timezone from
its host machine. It resolves a relative delay once, before submission, so an
acceptance retry keeps the same time. The receipt shows the accepted UTC time.

This is a not-before time: a busy conversation, a held request, unavailable model
or offline delivery can make the reminder arrive later. `/queue reschedule N now`
makes it due for the next available request boundary; it does not interrupt work.
Rescheduling keeps the input's text, attachments, answerer and tool restrictions.
The requester or bot owner can change it under the same queue permission rules.
`/new` and workspace switches preserve delivery to its original chat/topic.
These reminder commands accept text only and create one waiting input. Use `/job`
for independent work or recurring schedules.

Scheduled jobs store their prompt and `once`, `interval` or `daily` rule in Nexus.
For example, `/job create once in 20m Inspect the report` starts a fresh child
conversation when due, even while the main conversation is busy. Each execution
reports back through the ordinary asynchronous task callback. `/job create every
1h Inspect the report` repeats; `/job create daily 09:00 Asia/Shanghai Inspect the
report` uses the named timezone. `/job list` and `/job show ID` read the current
server record. Long lists include the next command with its opaque cursor.
A listed record without a recoverable Telegram requester can be inspected, but
its presence alone does not grant Telegram controls or assign result ownership.

`/job history ID` shows distinct execution task IDs. Use `/status TASK_ID`,
`/stop TASK_ID`, `/steer TASK_ID TEXT` or `/transcript TASK_ID` to address that
execution. Stopping one execution does not cancel its future schedule;
`/job pause ID` and `/job cancel ID` control future occurrences. Unqualified
`/stop` keeps selecting the main request. After `/new` or a workspace switch,
a saved job still reports to its original conversation and chat/topic; its full
job ID remains manageable there.

The requester or bot owner can manage a job. Non-owner creation freezes the
isolated group profile and its explicit read-only tool subset; edit and resume
re-check that current server policy. Pause and cancel remain available if that
policy changes. Relative creation times and policy are saved before submission,
so a lost response retries the original request within the receipt window.
After that window, the bot reports uncertainty and asks for inspection instead
of creating another job. A lost edit or lifecycle response is never reapplied
automatically. Plans and due times are not copied into Telegram state.

The adapter retains job ownership and per-execution identities, and discovers
model-created jobs only when their persisted source execution maps to a known
request. It polls bounded execution-history pages on the existing history
cadence and follows only main conversations for result delivery. Durable
callback source identities recover the mapping after event history expires;
child results do not produce a second Telegram notice. Each occurrence retains
its own explicitly selected result destination; discovery does not copy the
creating task's destination to the job or its workers.

While this ingress is enabled, its current chat/topic conversation is reported to
rho as Telegram-bound, including the chat and topic in its label. The binding
comes from the saved route and remains present while Telegram is offline. `/new`,
`/resume` or a workspace switch releases the previous conversation without stopping its
background deliveries. Disabling the ingress removes its binding hook; no
separate lock or takeover state is stored.
Disconnecting from Nexus clears the active binding projection. Reconnecting loads
only the connected Agent profile's saved routes, including when the daemon stays running.
This coordinates rho's WebUI; Nexus and CLI clients retain their ordinary
permissions and lifecycle behavior.

Ordinary text receives the assistant's answer directly, without
a separate queue acknowledgement or task ID message. Starting background work is
acknowledged by the assistant after it has actually launched that work; reminders
and scheduled jobs retain their explicit scheduling receipts. `/status` lists the
ten most recent accepted task IDs in the selected conversation, including media
after admission; `/queue` also shows the
waiting input IDs. An accepted steering instruction retains its original task ID.
Independent child requests also have their own input IDs. A busy child's latest
request is discovered through the existing parent snapshot; completed callbacks
recover that identity even when the child finished before a refresh. Reusing a
child for another request creates another task ID.
For an ordinary child, this early ID can select a future result destination before
the original execution is reliably linked. Stop and Steer become available only
after that link is known; the active variant may belong to a later regeneration.
Scheduled executions already linked by their execution record keep their usual
controls.

Use the full UUID in `/status TASK_ID`, `/stop TASK_ID`, or `/steer TASK_ID TEXT`.
An explicit ID takes precedence over a replied-to message and stays bound to the
original request, conversation and workspace after `/new`, `/resume` or restart.
Unknown or unavailable IDs are refused, never replaced by the current task.
Without an ID, the existing reply/current-task selection applies. A UUID-shaped
first word in `/steer` is treated as a task reference and requires instruction text.

`/status TASK_ID` reports the original execution's status, not an aggregate of
child work. A completed original execution may still own background work; Stop
uses the kernel's source ownership to cancel that work, while Steer only targets
the original execution and is refused after its delivery or end. Task controls
never use a reused child's current conversation as a substitute target.

The owner can select another result destination with `/destinations`, followed
by `/deliver TASK_ID CHAT_ID:TOPIC_ID`. Use an exact listed key; `0` means no topic.
The list contains only groups/topics the bot already knows and that remain on its
allowlist, plus the owner's known private chat. Other people's private chats and
unknown groups/topics are unavailable. Selecting a destination copies the latest
completed formal result once and sends that task's future formal results there,
including later supplementary results after a restart. Captured attachments follow
the result; copying a completed answer does not generate another spoken reply.
For an independent child or scheduled execution, that result is the worker's own
formal answer and its committed attachments, at the exact version recorded by its
callback. Later edits or regeneration in the child do not replace that answer.
Worker destinations are selected separately; they do not inherit an explicit
destination chosen for their parent task.
The parent conversation's report always returns to its original chat/topic,
including a report combining several compatible worker results. It is never
exported as one worker's answer. Replies to that report continue the parent
conversation under its own requester and execution, while an exported worker
result retains the explicit-control behavior described below.
The report's text, attachments and spoken reply share this identity. If the report
is recovered after its original execution events have expired, replies still
continue its parent conversation, but Stop and Steer remain unavailable rather
than selecting a regenerated execution.
Every message already queued keeps its original destination, including a partially
sent or uncertain message. Repeating `/deliver` does not resend the same saved copy.

Independent workers have their own task IDs, using the worker's accepted input
UUID. A parent request that starts several workers never aliases one of them.
`/deliver WORKER_ID CHAT_ID:TOPIC_ID` copies that worker's own formal final and
captures, using the exact version returned by the kernel, and changes only that
worker's future destination. A later regeneration does not substitute a different
answer. The worker inherits its requester and source chat/topic, not the parent's
explicitly selected external destination.

Compatible worker results may be summarized together in the main conversation.
That report stays in the main conversation's original chat/topic, independently
of the workers' chosen destinations. Stopping one worker after its result was
consumed does not retract the result or stop the combined report. The main
conversation's own Stop still applies.

The source conversation, workspace, answering profile, tools, working files and
memory stay in place. Questions, approvals and progress remain in the source
chat/topic. At the saved destination, only the bot owner can use `/status TASK_ID`,
`/stop TASK_ID` or `/steer TASK_ID TEXT`; these commands address the original work.
A normal reply to a delivered result cannot continue the source conversation.
Send a new message to start separate work in that destination's own context.
Copies identify their task and source chat/topic. Removing a destination group
from the allowlist prevents queued results from being sent there.

`/steer` receives an acceptance acknowledgement, which does not mean the model has
already consumed the instruction.
It does not cancel tools or undo completed effects. Empty `/steer`
commands show usage without submitting input.
This command accepts text only; an attachment caption receives a clear
refusal so its media is not silently discarded.

Each requester in a Telegram chat/topic uses one selected agent conversation.
`/side` and `/btw` are unavailable: they create no conversation or input and do not
change running work. Continue in the selected conversation, or use `/new` to
select a new one. rho's Side feature remains available outside Telegram.

`/observe on` records allowed participants' non-triggering messages as attributed
conversation history without starting a model call. Telegram must deliver those
messages: make the bot a group administrator, or disable Group Privacy in
BotFather and remove and re-add the bot. The command checks this capability.
Turning observation off stops recording new background messages and retains
already recorded context; future requests no longer receive that background context.
It does not stop accepted tasks. The setting applies only to the current group or,
in a forum, the current topic. Other topics and groups retain their own settings;
there is no group-default inheritance. Replies identify the affected group/topic.

Group requests still require an explicit mention or a reply to the bot or a known
task. Observation does not produce automatic participation. `/settings` and
`/observe` always use the current group/topic and the command sender's own
conversation settings, even when replying to another person's task or an old bot
message. This does not grant control of that person's task. Observation changes
and their acknowledgements are saved together; a restart replays the acknowledgement
without applying the change again.

The owner's private chat uses the normal rho profile, configured tools, personal
memory and skills. Other private chats and all group tasks use the
`telegram-group` profile with explicitly bound database memory. Other private
requesters receive their own `person/` and current `conversation/` roots; group
requests receive current `conversation/` and shared `group/` roots. The owner can
write shared group memory; other participants can read it. The operator's persona
and skill catalog are omitted, and cross-conversation spawn, send and history
search/read tools are not offered. Non-owner requests retain the read-only runner
tool set. The profile's tool list is a permission ceiling: Nexus imports only
the allowed tools served by the conversation's selected Runner. Optional browser
or image tools need not be installed. Kernel tools retain the current profile's
aliases through their canonical identities. Owner group coding, browser and code
tools use that Runner and its ordinary approval policy. This profile is not an operating-system sandbox;
choose the runner and its accessible files for the people you authorize.

The group profile guides sustained work into a bounded background task with
conversation lifetime, then acknowledges the accepted work and leaves the chat
available. Its result starts a supplementary reply under the same task ownership.
Quick questions and simple reads stay in the current reply, and an explicit
request for synchronous work takes priority. Its system prompt also carries the
current conversation kind before the first model call. A child or scheduled
execution performs its assigned work and returns the result; launching another
worker is not completion. Independent subtasks whose results are needed for the
current delivery use turn lifetime or an explicit wait. Explicit requests for
persistent background work are still supported. Group workers take one
assignment; they do not expose a persistent child conversation for follow-up
messages.

Result summaries follow the current receipt's source, execution time and original
qualifications. A neighboring task cannot determine whether this execution was
one-time or recurring, and the job's editable current rule is not a historical
snapshot. When that distinction is unknown, the report calls it "this execution".
This shared rho policy guides the model; deterministic prompt tests do not prove
live execution quality or factual wording.

## Output, recovery and limits

Progress is a short, replaceable status rather than a tool transcript. Private
chats use Telegram drafts when available and fall back to ordinary message
editing; groups use message editing. A draft's Stop control targets its original
loop and cannot become a Stop for a later execution. Completed answers and later
background results are new formal messages, including results from the previous
conversation after `/new`.
The final answer ends a private draft without publishing a completion bubble.
An existing ordinary progress message is finished by editing that same message;
completion never creates a new progress message.

Completed replies use the next local follower update instead of waiting for the
periodic history reconciliation. Running work and pending questions retain their
bounded polling cadence. A failed model request reports a safe recovery hint:
when its provider is unavailable, check the credentials and model settings in
Nexus, then open the failed request in rho to retry it. Upstream error bodies are
not posted to the chat, and a failure does not automatically retry the request.

If another surface changes the current execution, its previous preview is marked
no longer current; this does not claim that independent background work stopped.
Before sending each queued answer chunk, the adapter checks the source turn and
active variant. A replaced or deleted answer is discarded from the unsent queue.
Independent worker copies instead check current worker access and the fixed
formal variant's existence; an active-candidate change does not redirect them.
Already delivered messages remain historical copies: editing or swiping that
same turn in the WebUI does not rewrite them or automatically send its replacement.
Later supplementary turns still arrive as separate messages.

The adapter reads local conversation follower progress every second. Every five
seconds it checks for follower changes and reconciles pending questions, sharing
one addressed inbox read and one attention page per workspace. Turns and queued
inputs refresh when the local follower changes, when voice input needs mapping,
or every 60 seconds as a fallback. Advancing history pages continue on the next
pass, and restart reads history afresh. This keeps quiet historical rooms from
spending the shared API budget while retaining late background replies and
restoration recovery. Child questions remain independent of the parent's event
sequence. Commands still read current state, and every queued answer chunk keeps
its separate source/variant check immediately before sending.

If a followed conversation is no longer readable, the adapter stops following it,
removes its unsent content and pending controls, and explains how to continue with
`/new` or `/workspace list`. It never opens a replacement conversation implicitly.
Archive alone does not remove read access, so readable archived history can still
be delivered. Temporary connection, rate-limit or server failures preserve the
queue for retry. Questions wait for a successful pending-state refresh; replying
to a retired bot question reports that it expired rather than starting a new turn.
When a question becomes answerable in Telegram, the bot sends its prompt even if
it previously directed you to the rho CLI. Replying to either message answers the
same pending question.

Formal answers use ordinary Telegram messages with HTML formatting, converted
from Markdown. Headings, bold, emphasis, strikethrough, links, lists, quotes and
code are readable; tables become text rows and raw HTML remains literal text.
Long answers preserve their rendered text across chunks, including Chinese,
emoji and fenced code. A definite formatting rejection retries the same chunk
as plain text. This avoids the delayed live display observed with Telegram's
newer rich-message API in Web K. Preview text is
limited to 800 UTF-16 units and split at grapheme boundaries. Progress defaults
to at most once per second privately and once per four seconds in groups; all
topics share the group's message budget. Final answers and control feedback take
priority but still respect Telegram's `retry_after` flood wait, including after
a restart.

The default `stale_after` is 600 seconds and must be positive. Dated messages and
commands first received after this window are consumed without being executed.
An already saved pending update resumes after a restart while its message date
is still within the 24-hour input recovery window; current access is checked again.
An older unconfirmed request is not resubmitted. The bot reports the uncertainty
and asks you to inspect `/queue` or `/history` before sending it again.
Telegram itself keeps undelivered updates for at most 24 hours. Callback and draft-stop
updates have no event timestamp; the date on a callback's attached message is not
the click time. These controls instead require their exact still-valid owner.

The Agent's Nexus Store entry `rho.telegram/state` records the bot binding,
chat/topic mappings, memory anchors, pending input, consumption offset and delivery
receipts. It commits before an input is consumed or a formal message is sent.
The in-process cache is disposable; restart and every member reconnection read the database. Concurrent writes
use the entry's version and a conflict is surfaced rather than overwriting newer
state. If a write response is lost, the adapter checks the database for that exact
value. It never retries a mutation against a newly read version.

Disconnect, lost member credentials and a change of Agent profile stop the old
poller and conversation follower before a new worker starts. Each worker holds
the store client for its own credential lineage and rechecks the bot binding.
The old profile's offset, routes, pending input and delivery receipts remain in
that profile's store; a different profile never inherits them. While disconnected,
status reports `waiting_for_nexus` without the retired profile's cached state.

The bot token and deployment settings remain local
bootstrap configuration. Nexus unavailability pauses consumption and sending;
`rho telegram status` reports `waiting_for_nexus` when state cannot be read. The
Store value has Nexus's explicit 1 MiB snapshot bound: exceeding it is a visible
failure, never silent state truncation. An Agent already bound to one bot refuses
a different bot; use a different Agent for another bot. Nexus input recovery
reuses the original workspace, conversation, model and idempotency key. Nexus's
input receipt lasts 24 hours; recovery conservatively uses the original message
date and does not extend that window when `stale_after` is raised.
Do not delete the Telegram state to retry a
request.

A final Telegram POST whose response was lost may already have delivered its
message. Such deliveries are marked `uncertain` and are not resent automatically;
inspect `rho telegram status` and the conversation in rho's console. A sending
receipt left by a lost Nexus response is also surfaced as uncertain on the next
flush, without requiring a restart. A control
whose outcome is uncertain is also not blindly applied again to newer work.
Known rejections, transport uncertainty and successful delivery remain distinct.
Removing an allowed group prevents pending replies to that group immediately
and after restart. Removing or ignoring a user blocks future input while keeping
already accepted work and its replies. The private `/start` ID guidance remains
available to people not yet allowed; ignored users receive no guidance.

## Files, images and voice

Send a document (PDF, Office, spreadsheet, Markdown, code or archive), a photo,
or an image as a document, with an optional caption. Ordinary documents retain
their Nexus upload identity across retries and later turns. The model receives
an attachment reference and uses the selected Runner's `file_import` to download it
into working files, then `read` or `bash` and the prepared `workspace-tools`
guide to inspect it. Files are not automatically parsed or executed. A runner
without the needed document tooling reports that limit; the gateway does not
install tools on its host.

Send images with an optional caption. In a group,
mention the bot in the caption or reply to its message; private images can have
no caption. The selected text model must support image input to see the picture.
Nexus retains the original attachment and prepares the representation supported
by that model. Current Codex text models support PNG, JPEG and WebP inputs.

Set the top-level `image_model` to an available image-generation model to enable
rho's image tool. Generated images are sent directly to the originating chat or
topic after the text answer. Oversized photos and rejected photo formats fall
back to a document. The tool also edits images from local reference files or
recent pictures submitted in its conversation. It does not select pictures from
later messages. The model uses `file_publish` to send a generated PDF,
spreadsheet, document, code file or archive. It selects an existing working file;
the runner uploads it through Nexus's normal capture path and returns a
`resource_link`. A failed publication is an error, with no download link.
Telegram sends successful explicit file publications as documents and the
image tool's captures as images. Incidental `read`/`bash` captures and model
prose naming a filesystem path do not send a user-facing file.

The optional `telegram.transcription_model` accepts Telegram voice notes through
Nexus's transcription workload. A voice note is transcribed before it becomes a
conversation input; its caption, when present, accompanies the transcript. The
same requester's following requests stay in order, while control commands and
other requesters continue. Reply to the original media message or its receipt with
`/stop` to cancel that request's preparation, leaving later requests intact.
`/new`, `/resume` and a workspace switch discard that requester's media still
waiting for admission in this chat/topic. A conversation becoming archived or unreadable
also stops admission and reports how to recover. Ordinary music/audio documents
are not treated as voice instructions. Group observation records a voice marker
without starting a transcription call.
Media waiting for admission belongs to Telegram's queue: reply to it with `/stop`
to cancel that preparation. Nexus and WebUI Stop apply to work already admitted to
the conversation.

The optional `telegram.speech_model` enables `/voice`. The default is `off`;
`voice_only` speaks the answer to an actual voice input, and `all` speaks every
answer. These are separate model calls and may incur provider charges. Long
answers are spoken in order as several clips. Text is delivered independently,
so a speech failure leaves the readable answer available. The standard OpenAI
speech lane produces MP3, which Telegram accepts as a native voice message;
WAV and other non-voice formats are sent as documents. There is no local speech
engine or transcoding dependency.

Model references in the example require the corresponding provider to be
configured and enabled in Nexus. The Codex subscription covers its text and image
models; the OpenAI API speech lanes require separate OpenAI API credentials.
Omit unused media model settings. Provider keys remain in Nexus.

Telegram cloud file downloads are limited to 20 MB. Outgoing photos use the
10 MB photo limit; other supported media use the 50 MB document/voice limit.
The adapter bounds downloaded bytes even if Telegram omitted a size. Media
receipts retain upload IDs, original input identity and completed sends across
restarts, so a retry does not duplicate text or change the image on an accepted
input. Later unsent files and voice clips are subject to the same exact
turn/variant checks as text. See the Telegram API's
[getFile](https://core.telegram.org/bots/api#getfile),
[sendPhoto](https://core.telegram.org/bots/api#sendphoto) and
[sendVoice](https://core.telegram.org/bots/api#sendvoice) contracts.
If history cleanup has removed an attachment while retaining the answer, a
pending media delivery reports it as unavailable and allows other chats to
continue. Temporary download failures remain retryable.

## Ruby transport and rendering

The Bot API client uses `telegram-bot-ruby`'s raw `Api#call` with an HTTPX Faraday
adapter. Polling, sending and downloading own separate bounded connections. Redirects and
automatic retries are disabled. `Client#call(method, params, poll: false)` returns
the raw result; new Telegram fields do not depend on the gem's generated types.
`Client#close` cancels outstanding requests and closes these connections.

`Client::Refused` carries `code`, `description`, and optional `retry_after` for a
definite API rejection. `Client::Unavailable#ambiguous` means a delivery may have
occurred: do not automatically repeat a final message after a timeout, lost
response or server failure. Errors omit token-bearing URLs and upstream causes.
The runtime owns offset persistence and explicit recovery decisions.

`Render.chunks(text)` uses the pure-Ruby kramdown GFM parser and returns `formatted`
and `plain` payloads with identical visible text. The formatted payload is
`{text: html, parse_mode: "HTML"}` and contains only Telegram-supported tags.
Text and attributes are escaped; links allow HTTP, HTTPS and mailto. Raw HTML and
kramdown configuration extensions cannot become active markup. Images are shown
as their label and URL, without fetching them. No syntax-highlighting process or
JavaScript runtime is used.

Each chunk holds at most 4096 UTF-16 units of rendered text. Formatting and code
blocks close and reopen at chunk boundaries, so a long block remains complete.
A definite formatting rejection may fall back to that chunk's visible plain
text, without changing boundaries or repeating earlier chunks. Markdown syntax
is presentation rather than preserved source bytes. Commands, questions and
approval requests use `Render.chunks(text, plain: true)` to preserve their exact
text, including literal Markdown and tool arguments. `Render.preview(text)` is
capped at 800 UTF-16 units without splitting a grapheme cluster; complete messages
are never preview-truncated.

`RateLimit` only calculates when a send is due. `next_at`/`ready?` read the current
budget, `sent` records a send and `retry_after` applies Telegram's flood wait to
every priority. All topics in a group supply the same `chat_id`. Progress defaults
to once per second privately and once per four seconds in groups; ordinary
messages also respect a shared chat and bot budget. The runtime owns coalescing
and chooses final/control messages before pending progress.

Run `bundle exec rake` for the package gate and `bundle exec rake build` to build
the gem. Transport tests use a loopback fake with a synthetic token. They never
contact Telegram or load a real bot token from the environment. Local tests do
not establish Telegram client rendering, live flood quotas or real-network
behavior; those require an explicitly authorized test bot and chat.

## Database memory

Memory content stays in Nexus `MemoryDocument` / `MemoryDocumentVersion` rows.
The six model tools use logical file paths: `memory_read(path)`,
`memory_write(path, content)`, `memory_edit(path, old_text, new_text)`,
`memory_ls(path)`, `memory_grep(pattern, path)` and `memory_delete(path)`. These
operations do not create or modify files on the agent's machine. Filesystem tools
belong to the runner for coding and cowork-style work.

`/memory` uses the same database doors as `rho memory CONVERSATION_ID`:

- `/memory ls [PATH]` and `/memory read PATH` inspect notes.
- `/memory write PATH TEXT` replaces a document; `/memory delete PATH` removes it.
- `/memory edit {"path":"group/team.md","old_text":"old","new_text":"new"}` changes one exact match.
- `/memory grep PATTERN` searches the bound documents.

The bot owner's private chat keeps the ordinary conversation, workspace and user
roots. Group tasks bind `conversation/` to their own notes and `group/` to one
shared database Conversation per workspace and chat/topic. All requesters in that
room read the same shared notes; only owner-requested work may change `group/`.
Other requesters may write their own `conversation/` notes. An external person's
private chats bind `person/` to that person's shared database Conversation in the
current workspace, without reading the bot owner's `user/` notes. External chat
identities remain ingress speakers; no implicit Nexus Human account is created.

These anchors are ordinary, input-free Conversations unless the same Conversation
also holds passive group observation. They appear in ordinary conversation
management. Starting `/new` preserves the shared anchor. Different groups/topics,
workspaces and external people have different anchors. Notes about a person or
project can use subpaths such as `group/people/alice.md`; the path describes the
subject and does not create a new access scope. Injection, explicit tools,
preview and active participation share Nexus's binding resolver.

Ordinary requested turns use rho's shared memory policy: retain useful confirmed
facts and preferences, correct outdated claims, merge duplicates, and recall
relevant notes through the available memory tools. The model reads existing
content before changing it and reports a memory effect only after the tool
succeeds. Private information stays in its personal binding, and non-owner group
requests cannot write shared group memory. `/memory` remains available for direct
inspection and correction.

This policy is included in both the owner's ordinary assistant prompt and the
separate Telegram answering profile. It adds no background model call or scanner.
Passive observation and active participation remain tool-less and do not extract
group messages into memory. Deterministic tests cover prompt delivery and actual
memory-tool workflows; they do not establish live extraction or recall quality.
