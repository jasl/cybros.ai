# Agent API OneShots

Status: live Agent API resource.

A OneShot is one accepted model request and its execution — one, or a
second on the creator's declared fallback when a provider's classifier
declined the first ("The creator's declared fallback", below): created
asynchronously, observed by polling, by the durable events replay window, or
by the realtime cable stream. It is ONE resource with the workload in the
payload — the typed per-workload lanes are the SDK's (`sdks/ruby/README.md`).

## Routes

```http
GET    /agent_api/v1/workspaces/{workspace_public_id}/one_shots
GET    /agent_api/v1/workspaces/{workspace_public_id}/one_shots?workload=text_generation
GET    /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{public_id}
POST   /agent_api/v1/workspaces/{workspace_public_id}/one_shots/input_estimate
POST   /agent_api/v1/workspaces/{workspace_public_id}/one_shots
POST   /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{one_shot_public_id}/cancellation
DELETE /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{public_id}
GET    /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{one_shot_public_id}/events
GET    /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{one_shot_public_id}/events?after=...&limit=...
GET    /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{one_shot_public_id}/files/{index}
WS     /agent_api/v1/cable
```

## Input estimate

`POST .../one_shots/input_estimate` accepts the same workload, model, input,
configuration, and uploads as Create under an `input_estimate` root. It does
not take an `Idempotency-Key` because it writes nothing.

```json
{
  "input_estimate": {
    "workload": "text_generation",
    "model": { "model": "openai_api/gpt-6.1-sol", "reasoning_effort": "medium" },
    "input": "say hi",
    "configuration": {},
    "upload_public_ids": []
  }
}
```

The response uses the model selected from the Catalog currently loaded in
this process:

```json
{
  "input_estimate": {
    "input_tokens": 12,
    "tokenizer_exact": true,
    "catalog_input_token_limit": 1050000,
    "model": {
      "provider_id": "openai_api",
      "model_ref": "gpt-6.1-sol",
      "reasoning_effort": "medium"
    }
  }
}
```

This is a client aid for deciding whether to compact or trim input. The call
performs the same selection, upload resolution, and input normalization as
Create, then counts locally: it creates no OneShot or ModelInvocation,
contacts no Provider, and stores no estimate or Catalog revision. It also
does not promise that a later Create will be authorized or accepted.

`tokenizer_exact` says only whether the selected profile's declared tokenizer
counted the text portion of the local estimate. It does not make Nexus authoritative for the
Provider's chat template, tokenization, or live context window. The Provider
is always final, and neither the hard Catalog limit nor the softer advisory
limit is a server-side admission gate. Optional limits are absent when the
Catalog declares none. Selection, upload resolution, workload normalization,
and counter failures use typed `422` refusals. The estimate deliberately does
not perform Create's idempotency, authority, canonical-storage, or durable
write checks.

## Create

`POST .../one_shots` requires an `Idempotency-Key` header (blank is
`400 idempotency_key_required`). The body:

```json
{
  "one_shot": {
    "workload": "text_generation",
    "model": { "model": "openai_api/gpt-6.1-sol", "reasoning_effort": "medium" },
    "input": "say hi",
    "configuration": {},
    "upload_public_ids": [],
    "billing_subject": "optional-app-key"
  }
}
```

- `input` is a string or an array of message objects; the coercion boundary
  inside the domain types it all-or-nothing.
- For `image_generation`, `input` is the prompt string and `upload_public_ids`
  supplies the source images for an edit. Their submitted order and repeated
  occurrences are preserved on every provider attempt. An empty list requests
  image generation without source images.
- Creation is asynchronous: `202 Accepted` returns the queued resource.
  Exact replay under the same key returns `200` with the standing resource;
  a different payload under the same key is `409 idempotency_envelope_mismatch`.
  The key is reserved for 24 hours per caller within the workspace, across
  workloads. After expiry it is a new create; the original OneShot is unaffected.
- Refusals are TYPED: the domain's refusal symbol is the error code at
  `422` (`model_plane_unavailable`, `billing_subject_too_long`, upload
  and selection refusals), except `not_authorized`, which is an honest
  `403` (the workspace is not writable by the caller).
- Two refusals carry a status the code decides rather than the surface.
  `not_authorized` is the `403` above; a refusal whose code belongs to the
  family — a storage-bound `content_too_large` from the input body — carries
  its published status, `413`. The vocabulary is otherwise OPEN: branch on
  `422` plus whatever code string arrives, and treat one you do not know the
  way you would treat any other `422`.
- A model that cannot take this much input is NOT a payload refusal. It is
  `422 input_over_model_limit`, measured against that model's own declared
  limit, and an upload too large to inline into one request part is
  `422 input_media_too_large`. Neither is `content_too_large`, which is this
  platform's storage and envelope bound and says the server would not process
  the request at all.

## Read

`show` renders the full projection: `public_id`, `workload`, derived
`status` (`queued | running | completed | failed | canceled | timed_out`),
`model {provider_id, model_ref, reasoning_effort}`, `billing_subject`,
timestamps, `usage_summary` (the cumulative counters across the whole
attempt history, retries included — always present, zeros when nothing was
recorded), and — once terminal — `result {status, finish_quality,
refusal_category, output_text, usage, timing, error, reasoning,
model_change}` (absent members compact away: a cancelled-before-start run's
result is just its status). `status`, `model` and `result` are the run's
LATEST execution — the one a declared fallback started, when one did (below).

**Vectors.** An `embedding` run's answer is not prose: its terminal result
carries `embeddings: [{index, vector}]` — the provider's ordinal and the
numbers, in the provider's order — and `output_text` is ABSENT on that
workload. There is no JSON document to parse out of the prose slot.

**Binary outputs.** An `image_generation` or `speech_generation` run produces
files, and terminal results for those workloads carry `output_files`:
`[{index, filename, content_type, byte_size}]`. The member is ABSENT for a
workload that produced none, so a text caller never has to know it exists.
`output_text` on those workloads is whatever prose the provider sent alongside
— a revised prompt, usually nothing — never a handle on the bytes.

```http
GET /agent_api/v1/workspaces/{workspace_public_id}/one_shots/{one_shot_public_id}/files/{index}
```

`index` is the ordinal from the listing and the only address a file has: the
bytes carry no identifier of their own. The route streams them through this
API under the same workspace containment as the OneShot itself — deliberately
not a redirect to storage, because a storage URL is a bearer token that
outlives every authorization made here. Addressing a file through a workspace
that does not contain its OneShot is `404`, exactly as reading the OneShot
there would be.

The route streams through the framework's own `ActiveStorage::Streaming`, on
whichever storage service the deployment configured. It honours `Range`,
answering `206` with `Content-Range` for a satisfiable one and `416` for a
range past the end, so a long speech clip can be seeked and an interrupted
download resumed rather than restarted; a whole read carries `Accept-Ranges`
and `Content-Length`.

`finish_quality` is the caveat beside the status, and it appears ONLY when
the answer stopped early: `output_budget_exhausted` (the output allowance ran
out — ask for more) or `context_window_exhausted` (the shared window ran out —
compact the input). A run that says `completed` with no `finish_quality` ran
to its natural end; one that says `completed` WITH it produced a real,
billed, but cut-off answer. It is deliberately not a member of `error`: a
truncated answer is a success with a caveat, and `error` is for runs that
produced nothing. A terminal replay wake may carry the same caveat, but the
REST result is authoritative.

A DECLINED answer is not a caveat but a FAILED run, reported the way every
other lane reports it: `refused` (the provider's classifier declined the
request or the answer — an HTTP 200 whose finish says so, on every lane) or
`blocked` (a content-protection stop on the content itself) sits in
`finish_quality`, `status` is `failed`, `error.code` is `model_refused`,
there is no `output_text`, and `refusal_category` is the provider's own word
for why — `cyber`, `SAFETY`, … — absent when it named none. The call was
billed, so `usage` is its receipt. Re-sending the same request to the same
model usually earns another refusal. Until the terminal event is recorded
the run reads `running` with no `result` — the refusal's apply and what it
comes to are two moments, and nothing may act on the first alone — so a
`DELETE` in that window is `409 not_terminal` like any running work.

**The creator's declared fallback.** When the run's creator is an Agent
Profile that declared a `fallback_model` ([Profile](profile.md)), a
`refused` answer — never a `blocked` one — or whose provider was overloaded
on every attempt of its budget (503, 529 or the streamed `overloaded_error`
each time: `provider_overloaded`) runs ONCE more on that model
before the run settles: the same sealed input, under the parameters the
caller chose (the declining model's own defaults are left behind), at the
fallback's reasoning default. The decision is made when the declined
answer's terminal is recorded, against the gates the create judged, read
again at that moment: the run is live, its workspace still takes the
creator's writes, the account can run the fallback for this request, and
the fallback takes the input (a picture, for one, is refused by a text-only
model; a model that needs every tool round's reasoning back refuses an
input carrying tool rounds). Any of them failing, no declaration, or a
fallback equal to the model that failed, and the failure stands as above. After a switch the
run reads the new execution — `status` from `queued` onward, `model` the
fallback's — and its finished `result` is the fallback's answer, receipt and
finish, with `model_change {from, to, reason: "model_refused" | "provider_overloaded", category}`
(`category` absent when the provider named none) saying what it replaced;
`usage_summary` counts both calls. A run switches once: a fallback that
declines or is overloaded in turn is the failed run above, `model_change`
beside it. Until the terminal converger has decided — the switch or the
stand — a declined or overloaded run reads `running`. The
declared ref is read live from the creator's profile, and the kernel
chooses no model of its own.

`result.error` is `{code}`. When the retry budget is what ended the run, `code`
names what the PROVIDER said on the last attempt — `provider_overloaded` when it
said so on every one — and `error` carries the additional member
`attempt_budget_spent: true` beside it — present ONLY in that case. That one is special because both facts exist and only one used to be
reported: "retry later" and "fix your request" are the two answers a failed turn
has to tell apart, and a caller that saw only the budget code learned that we
stopped, not why.

A provider HTTP 401, 403 or 404 is classified as
`provider_model_unavailable`. OneShot preserves that failure; it does not
use the automatic fallback reserved for conversation result mail, and the
declared fallback above is for a refusal or an overload alone. A rate limit
(429) is neither: it waits out the provider's `Retry-After` floor and retries
within the budget.

Every other terminal reason names ITSELF, because there is no provider answer to
relay: a passed deadline (`timed_out`), a result that could not be stored, and
the authority and lifecycle reasons a run can end on are this side's own
judgements and say so. A failed replay wake carries a bounded error summary;
read the OneShot for the complete terminal result.

`result.usage` is the terminal attempt's own receipt (`cost_complete`
distinguishes computed money from unmetered or unanswered pricing). A durable
`usage` event may narrate the same attempt receipt as a snapshot, but does not
replace this read. The list renders summaries with keyset pagination
(`pagination.next_after`).

No effective access, tombstoned workspaces, and tombstoned OneShots all read
as `404 not_found`.

## Cancel

`POST .../cancellation` is a named command (never DELETE), idempotent and
total: it cuts the invocation through the same kernel every authority cut
uses, converges asynchronously, and returns the standing projection —
cancelling terminal work changes nothing. A declined answer whose terminal
is not yet recorded (the run still reads `running`) settles on the spot as
the failed run it is, and no fallback follows: the stop wins over the
switch; a fallback already started is cut like any running work. Requires
the workspace write tier (`403 not_authorized` otherwise).

## Delete

`DELETE .../one_shots/{public_id}` is delete intent itself (the one verb
the command doctrine reserves for it): terminal-only tombstone — the run
disappears from every read and the frozen 30-day reap clock starts.
Success is `204`. Running work refuses `409 not_terminal` (cancel first;
cleanup never cancels on the caller's behalf); requires the write tier
(`403`); a second DELETE reads as the `404` the concealment already
serves. Receipts and their statistics outlive the aggregate — only the
run, its events, and its content go.

## Events replay

`GET .../events` serves the durable replay stream: items strictly AFTER the
opaque `after` cursor, ascending, default window 100, `limit` at most 200
(beyond is `400`, a reject rather than a clamp; malformed cursors are `400`
too). Each item is `{public_id, sequence, cursor, type, resource {type,
public_id}, occurred_at, payload}`; `pagination.next_after` is the last item's own
cursor. Item types: `run_status`, `text_delta`, `reasoning_delta`,
`provider_output_item_*`, `usage`, `result`, `rollback` (streamed output
was thrown away — reset and replay; its `reason` is `retry` for a transient
retry and `refused` for an answer the provider declined, which the kernel
stores none of). A declined answer the creator's fallback runs again ends
its own execution with `run_status {status: "queued", model_change}` and
its `usage` — no `result`, since the run goes on — and the fallback's
execution then streams and ends as any run does.

**Two ordered values, two jobs.** `sequence` is OneShot-local, starts at 1 and
is contiguous — order and merge by it, and treat a jump as proof you missed
something. `cursor` is opaque: hand it back to a replay read and never parse
it. They will not disagree, which is why you never need to.

**`pagination` carries two different answers, and following needs the second.**
`next_after` is where THIS PAGE stopped, and it is null when the page is empty.
`watermark` is the highest sequence committed to the stream when the request
was served — where the STREAM is. Drain until the last sequence you applied
reaches the watermark you froze before you started; a page that "came back
short" proves nothing about a run that is still producing. `watermark` is a
sequence rather than a cursor for the same reason as above: it exists to be
compared, and it is present on every page, including an empty one.

## Realtime stream

**What each transport is for.** Bytes and commands go over HTTP: staging an
upload, placing a run, reading a run, fetching a file it produced. The socket
is a low-latency mirror of durable projected event items, not a second result
API. It carries deltas while a run is producing them and bounded lifecycle
wakes when state changes. The terminal `result` item contains status, optional
finish/error summary, and the OneShot id; fetch the OneShot for the complete
currently exposed output, files, usage, timing, and reasoning. The typed
non-text result objects — `embeddings` as `[{index, vector}]`, the output
files streamed by ordinal — are the SDK's (`sdks/ruby/README.md`) and are
not restated here.

**Subscribing is the client's decision and it is not required.** The replay
window alone delivers every durable event in order, so a consumer that never
opens a socket is a supported consumer rather than a degraded one — it trades
latency for one fewer connection. A client following several runs will usually
want a socket only for the one a person is looking at. Attaching one late is
the same barrier used at the start:

    drain the replay window to a frozen head → subscribe → drain the gap → live

The gap drain is not optional. Subscribing replays no backlog, so items
published between the head you froze and your confirmed subscription exist only
in the replay window. `CybrosAgent::KernelFeed` implements this sequence and
re-runs it after every disconnect; a consumer writing its own follower owes the
same barrier. Detaching costs nothing and loses nothing: keep the position you
reached, stop the socket, and the replay window still holds everything from
there.

ActionCable at `/agent_api/v1/cable`, authenticated by the same member
credential as the REST surface — `Authorization: Bearer …` on the upgrade. A client that is not
a browser may omit `Origin` or send the HTTP(S) origin of the configured API
endpoint. A different browser origin is rejected before authentication.

Every subscription reloads the bearer credential and evaluates current
Workspace access before it starts a stream. A committed token revocation or
Workspace authority cut also asks ActionCable's adapter to disconnect the
affected sockets; a reconnect then reauthorizes every subscription, and bearer
authority is rechecked periodically while the connection remains open. Nexus
does not put an ACL query on every published delta. Consequently an existing
Workspace subscription depends on that adapter disconnect reaching the cable
process. If the notification cannot be published, that subscription can remain
until its transport reconnects; Cable carries no fact absent from the durable
stream, and every REST replay/read request reevaluates current authority.

**Two deployment facts a client cannot work around.** The WebSocket handshake
is an HTTP/1.1 `Upgrade`, so a reverse proxy in front of this API must forward
the `Upgrade` and `Connection` headers or the cable cannot work at all. And
over TLS, offer **only `http/1.1` in ALPN**: if the negotiation settles on h2,
the handshake becomes RFC 8441 extended CONNECT, which Rails' hijack-based
upgrade does not speak — and the shipped image fronts the app with an HTTP/2
proxy, so this is the normal case rather than an exotic one. Both are silent
in a plain `ws://` localhost setup and appear only in a real deployment.

The channel `AgentAPI::V1::OneShotEventsChannel` (params: `workspace_id`,
`one_shot_id`, optional `items`) carries `{ "event": <the same public event
projection as replay> }` on stream
`agent_api:v1:one_shot:{public_id}:events`.
Authorization mirrors REST tier by tier, and a refusal arrives as
`reject_subscription`.

**`items: "lifecycle"` is for a subscriber that is not reading the output.** It
carries `run_status` and `result` and nothing else — where the run GOT TO, as
opposed to what it is producing — on the separate stream
`…:{public_id}:lifecycle`. The narrowing is a different broadcasting rather
than a filter applied per subscriber, so the SOCKET carries two frames for a
run instead of one per delta. That is what lets a client hold many runs it is
not watching and be told the moment each one finishes, on the one socket
ActionCable multiplexes every subscription over — in place of a poll per run
per second. Any other `items` value is rejected rather than silently given the
wider feed. Omitting `items` selects `events`.

**What the narrowing does NOT do is spare a barrier-following consumer the
deltas**, and the reason is worth stating because the shape is not obvious. The
replay window takes no narrowing — `GET .../events` serves the whole stream —
and a correct follower drains it whenever a live item arrives more than one
sequence past its position. On a lifecycle stream that is nearly every item, so
the follower re-drains and receives the deltas it did not subscribe to. That is
not waste: the durable window is the authority, the drain is what makes the
answer complete, and it happens twice per run rather than once per second. The
saving is a socket that stays silent and a client that stops polling — not a
consumer that never sees a delta. A consumer that genuinely wants no deltas at
all reads the run's `result` and ignores the rest.

A lifecycle subscriber that later wants the output does not start over. It
attaches the full subscription through the same barrier as any other late
attach, which replays what landed while it was not reading and then continues
live.

**Delivery is opportunistic and the REST window is the authority.** The socket
may miss an item, deliver one twice, or deliver two out of order; a broadcast
that fails is logged and never fails the run that produced it. Subscribing
replays no backlog — you receive only what is published after your
subscription is confirmed.

So a client that must not miss anything follows this order, and it is the
whole contract:

1. Freeze the `watermark` and `GET .../events?after=<your last cursor>` until
   the last sequence you applied reaches it.
2. Subscribe, and wait for the confirmation.
3. Drain again from your cursor, to a NEWLY frozen watermark — this covers
   whatever was published between step 1 and the confirmation.
4. Apply live items, dropping any whose `sequence` you have already applied.
   A sequence *ahead* of the next one you expect means you missed something:
   go back to step 3 rather than accepting the jump.
5. Advance your stored cursor only after your handler has finished with the
   item, so a crash replays it instead of losing it.

This detects a dropped frame only when a later sequence exposes the gap. If
the dropped frame was the final wake, the socket alone has no later fact with
which to prove it. A consumer that requires bounded terminal detection must
also poll the OneShot REST read (or deliberately reconnect and drain on its
own idle policy). The protocol does not currently define an idle timeout or
server-side terminal acknowledgement; a consumer that needs one polls the REST
read. This policy belongs to the consuming application; the SDK's feed does
not provide bounded terminal detection on its own.

### Following without subscribing

Not subscribing is a supported way to use this API — every fact the socket
carries is durable and readable over HTTP — but the two things you might
follow have very different costs, and the difference decides your design.

**Terminality across many turns is bounded, not magically constant.**
`GET .../one_shots` returns up to 100 current projections per page, ordered by
UUIDv7 `public_id`. Its keyset cursor advances to later-created rows; it does
not revisit an earlier in-flight row when that row becomes terminal. Poll a
known OneShot directly when its completion matters, or reread the bounded
pages that contain the runs you are supervising. The API makes no O(1)
terminality claim across an unbounded set of runs.

**Deltas are not.** Each turn's `GET .../events` is its own request, so
following N turns' narration costs N requests per poll. Its budget is 6,000
requests per minute per credential, so at a poll interval of P seconds the
ceiling permits `100 * P` concurrent turns before allowing for replay or other
requests. The `one_shots` create/read family has its own 6,000-request budget;
input estimation and cancellation each have a separate default 6,000-request
budget. These limits do not guarantee server throughput.
Leave headroom instead of treating any ceiling as a target.

So: poll known OneShots for "is it done", and subscribe when you want to watch
the words arrive. A `429` carries `Retry-After`; honour it rather than retrying
on your own schedule.

**One caveat about which host produces what.** The reactor (`bin/model_runner`)
streams the deltas; the terminal `result` item is written by a queue worker. A
deployment running the reactor without a queue host will stream an answer and
then never close the stream.
