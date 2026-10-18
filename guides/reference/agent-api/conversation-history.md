# Conversation history search

These read-only member-plane endpoints use the caller's current workspace and
conversation access. Human members and Agents have the same read contract.
Tombstones, hidden or concealed turns and inaccessible conversations are omitted
before pagination. Inherited fork turns follow the destination conversation's
view, independent of the source conversation's local view.

## Search

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/conversation_search
```

| Parameter | Meaning |
| --- | --- |
| `query` | Required, nonempty keywords, at most 1024 UTF-8 bytes. |
| `archived` | `exclude` (default), `include`, or `only`. |
| `include_auxiliary` | Boolean, default false; includes side and subagent conversations when true. Ordinary forks are included by default. |
| `answering_user_public_id` | Optional UUID of the Conversation's default answerer; combines with the other filters. |
| `limit` | 1–50; default 20. |
| `after` | Opaque `pagination.next_after` from the preceding page. |

Search covers titles and the active variant's final input, response and accepted
steering text (`prompt`, `content`, `steers`). It excludes reasoning, tool output,
execution requests, old candidates, compaction summaries and attachments' bytes.
A picture with no words has no searchable text.

Chinese uses search-mode segmentation. English uses PostgreSQL's English
stemming and stop words; case is ignored. Punctuation separates tokens, and
underscored identifiers pass through PostgreSQL's lexical parser. Keywords are
ANDed within one field. An all-stop-word query returns no matches. Lexemes of
2048 bytes or more are not indexed, matching PostgreSQL's lexical limit. Indexing
processes the complete source in bounded chunks; it never truncates a long body
at a preview or a tsvector size limit.

This is keyword search, without relevance ranking, phrase positions, substring
matching or cross-field AND semantics. Results are ordered by descending turn
UUID (conversation UUID for title hits), conversation UUID and field name.
The cursor is a keyset rather than an offset; each page uses current access and
visibility. A shared prefix may appear once for each readable fork that displays
it.

```json
{
  "matches": [{
    "conversation_public_id": "01900000-0000-7000-8000-000000000070",
    "title": "Research",
    "turn_public_id": "01900000-0000-7000-8000-000000000071",
    "variant_public_id": "01900000-0000-7000-8000-000000000073",
    "position": 2,
    "field": "content",
    "inherited": false,
    "excerpt": "人工智能 research is running.",
    "truncated": false,
    "location": "W251bGwsMCwwXQ"
  }],
  "pagination": { "next_after": null }
}
```

Title hits have null turn/variant/position/location fields. Excerpts are plain original
text, at most 500 characters, centered near a Chinese literal term or an English
stem prefix when one is found. Unusual non-prefix stemming can fall back to the
initial excerpt. `location` is the start of that excerpt within the exact
candidate field. Search terms can occur in different steering entries in the
same field; the excerpt does not imply that all terms occur in one entry.
Render text as text, never as trusted HTML. Open the saved candidate through the
field endpoint below, or use the turn UUID to read surrounding active history.

## Read an exact field

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{variant_public_id}/fields/{field}
```

`field` is `prompt`, `content`, or `steers`. Pass the search match's opaque
`location` to start at its excerpt, or omit it to start at the beginning. Pass
the returned `pagination.next_after` as `after` to continue. `location` and
`after` are mutually exclusive. Treat both as opaque values scoped to this
candidate and field; do not construct them or reuse them for another target.

Each response reads at most 20 stored entries and returns at most 16 KiB of
UTF-8 text. It preserves complete Unicode code points and can continue inside
one large text part, then across parts and entries. `text` joins the window's
text parts with display newlines. Empty entries can produce an empty window
with a continuation; null `next_after` means the field is exhausted. No
adjustable limit or backward cursor is provided.

```json
{
  "conversation_public_id": "01900000-0000-7000-8000-000000000070",
  "turn_public_id": "01900000-0000-7000-8000-000000000071",
  "variant_public_id": "01900000-0000-7000-8000-000000000073",
  "field": "steers",
  "inherited": false,
  "text": "Use the latest notes. 请保留原文。",
  "pagination": { "next_after": null }
}
```

The exact candidate remains the target after another candidate becomes active.
Every request checks the caller's current Workspace/Conversation access, the
effective timeline, and that candidate's visibility. An unavailable target is
404; an invalid field or cursor is `parameter_invalid`. A reachable candidate
with no saved text for the field returns an empty string. Inherited text follows
the destination Conversation's view and grants no source execution access.
Retained text stays readable after execution-detail pruning.

Ruby uses `chat.turns.field(turn_id, variant_id, "steers", location: match.location)`;
TypeScript uses `chat.turns.field(turnId, variantId, "steers", { location: match.location! })`.
Rust uses `chat.turns().turn(turn_id)?.variant(variant_id)?.field("steers", &query)` with
`ConversationFieldQuery`. All three SDKs return the text and continuation without
automatically fetching another window.

## Read context

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/history
```

`limit` is 1–50 (default 20). Omit a cursor for the newest window, or use exactly
one of `around_turn_public_id`, exclusive `before_position`, or exclusive
`after_position`. An around target that is outside the visible timeline is 404.
Returned turns are ordered by ascending position.

The response contains `conversation: {public_id, title}`, `turns`, `pagination`
and `truncated`. A turn contains `public_id`, `position`, `kind`, `role`, `status`,
`created_at`, `truncated` and any available `prompt`, `steers`, `content` strings.
Text is read in that order, at most 2000 characters per field and 12000 across the
page. An `around_turn_public_id` window gives the target text first, then its
nearest neighbors (the newer turn wins equal distances). Other windows allocate
text from the cursor's near edge: oldest first after a position, newest first
before a position or for the default latest window. Returned rows remain in
chronological order. The turn/page `truncated` flags state that text was omitted. Pagination
contains `before_position`, `after_position`, `has_older`, `has_newer`. These
cursors page turns, not the truncated characters within a long message.

Archived conversations and unfinished turns remain readable. A running turn's
materialized input is available before its final answer. Hidden/concealed turns
and compaction summaries do not appear. The text always comes from the active
variant; a regeneration candidate does not replace that text until selected.

### Include execution progress

| Parameter | Meaning |
| --- | --- |
| `include_execution` | Boolean, default false. Add a bounded execution snapshot for the around target, or the newest turn in the returned window. |
| `execution_before` | Opaque `execution.pagination.next_before` from the preceding execution page. |
| `execution_prefix` | A tool task key whose delegated branch should be read. Omit for the main thread. |

With `include_execution: true`, the response also contains `execution`. It is
null when the selected turn has no Run, or the caller cannot read that Run.
Reading a fork's inherited text does not grant access to its source Run. The
caller's existing workspace, conversation and Agent reach restrictions apply.
When execution is omitted or false, the `execution` field is absent and its
two selectors have no effect.

An available snapshot has this shape:

```json
{
  "execution": {
    "turn_public_id": "01900000-0000-7000-8000-000000000071",
    "variant_public_id": "01900000-0000-7000-8000-000000000073",
    "active": true,
    "status": "running",
    "run_public_id": "01900000-0000-7000-8000-000000000074",
    "run_status": "running",
    "rounds": [],
    "pagination": { "next_before": null, "has_older": false },
    "truncated": false
  }
}
```

The selected execution belongs to the pending or running variant when one
exists, otherwise the active variant. `status` is that variant's status;
`run_status` is the Run's status. `active` states whether this is also the variant
used for the turn's text. These UUIDs let the reader distinguish a running
regeneration from the previous answer. Optional `attention_reason` and
`failure_reason` report the Run's recorded reason, including a wait for Human
input or approval.

`rounds` uses the [Run transcript](runs.md#read-the-transcript) projection: task keys, statuses,
persisted text previews, errors, timing and a counted, bounded fan of tool
calls, including completed output previews and unfinished calls. Each page
contains at most 20 rounds and each round displays at most 24 calls. The call
count can exceed the displayed items. Delegated branch keys are supplied in
`branches`; pass one as `execution_prefix` to inspect that branch. Tool result
titles and metadata intended for the UI are omitted. This is persisted progress,
not a sealed provider request, complete tool output or a stream of uncommitted
tokens; live consumers use the existing conversation and Run feeds.

The selected turn's text is allocated first, then execution previews from newest
to oldest, then neighboring turn text. All share the 12000-character page text
budget above; returned turns and rounds remain chronological. The page and
execution `truncated` flags report omitted text. Keys, statuses, counts and
pagination remain available when previews are truncated. To read older rounds,
pin `around_turn_public_id` to `execution.turn_public_id` and send
`execution_before`; keep the same branch prefix. An invalid cursor returns
`parameter_invalid`; a nonexistent branch on an available execution returns
`not_found`.

After execution-detail retention, the snapshot retains its identities and
statuses, adds `details_pruned_at`, and has empty rounds with no older page.
The turn's durable text remains readable. `details_pruned_at` distinguishes
removed details from a Run that has no transcript rows.

## Model tools and index maintenance

`nexus.conversation.search` is exposed as `session_search` with the search
parameters above. `nexus.conversation.read` is exposed as `session_read`, using
`session_id` for the conversation and `around_turn_id` for the optional centered
turn; the other read parameters keep their names. They return the same bounded
JSON envelopes as text. Tools read the answering principal's current workspace
and access and must be declared like other kernel tools.

`session_search` also returns the exact candidate, field and opaque excerpt
location. The member field endpoint consumes that location; `session_read`
continues to read active-variant context and does not switch to an old candidate.

New title writes and sealed transcript bodies maintain their keyword arrays.
Execution-detail retention preserves these bodies and their indexes.
The field window bounds returned text and loaded entry count; it does not bound
the search query or the existing excerpt scan across a matching field.
