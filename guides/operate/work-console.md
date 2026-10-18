# Inspect and recover work

Use the Nexus browser console to find work you can read, inspect its history,
and resolve approvals, questions or failed Tasks. Sign in with your Human
account, then use the **Work** section of the sidebar.

## Read Overview

The main entries are **Overview**, **Connect an Agent**, **Agents** and
**Workspaces**. Settings, administration and other inspection pages are secondary;
**Runners** provides connection guidance and management of your execution addresses.

Overview shows managed Agent identities and browsable Workspaces, plus model
calls, recorded tokens and known cost for readable Conversations in the exact
last seven days. It takes one window from seven days before the update time up
to, but excluding, that time. This is not a total for standalone Runs or
InferenceRequests. Unknown cost is marked separately; absent token fields do
not prove zero usage. Account cost units apply to the known subtotal.

The short attention list links to Tasks you can currently act on. Recent work
shows at most five readable Conversations or standalone Runs. These current
navigation lists are independent of the receipt window. An empty installation
offers Agent connection and Workspace creation; only an administrator sees the
model configuration entry when needed.

## Find a Conversation

Open **Workspaces**, select one, then **Work → Conversations** to browse root
Conversations by recent activity. Filter by default answering Agent or archive
state. Keyword search stays within this Workspace. A text match opens the exact answer candidate and field that
matched, even if another candidate is now selected. **Continue reading** loads
the next bounded part of that field; title matches open the Conversation.
The excerpt identifies a starting position and may not contain every search term.

Open a Conversation to read its inputs and answer candidates. Use the history
navigation to read older or newer Turns, and the candidate list to inspect an
alternative answer. Related links open readable children, Sides and branches.
Each linked source and Run is checked independently against your current access.
Text supports Markdown tables, lists, links and code blocks, with code copying
and an expandable original. External images are not loaded from Markdown;
uploaded attachments keep their separate authenticated previews.
Markup that exceeds the renderer's nesting limits appears as escaped original
text, keeping the result readable and copyable.

Files and image previews use your browser Session. **Download diagnostics** downloads the
Conversation as compressed JSON Lines; see the
[export reference](../reference/agent-api/conversation-export.md) for coverage,
retention and partial-export behavior. To inspect or cancel an accepted input,
follow [Read and cancel Conversation inputs](read-conversation-inputs.md).
To rename, archive or browse saved candidates and branches, follow
[Organize a Conversation](organize-conversation.md).
For connection and first work, use [Connect an Agent](connect-agent.md). To change a cost limit and recover its failed
work, follow [Recover a Conversation cost limit](recover-conversation-cost.md).

## Stop Conversation work

Open the Conversation, choose **Stop conversation work**, review the
confirmation, then submit. This requires full Conversation access and a writable
Workspace. An archived Conversation still offers the action, including when no
current Run is shown.

The command stops execution already belonging to the Conversation when you
submit: the current reply or regeneration, earlier turns' background work, and
their child requests and undelivered follow-up replies. Later independent work
in a reused child Conversation is preserved. Stopping a child does not stop its
parent. The [stop contract](../reference/agent-api/conversation-turns.md#stop-the-conversation)
defines which derived work belongs to the request.

Ordinary queued inputs remain and can start new execution after the stop.
Schedules keep their current state and settings. Published answers and completed
external effects are not undone.

After acceptance, you return to the same Conversation history location. The
message confirms that the stop request was accepted; work may still be stopping.
Read the answer candidate's status for a reply without a Run. When a Run exists,
use **Inspect run** on that candidate, including an older candidate in
**Candidate versions**, to inspect its current execution state. Use **Refresh**
to read the latest state if needed.

A completed answer keeps its content and completed status when its remaining
background work or result delivery is stopped. That status does not prove that
all derived work or external processes have ended. If nothing remains to stop,
the confirmation page reports that result instead of acceptance; return to the
Conversation to inspect its current state.

## Inspect a Run

Open **Workspaces → Work → Runs**, or follow an execution from its Conversation.
Filter by status, attention, creation time or Run kind. Creation
time uses an inclusive start and exclusive end. Workspace lists default to standalone Runs;
select all kinds to include Conversation Runs.

A Runner's **Related readable runs** opens `/runners/{public_id}/runs`. This list
stays scoped to that managed address when filtering, paging or resetting. Association
comes from retained Task targets or current claimants, not the Conversation's default
Runner or a complete execution history. A Run may involve several Runners; its running
status does not prove that any one Runner is busy. Removed execution details no longer
supply an association. Your current Workspace and Conversation access still applies.
There is no global HTML `/runs` list; canonical `/runs/{public_id}` details remain available.

A Run page presents its state, errors and recent result previews. Expand the
captured configuration when needed, or follow Transcript, Graph or Tasks for
execution details. The current Agent declaration link is read-only. Open a Task to inspect its inputs,
output and available decisions. Captured output files have download links and,
for supported types, preview links. Names, types and sizes come from the stored
files. Download access is checked again when you open the link. Execution detail that retention has removed is
shown as unavailable; retained Conversation text and cumulative usage remain
readable. See [Retention, usage and budgets](retention-usage-budgets.md).

The console refreshes active work through its event subscription. If that
connection is interrupted, the page shows its connection state and refreshes
again after reconnecting. Task commands always check current state when submitted.
For an ordinary Conversation Run, open **Text corrections** to inspect its
waiting corrections and cancel eligible items. Applications and SDKs submit or
advance corrections. Follow
[Inspect running corrections](inspect-running-corrections.md) for timing and result evidence.

## Resolve attention

1. Open **Needs attention** and select a Workspace if needed.
2. Choose **I can act** for work you can change, or **Work I can read** for
   readable work, including decisions another member must make.
   Bounded request summaries help identify each item. Effective waiting time
   freezes during execution pauses; failed Tasks show time since failure.
3. Open a Task. Review the proposed tool operation before approving or denying
   it, or answer the question shown on the page.
4. For an unresolved failed Task, inspect the failure before choosing an
   available retry or abandon action. The Run page also offers pause, resume
   and stop when your access and the Run's current state permit them.

Overview and **Needs attention** share the existing actionable Task query.
The Run attention filter includes the broader set of Runs with an attention
reason; **Inspect other blocked runs** opens that set at `/attention/runs`.
Workspace filters and pagination preserve the attention condition. The list includes
both kinds of Run and read-only work without granting recovery authority. The
[attention reference](../reference/agent-api/attention.md) defines the queue.

## Recover part of a Run

Open a Task and use **Cancel branch** to request cancellation of the unfinished
work that branch owns. An already completed launching Task can still own active
work. The mainline and work outside the branch remain, and completed external
effects are kept. Their execution still follows the Run's pause and attention
state. Selecting a spawn waiting Task cancels only its short wait; selecting
the launching Task follows that spawn's lifetime and completion ownership.

Confirm the request, then inspect the latest state. Running model work can take
a moment to settle after cancellation is accepted. To stop the entire Run, use
**Stop**. To resolve an existing failure, use its available retry or abandon
action.

For a queued model Task, **Compact context** requests a summary of its history
when the Task's compaction policy allows it. This can consume model tokens and
resets the Task's prompt cache. If it has no history to summarize, the command
explains that without creating new work. A running Task cannot be compacted;
a failed Task must first be retried.

After acceptance, **View current compaction step** opens the current hook or
summary. Return to the original Task to follow the latest step after a hook
finishes or delegated compaction falls back to a model summary. Reopening the
original Task preserves this navigation. The page calls a summary usable only
when it completed with a successful, nonempty result; inspect the step for
errors and available recovery actions.

A paused Run stays paused after accepting compaction. Choose **Resume** to
execute its remaining work. Compaction can release a Run's attention hold, but
other unresolved failures can hold it again and still need their own recovery.

## Access and browser sessions

Work pages use the signed-in Human's existing browser Session. Forms carry
Rails CSRF protection; an API token is not a browser login. If the Session
expires, sign in again and return to the requested page. A command interrupted
by login is not replayed automatically.

Workspace and Conversation access apply to every reader and command. Archived
Workspaces remain readable but cannot be changed. A read-only Conversation
permits inspection and export but grants no Run or Task control. Hidden or
deleted resources are absent. Being an account owner or administrator does not
grant access to another member's work content.

Use a Workspace's **Work** section for Conversations, Runs and Schedules,
**Data** for persistent content, and **Settings** for access and lifecycle.
The Workspace owner manages its settings. **Administration → Usage** is a
separate account-wide aggregate summary. Its download accepts provider, model,
workload and attempt-status filters; it has no member activity or content drilldowns.

## Usage and downloads

**Work usage**, an Agent's **Work report**, and **Administration → Usage** show
one rolling seven-day summary, updated when the page is requested. Dates and
model filters do not change that summary. **Export usage** selects a separate
file's exact UTC window (up to 90 days), model filters, grouping and ranking.

Work usage covers receipts attributed to currently readable Conversations;
it is not a personal bill or a total for standalone Runs and InferenceRequests.
Known costs retain the Account unit. Missing amounts stay unknown, and a
recorded zero remains distinct from no amount evidence. The Agent report
filters receipts by their captured consumer; managing an Agent grants no
additional content access.

**Download diagnostics** on a Run includes its retained execution and model
attempts. **Download Workspace data** on the Workspace Data page includes
current permitted Memory, Store and character documents. See
[Export retained data](export-data.md) for file coverage and completion checks.
Online approval, errors, stopping and recovery remain available independently
of downloads. The programmatic [work analysis](../reference/agent-api/work-analysis.md)
and [Account analysis](../reference/platform-api/admin-model-usage.md#read-an-analysis)
keep their existing filtering and metric contracts.

## Next

- [Workspaces and access](workspaces-and-access.md)
- [Connect and inspect an Agent](connect-agent.md)
- [Usage and cost](../build/usage-and-cost.md)
- [Errors and recovery](../build/errors-and-recovery.md)
