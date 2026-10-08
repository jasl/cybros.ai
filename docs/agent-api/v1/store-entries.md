# Agent API Store Entries

Status: live Agent API resource.

Store entries are the bounded namespaced JSON current-value store over
three hosts: a Workspace's, a Conversation's,
and the acting principal's own. Each host holds at most 64 entries,
logically unique by `(namespace, key)` per host, values bounded by the
1 MiB snapshot bound; the same body, projections and status mapping serve all
three. Entries are data, not management: any principal with effective data
access reads them, writes require a live host, and a mismatched Agent on a
dedicated Workspace — or on a conversation of one — is write-fenced while
its reads stay ordinary. A store is **application-private state**: no generic raw-store tool or
prompt assembly block exposes its entries as memory. An application domain
operation may read its own store and return a purpose-specific result, such as
a work status, under that operation's ordinary authorization and output contract.
This separates a store from [memory](conversations.md#memory--durable-scoped-and-on-this-plane-injected-rather-than-fetched).

Store reads and writes share a **6,000 requests/minute per caller per resource**
budget, with the ordinary broad IP backstop and `429` / `Retry-After` behavior.

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_id}/store_entries
POST   /agent_api/v1/workspaces/{workspace_id}/store_entries
GET    /agent_api/v1/workspaces/{workspace_id}/store_entries/{store_entry_id}
PATCH  /agent_api/v1/workspaces/{workspace_id}/store_entries/{store_entry_id}
DELETE /agent_api/v1/workspaces/{workspace_id}/store_entries/{store_entry_id}?lock_version=...
GET    /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/store_entries
POST   /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/store_entries
GET    /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/store_entries/{store_entry_id}
PATCH  /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/store_entries/{store_entry_id}
DELETE /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/store_entries/{store_entry_id}?lock_version=...
GET    /agent_api/v1/profile/store_entries
POST   /agent_api/v1/profile/store_entries
GET    /agent_api/v1/profile/store_entries/{store_entry_id}
PATCH  /agent_api/v1/profile/store_entries/{store_entry_id}
DELETE /agent_api/v1/profile/store_entries/{store_entry_id}?lock_version=...
```

- The route says whose store it is; no host field rides the wire. Each
  host's list holds its own rows only — a conversation's entry is absent
  from its workspace's store and vice versa.
- A store entry under the wrong host renders `404` exactly like absence;
  a tombstoned Workspace or Conversation reads as absence too. The
  archived bin of either stays browsable and refuses writes.
- Lists paginate by keyset over `(namespace ASC, key ASC)` with an opaque
  composite cursor; `limit` defaults to 25 and accepts 1–100. Non-integer
  values, values below 1, and values above 100 return
  `400 parameter_invalid`.
- The list projection omits `value`; show, create, and update return it.
  Separate Basic/Full shapes keep an omitted list value distinguishable from
  a stored JSON `null`.
- Reads stay open on any browsable host; writes require a live one.

## Whose

The profile store is the **acting user's own row**: an agent's
`profile/store_entries` are the agent's, not its steward's, and the
steward's are the steward's — client-owned state per principal, never a
shared cap or namespace across a steward's agents. Memory's
`user/` scope is the other rule — the controlling Human's — and
[profile.md](profile.md#memory--the-persons-own-scope) says why. There is
no fence on a person's own row; another principal's store is unreachable.

## Create and idempotency

`POST` requires a client-minted `Idempotency-Key` header on every host. Its
receipt is the host's:

- **Workspace** — `workspace_command_receipts`, as Workspace create: 24-hour
  exact replay, digest bound to the host identity, `409
  idempotency_envelope_mismatch` on a different digest.
- **Conversation** — `conversation_command_receipts`, the key scoped to the
  conversation: one key on two conversations of one workspace is two
  receipts, never a replay of the other's; the same 24-hour replay and
  mismatch rule.
- **Profile** — no receipt is kept: a repeat with the same key is
  `409 key_taken`, never a replay — the unique index and `lock_version` are
  the whole convergence contract. The header is still required and
  size-checked.

Replay resolves the host through the caller's current scope first — access
loss or a tombstoned host is `404`.
StoreEntry creation responses on Workspace and Conversation hosts include
`Idempotency-Replayed: false`; exact receipt replay preserves the original
`201` and body with `Idempotency-Replayed: true`. Agent creation does not
use receipt replay and does not return this header.

Body (`store_entry`): `namespace` (required), `key` (required), `value`
(required; JSON `null` is a legal stored value). PATCH replaces `value` under
a required `lock_version`.

## Fork and collection

A conversation's entries are copied into a fork's child as fresh current
values (`lock_version` 0, new ids): a store row is mutable, so it is never
shared by pointer the way memory is. Workspace entries leave with the
workspace's collection, conversation entries with their conversation's
reap, and a person's with nothing but the account — they outlive every
workspace the person used.

## Projections

StoreEntry Basic (lists):
`public_id, namespace, key, lock_version, created_at, updated_at`.

StoreEntry Full adds `value`.

## Status mapping

| Outcome | HTTP |
| --- | --- |
| created | `201`, Full projection |
| updated | `200`, Full projection |
| deleted | `204`, empty body |
| host or entry not reachable, tombstoned Workspace or Conversation | `404 not_found` |
| mismatched Agent write on a dedicated Workspace or its conversation | `403 workspace_agent_identifier_mismatch` |
| read-level principal writing a conversation's store | `403 not_authorized` |
| write outside a live Workspace | `409 workspace_not_active` |
| write on an archived Conversation | `409 conversation_archived` |
| stale `lock_version` | `409 stale_object` |
| 65th entry on a host | `409 entry_limit_reached` |
| duplicate `(namespace, key)` on a host, or a retried profile create | `409 key_taken` |
| value over the envelope bound | `413 content_too_large` |
| other validation failures | `422 validation_failed` |
