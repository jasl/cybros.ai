# Events and streaming

HTTP owns business commands, current state and retained event replay. Action Cable reduces delivery latency. An open socket is not proof that work is available, that execution succeeded, or that every frame arrived.

## The feeds

| Feed | Purpose | Recovery |
| --- | --- | --- |
| `events` | Durable resource events with a resource-scoped sequence | HTTP replay after the last consumed cursor; rebuild from current resources when retention has removed history |
| `lifecycle` | A filtered view of the same events: `turn_status`, `attention_required`, `conversation_ended` | The same replay, filtered |
| `transcript` | Text deltas, resets and settled text snapshots | Read the current variant or task output over HTTP; these frames have no replay log |
| `progress` | Temporary tool and process output and kernel timings | Resume with future frames; use the durable task result for the outcome |
| Executor inbox notifications | `work_available` and `work_canceled` hints | Poll the HTTP inbox and the held claim |

A conversation-hosted run publishes on its conversation's stream; a standalone run hosts the same stream at its own address. Every item names its host as `resource: { type, public_id }`. The 25 event types are listed in the [events reference](../reference/events.md).

## Replay

```http
GET …/conversations/{conversation_id}/events?after={cursor}&limit={n}
```

Replay returns ascending sequences, an opaque `next_after` cursor and a committed `watermark`. The watermark survives item expiry: an empty page whose watermark is beyond your consumed sequence means committed progress is no longer replayable — refresh from the resource's durable state rather than inventing events. Retention keeps a 30-day replay window independent of execution-detail retention.

## A durable follower

1. Subscribe to the cable and wait for confirmation.
2. Buffer live events while draining HTTP replay from the saved cursor through the first response's watermark.
3. Merge by resource identity and sequence, discard duplicates, and advance the saved cursor only after consumption succeeds.
4. On reconnect, repeat the same recovery.

Keep the server's cursor opaque. The Ruby SDK's durable feed implements this coordination, and `CybrosAgent::InputMaterialization` tracks one accepted input through replay with an HTTP recovery callback.

## Text and status are separate

A terminal status can arrive before, after or without the final text frame. When you hold a terminal status but no settled text, read the authoritative text over HTTP and replace the accumulated draft. Check the turn, variant or task identity again before applying an asynchronous read so a previous answer cannot overwrite a newer selection.

## Cable channels

Conversation events subscribe with `items: "events" | "lifecycle" | "progress"` on the conversation events channel. Progress frames arrive under `{ frame }`, never `{ event }`, and are limited to one frame per key per 250 ms per kernel process; excess cadence is acknowledged and dropped. Executors subscribe to their inbox channel, keyed by executor.

## Polling while subscribed

An executor keeps polling even while subscribed. Drain each bounded inbox scan to its end, then start the next scan from the beginning; a notification only brings that scan forward. Claim, extend, commit and cancel decisions remain HTTP operations.

## Why there are no webhooks

Nexus never dials out to an application; components connect outbound to Nexus. Durable replay with cursors covers the integration a webhook would provide, without requiring your application to expose an endpoint, and the same path serves reconnection after any outage.
