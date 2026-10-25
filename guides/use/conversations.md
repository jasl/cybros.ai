# Conversations

rho works through conversations stored in Nexus. A selected model answers, and a runner supplies working files and tools. This page covers the browser page; [Telegram](telegram.md), [editors](editors-acp.md) and the [terminal](terminal-requests.md) are other entry points to the same conversations.

## Entry points

| Entry point | Use it for |
| --- | --- |
| Browser — the stack's rho URL, or `rho console --open` on a host | Settings, Telegram setup, ongoing conversations, questions, approvals, execution controls and schedules |
| Telegram | Ongoing conversations, files, voice and controls from an allowed chat |
| Editor through ACP | Conversations inside a compatible editor |
| Terminal — `rho run "..."` | One noninteractive request with output and an exit code |

## Start and continue

Open rho and choose **Connect to Nexus** when no browser session exists. Later logins preserve the runtime's Agent connection; signing out ends only your browser session.

Create a conversation with an available model and runner. The runner uses its default working directory. The model picker starts at **Automatic**, which lets rho use the agent's [Preset](agent-presets.md). Send the first request and follow the answer and tool activity.

Choosing a specific model pins that provider and model, even when it matches the default. Reopening a conversation restores its original model choice; **Last response** in the model menu shows the route that actually answered, which can differ after fallback. Leaving the picker untouched preserves the conversation's model intent. Choose **Automatic** to clear an override on the next message and use the current Preset again.

- Sending another message **while work is running** steers the current reply at its next model boundary by default.
- Sending **when idle** starts a new turn.
- Reopen a saved conversation to continue from its durable history. Rename, archive and restore controls organize the list; there is no delete.
- **Conversations** lists the Main Agent's ordinary conversations in the selected workspace. Its archived view uses the same scope. Bot history and child executions stay outside this list.
- **Bots** is separate. A Bot's sidebar name opens its unique current conversation; its settings button opens identity, Home, channel target and history controls.


The composer offers three ways to deliver a message to running work: **steer** (the default) hands it to the next model boundary of the running reply; **queue** holds it for a later turn; **Send now** inserts a model boundary immediately while long tools keep running and deliver their results later.

**Ctrl+Enter** or **Cmd+Enter** sends normally in a new or idle conversation and uses **Send now** during running work. With an empty composer, it promotes the latest waiting steer instead of sending its words again.

Scroll upward to read earlier messages without following new output. **Jump to latest** returns to the bottom and resumes following.

## Conversation titles

After the first request is accepted in a new conversation, rho generates a short
title from your input in the background. The title follows your input's language.
Title generation keeps the conversation's access restrictions.
Later messages do not generate another title, and a manual rename takes
precedence. A title-generation failure leaves the conversation and its reply
available; you can rename it yourself.

Choose **Settings › Defaults › Conversation title model**:

| Choice | Behavior |
| --- | --- |
| Follow current model | Use the model selected for the first request; this is the default |
| None | Turn automatic titles off |
| A specific model | Use that available text model for titles |

The choice applies to future first submissions. It does not rename existing
conversations or change the model answering your messages.

## Execution controls

- **Questions and approvals** appear beside the work. Answer or decide the specific pending item there; see [Approvals and questions](approvals-and-questions.md).
- **Pause / resume** suspend and continue execution.
- A **failed step** can be retried or abandoned.
- **Stop** stops execution, including background work derived from the reply after it was delivered. Closing the browser or switching conversations only detaches the viewer.
- **Regenerate** produces a new candidate answer for a turn and permanently stops the replaced candidate's unfinished work. Selecting an older candidate never revives its work.

## Drafts and uncertain sends

A failed or uncertain send keeps its draft and request identity for a manual retry on that page. Reloading discards this pending state, so inspect the history before resubmitting an uncertain message after a reload.

## Retention

Old conversation text stays readable and searchable after Nexus's retention policy removes execution details; the page labels missing details. Administrators set the window; see [Retention, usage and budgets](../operate/retention-usage-budgets.md).

## Bot conversations

A [Bot](sub-agents.md) has one current conversation. Its page shows current and historical conversations, including archived rows, across their original workspaces. Open a history row to read it; **Resume** makes it current again.

**New conversation** immediately creates a conversation in the Bot's Home Workspace and selects it. New and Resume archive the replaced conversation unless its Workspace is already archived. In that case, the switch leaves the previous conversation unchanged. After restoring that Workspace, use **Resume** to select the old conversation before sending new input. Other archive failures prevent the switch from completing.

Switching does not stop accepted work. Old work and late results stay with their original conversation; use **Stop** explicitly when needed. Changing Home affects only future new conversations.

The Bot settings include **Subagent**, which starts on. Turning it off makes future
requests execute directly in the main Bot conversation. This also applies after
New, Resume and Fork. Bots always keep Code mode off; existing workers retain
their captured tools and can finish normally.

Bot conversations are read-only in the browser except for **Stop**, including history that is no longer bound to a channel. Continue messages and approvals in the Bot's [Telegram target](telegram.md). Attachments remain readable. The Bot's introduction is static text and does not start a model request.

## Browser access

After pairing, **Settings › General › Opening this page** decides what a browser needs before it can use rho:

| Choice | Behavior |
| --- | --- |
| Automatic | Opens by itself on this machine; asks for a Nexus sign-in from other machines |
| Open | Opens for anyone who reaches the page |
| Nexus sign-in | Always asks for a Nexus sign-in |
| Unlock password | Asks for rho's own password, stored as a salted digest |

A page admitted by the gate holds no Nexus account; Settings names how it got in and offers **Sign in with Nexus** for actions that need one. Changing or removing the password ends every other unlocked browser.

## Open a terminal

Enable the **Terminal** plugin on the rho serving this browser page to show
**Terminals** in the conversation header and tool chooser. Select a Runner, then
choose **New terminal**. The selected Runner must also have the
[Terminal plugin configured](../runners/deploy.md#interactive-terminals).
The shell opens in that Runner's default work directory, independently of the
conversation's environment. Each terminal has its own Run; no model call is needed.

Each new shell opens and selects its own terminal tab. Use the **New tab** (+) button
to open the tool chooser; switching tabs keeps each shell and its output in place.
Pending approval, startup failures and ended shells appear in their own tab. The tab's **×** stops
that terminal's Run, shell and ordinary shell jobs, then closes the tab. If stopping
fails, the tab stays open with an error so you can retry. Hiding the side panel or
switching conversations leaves shells running. Open **Terminals**, choose **Refresh**,
and select a running shell to reconnect; **Older terminals** reads earlier records from Nexus. Conversation Stop does not stop
these independent terminals. Deliberately disowned jobs or programs that create a
new session are outside the shell's job ownership.

Disabling the Terminal plugin removes its browser controls and tabs without
stopping accepted shells. Re-enable it and select a running shell to reconnect.

On narrow screens, a compact bottom row provides Esc, Tab, Ctrl and arrow keys.
Tap Ctrl, then type a letter to send a combination such as Ctrl+C or Ctrl+D.

## Attach to an interactive terminal

When an installed Runner tool owns a live PTY and publishes the
[terminal stream protocol](../reference/agent-api/task-realtime.md#output-recovery),
open its tool call in the conversation activity, then choose **Open terminal**.
This attaches to that existing task; it does not launch a shell or turn an ordinary
`bash` call into an interactive terminal. The screen and PTY resize to fit the panel.

A banner appears during connection, automatic reconnection and permission pauses.
Typing is disabled while interaction is unavailable. Reconnection keeps the original
PTY and task; input is never replayed. Retained output resumes from the last received
byte. A banner confirms reconnection. If some output cannot be restored, the viewer
clears its screen and scrollback and explains this in a banner. The shell, environment
variables and working directory are preserved; subsequent output appears on the cleared
screen.

The input status distinguishes Runner receipt from bytes written to the terminal.
A successful write does not confirm command completion. If the connection or
permission is lost before confirmation, delivery is unknown: input may already
have taken effect and will not be resent. Unsent keyboard batches are discarded.

Closing the side panel detaches the viewer. **Stop terminal** cancels the original
branch task. A mainline task requires Conversation Stop; the panel reports that
restriction instead of canceling other work. Conversation Stop retains its ordinary
ownership of the execution. If Stop cannot be confirmed, the panel says so and lets
you try again.
