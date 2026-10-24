# Telegram

The Telegram extension runs inside rho's daemon and polls the Bot API. No Node service or inbound webhook server is needed. The daemon only dials out.

## Connect a Bot

A **Connection** owns a physical Telegram bot account, its token and polling. A rho **Bot** chooses that connection and one fixed destination: a private chat, group or forum topic. Several Bots can share a connection when their destinations differ. A connection and destination pair can belong to only one Bot.

1. Create a Telegram bot with [BotFather](https://core.telegram.org/bots/features#botfather) and keep its token.
2. Enable **Telegram** on rho's **Plugins** page.
3. Open **Settings → Connections**, choose **New connection**, give it a name and save its token. The Telegram plugin's settings open the same connection editor.
4. Open **Bots**, create a Bot and select its Agent Preset. The Preset supplies its model and instructions.
5. On the Bot's page, choose and save its **Home Workspace**.
6. Under **Telegram target**, choose the shared connection, enter the numeric **Chat ID** and **Bot owner user ID**, optionally enter a **Topic ID**, and enable the target. A private chat uses a positive chat ID; a group uses a negative chat ID. A topic is a positive ID within that group.

The Bot uses rho's existing Nexus connection. Main is the local assistant and has no implicit Telegram target. Messages outside every configured target are ignored; an owner's separate private chat is not an extra management route for a group Bot.

For terminal setup, run `rho setup telegram` (or `./cybros setup telegram` in the Docker stack). Choose or create a Connection, confirm the Telegram account, then choose an existing Bot with a Home Workspace and confirm its chat/topic and owner IDs. If the daemon is offline, setup saves only the Connection. Once rho is running, `rho setup telegram --finish` binds a saved enabled Connection without asking for its token again. Setup does not discover chat IDs, poll updates or send messages.

The token is a write-only setting stored privately in rho's `settings.json`. The page and control API show only whether one is saved. A blank token field keeps it; the explicit clear control removes it. It has no environment-variable fallback. Keep tokens out of command arguments and source control. Use one polling daemon per physical Telegram bot, and remove any existing Telegram webhook first.

The connection switch stops that connection's polling. The switch on **Plugins** stops every Telegram connection. Each Bot's target switch controls that Bot independently.

## Purpose, access and memory

A Personal Bot accepts only its configured owner's private messages. An External requests Bot also admits people and groups selected in its **People and groups** settings. Group admission requires both the chat and the sender to be allowed; ignored users remain excluded. Configure the initial group access in the browser. Once admitted, the configured owner can use `/access` and `/ignore` in that fixed destination; being a Telegram group administrator does not confer Bot management permission.

Everyone admitted to a group Bot shares its current conversation and history. Speaker memory is still per person and per Bot: one person's notes are separate from another person's, and the same person has separate notes with another Bot. See [Purpose and memory](sub-agents.md#purpose-and-memory).

## Current conversation and history

Each Bot has one current conversation across its channel and browser controls. Open the Bot's name in the sidebar to view it; use its settings button for current conversation, history, Home and channel settings. Reading the Bot's page does not create a conversation or make a model request.

- **New conversation** and `/new` create a new conversation in the latest Home Workspace and select it. They do not stop accepted work. Use **Stop** or a task-specific `/stop` when needed.
- **Resume** and `/resume ID` restore a saved conversation as current. They retain the resumed conversation's original workspace; a separate conversation restore step is unnecessary.
- Changing Home affects future new conversations. Existing conversations, resumed history and scheduled work keep their original workspaces. Clearing Home prevents new conversations while existing work remains available.
- The Bot owner controls these shared switches. Admitted group members share history, but task controls and answers to pending questions remain restricted to that task's requester or the owner.

New and Resume archive the replaced conversation, with an [exception for an already archived Workspace](conversations.md#bot-conversations).

Current and historical Bot conversations are read-only in the WebUI except for **Stop**. They remain in the Bot's history after a target is disabled or changed. Main's conversation list contains its ordinary conversations separately.

The Bot's **Introduction** can use its name and description, use custom static text, or be disabled. It does not require a model call.

## Messages and controls

Private messages to the configured target continue its current conversation. In a group, mention the bot or reply to a known task or answer. Files and voice use the same conversation; questions, approvals and controls return to the saved route. Ordinary text within the **Message grouping delay** is combined per sender; commands bypass the window.

- `/sessions`, `/search` and `/history` inspect this Bot's saved conversations and current history.
- `/workspace use ID` or `/workspace create NAME` changes Home and starts a new current conversation; these are owner actions.
- `/job` manages [schedules](schedules.md). Existing jobs retain their original conversation and route after a switch.
- `/codemode` explains that Bots do not use Code Mode. The Bot's **Subagent** setting defaults to on; turn it off in Bot settings to complete work directly in its current conversation. Changes apply to later requests, while accepted work can still finish and return its result.
- `/observe on|off` and `/mode assistant|active` let the owner configure background observation and optional participation for a group or topic. Observation writes attributed messages to the Bot's current conversation without a model call. Active participation uses the Bot's model and captured conversation and Speaker context, without tools.

Late results keep the original conversation and destination after `/new`. If an active-participation reply was already sent when its source conversation became archived, the adapter preserves its delivery receipt even when appending that reply to archived history is refused. It neither appends to the new current conversation nor sends the reply again.

## Delegated answers

Bots delegate through published [Subagent roles](sub-agents.md). Explicit peer messages can separately reach an eligible Bot. When that Bot has a Telegram connection, its canonical result uses that connection and an already known destination that admits the requester. It does not infer a destination from the front Bot. Missing admission or destination reports delivery unavailable; a Bot without Telegram uses the ordinary parent callback. The front Bot can still summarize the outcome in its own conversation.

Cross-Bot delivery retains one durable receipt across restarts. An ambiguous send requires recovery instead of an automatic resend.

## Voice and status

Select transcription and speech models under the Bot's **Messages** card, from the account's usable `transcription` and `speech_generation` models. A saved model that is no longer offered stays selectable as unavailable.

The extension runs inside rho. Its tools use Local or an explicitly selected eligible Runner. `rho telegram status` (or `./cybros rho telegram status`) reports shared connection status without exposing tokens.
