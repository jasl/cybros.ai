# Export retained data

Download retained evidence from the Nexus browser console when you need to
inspect work outside the page. Sign in as a Human with the same access needed
to read the resource. These downloads do not create an archive job or retain
another copy on the server.

## Download usage

1. Open **Work usage** from Overview or a Workspace, or **Work report** from an Agent.
2. In **Export usage**, choose an exact UTC window, up to 90 days.
3. Optionally filter provider, catalog model, workload or attempt status. Choose
   the grouping, ranking and number of displayed groups in the file summary.
4. Select **Download report**. The page's seven-day summary does not change.

The gzip JSON Lines file uses format `nexus.work.usage`, version `1`. Its opening
record has export time, scope, Workspace/Agent public UUIDs when selected,
filters and retention limits. A `summary` record contains the existing
[work analysis](../reference/agent-api/work-analysis.md) projection, including
exact `from` and `to`, Account cost unit, known amounts, missing amount samples,
latency samples and omitted-group totals. `usage` records contain every matching
retained receipt's public usage, timing, Conversation and Workspace attribution.
The Top N limit bounds summary groups, not the number of exported receipts.

Receipts use `recorded_at` in `[from, to)`. A Workspace or Agent scope does not
expand the downloading Human's current Conversation access. Removed or concealed
Conversations contribute no receipts even when the receipt itself still exists.
Agent usage selects the captured consumer. The Run summary uses Run creation
time, and model filters do not narrow that separate cohort. Retained Task counts
are not lifetime activity totals; collected execution is identified in the
summary. The file contains no payer identity, balance or Agent-private documents.

Account administrators instead use **Administration → Usage**. Its download
format is `nexus.account.model_usage`, version `1`, with an Account public UUID,
filters and an [aggregate analysis](../reference/platform-api/admin-model-usage.md#read-an-analysis)
summary. It has no individual receipt, Conversation, Workspace, Run or member
activity records. Member, payer, billing-subject and Workspace selectors are
refused. Account administration grants no additional content access.

## Download Run diagnostics

Open a readable Run and select **Download diagnostics**. The file is named
`run-{public_id}.jsonl.gz`, format `nexus.run.diagnostic`, version `1`.

| Record | Retained material |
| --- | --- |
| `export` | Export time, Run/Workspace UUIDs, scope and retention limits |
| `run` | Public Run summary and execution-detail collection marker |
| `task` | Task detail, including input, output, errors and public approval facts |
| `graph_node`, `graph_edge` | Task-key graph projections |
| `request` | Selected Task's sealed semantic request |
| `steer` | Retained Task steer entries |
| `model_invocation` | Model, status, failure and timestamps for each retained Run-owned invocation |
| `model_content` | Request, response, display reasoning and tool-call entries by role and position |
| `attempt` | Public attempt UUID, ordinal, status, admission shape and start/end times |
| `usage` | Public receipts attached to retained invocations |
| `file` | Bound upload metadata and its authenticated bytes path |
| `input` | Standalone Run's current waiting-room Inputs |
| `execution_unavailable` | Execution detail is pruned or became unavailable during reading |
| `end` | Completion time and record counts |

Attachments remain on their authenticated download paths; the archive does not
read their bytes or copy a Runner's local files. Tool results also retain their
ordinary resource links. Native reasoning replay material, provider credentials,
claim tokens, resolution tokens and internal database IDs are not exported.
Opaque application content keeps its recorded values.

The export includes retained invocations, including earlier attempts and fallback
work, rather than only the Task's currently selected invocation. Collection can
remove those associations; the file does not reconstruct deleted details or
infer missing receipt attribution. Standalone Runs do not inherit Conversation's
execution-retention period. Conversation-hosted Runs report that Account setting
and the collection marker; see [execution retention](../reference/agent-api/execution-retention.md).
The separate [Conversation export](../reference/agent-api/conversation-export.md)
remains available for retained timeline, candidates and Conversation receipts.

## Download Workspace data

Open **Workspace → Data → Download Workspace data**. Format
`nexus.workspace.data`, version `1`, contains current Workspace Memory documents,
opaque Store entries and the character document, using their ordinary public
read shapes. It includes the Workspace UUID, export time and current-version
scope. It excludes Conversations, Agent-private and Speaker documents, old
versions and attachment bytes. Store namespaces are not interpreted as product
configuration.

When a tool provider owns Workspace Memory, ordinary kernel Memory is unavailable.
The file emits `memory_unavailable` with `memory_overridden` and includes only
the existing `workspace/skills/` read exception. Store and character reads remain
independent. Workspace access and lifecycle rules are unchanged.

## Check completion

All files are `application/gzip` attachments with `Cache-Control: no-store`.
Decompress them as UTF-8 JSON Lines. Every file ends with an `end` record that
counts all record types, including itself. Accept a download only after gzip
finishes successfully and that record is present. A failed or disconnected
stream may leave partial bytes; discard it and request a fresh file. There is
no resumable-download contract.

An `end` record means traversal finished, not that all historical material exists.
Read every retention and unavailable marker. These are observation intervals,
not atomic backups: collections have bounded pages and frozen upper frontiers,
while edits, current access and collection can change between reads. The usage
summary is sampled before receipt enumeration, so concurrent activity can make
the file's later rows differ from that summary. The administrator aggregate is
one consistent analysis snapshot. No download recreates deleted logs or grants
access to another resource merely because its UUID appears in an exported record.
