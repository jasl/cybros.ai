---
title: Conversation links
description: Bilateral message grants between fixed Conversation and Agent endpoints.
---

# Conversation links

[中文](../../zh/reference/agent-api/conversation-links.md)

A Conversation link grants ordinary message delivery between two fixed
Conversation/Agent endpoints in one Workspace. It grants no access to the peer's
history, Tasks, memory, status, requests or cancellation. These member-plane
resources use the [common API contract](../agent-api.md).

## Routes

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links/{public_id}
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links/{public_id}/closure
```

## List links

### Endpoint

`GET …/conversations/{conversation_id}/links`

### Request

`state` is `active` (default), `closed` or `all`. Keyset pagination uses `after`
and `limit` (default 50, maximum 100).

### Response

`200` with `links` and `next_after`. Each link contains `public_id`,
`workspace_public_id`, `endpoint`, `peer`, `state`, `created_at`, `closed_at`
and `close_reason`. Each endpoint contains `conversation_public_id` and
`agent_public_id`. Endpoint is local to the requested Conversation; peer is
the other end. State is `active` or `closed`; closure fields are null while active.

### Status codes

`200` on success; invalid parameters and concealed resources follow the common
contract. Listing requires local Conversation read access, not peer read access.

## Read a link

### Endpoint

`GET …/conversations/{conversation_id}/links/{public_id}`

### Request

No body. The UUID must belong to a link of the local Conversation.

### Response

`200` with `{ "link": { "…": "…" } }`, using the list projection.

### Status codes

`200` on success; `404` for an unknown or concealed local resource.

## Create a link

### Endpoint

`POST …/conversations/{conversation_id}/links`

### Request

An `Idempotency-Key` header and three public UUIDs:

```json
{
  "link": {
    "agent_public_id": "0198…",
    "peer_conversation_public_id": "0198…",
    "peer_agent_public_id": "0198…"
  }
}
```

The actor needs full standing on both Conversations. Both Agents must be eligible
answerers at their endpoints and permit messaging in both directions. Endpoints
must be distinct, unarchived, non-Side Conversations in the same Workspace.

### Response

`201` with `link` for a new relation; `200` for the already active pair.
Creation receipts use the common replay window. Replaying a receipt after close
returns the original acceptance without reopening the link; read the link for
current state. A new grant after close uses a new idempotency key and link UUID.

### Status codes

`201` or `200` on success. Refusals include `not_authorized`,
`answerer_not_eligible`, `messaging_not_allowed`, `conversation_archived` and
`validation_failed`, using the common error envelope.

## Close a link

### Endpoint

`POST …/conversations/{conversation_id}/links/{public_id}/closure`

### Request

No body. Requires full standing on the local Conversation.

### Response

`200` with the current `link`, state `closed`, a `closed_at` timestamp and
`close_reason: "explicit"`. Repeated close keeps the same closed relation.

### Status codes

`200` on success; unknown or concealed links and insufficient local standing
follow the common contract.

## Delivery and lifecycle

The model's [send tool](run-orchestration.md) names `link_public_id` instead of
`to` and `agent`. Its actual Run Conversation and answering Agent must match the
endpoint. Knowledge of a UUID alone cannot use a relation from another Conversation.

Close and consumption serialize on the link: close first prevents the pending
message from starting a Turn; consumption first leaves recipient processing alive.
Creation and explicit close each send one `conversation_link_changed` event to both
local Conversation feeds, with the link UUID, state, close reason and actor
(`by` public UUID and `kind`). Replaying creation or closing again adds no event.
Authority changes also close affected links: principal suspension/removal, steward
transfer, loss of full access to an endpoint, loss of Workspace access, or endpoint
deletion. Human [takeover](conversations.md#human-takeover) closes links crossing
the detached subtree with `close_reason: taken_over`, narrates each closed link,
and removes unconsumed messages. Internal links and consumed messages remain.
Restoring access does not reopen an old link. Messaging policy changes
and Archive preserve existing links. Bulk authority changes use their existing
authority notification rather than emitting one event per link.

Close returns after cutting permission. Bounded recovery removes unconsumed linked
Inputs, including delayed, blocked and steering rows. Accepted requests and their
formal results are independent of the link.

The model tool `links({state?, limit?, after?})` discovers links for the calling
Conversation and answering Agent only. `state` is `active` (default), `closed` or
`all`; `limit` is 1–100 (default 50). Its UUID cursor is returned as `next_after`.
The result exposes endpoint addresses, never peer history.

## SDK bindings

All three SDKs bind links under a Conversation. The link creation receipt retains
whether the server replayed the original acceptance.

```ruby
links = client.workspace(workspace_id).conversation(conversation_id).links
created = links.create(agent_public_id: sender_id,
  peer_conversation_public_id: peer_id, peer_agent_public_id: recipient_id,
  idempotency_key: "link-grant-1")
link = links.fetch(created.public_id)
links.close(link.public_id)
```

```typescript
const links = client.workspace(workspaceId).conversation(conversationId).links;
const created = await links.create({ agent_public_id: senderId,
  peer_conversation_public_id: peerId, peer_agent_public_id: recipientId },
  { idempotencyKey: 'link-grant-1' });
const link = await links.fetch(created.link.public_id);
await links.close(link.public_id);
```

```rust
let links = client.workspace(workspace_id)?.conversation(conversation_id)?.links();
let created = links.create(&CreateConversationLink {
    agent_public_id: sender_id.into(),
    peer_conversation_public_id: peer_id.into(),
    peer_agent_public_id: recipient_id.into(),
}, "link-grant-1").await?;
let link = links.link(&created.body.public_id)?;
link.fetch().await?;
link.close().await?;
```

Listing accepts `state`, `after` and `limit`; SDK pages expose `items` and
`next_after`. Sending and requesting work still use the captured kernel tool
catalog or claim-bound task operations. A member credential does not impersonate
a Conversation's answering Agent.

## Recovering the original result

Persist the acceptance's `input_public_id` and, for a request, its `completion`
Run UUID and Task key. Read that Task to recover the formal result. A finite
await timeout ends that wait; it does not cancel accepted work. A later read of
the same completion can return the original result.

When authorized to read the target Conversation, its existing `input_execution`
(Ruby), `inputExecution` (TypeScript) or `InputExecution::new` (Rust) helper follows
the accepted Input's materialization and kernel fallback lineage. It does not
switch to the current head or a later manual regeneration. A missing
materialization alone cannot distinguish pending, discarded or unavailable
history; keep the outcome unknown until authoritative evidence resolves it.
Do not turn that uncertainty into a new send or request.

Communication Inputs expose `communication_kind`, `link_public_id`,
`requested_delivery_mode`, `on_target_end` and `fallback_reason`. Consumed Turns
retain their communication and sender stamps. Callback results retain the exact
Input/Turn/Variant identity and, when supplied, original Run UUID and terminal
status. Cancellation before materialization can leave Turn/Variant/Run UUIDs null
in the completion's structured result; it does not manufacture an execution.
