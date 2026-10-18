# Conversation diagnostic export

The member plane exports one readable Conversation as a gzip-compressed UTF-8
JSON Lines file. Use it to inspect retained messages, execution, requests, usage
and events together. Attachment bytes remain on the authenticated
[upload resource](uploads.md).

## Routes

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_public_id}/export
```

## Download an export

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_public_id}/export
```

### Request

Use the ordinary [member credential](../agent-api.md). The request has no body,
filters, pagination or format parameter. `read` and `full` access both permit
export. Archived Conversations remain readable.

### Response

`200` streams an `application/gzip` attachment named
`conversation-{conversation_public_id}.jsonl.gz`, with `Cache-Control: no-store`.
The bytes are a gzip file; the response does not use `Content-Encoding`.
There is no Range or resumable-download contract.

Decompress the file and parse each line as one JSON object. The opening record
identifies the format:

```json
{
  "type": "export",
  "format": "nexus.conversation.diagnostic",
  "version": 1,
  "conversation_public_id": "0199a000-0000-7000-8000-000000000001",
  "exported_at": "2026-10-15T12:00:00Z",
  "scope": "retained_conversation",
  "consistency": "observation_interval"
}
```

Every record carries `type` and the target `conversation_public_id`. Content
records nest their projection under the corresponding resource name. Correlation
fields use public UUIDs, Task keys and entry positions.

| Type | Projection |
| --- | --- |
| `conversation` | The full [Conversation](conversations.md) |
| `input` | A current [waiting-room Input](conversation-inputs.md) |
| `turn` | An effective [timeline Turn](conversation-turns.md) |
| `variant` | A live candidate, including retained prompt and content |
| `steer` | One retained steer payload, its Variant and entry position |
| `run` | A readable Run's basic projection |
| `execution_unavailable` | A Variant and the omission reason |
| `task` | The existing [Task detail](runs.md) |
| `graph_node`, `graph_edge` | Individual Run graph projections |
| `request` | The existing [sealed semantic request](conversation-context.md) |
| `usage` | Public usage, timing and receipt attribution |
| `event` | An ordinary [replay event](conversation-feeds.md) |
| `end` | Completion time and counts by record type |

Execution records use `turn_public_id`, `variant_public_id` and, where applicable,
`run_public_id`, `task_key` and `model_invocation_public_id` for correlation.
An omission has reason `execution_details_pruned` or `unavailable`.

Usage retains the public token counts, exact decimal cost, cost completeness and
timing. Attribution includes `usage_record_public_id`,
`model_invocation_public_id`, `attempt_ordinal`, `recorded_at`, `provider_id`,
`catalog_model_ref`, `workload`, `purpose`, `status` and an optional `error_code`.
`provider_id` is the provider's string identifier. Payer balances, provider
credentials, raw provider usage and pricing configuration are not included.

The final record has `type: "end"`, `completed_at` and `counts`, including the
opening and completion records. A consumer must finish gzip decompression and
read that completion record before accepting the file. A connection or reader
failure during download can leave a partial file; discard it and request a new
export. A streaming failure cannot replace already-sent bytes with a JSON error.

### Status codes

| Status | Meaning |
| --- | --- |
| `200` | Gzip download started |
| `401` | The member credential was not accepted |
| `404` | The scoped Conversation is absent or unreadable |
| `429` | The ordinary request rate limit was reached |

Errors before streaming use the [common JSON error envelope](../agent-api.md).

## Scope and consistency

The file observes a read interval. It is not an atomic snapshot or an import
package. Each collection freezes an upper bound before enumeration. Later rows
may be omitted, and mutable state and retention are observed when each page is
read. Input queue positions are included as data; their current order does not
control export enumeration.

The effective timeline includes inherited history, hidden Turns and content
excluded from model context. It excludes effectively concealed Turns and deleted
candidates. The candidate records include live replaced and failed candidates.
Materialized Inputs no longer have waiting-room rows: their retained input UUID,
prompt, content and landed steers remain with the Turn and Variant.

Reading inherited content does not grant access to the source Run's execution.
Tasks, graph and whole-Run requests pass that Run's existing read gate. An
unavailable Run produces an omission record. Ordinary messages and history
boundaries that own no execution need no omission record.

[Execution retention](execution-retention.md) can remove Tasks and request details
while keeping final content and usage. The export marks that gap. Events retain
the ordinary feed's retention and visibility semantics, so they may contain a
preview of content later concealed or pruned.

Usage belongs to the target Conversation, including receipts for edited history
or collected execution. Inherited and spawned Conversation spending is not
included. Child Conversations, Side Conversations, memory/store catalogs,
attachment bytes and private credential or claim state are not recursively
exported. Opaque user text, metadata and tool results keep their existing values.
