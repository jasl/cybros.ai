# Ruby SDK

The Ruby gem contains the API client and an agent framework under `CybrosAgent::`. Consume it by path from the repository:

```ruby
gem "cybros_agent", path: "sdks/ruby"
```

See [SDKs](sdks.md) for the shared contract and compatibility policy.

| Area | What it provides |
| --- | --- |
| `CybrosAgent::DeviceFlow::Client` | Device authorization, polling with the server's intervals and deadline, refresh rotation and revocation |
| `CybrosAgent::ApplicationOAuth::Client` | Authorization Code with PKCE and device flow for browser-based applications, returning a human platform credential plus optional agent and runner bundles |
| `CybrosAgent::Credentials::OAuth` | Credential lineages stored through an application-supplied store, with interrupt-safe rotation |
| `CybrosAgent::Credentials::APIKey` | Independent long-lived plane credentials in the same application-supplied store, without refresh |
| `CybrosAgent::Client` | The member plane: profile, prompt documents, memory and store entries, workspaces and their management commands, conversations, inputs, turns, uploads, schedules, runs and their pending decisions, InferenceRequests, models and executors |
| `CybrosAgent::ExecutorClient` | The transport plane: announcement, inbox, claim, extend, commit, captures and progress |
| `CybrosAgent::PlatformClient` | Human settings and administration, used by cmctl and rho's settings proxy |
| `CybrosAgent::Platform::Sessions` | Human password login, returning a Platform API session credential |
| Durable feeds, `InputMaterialization`, `InputExecution` | Replay-and-cable coordination, accepted-input correlation and recovery of that execution's status, content and pending decisions |
| `CybrosAgent::Steps` | Typed authoring of DAG steps |
| `CybrosAgent::Toolsets` | The kernel tool names grouped by capability — orchestration, conversation, history, memory, discovery, skills — for `kernel_tools:`, with an explicit `verify` against the deployment's catalog |
| Realtime | An optional Action Cable module that runs inside an `async` reactor; the consumer supplies `async-websocket` |

The SDK owns protocols, not storage: no files, directories or logs. Applications implement the credential store and any durable state they need. The synchronous client loads independently of the realtime stack.

All three clients accept either a static `credential:` or a `credential_provider:` callable read once per request, so long-lived contexts survive OAuth rotation. Every creation that supports idempotency requires an explicit, caller-minted `idempotency_key:`; the SDK never mints one silently. Typed failures (`CybrosAgent::Api::Error` and subclasses) carry the envelope's `code` and `details`.

rho is the reference application built on this SDK.

`conversation.export(io)` streams a
[Conversation diagnostic export](../reference/agent-api/conversation-export.md)
into caller-owned IO and returns the HTTP response. The caller closes its IO and
discards partial output if the download fails.

## API keys

Use a member key directly for an application that only calls the Agent API:

```ruby
client = CybrosAgent::Client.new(
  base_url: "https://nexus.example",
  credential: ENV.fetch("CYBROS_API_KEY")
)
profile = client.profile.fetch
```

An application that owns a credential store can install keys with
`Credentials::APIKey.issue(authority:, store:, access_token:,
executor_access_token:)`. A Runner-only store supplies only
`executor_access_token:`. `Credentials.load(authority:, store:)` loads the
document by its `authentication_kind` (`oauth` or `api_key`). Both holders expose
the same plane credential readers and `revoke`; only OAuth is `refreshable?`.
API keys have no expiry, rotation counter or refresh token. A `401` is reported
for the refused plane without a refresh attempt. Revocation calls the existing
OAuth revocation endpoint for each held key and deletes the store only after
all calls succeed; an interrupted or failed revocation can be retried.

The [Agent settings API](../reference/platform-api/agents.md) creates the Agent;
[API keys](../reference/platform-api/agent-api-keys.md) describes Human-owned
issuance and revocation.

## Execution observation

Ruby's `wait_for_tool_result` manages a one-task request Run: it stops the Run
after a non-completed terminal Task or when the caller's `patience` expires,
then returns the terminal Task. Interrupting the waiter only closes local
observation. This managed cleanup differs from the TypeScript and Rust
tool-result waiters, which leave Run lifecycle commands to the application.

Save the feed position before submitting an input, then keep that position with
the accepted input's UUID.
Observe that input without borrowing a later input's answer:

```ruby
observation = conversation.input_execution(input_public_id, position: saved_position)
observation.refresh

if observation.result
  snapshot = observation.recover
  decisions = observation.decisions if snapshot.attention
end
```

`refresh` only tracks materialization through event replay and its recovery read;
it does not fetch the variant deck, Run or decision details. `result` retains the
original turn, variant and Run identifiers. `blocked_reason` and `compaction`
describe progress before that input materializes. The application owns waiting,
deadlines and persistence of the position.

`recover` explicitly reads the candidate, retained events and current Run.
`snapshot.execution` follows only the original candidate's automatic fallback
chain; a manual regeneration or a newer input cannot replace it. `snapshot.content`
is the retained candidate's body when readable. The reads are separate
observations, so a later read may be needed while kernel state converges.
For a known execution without an input receipt, use
`conversation.execution(result)` with an `InputMaterialization::Result`.

`snapshot.terminal?` describes the observed reply, not all background work in its
Run. A completed reply can coexist with a running Run. `snapshot.attention`
describes any current attention, including questions and approvals on a running
Run; `decisions` reads their details only when called. `snapshot.needs_attention?` has the
same narrow meaning as `Run#needs_attention?`: the Run has status
`needs_attention`. It is not a test for every pending human decision. The
application owns answering, approving, retrying and stopping; ending observation
does not stop execution. See [Events and streaming](events-and-streaming.md).

## Workspace messaging

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
