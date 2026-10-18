# Rust SDK

Use the `cybros-agent` crate to call Nexus from an asynchronous Rust application.
Its import name is `cybros_agent`. Clients use Tokio and reqwest, with separate
Member, Executor and Human Platform roots. Resource handles share their client's
connection pool and perform no IO until an operation is awaited.

## Install from source

Add the crate by path from your application, together with the Tokio runtime you
use to run it:

```toml
[dependencies]
cybros-agent = { path = "../cybros.ai/sdks/rust" }
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

The package's `Cargo.toml` declares its minimum Rust version. Repository checks
use its lockfile and `rust-toolchain.toml`. Enable the `realtime` feature when
your application needs Action Cable; ordinary HTTP clients do not require it.
See [SDKs](sdks.md) for the shared source and compatibility policy.

## Submit a Conversation Input

Use named request types and keep the operation key with the mutation it
identifies. The SDK never creates an idempotency key for you.

```rust
use cybros_agent::{Client, Result};
use cybros_agent::types::requests::{CreateInput, InputKind, ModelRequest};

async fn submit(
    base_url: &str,
    member_credential: &str,
    workspace_id: &str,
    conversation_id: &str,
    operation_key: &str,
) -> Result<String> {
    let client = Client::new(base_url, member_credential)?;
    let conversation = client.workspace(workspace_id)?
        .conversation(conversation_id)?;
    let response = conversation.inputs().create(
        &CreateInput {
            kind: InputKind::DirectReply.into(),
            text: "Hello".to_owned().into(),
            model: ModelRequest {
                model: "local/example".to_owned().into(),
                ..Default::default()
            }.into(),
            ..Default::default()
        },
        operation_key,
    ).await?;
    Ok(response.body.public_id)
}
```

Choose a model available on your installation. `Response<T>` carries the typed
`body`, original HTTP `status`, response headers and `replayed` flag. Acceptance
does not mean execution has finished. Save the accepted Input UUID with the
Conversation's pre-submission event position and observe that exact execution.
Standalone Runs use their own state, events and task results.

Protocol fields retain their wire names. UUIDs, ISO timestamps and decimal money
values stay strings. `Field::Unset`, `Field::Null` and `Field::Value(value)` keep
omission distinct from a deliberate null where the request supports it. Opaque
tool arguments, structured output and provider extensions remain JSON values.
Response vocabularies retain unknown values; authorization discriminators
reject unsupported values.

## Credentials and errors

`Client`, `ExecutorClient` and `PlatformClient` accept only their respective
credential planes. Use a shared credential provider for a long-lived client
whose token rotates. The application implements credential storage and its
exclusive mutation port; the crate does not own files or logs.

Device connection and Application OAuth login remain separate ceremonies.
An already-started rotation owns its bounded exchange and persistence until
completion. Dropping the calling future only ends that caller's wait. Drain
started credential work before application shutdown. A persistence failure after
rotation preserves the newly issued pair and reports that it is not durable;
it never retries the spent refresh token.

Operations return `Result<T, Error>`. API failures retain HTTP status, error code,
details and request metadata. Transport errors distinguish a known unsent
request from an ambiguous outcome. Requests have finite budgets, follow no
redirects and perform no automatic retries. The application decides how to
recover or repeat a mutation using its original operation key.

## Observe and close

Durable event consumers acknowledge successful handling before advancing their
position. Reconnection or a forward gap resumes HTTP replay. Expired history
requires explicit state recovery. Transcript deltas and progress are temporary
observations; use resource reads to recover final output.

Dropping an observation future or closing a stream ends local waiting. Server
Input cancellation, Run stop and InferenceRequest cancellation are explicit
resource commands. Realtime is optional and does not replace HTTP replay.

`UploadBody` accepts bytes or a caller-provided stream. Downloads return their
status, headers and a caller-owned byte stream, preserving range and ETag
semantics. Consume or drop the stream when finished; the crate never opens a
local path or saves a download itself.

`conversation.export().await` returns that download type for a
[Conversation diagnostic export](../reference/agent-api/conversation-export.md).
The caller consumes the gzip bytes and discards partial output after failure.

See [Credentials and planes](credentials-and-planes.md),
[Events and streaming](events-and-streaming.md) and the
[API reference](../reference/index.md) for the underlying contracts.
