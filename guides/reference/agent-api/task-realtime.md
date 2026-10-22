---
description: Task-attached WebRTC signaling and current interaction permission on the member and executor planes.
---

# Task realtime

An explicitly interactive Runner handler exchanges a complete WebRTC offer and answer under its
existing ToolTask. Nexus stores one bounded handshake and projects current interaction permission.
It does not transport input or media. The original claim, deadline, Stop and result remain the
execution contract. Ordinary tools do not become interactive automatically.

## Routes

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/realtime
PUT /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/realtime
GET /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/realtime
PUT /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/realtime
```

## Read the Runner projection

### Endpoint

```http
GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/realtime
```

### Authentication

Use the Runner's executor-transport bearer and original `Claim-Token` header. Only the exact
claimant of a ToolTask can use this door; agent and tool-provider executors cannot.

### Request

No body. Keep the claim proof out of the URL.

### Response

`200` with the projection below. Reads do not renew, settle or cancel a task.

### Status codes

| HTTP | Code | Meaning |
| --- | --- | --- |
| 200 | — | Current projection, including closed interaction |
| 400 | `parameter_missing` | Missing claim header |
| 401 | `unauthorized` | Invalid transport credential |
| 404 | `not_found` | Missing or tombstoned Run or ToolTask |
| 409 | `not_claimant` | Wrong Runner or original claim |
| 429 | `rate_limited` | Retry after the response's delay |

## Publish an offer

### Endpoint

```http
PUT /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/realtime
```

### Authentication

The same executor bearer and original `Claim-Token` header as the read.

### Request

```json
{
  "connection_id": "01900000-0000-7000-8000-000000000099",
  "previous_connection_id": null,
  "sdp": "…"
}
```

`connection_id` is a new lowercase UUIDv7. `sdp` is a complete gathered offer, at most 65,536
UTF-8 bytes, beginning with `v=0` and containing one distinct SHA-256 DTLS fingerprint.
Repeated identical fingerprint lines are accepted. Trickle candidates are not supported.
The WebRTC implementation validates the rest of the SDP and receives these exact authenticated bytes.

Omit `previous_connection_id` or send null for the first offer. To replace an existing handshake,
read it and name its `connection_id` here. This compare-and-replace rule prevents an old delayed
request from overwriting a newer connection without relying on client clock ordering.
Retrying the same connection ID, identical SDP and original executor credential is idempotent.
A different offer under that ID is refused. Stop the old input entrance before replacing it.

### Response

`200` with the current projection, normally `waiting` until the Agent answers. A handshake
cannot start a tool, acquire a claim or resurrect a canceled task.

### Status codes

Read errors also apply. `400 parameter_invalid` rejects invalid IDs or SDP, `409 signal_conflict`
rejects changed or stale handshakes, and `409 realtime_unavailable` rejects an expired, paused,
stopped, unauthorized or maintenance-blocked execution.

## Read the Agent projection

### Endpoint

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/realtime
```

### Authentication

Use the executing Agent's member credential. A named Agent is represented by its current
application owner; both identities must retain write standing, and the named Agent must retain
execution eligibility. A Human or unrelated Agent cannot attach. The ordinary Workspace and
Run visibility rules apply first.

### Request

No body. A transport credential cannot substitute for the member bearer.

### Response

`200` with the same projection, including the offer when attachment is available.

### Status codes

`401 unauthorized`, `403 not_authorized`, `404 not_found`, `410 execution_details_pruned` and
`429 rate_limited` follow the member family's rules. Non-active interaction still returns a
`200` projection when the caller has standing to read this door.

## Answer an offer

### Endpoint

```http
PUT /agent_api/v1/workspaces/{workspace_public_id}/runs/{run_public_id}/tasks/{task_key}/realtime
```

### Request

```json
{ "connection_id": "01900000-0000-7000-8000-000000000099", "sdp": "…" }
```

Use the current offer's ID and a complete gathered answer under the same SDP bound. The member
credential used for the answer is bound to this handshake. Replacing that credential requires a
new offer; refreshing permission does not silently change the peer's credential binding.

### Response

`200` with the projection. An identical answer from the same credential is idempotent.

### Status codes

Member read errors apply. `400 parameter_missing` or `parameter_invalid` rejects malformed
input. `409 signal_conflict` rejects an old connection ID or a changed accepted answer;
`409 realtime_unavailable` rejects a handshake whose execution or original credential no longer
permits attachment.

## Projection and permission window

```json
{
  "realtime": {
    "status": "active",
    "reason": null,
    "connection_id": "01900000-0000-7000-8000-000000000099",
    "offer_sdp": "…",
    "answer_sdp": "…",
    "max_age_ms": 1000
  }
}
```

| Status | Meaning |
| --- | --- |
| `waiting` | No offer yet, or no accepted answer |
| `active` | Original claim, both original credentials and current execution standing permit interaction |
| `paused` | Run Pause or deployment maintenance blocks interaction |
| `closed` | Revocation, expired deadline, changed claim or execution termination blocks this connection |

Only `active` grants permission. Treat unknown status values as unavailable. `max_age_ms` is zero
for every other status, at most 1,000 for active permission, and clamped by the original credentials'
expiry and task deadline. Start the local monotonic window **before sending the HTTP request**.
A late response does not grant a fresh second from receipt. The Runner polls every 500 ms while attached;
errors, timeouts and 429 responses never refresh the window. Honor `Retry-After` while the local
gate expires independently. Each plane has a separate 3,000-request/minute bucket per credential
and operation for these endpoints.

rho's browser uses member HTTP reads for handshake discovery and recovery. Once
connected, it observes the Runner's remaining window over the same authenticated
peer instead of repeating the full Nexus permission read. The Runner's projection
still checks both original credentials and all execution authority.

### Relayed permission

The rho transport negotiates an ordered `permission` DataChannel with id `1`,
separate from the application data channel on id `0`. Permission observation
does not interpret the application payload or grant another tool capability.

The browser sends a JSON integer nonce from `1` through `2**53 - 1`, at most
16 bytes. It keeps one outstanding probe, normally sent every 250 ms, replacing
an unanswered probe after 500 ms. The handler returns a JSON text object
`{"nonce": 1, "max_age_ms": 750}` containing only the **remaining** original
Runner window. The helper retains one pending nonce and no authorization state.
Responses are bounded to 128 characters and budgets to `0..1000`.

The browser accepts only its outstanding nonce on the current peer. It sets
expiry to its own probe-send monotonic time plus that remaining duration,
discounting the whole round trip. Zero, expired or absent permission hides media
and blocks input; late or replaced-peer replies cannot restart a window.
The Runner continues enforcing its own gate independently. A disconnected peer
returns to HTTP discovery. Context-free low-level adapters still require their
caller's ordinary member-plane permission checks.

Before every new input, capture or media send, check the local window. On expiry or Pause, stop
those actions and clear pending input/output; retain the existing handler and resource. A fresh
valid projection can resume the same handshake after a temporary outage or Pause. An explicit
closed response or peer mismatch closes that handshake; renewed credentials require a new offer.
Rebuilding a PeerConnection always requires a fresh offer. Never replay unacknowledged inputs.

`reason` explains the current refusal: `offer_required`, `answer_required`, `execution_paused`,
`execution_ended`, `deadline_passed`, `not_authorized`, `claim_changed`,
`executor_credential_revoked` or `member_credential_revoked`. It is diagnostic, not a new task state.
SDPs are null when closed or paused. `connection_id` is null before the first offer.

All responses are `Cache-Control: no-store`. Signaling is encrypted at rest, omitted from ordinary
task/result projections and excluded from parameter logs. The single current handshake is removed
with its Task; no signal history or per-packet events are retained.

## Runner integration

rho-runner exposes `context.realtime` inside the existing handler. Call `offer(sdp:)` on the worker;
the existing control reactor performs signaling and subsequent permission reads. The return value
is the initial projection; read `snapshot` for the answer, and use `allowed?` for every action.
The bridge is idle until the handler explicitly offers. It does not instantiate WebRTC or an OS
resource. Your transport adapter owns peer verification, bounded queues and native cleanup.

For a byte DataChannel, rho-runner also supplies the optional
`rho/runner/webrtc_transport` adapter. Build its Pion helper from the installed gem's
`transport/` directory with `go build -o /your/bin/rho-webrtc .` using the Go version
in `go.mod`. Ordinary Runner startup does not load the adapter or require Go.
The helper receives ICE server configuration through private stdio, without Nexus
credentials or a listening HTTP control endpoint.

Inside a handler, create `Rho::Runner::WebrtcTransport.new(executable: path, context: context)`
and call `connect(servers: ice_servers)`. ICE server entries use WebRTC's `urls`,
`username` and `credential` fields. The default permits direct and TURN candidates;
`relay: true` restricts it to TURN. `connect` publishes a fresh offer through the
original claim and waits for the member's answer. The member adapter uses `answer(sdp:,
servers:, relay:)`, then publishes that SDP through `TasksContext#answer_realtime`.
A context-free adapter is a low-level peer: its caller must apply member-plane permission
checks before sending or consuming data.

`poll` returns `data` (binary strings), `ready`, connection `state` and the selected
candidate `pair` types. Keep polling while attached, including while permission is
unavailable, and check `context.realtime.allowed?` immediately before applying each
returned input to the OS resource. `send_bytes` checks permission and returns false
when it is unavailable. Each block is at most 16 KiB; the helper buffers at most four
incoming blocks and 64 KiB of outgoing DataChannel data. Overflow or unavailable
transport raises a Runner error; no input is retried automatically. Queued input
received before the current uninterrupted permission window is discarded.

For automatic recovery, require `rho/runner/webrtc_connection` and create
`Rho::Runner::WebrtcConnection.new(executable: path, context: context, servers: ice_servers)`.
Call `poll` in the existing handler loop; it starts the first offer and advances the
handshake. It has the same `poll` and `send_bytes` surface, plus `connection_id`.
A disconnected or failed peer, unavailable transport, or handshake timeout closes the
old helper and creates a fresh offer under the original claim. The first attempt uses
auto ICE; subsequent attempts restrict candidates to relay when ICE servers are supplied.
Supply working TURN credentials for this fallback. Failures back off by 1, 2, 4, then
8 seconds between attempts. Answer and connection waits each have a 10-second limit.
The member must keep observing this task's signaling, close its previous peer and answer
each new connection UUID. No new tool execution is involved.

`ready: false` means the handler must discard or handle output according to its own
policy. The adapter never queues bytes across a replacement and never retries an input
with an unknown outcome. Explicit permission closure stops recovery; temporary permission
expiry still gates bytes. Cancellation interrupts helper IPC and handshake waits through
the original execution context. Offer gathering may occupy a poll for up to 10 seconds;
there is no background transport thread.

Close either adapter in the handler's `ensure`. The handler retains its original PTY,
claim and Stop cleanup; the adapter never creates or restarts an OS resource. The byte
transport provides no terminal tool, terminal UI or Windows PTY implementation.
The raw byte adapters do not retain output; use the optional stream below for recovery.

### Output recovery

Require `rho/runner/webrtc_stream` to wrap an existing `WebrtcConnection`:

```ruby
stream = Rho::Runner::WebrtcStream.new(connection: connection, context: context)
# Inside the original handler loop:
packet = stream.poll
packet.data.each do |bytes|
  written = context.realtime.allowed? ? writer.write(bytes) : 0
  stream.acknowledge_input(written)
end
# Pass every PTY read here, including when packet.ready is false.
stream.write_output(output_bytes)
# In the handler's existing ensure, alongside its own PTY cleanup:
stream.close
```

The window is in memory for this handler only. Defaults are at most 256 KiB, 30 seconds
from capture, and 256 blocks. The oldest whole blocks are evicted when any bound is reached;
`window_bytes:` and `window_seconds:` configure the first two bounds. It is not a durable
transcript and does not survive handler exit. New peer generations share this window and
retain the original PTY, claim, task deadline and Stop path.
If a cursor has fallen into unavailable output, the gap advances it to the newest
retained block, skipping older backlog explicitly. This lets a live viewer recover
from an output flood instead of repeatedly chasing an evicted oldest block.
A cursor still inside retained output continues ordered replay. The terminal
handler also paces PTY reads to at most 16 KiB per 10 ms iteration, and the WebUI
requests the next frame after the renderer consumes the current output.

Keep one `WebrtcStream::Receiver` for this task across peer replacements. On a ready peer,
send `receiver.resume` with the low-level peer's `send_bytes`. Feed each received block to
`receiver.receive(bytes)` and consume the returned events in order. After consuming a frame,
send `receiver.resume` again to request the next one. If no response arrives, retry this
idempotent cursor request at a bounded interval, for example 500 ms: a request can be lost
while the Runner's permission window is unavailable. Never retry an input this way.
Use `receiver.input(bytes)` to frame terminal input, at most 8 KiB per input block. This
framed stream requires both sides to use these methods; it cannot mix bare terminal bytes
with protocol frames.

`Output` events carry a byte `offset` and binary `bytes`. `Gap` events carry the unavailable
half-open byte range `from...to` and a default display `message`, for example
“Output gap: 32768 bytes are unavailable.” Display the gap separately from terminal bytes;
do not write it to the PTY. The receiver trims duplicate and overlapping output and advances
its offset when returning events to the caller. Consume all events before requesting more
or reusing that cursor. This is delivery to the caller, not proof of rendering or durable
storage. A receiver belongs to one task's stream and must not be reused for a different task.

Each cursor request returns at most one output or gap frame, with up to 8 KiB of output.
If no output is available yet, that request waits locally until a later poll has a frame.
This bounds output in flight for slow consumers, at the cost of one round trip per frame.
Successful transport sends do not discard retained bytes: a replacement peer resumes from
the receiver's actual offset, including data lost before disconnection was detected.

Capture and replay both use the original interaction permission. Bytes passed to
`write_output` without current permission advance the offset but are not retained; later
recovery reports a gap instead of exposing them. Previously authorized capture can be
replayed only while current permission allows it. Expiry is checked during append/poll;
explicit closure clears retained content, and the handler's Stop/ensure clears the window
and closes its connection. Output recovery never replays input or starts another execution.

The DataChannel frames are JSON objects, bounded by the transport's 16 KiB message limit:

| Direction | Frame | Fields |
| --- | --- | --- |
| Member → Runner | `resume` | `type`, nonnegative byte `offset` |
| Member → Runner | `input` | `type`, positive `id`, base64 `data` |
| Runner → Member | `output` | `type`, byte `offset`, base64 `data` |
| Runner → Member | `gap` | `type`, byte `from`, byte `to` |
| Runner → Member | `receipt` | `type`, `id`, `sequence`, `status`, byte count `bytes` |

Offsets and input identifiers are at most `2**53 - 1`; a resume beyond captured output is rejected. Base64 payloads
contain 1–8192 raw bytes. These frames travel only over the authenticated peer, never through
Nexus HTTP or Cable. The member caller enforces its current local permission
window, obtained through HTTP or the bounded relayed permission described above.

### Input receipts

Send one input block at a time, waiting for its `written` receipt before sending the
next. Input ids increase within a peer; the handler assigns a `sequence` increasing
across peer replacements in that handler's lifetime. The Ruby receiver generates
ids automatically and returns `Receipt` events alongside output/gap events.

`received` means the Runner accepted the input; its `bytes` is the input size.
`written` means the PTY writer accepted that many bytes (zero through the input
size). The handler must call `acknowledge_input(actual_bytes_written)` after writing;
its writer must recheck current permission while waiting or writing partial blocks.
Neither receipt proves that a shell command started, finished or succeeded.

rho's terminal panel displays these distinctions. It holds at most one in-flight
block plus one unsent 8 KiB keyboard batch. The latter retains its original
permission deadline. Receipt processing continues while output rendering is busy.
Expiry, disconnect, replacement, Stop and detach discard unsent input and mark
unconfirmed delivery unknown. Input may already have taken effect when a receipt
is lost. Reconnection never resends it; old-peer receipts cannot confirm new input.
If no written receipt arrives within five seconds, the panel also reports unknown
and closes its peer so the original handler can replace the connection. This does
not cancel the Task. Receipts have no replay window or durable ledger and never
renew permission.

Stop still follows [claim recovery](executor-inbox.md). The bridge closes its gate when the
ExecutionContext is canceled; permission expiry alone never calls cancel or releases local capacity.
The handler closes its peer and reaps its own resources in its existing cancellation/ensure path.
An accepted Stop does not prove a non-interruptible native action has finished.

Ruby uses `ExecutorTaskContext#offer_realtime` / `#realtime` and `TasksContext#answer_realtime` /
`#realtime`. TypeScript uses `offerRealtime` / `realtime` and `answerRealtime` / `realtime`.
Rust uses `offer_realtime` / `realtime` and `answer_realtime` / `realtime`. These SDK methods carry
signaling and permission projections; they do not implement media, PTY or desktop transports.
