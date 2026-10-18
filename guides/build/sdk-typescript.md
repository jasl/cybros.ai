# TypeScript SDK

Use `@cybros/agent` to call Nexus from a Node.js application. It provides
typed asynchronous resources, credential ceremonies, execution observation and
an optional realtime entry point. The package ships ESM JavaScript and TypeScript
declarations. Protocol fields keep their `snake_case` names.

## Install from source

Use Node 22.13+ or Node 24 for development and the pnpm version declared in the
package's `packageManager` field. Build from the repository's `sdks/typescript`
directory:

```sh
pnpm install --frozen-lockfile
pnpm run build
```

Add a local dependency to your application's `package.json`, using its relative
path to the checkout, then run `pnpm install`:

```json
{
  "type": "module",
  "dependencies": {
    "@cybros/agent": "file:../cybros.ai/sdks/typescript"
  }
}
```

Node 22 and Node 24 are the supported runtimes. This is a server SDK;
browser applications use their own server's API. See [SDKs](sdks.md) for the
shared source and compatibility policy.

[Run a standalone SDK Agent](standalone-agent.md) provides a complete source
example with device connection, an application tool, process recovery and files.

## Submit a Conversation Input

Supply a member credential and use scoped resource handles. Constructing a
handle makes no request. Keep each idempotency key with its intended mutation
so an explicit retry can reuse that key.

```ts
import { Client } from "@cybros/agent";

const client = new Client({
  baseURL: "https://nexus.example",
  credential: process.env.CYBROS_API_KEY!,
});
const { workspace } = await client.workspaces.create(
  { name: "SDK example" },
  { idempotencyKey: crypto.randomUUID() },
);
const { conversation } = await client.workspace(workspace.public_id)
  .conversations.create({}, { idempotencyKey: crypto.randomUUID() });
const chat = client.workspace(workspace.public_id)
  .conversation(conversation.public_id);
const position = { cursor: null, sequence: 0 }; // New Conversation.

const accepted = await chat.inputs.create(
  { kind: "direct_reply", text: "Hello", model: { model: "local/example" } },
  { idempotencyKey: crypto.randomUUID() },
);
const execution = chat.inputExecution(accepted.input.public_id, position);
await execution.refresh();
const snapshot = await execution.recover();
```

Choose a model available on your installation. An accepted Input may still be
queued, so `snapshot` can be `null`. The application owns later refreshes,
deadlines and durable storage. For an existing Conversation, retain its feed
position before submission and store that position with the accepted Input UUID.
The observer recovers that Input's original execution and its automatic fallback;
it never selects a newer input or manual regeneration as the answer.

Creation receipts expose the resource, HTTP `status`, `replayed` and `requestId`.
Ordinary reads return typed resources. Wire `undefined` fields are omitted;
explicit `null` remains null. Opaque JSON keys are preserved.

## Credentials and cancellation

Use `ExecutorClient` for a Runner or Tool provider and `PlatformClient` for a
Human's settings. `Sessions` performs password login. `DeviceFlow` and
`ApplicationOAuth` implement their distinct connection and login ceremonies.
The [credential planes](credentials-and-planes.md) determine which token belongs
to each client.

For a rotating credential, pass `credentialProvider` instead of `credential`.
The client calls it once for each request. `OAuthCredentials` uses an
application-supplied `CredentialStore`; `APIKeyCredentials` holds static keys
for their respective planes. The SDK does not choose a filesystem location or
write logs.

Request options accept an `AbortSignal` and a finite `timeoutMs`. Cancellation
ends the local request or observation. It does not cancel an accepted Input or
stop a Run. An already-started OAuth rotation finishes its bounded exchange and
persistence even if its caller stops waiting; drain pending credential work
before shutting down the application.

`APIError` and its subclasses expose the HTTP status, API code, details, request
ID and retry information. Redirects are refused and requests are not
automatically retried. After an ambiguous mutation, recover through the owning
resource or deliberately reuse its original idempotency key.

## Events and binary data

`chat.feed()` replays durable events. `consume(handler)` advances its position
after the handler succeeds. Async iteration acknowledges an item when the next
item is requested; stopping early can replay the last item. A retention gap
requires an explicit state-recovery decision.

Realtime lives under `@cybros/agent/realtime` and uses the optional `ws` peer
dependency. HTTP-only consumers do not load it. The socket supplies latency
hints; durable feeds reconcile through HTTP replay. Close subscriptions and
feeds when their consumer finishes.

Uploads accept caller-owned `Blob` data. Downloads return a caller-owned
`ReadableStream` with HTTP status, ETag and range metadata. Consume or cancel
that stream; the SDK never writes a local file.

`chat.export(options)` returns the same caller-owned download type for a
[Conversation diagnostic export](../reference/agent-api/conversation-export.md).
Consume the gzip file completely; discard partial output after a failed read.

See [Events and streaming](events-and-streaming.md),
[Claims and results](../runners/claims-and-results.md) and the
[API reference](../reference/index.md) for the underlying contracts.
