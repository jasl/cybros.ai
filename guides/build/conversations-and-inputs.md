# Conversations and inputs

A conversation holds inputs, turns, candidate answers, forks, memory and access rules under its workspace. Inputs are the one front door: every message, steering instruction, kernel receipt and scheduled instruction enters the conversation as an input and is materialized into a turn by the kernel.

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_id}/conversations
GET    /agent_api/v1/workspaces/{workspace_id}/conversations/archived
POST   /agent_api/v1/workspaces/{workspace_id}/conversations
GET    …/conversations/{conversation_id}
GET    …/conversations/{conversation_id}/children
PATCH  …/conversations/{conversation_id}
DELETE …/conversations/{conversation_id}
POST   …/conversations/{conversation_id}/archive
POST   …/conversations/{conversation_id}/unarchive
GET    …/conversations/{conversation_id}/inputs
POST   …/conversations/{conversation_id}/inputs
PATCH  …/conversations/{conversation_id}/inputs/{input_id}
DELETE …/conversations/{conversation_id}/inputs/{input_id}
POST   …/conversations/{conversation_id}/inputs/reorder
GET    …/conversations/{conversation_id}/inputs/{input_id}/materialization
POST   …/conversations/{conversation_id}/forks
PUT    …/conversations/{conversation_id}/default_runner
PUT    …/conversations/{conversation_id}/access
POST   …/conversations/{conversation_id}/cancellation
GET    …/conversations/{conversation_id}/turns
GET    …/conversations/{conversation_id}/turns/{turn_id}
PATCH  …/conversations/{conversation_id}/turns/{turn_id}
DELETE …/conversations/{conversation_id}/turns/{turn_id}
POST   …/conversations/{conversation_id}/turns/{turn_id}/edit
POST   …/conversations/{conversation_id}/turns/{turn_id}/regeneration
GET    …/conversations/{conversation_id}/turns/{turn_id}/variants
POST   …/conversations/{conversation_id}/turns/{turn_id}/variants/{variant_id}/activation
PATCH  …/conversations/{conversation_id}/turns/{turn_id}/variants/{variant_id}
GET    …/conversations/{conversation_id}/turns/{turn_id}/variants/{variant_id}/request
POST   …/conversations/{conversation_id}/context_estimate
POST   …/conversations/{conversation_id}/compaction
GET    …/conversations/{conversation_id}/events
GET    …/conversations/{conversation_id}/memory
POST   …/conversations/{conversation_id}/memory
POST   …/conversations/{conversation_id}/memory/show
POST   …/conversations/{conversation_id}/memory/delete
WS     /agent_api/v1/cable
```

Creation requires an `Idempotency-Key`; the receipt replays the original status and body for 24 hours, marked by `Idempotency-Replayed`.

To rename a Conversation, replace its metadata or change its cost limit, read it and pass its
`lock_version` with the changed fields. A newer edit returns `409 stale_object`
and preserves the newer values. Refetch and reconcile before trying again;
see [Update a conversation](../reference/agent-api/conversations.md#update-a-conversation).

## Inputs

| Field | Values |
| --- | --- |
| `kind` | `direct_reply` starts a model reply; `message` records speech without one |
| `role` | `user` by default |
| `text`, `attachments` | The words and staged uploads; images and PDFs use native placement when the model supports them |
| `delivery_mode` | `queue` (default) waits for the turn boundary; `steer` enters the next model boundary of running work and falls back to the queue when that work ends; `steer_now` inserts a model boundary ahead of pending tools, which keep running |
| `expected_steering_run_public_id` | Apply a steer only to that exact execution |
| `model` | `{ "model": "provider/model", "reasoning_enabled": …, "reasoning_effort": … }` |
| `deliver_at`, `deliver_in` | Hold a queued input until a time; an absolute time permits exact replay |
| `tool_names`, `approval_mode`, `configuration` | Narrow the declared tools or tighten approval for this request; never widen |
| `steps` | Authored DAG steps appended after the first model task; see [Orchestration](orchestration.md) |
| `to` | Address another answerer by handle in a group conversation |
| `context_mode: "raw"` | Supply the complete request under the `raw` prompt mechanism |

A `202` response means acceptance. Read `inputs/{id}/materialization` to recover the turn, variant and nullable run the input produced; it survives consumption and event retention. A `blocked` input carries `blocked_reason`: edit it with `PATCH` or delete it rather than submitting duplicates. Edits take `expected_lock_version`.

Kernel-origin inputs — a background task's result, a child conversation's reply, a scheduled occurrence's report — drain before ordinary queued inputs. With `wake: "auto"` they start a reply when the conversation is idle; with `wake: "passive"` they materialize a message-only turn the next active input can read.

## Turns and variants

A turn is one slot on the timeline. A reply turn's `active_variant` is the displayed answer; a `running_variant` is a regeneration in progress. `…/regeneration` creates a new candidate and a new run and permanently stops the replaced candidate's unfinished work; `…/variants/{id}/activation` selects another candidate with the same cancellation consequence for the one it replaces. `…/edit` creates a variant without running a model. Turns can be deleted and the conversation's execution stopped through `…/cancellation`; published content stays readable.

The turn list is a position window; a known turn reads directly. Settled text is read from the turn even when a streamed draft looked complete.

## Lifecycle

Conversations have a working list, an archive (restorable) and deletion (a tombstone absent from every surface). Both lifecycle changes narrate `conversation_ended`. Archive closes new independent input while accepted execution and its delivery continue; a tombstone ends the feed. Access levels are described in [Workspaces and access](../operate/workspaces-and-access.md); `PUT …/access` replaces the carrier whole.

## Forks and sides

`POST …/forks` branches history at a turn into a new conversation, copying access rows and the source's derived-full principals. A **side** conversation is a fork mode for a temporary branch whose reference snapshot is readable context, never new replies. Fork-point runner effects are projected so a client can restore each runner's checkpoint independently.

## Compaction and context

When a context will not fit, Nexus repairs it rather than reporting it: the kernel's summarizer, a delegated summarizer tool, or pruning, as the configuration's `compaction_policy` selects. Mid-turn compaction and a between-turn summary both narrate `context_compacted`. A context estimate endpoint and a `render: true` preview show what assembly would send.

## Memory and history

Memory documents in the conversation's bound scopes are injected by the default prompt mechanism and read and written through kernel tools; see [Memory, store and uploads](memory-store-and-uploads.md). Keyword search and bounded history reads cover older context, and the [retention](../operate/retention-usage-budgets.md) window decides how long execution detail remains.

The complete contract — field tables, response shapes, lifecycle, access, memory, compaction, feeds and status codes — is the [Conversations reference](../reference/agent-api/conversations.md), with [history search](../reference/agent-api/conversation-history.md), [reasoning replay](../reference/agent-api/conversation-reasoning.md) and [execution retention](../reference/agent-api/execution-retention.md) beside it.
