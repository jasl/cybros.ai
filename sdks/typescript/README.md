# @cybros/agent

Typed server SDK for the Nexus member, executor and Platform APIs. Supports Node 22 and Node 24, with ESM JavaScript and declarations. This package is currently built from this repository; it is not published to a registry.

Development uses Node 22.13+ or Node 24 and pnpm 12.15.0, pinned in `packageManager`.

```sh
pnpm install --frozen-lockfile
pnpm run check
```

`pnpm run typecheck` and `pnpm run check` build the package first so examples and tests resolve the current exported declarations from a clean checkout.

A consuming application can depend on `file:../cybros.ai/sdks/typescript`, or install the tarball produced by `pnpm pack` after `pnpm run build`. Install `ws` when using the optional `@cybros/agent/realtime` entry point. The HTTP entry point has no runtime dependencies.

```ts
import { Client } from '@cybros/agent';
const client = new Client({ baseURL: 'https://nexus.example', credential: 'member-token' });
const { workspace } = await client.workspaces.create(
  { name: 'Example' }, { idempotencyKey: crypto.randomUUID() },
);
const scoped = client.workspace(workspace.public_id); // No request.
const page = await scoped.conversations.list();
```

Methods use camelCase. Request and response fields preserve the protocol's snake_case names. `undefined` is omitted; explicit `null` is sent. Opaque JSON stays unchanged. Named projections validate required response fields and preserve unknown status/event values. Authentication plane and token-type fields are closed and fail on unknown values.

Human stewards use `platform.agents.agent(id).configuration()` to inspect the saved declaration and its owned prompt documents. Applications publish configuration through `client.profile.declareConfiguration()`. Editors and Presets belong to the application; accepted execution snapshots remain independent of later declarations. See [Agent configuration](../../guides/operate/configure-an-agent.md).

Full Conversation documents expose `cost_limit: string | null` and `cost_limit_reached: boolean`. Conversation create/update accepts optional `cost_limit`; a decimal string sets it and `null` clears it. This runtime limit is separate from Human balances and Agent allowances. A limit reached by known cumulative cost refuses the next positively priced request with `conversation_cost_limit_reached`; unknown pricing remains eligible. Raising or clearing it does not restart work: use the existing Run task retry operation to retain completed graph work.

`client.work.analysis()` and `platform.modelUsage.analysis()` return model group totals, Top-N remainder, amount sample counts and nearest-rank latency percentiles. Exact UTC windows retain fractional seconds and span at most 90 days. Member analysis additionally reports its currently readable Run cohort and retained tools; model filters affect only model receipts. Money remains decimal strings, missing percentiles remain `null`, and unknown group, rank and status-map keys survive parsing. See [work analysis](../../guides/reference/agent-api/work-analysis.md).

`client.schedules.list({ workspace_public_id })` narrows currently readable schedules to a Workspace; global and scoped lists share its status filter. Schedule execution references include `variant_public_id`; use `conversation.turns.variant(turnId, variantId)` to read that exact retained result as `{ variant, turn_public_id, turn_inherited }`. Human budget reads are available through `client.profile.budgets` and `platform.profile.budgets`. Administrators use `platform.budgets(humanId)`, while current Agent stewards use `platform.agents.agent(agentId).budgets` for allowance reads and explicit-key mutations. Lists preserve `current_budget`, measurement time, exact headroom and pagination; `fetch()` returns the budget with its measurement time, and `entries()` exposes amount ledger metadata. See [budgets and allowances](../../guides/reference/platform-api/budgets.md).

`client.memoryCollections` exposes global list/fetch/update/archive/restore/delete
and `documents(collectionId)`. Owner-scoped `memoryCollections` on profile,
named Agent, Workspace and Conversation handles adds create and paginated discovery.
Direct document paths are relative. `chat.memory` retains binding paths; its writes,
edits and deletes require `expected_collection_public_id` along with the original
document UUID/version, including null/null document conditions for create. Use
`chat.memory.bindings()` to select the UUID when the document is absent.
`MemoryBinding.source` is either a natural scope source or `{collection_public_id}`;
`MemoryContextLimit` accepts only natural sources without private identities.
Collection metadata uses its own `lock_version`. See
[Memory collections](../../guides/reference/agent-api/memory-collections.md).

`Client`, `ExecutorClient` and `PlatformClient` accept exactly one static `credential` or asynchronous `credentialProvider`, resolved once per request. `Sessions`, `DeviceFlow` and `ApplicationOAuth` cover password, device and PKCE ceremonies. `OAuthCredentials` accepts an application-owned atomic `CredentialStore`; refreshes serialize through `withLock`, retain a newly issued pair if publication fails and expose it through `NotDurable.credentials`. Call `persist()` to retry storage, and `drain()` before shutdown. A replacement issue supersedes the old connection. `APIKeyCredentials` is a static holder with no refresh lifecycle.

Mutation keys are explicit. The SDK does not retry mutations, choose keys, follow redirects, log credentials or write filesystem state. Receipts expose the resource, HTTP status, replay flag and request ID. Errors retain HTTP status, code, details, Retry-After, request ID and at most 4096 characters of response body. A local AbortSignal never cancels accepted server work. Request deadlines cover credential resolution, connection and body consumption; downloads remain caller-owned streams that must be consumed or canceled.

Durable feeds freeze replay watermarks, reconcile live gaps and reconnects, and advance the saved position only after successful consumption. Async iteration acknowledges the prior item when the next item is requested; breaking may replay the last item. Retention gaps require explicit state recovery. Transcript and progress subscriptions are ephemeral. `InputExecution` retains an accepted Input's original identity, follows only automatic fallback descendants and reads decisions separately; standalone Run scopes expose their own task lifecycle. `TranscriptAccumulator` bounds its UTF-8 tail while retaining the total byte count; `ThreadAccumulator` reconciles live mainline rows with settled snapshots.

`rewind()` forks history and restores retained checkpoints independently on their original Runners. Its explicit root idempotency key deterministically derives separate keys for each Runner operation. A restore refusal or failure stays attached to that Runner; this is not a global rollback. `waitForToolResult()` has explicit polling/patience options and never stops server work on local timeout or cancellation.

Coverage is checked against `contracts/nexus/v1/operations.json`: all supported routes have actual public-method dispatch tests. Administrator Human removal is deliberately excluded. Ruby ModelPattern/ModelAdaptations policy loaders are application policy and are not included. No compatibility aliases or generic raw HTTP API are exported.

See [the guide](../../guides/build/sdk-typescript.md), [the compiled example](examples/server.ts), and [the shared API contracts](../../contracts/nexus/v1). `pnpm run test` runs behavior and contract tests with Vitest. After building, `pnpm run test:node` runs native HTTP, binary streaming, multipart, SSE and Cable tests against the build; `pnpm run test:package` repeats those checks against a tarball and compiles its exported declarations, guide and example. CI runs the complete `pnpm run check` under Node 22 and Node 24, including strict types, shared fixtures, route coverage and both package checks.
