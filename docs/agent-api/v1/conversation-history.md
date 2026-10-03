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
    "truncated": false
  }],
  "pagination": { "next_after": null }
}
```

Title hits have null turn/variant/position fields. Excerpts are plain original
text, at most 500 characters, centered near a Chinese literal term or an English
stem prefix when one is found. Unusual non-prefix stemming can fall back to the
initial excerpt. Render text as text, never as trusted HTML. A hit's turn UUID
opens its surrounding context through the history endpoint.

## Read context

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/history
```

`limit` is 1–50 (default 20). Omit a cursor for the newest window, or use exactly
one of `around_turn_public_id`, exclusive `before_position`, or exclusive
`after_position`. An around target that is outside the visible timeline is 404.
Returned turns are ordered by ascending position.

The response contains `conversation: {public_id, title}`, `turns`, `pagination`
and `truncated`. A turn contains `public_id`, `position`, `kind`, `role`,
`created_at`, `truncated` and any available `prompt`, `steers`, `content` strings.
Text is read in that order, at most 2000 characters per field and 12000 across the
page. An `around_turn_public_id` window gives the target text first, then its
nearest neighbors (the newer turn wins equal distances). Other windows allocate
text from the cursor's near edge: oldest first after a position, newest first
before a position or for the default latest window. Returned rows remain in
chronological order. The turn/page `truncated` flags state that text was omitted. Pagination
contains `before_position`, `after_position`, `has_older`, `has_newer`. These
cursors page turns, not the truncated characters within a long message.

Archived conversations remain readable. Hidden/concealed turns, compaction
summaries and execution details do not appear in this text-only read.

## Model tools and index maintenance

`nexus.conversation.search` is exposed as `session_search` with the search
parameters above. `nexus.conversation.read` is exposed as `session_read`, using
`session_id` for the conversation and `around_turn_id` for the optional centered
turn; the other read parameters keep their names. They return the same bounded
JSON envelopes as text. Tools read the answering principal's current workspace
and access and must be declared like other kernel tools.

New title writes and sealed transcript bodies maintain their keyword arrays.
Execution-detail retention preserves these bodies and their indexes.
