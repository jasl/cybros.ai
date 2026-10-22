# cybros-agent

Asynchronous Rust clients for Cybros Nexus. The crate uses Tokio and reqwest;
`realtime` adds a native Action Cable client. Minimum supported Rust: **1.85**.
Repository development uses the pinned `rust-toolchain.toml`.

```toml
[dependencies]
cybros-agent = { path = "../cybros.ai/sdks/rust" }
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
```

Use `cybros_agent::Client` for Member operations, `ExecutorClient` for execution
claims and results, and `PlatformClient` for Human administration. All resource
handles share a pool and construct without IO. See
[`examples/submit.rs`](examples/submit.rs) for a typed Conversation input.

```rust,no_run
use cybros_agent::{Client, Result};

async fn profile(base_url: &str, member_token: &str) -> Result<String> {
    let client = Client::new(base_url, member_token)?;
    Ok(client.profile().fetch().await?.body.member.handle)
}
```

The clients expose the supported Member, Executor and Human Platform operations,
including Agents and their API keys, managed machines, budgets, usage and bounded
Deployment log streams. User removal through the administrative User surface is
intentionally excluded. Protocol field names stay in `snake_case`; UUIDs,
timestamps and decimal money amounts stay strings. Named request documents live
in `types::requests`, and named response documents in `types::member` and
`types::platform`. Open response vocabularies retain newer values as `Unknown`.
OAuth and credential authority discriminators reject unsupported values.

`Field::Unset`, `Field::Null` and `Field::Value(value)` distinguish omitted values
from explicit nulls. Opaque tool input, provider configuration and structured
output remain JSON. A `Response<T>` carries its typed body, HTTP status, headers
and idempotency replay flag. Mutations that require an operation key accept it
explicitly; keep that key with your operation and reuse it for intentional replay.

Full Conversation documents expose `cost_limit: Option<String>` and
`cost_limit_reached: bool`. `CreateConversation` and `UpdateConversation` accept
`cost_limit: Field<String>`: `Unset` preserves omission, `Null` clears it and
`Value` sets an exact decimal amount in Account units. This runtime limit is
separate from Human balances and Agent allowances. Known cumulative cost at or
above the limit refuses the next positively priced request with
`conversation_cost_limit_reached`; unknown pricing remains eligible. Raising or
clearing it does not restart work: use the existing Run task retry operation to
retain completed graph work.

## Credentials and request boundaries

Static credentials and `CredentialProvider` resolve a single requested plane.
The SDK never substitutes a Human token for a Member or Executor credential.
`OAuthClient` provides device connection, Application OAuth login, PKCE, code
exchange, rotation, revocation and bounded polling. Application and child grants
have independent refresh lineages.

Implement `CredentialStore` and `CredentialTransaction` in your application.
The transaction is the exclusive mutation authority shared by every owner of
that store; it holds the full wire rotation and atomic publication. A
`CredentialManager` owns started mutations in Tokio tasks, so dropping a waiter
does not discard a rotated pair. Call `drain()` before shutting down the runtime.
The crate never opens a credential file or chooses filesystem permissions.

A rotated pair is retained in memory if publication fails. `NotDurable` prevents
another rotation until `persist()` succeeds; expiry is still enforced. A failed
initial `issue()` returns an `IssueFailure` with the live holder for persistence
recovery. Replacement is fenced by the predecessor identity under the same store
transaction. An unknown rotation outcome loses refresh authority and never retries
the old single-use token. A known unsent failure remains retryable by the caller.

Requests have finite total, connect and read budgets, do not follow redirects,
and never automatically retry. Deployment release checking has a finite 130-second
operation budget. Errors preserve status, safe server messages, structured details,
request IDs and Retry-After. Transport failures distinguish known unsent requests
from ambiguous outcomes; malformed successful documents are separate decoding
errors. Secret wrapper values redact Debug and Display output.

## Events and execution

`KernelFeed` replays ordered events to a frozen watermark, deduplicates them and
advances its position only after `ack()` or a successful `consume()` callback.
Persist projection and position together. The `realtime` feature adds `follow()`:
replay, exact subscription confirmation, gap replay, then live hints. Disconnects,
forward gaps and buffer overflow recover through HTTP replay. Retention gaps are
reported explicitly; the caller recovers current state.

`InputExecution` follows one accepted Conversation Input's original execution
and automatic fallback lineage. Save the Conversation's pre-submission position
with its accepted Input UUID. Active manual regenerations never replace that
Input's result. `for_execution()` observes an explicitly selected execution.
Standalone Runs use their own state, events and task results.

`TranscriptAccumulator` retains a bounded UTF-8 tail; `ThreadAccumulator` merges
mainline transcript and progress while retaining a configured maximum number of rows. Final HTTP
snapshots replace temporary live text. Neither accumulator is durable history.
Closing a subscription or dropping/timing out an observer only ends local
observation. Input cancellation, Run stop and InferenceRequest cancellation are
explicit resource commands.

`authoring` contains Steps, deployment-catalog-backed Toolsets and deterministic
MCP tool lowering. `checkpoints` composes explicit forks and independently reported
Runner restorations using caller-owned operation keys. It does not implement an
execution engine, model router, scheduler or global rollback.

Uploads accept bytes or caller-owned streams. Downloads expose status, headers
and byte streams, including ranges, ETags and 304 responses. The application
consumes or drops streams and owns local paths.

## Verify from this source tree

```sh
bin/ci
```

This checks formatting, Clippy, default/all-feature tests, documentation, actual
Rust 1.85 compilation, package verification and an external package consumer.
Tests use shared producer-owned fixtures under `../../contracts/nexus/v1` and native
local HTTP/WebSocket servers. The operation inventory test invokes every supported
operation through its real public method; fixtures are not copied into the crate.
The cross-language E2E harness owns real Nexus and database lifecycle separately.

Work inspection includes `client.schedules().list(...)`, exact
`variant(...).fetch()`, and `client.work().analysis(...)`. Analysis keeps the
exact window, cost evidence, sample counts and nullable p50/p95 milliseconds;
`platform.model_usage_analysis(...)` provides Account aggregates.
`profile().budgets()` reads the acting member's current window, history and
amount-only ledger. `platform.agents().agent(id)?.budgets()` manages the current
steward's Agent allowance; `platform.budgets(human_id)?` manages Human balances
with an administrator credential. Missing windows and negative headroom remain
distinct, and monetary values stay decimal strings.

Agent defaults are readable through `agent.configuration()`. Applications publish
configuration through the member profile API; editors and Presets belong to the
application. Accepted execution snapshots remain independent of later declarations.
See the [configuration API](../../guides/reference/platform-api/agents.md).

The repository's [Rust guide](../../guides/build/sdk-rust.md),
[SDK overview](../../guides/build/sdks.md) and
[protocol reference](../../guides/reference/index.md) describe the public contract.
