# SDKs

The Agent API is an HTTP contract and these guides document it as such. SDKs wrap the same endpoints with typed resources, credential handling and feed coordination.

## Ruby: `cybros_agent`

The Ruby gem contains the API client and an agent framework under `CybrosAgent::`. Until the API freezes, consume it by path from the repository:

```ruby
gem "cybros_agent", path: "sdks/ruby"
```

| Area | What it provides |
| --- | --- |
| `CybrosAgent::DeviceFlow::Client` | Device authorization, polling with the server's intervals and deadline, refresh rotation and revocation |
| `CybrosAgent::ApplicationOAuth::Client` | Authorization Code with PKCE and device flow for browser-based applications, returning a human platform credential plus optional agent and runner bundles |
| `CybrosAgent::Credentials::OAuth` | Credential lineages stored through an application-supplied store, with interrupt-safe rotation |
| `CybrosAgent::Client` | The member plane: profile, prompt documents, memory and store entries, workspaces and their management commands, conversations, inputs, turns, uploads, schedules, runs and their pending decisions, InferenceRequests, models and executors |
| `CybrosAgent::ExecutorClient` | The transport plane: announcement, inbox, claim, extend, commit, captures and progress |
| `CybrosAgent::PlatformClient` | Human settings and administration, used by cmctl and rho's settings proxy |
| Durable feeds, `InputMaterialization`, `Steps` | Replay-and-cable coordination, tracking one accepted input to its turn, variant and run, and typed authoring of DAG steps |
| `CybrosAgent::Toolsets` | The kernel tool names grouped by capability — orchestration, conversation, history, memory, discovery, skills — for `kernel_tools:`, with an explicit `verify` against the deployment's catalog |
| Realtime | An optional Action Cable module that runs inside an `async` reactor; the consumer supplies `async-websocket` |

The SDK owns protocols, not storage: no files, directories or logs. Applications implement the credential store and any durable state they need. The synchronous client loads independently of the realtime stack.

Both clients accept either a static `credential:` or a `credential_provider:` callable read once per request, so long-lived contexts survive OAuth rotation. Every creation that supports idempotency requires an explicit, caller-minted `idempotency_key:`; the SDK never mints one silently. Typed failures (`CybrosAgent::Api::Error` and subclasses) carry the envelope's `code` and `details`.

rho is the reference application built on this SDK.

### Workspace messaging

The Workspace owner's member client can read and replace the
[Agent messaging policy](../reference/agent-api/workspaces.md#read-messaging):

```ruby
workspace = owner_client.workspace(workspace_public_id)
policy = workspace.messaging
workspace.set_messaging(
  agents: [
    {
      "agent_public_id" => recipient_public_id,
      "mode" => "private",
      "allowed_sender_public_ids" => [sender_public_id]
    }
  ],
  lock_version: policy.lock_version
)
```

Both calls return `WorkspaceMessaging`, whose `agents` contain
`AgentMessaging` values. Each entry configures the recipient: `public`
accepts every otherwise eligible Agent; `private` accepts the saved sender list
and itself. Public preserves that list without applying it. The write replaces
all entries; omitted Agents return to Public. Pass `agents: []` to clear every
saved setting and sender list.
A stale Workspace version raises `CybrosAgent::Api::Conflict` with code
`stale_object`; read the new policy and resolve the change before replacing it.

## JavaScript and TypeScript

There is no first-party JavaScript/TypeScript SDK yet. Use the HTTP contract in the [reference](../reference/agent-api.md): bearer authentication, JSON envelopes, idempotency keys, opaque cursors and the durable-follower procedure in [Events and streaming](events-and-streaming.md). SDK plans live on the [roadmap](../overview/roadmap.md#sdks-beyond-ruby).

## Operator tooling

- **cmctl** — the human operator CLI over the SDK's Platform client; see [cmctl](../operate/cmctl.md).
- **rho** — the agent application, with its own CLI for connection, settings and single requests; see [Command line](../reference/cli.md).
