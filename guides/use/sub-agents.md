# Agents, Bots and Subagent roles

The **Main Agent** is rho's persistent identity for Web conversations.
A **Bot** is a separate persistent identity with its own name, purpose,
welcome message and selected [Agent Preset](agent-presets.md). The Preset
owns instructions, model selection, fallback models and tools. Sharing a
Preset does not share conversation history or private memory. Your MCP connections
are available to your Main Agent and Bots by default; each selected Preset can
[turn off connections or tools](agent-presets.md#connect-nexus-mcp-tools).

Nexus holds each Bot as a named Agent under your account, with an
`@<name>` handle and no separate credential or executor address. The
**Bots** page owns each Bot's current conversation, history, Home Workspace and
channel settings. A Bot can use a shared [Telegram connection](telegram.md#connect-a-bot)
with one fixed private-chat, group or topic destination.

The Workspace owner sets each Bot's [messaging mode](../operate/workspaces-and-access.md#agent-messaging)
to **Public** or **Private**. Public accepts contact from every otherwise
eligible Agent; Private accepts only its allowed senders and itself.
Each Bot has its own setting, including Bots served by the same rho instance.

## Create or edit a Bot

1. Open **Bots** in the sidebar and select **New bot**, or open an
   existing Bot's **Settings**.
2. Enter its name, display name and description. The name becomes its
   handle and cannot be changed after creation.
3. Choose **Personal** or **External requests** as its purpose.
4. Select an **Agent Preset**. A new Bot starts with the **New Bots**
   default selected in **Settings › Agent Presets**.
5. Leave **Subagent** on to allow background workers, or turn it off to make the Bot
   complete work directly in its main conversation. It starts on for a new Bot.
6. Choose a default, custom or disabled **Introduction**, then select **Create bot** or **Save**.
7. Save a **Home Workspace** before creating its first conversation. Configure its
   channel target on the same page.

**Edit selected Preset** opens that Preset's configuration. Changes there
apply to new work for every identity using it. Already accepted work
keeps its captured configuration. The Bot form contains no independent
prompt, model or tool settings. Its model and tool count on the list are
read-only projections of its effective configuration.

Bots always keep Code mode off. A Bot's own **Subagent** setting applies to future
inputs in its current, new, resumed and forked conversations. Main's global defaults
and conversation buttons do not change it. With Subagent off the Bot waits for the
work it performs directly and then reports the result. Existing workers can still
finish and report; their captured tools, including Code mode, remain unchanged.

The introduction is static text stored with the Bot. The default uses its name
and description; custom text replaces it, and None disables it. Editing it does
not send a message or make a model request.

Choose Main's Preset in **Settings › Agent Presets › Default Presets**; **Settings › Defaults** owns rho's global initial
model and ordered fallback list. The main Agent has no separate built-in
prompt replacement editor.

A Bot with no effective model is marked **No model** and cannot answer requests. Edit its Preset or the global model setting to supply
one. Model recovery uses the execution's captured ordered candidates and
constraints; the global initial model is not an implicit fallback.
A plugin-owned Agent is marked **Plugin** and uses the plugin's workflow.

## Duplicate or remove a Bot

**Duplicate** creates a fresh identity with the same Preset reference and
welcome message and Subagent setting. Choose a new name and purpose. It copies no memory,
conversations, Home Workspace, Telegram credentials or chat bindings.

**Remove bot** stops its running work after confirmation. Its conversations
stay readable but cannot continue, and its name remains reserved. The
selected Preset remains available. The main Agent cannot be removed here.
Import and export belong to [Presets](agent-presets.md#import-and-export),
so a configuration file never creates or overwrites a Bot identity.

## Purpose and memory

Choose **Personal** for a Bot that serves you, or **External requests** for one that serves admitted visitors. This purpose is separate from the Workspace's Public/Private messaging setting: purpose limits what the Bot can use, while messaging controls which Agents may contact it.

An external Bot can write `conversation/` and `speaker/` memory and read `workspace/` knowledge. It has no Agent-private memory, Human-owned memory, owner persona or ordinary Local-environment tools. It can use the owner's MCP connections selected by its Preset, including tools served through rho.mcp. Its conversation tools and history stay within its current conversation and descendants. It delegates through the published Subagent roles, with the same external-purpose limits applied to every child. Separate peer messages may address itself or an eligible external Bot from the same rho instance using the exact UUID in the send tool. Workspace access and messaging rules still apply. An explicitly granted communication link also permits messages to its fixed peer; it grants no peer history access, Memory access or request dispatch.

External Bots retain a rules-based approval stage and all matching **deny** and **ask**
rules. With a selected mode of **ask**, every selected MCP call requires approval;
an allow rule does not override that requirement. With **rules**, authored allows
apply to the selected MCP callables with their argument and origin constraints.
With **bypass**, selected MCP calls are allowed unless a deny or ask rule matches.
Private session grants created by `rho approve --always` are not inherited by
external Bots or their Subagents.

A group Bot shares one current conversation and history among all admitted
participants. Its owner controls new/resume and other shared lifecycle changes.
All Bots use the same Speaker memory mechanism. `speaker/` holds one Bot's notes about one person; another Bot has separate notes about that person. A private Bot's owner is simply its usual Speaker. Subagent work retains attribution but does not automatically read that Speaker's or the owner's long-term notes.

An external identity cannot become private later. Use **Duplicate**, give the copy a new name, and choose its purpose. The copy receives a new identity and retains its Preset reference, welcome message and Subagent setting; it has no copied memory, conversations, Home Workspace, Telegram credentials or chat bindings. A private Bot can become external; new work uses the restricted policy, while accepted work retains the policy it captured.

## Commands

```sh
rho agents                     # list persistent Bots and their effective model
rho agents duplicate reviewer personal-reviewer owner
rho agents rm reviewer         # stop and remove this Bot; its name stays reserved
rho bots current reviewer      # select its current conversation, creating one if absent
rho bots new reviewer          # create and select a conversation in its Home Workspace
rho bots history reviewer      # conversation UUIDs and their recorded Workspace UUIDs
rho bots history reviewer --after CURSOR --limit 20
rho bots resume reviewer CONVERSATION_ID --workspace WORKSPACE_ID
```

A Bot selector is its name, `@handle` or public UUID. Set its Home Workspace
in the Bot's settings before opening its first conversation. Resume takes the
Workspace printed with that history row, even after the Bot's Home changes.
New and Resume leave accepted work running in its original conversation. See
[Bot conversations](conversations.md#bot-conversations) for their archive behavior.

Each switching command prints an operation ID before sending the request.
After an interrupted or uncertain result, retry the same command with
`--operation-id ID`; reusing that ID does not perform the switch again.
If another command has since selected a different conversation, the output
shows both the original selection and the current one. History only reads.

A plugin-provided Agent is managed by its plugin. The Bot editor does not change it.

## Publish and use Subagent roles

Open **Settings › Subagent roles**. The initial roles are **worker**,
**planner**, **explorer** and **reviewer**. Each publication names an existing
Preset and adds the role name and description used to select it. **Edit Preset**
opens its shared configuration; the role editor has no second prompt, model or
tool configuration. Unpublishing removes a role from future delegation catalogs
without deleting its Preset or interrupting already accepted work.

The Main Agent and Bots select an exact role when delegating. Ordinary work uses
**worker**; a later review is a separate **reviewer** task with the implementation
result and relevant evidence in its brief. Main Agent and Bot identities cannot
be used as spawn targets, including through a direct UUID or handle.

A Subagent starts a child Conversation with the task brief and the role's
captured configuration. It uses the caller's identity without creating another
User. Its memory is limited to its own Conversation and its conversation tools
to that Conversation and descendants. It receives neither the parent's full
transcript nor owner or Speaker notes automatically; include the context it
needs in the brief. The selected role may use a different subset of the
installation's tools from its parent, within the same Bot-purpose limits.
MCP tools inherit the direct parent's captured selection. The role Preset can
turn off more connections or tools; neither it nor a nested child can restore a
tool absent from its direct parent. Publishing a role creates no additional
connection authority.

**Follow the initiating conversation** takes the calling task's current model,
including any completed fallback. **Use the Preset's initial model** takes that
Preset's resolved default. A model explicitly requested for one delegation
overrides either choice for that task; it does not edit the Preset. The role's
fallback list remains independent. Later unqualified messages to the child use
the child's own current model and captured configuration. Those defaults also
survive a fork or cleanup of the parent's execution details.

## Messages, requests and stopping work

Use `send_message` for an ordinary message and `request` for an assignment whose
result must be tracked. A received message or request is labelled separately
from your own words in the conversation. A later exchange with the same worker
does not replace the original assignment's result.

Open **Background tasks** to inspect work and active communication links.
**Close communication** closes that link to messages. It does not block directly
addressed requests or stop either Conversation. Accepted requests retain their
original result.
Use the Stop beside a task to cancel that task's branch on its original Run,
or the Stop beside a Subagent to stop that child Conversation.
**Stop all work** stops work in the open Conversation. These controls have
different scopes; closing a link does not stop either Conversation.

## Read work in progress

The agent can inspect a readable conversation while its Bot or sub-agent is
still working. `status` reports whether the conversation is busy;
`session_read` reads its context. With `include_execution: true`, it also returns
the current execution's state, persisted intermediate text and tool output
previews, including tools that have not finished:

```json
{"session_id":"<worker conversation UUID>","include_execution":true,"limit":1}
```

The worker UUID comes from `spawn`. The latest returned turn is inspected by
default; `around_turn_id` selects a particular turn and keeps later execution
pages attached to it. A later read observes newly persisted progress. This
does not stop the worker or wait for it to finish. A Bot needs `session_read`
in its selected tools, and its usual workspace and conversation restrictions
still apply; external Bots remain within their conversation and descendants.

This read is separate from Side's fixed reference snapshot. It provides bounded
previews of recorded progress, with pagination for older model rounds; live
token streaming remains on the existing feeds. See the [history reference](../reference/agent-api/conversation-history.md#include-execution-progress)
for limits, regeneration candidates and retained execution details.

## Where this comes from

A named Agent is a kernel resource ([Named Agents](../reference/agent-api/profile-agents.md)).
rho owns the product's Main Agent, Bot and Preset distinctions and compiles
the selected Preset into Nexus agent configurations. Nexus retains
identity, execution, memory and permission authority.
