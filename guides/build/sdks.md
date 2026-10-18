# SDKs

The SDKs expose the same Nexus HTTP contract through typed resources, credential
handling and execution observation. Choose a language for your application;
Nexus owns the durable execution in every case.

| Language | Package | Calling style |
| --- | --- | --- |
| [Ruby](sdk-ruby.md) | `cybros_agent` | Synchronous HTTP with optional Async realtime |
| [TypeScript and JavaScript](sdk-typescript.md) | `@cybros/agent` | Promises and async iteration under Node.js |
| [Rust](sdk-rust.md) | `cybros-agent` | Async Tokio clients with optional realtime |

Use the packages by path from the repository. Package-registry publication is
separate from the source SDKs.

## Contracts and compatibility

Use Nexus, the SDKs, `contracts/nexus/v1` and these guides from the same checkout.
The [API reference](../reference/index.md) owns the public wire contract; shared
fixtures pin payloads, operation coverage and unknown-value behavior. Under the
[pre-release compatibility policy](../overview/release-and-compatibility.md),
interfaces may change with their implementations, clients and documentation.
The accepted source API baseline is the Git tag `sdk-api-baseline-2026-10-15`.

Each language keeps native method and type conventions. Protocol fields remain
`snake_case`, public resource identities are UUIDs, and opaque tool arguments or
structured outputs retain their original JSON keys. New response status/event
values remain readable. Credential grants reject unsupported plane and
token-type discriminators because those fields select authority.

## Credentials and ownership

All three SDKs separate Member `Client`, `ExecutorClient` and `PlatformClient`.
Human login Sessions authenticate Platform calls. Conversation, Run and Task
retain their execution meanings; a Session is not an execution handle. See
[Credentials and planes](credentials-and-planes.md).

Applications supply credentials and persistence ports. SDKs do not own files,
directories or logs. A resource handle does no IO until a method is called.
Creation uses caller-supplied idempotency keys; clients do not automatically
retry mutations or follow redirects. Canceling a feed or InputExecution observer
ends local waiting. Server cancellation and Run stop are explicit commands.
Ruby's managed `wait_for_tool_result` composition also stops its one-task Run
after a failed terminal result or its explicit `patience` deadline; interrupting
that waiter does not stop work. The TypeScript and Rust tool-result waiters only
observe, including when their local deadline expires.

Member, Executor and supported Platform resources share the same contract.
The Platform admin User-removal command is deliberately absent from typed SDK
resources; operator tooling owns that workflow. Deployment progress uses the
existing bounded SSE observation endpoint and never resubmits an upgrade when
the stream ends.

## Observe an execution

Use the Member client's `work` resource for cross-Workspace queries:

| Query | Ruby | TypeScript | Rust |
| --- | --- | --- | --- |
| Global Runs | `client.work.runs(...)` | `client.work.runs(...)` | `client.work().runs(&query)` |
| Attention | `client.work.attention(...)` | `client.work.attention(...)` | `client.work().attention(&query)` |
| Work report | `client.work.report(...)` | `client.work.report(...)` | `client.work().report(&query)` |

These reads use the member's current access. They return typed Run pages,
Task attention pages and work reports; commands remain on the existing scoped
handles. See [Runs](../reference/agent-api/runs.md),
[Attention](../reference/agent-api/attention.md) and
[Work report](../reference/agent-api/work-report.md) for filters and measurements.

Save the event position together with the accepted Input UUID. Conversation
InputExecution correlates that Input with its original Turn, Variant and Run.
It follows that candidate's automatic fallback and never substitutes a later
input or manual regeneration. A manual regeneration is observed from its own
returned identity. Standalone Runs use Run state, events and task results.

Durable feeds recover through HTTP replay and advance the position only after
successful consumption. Reconnection and sequence gaps resume replay; expired
history requires explicit state recovery. Transcript/progress frames are
ephemeral and do not carry a durable position. Ending observation does not
stop accepted work. See [Events and streaming](events-and-streaming.md).

Typed Steps and catalog-verified Toolsets author work for Nexus. Model-specific
prompt/tool adaptation packs remain application policy; the existing Ruby
helpers do not define another cross-language Nexus contract.

## Operator tooling

- [cmctl](../operate/cmctl.md) is the Human operator CLI over the Ruby Platform client.
- [rho](../reference/cli.md) is the reference agent application, with connection,
  settings and request commands of its own.
