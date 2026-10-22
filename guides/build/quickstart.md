# Quickstart

This guide takes a new agent from a connected agent to a completed conversation reply. You need a running Nexus whose administrator has configured at least one usable text model.

## 1. Connect

Use an Agent API key for a direct connection, or use OAuth device flow when the
application asks a person to approve its installation.

### API key

In Nexus, open **Agents**, create an Agent, and issue a member API key. Save the
shown value in your application's private configuration. This guide uses no
application inbox, so a member key is sufficient.

```ruby
require "cybros_agent"
require "securerandom"

member_credential = ENV.fetch("CYBROS_API_KEY")
```

The key remains valid until revoked or fenced by the Agent's authority. It needs
no browser approval, polling or refresh during use.

### OAuth device flow

Choose a stable, non-secret installation identifier; the person approves the
connection in the Nexus browser.

::: code-group

```ruby [Ruby SDK]
require "cybros_agent"
require "securerandom"

client = CybrosAgent::DeviceFlow::Client.new(base_url: "https://nexus.example")

authorization = client.request_authorization(
  agent_identifier: "my-agent.installation-1",
  agent_display_name: "My Agent",
  executor_display_name: "My Agent on this machine"
)
puts "Open #{authorization.verification_uri} and approve code #{authorization.user_code}."
credentials = client.await_credentials(authorization)
member_credential = credentials.access_token
```

```text [What you get]
An agent connection returns two credentials:
  member credential      -> everything in this guide
  transport credential   -> the application's own executor inbox
Store both as one agent credential bundle and rotate them with its refresh token.
```

:::

See [Credentials and planes](credentials-and-planes.md) for both credential lifecycles. Every request below sends:

```http
Authorization: Bearer <member credential>
Accept: application/json
Content-Type: application/json
```

## 2. Discover a model

```http
GET /agent_api/v1/models?workload=text_generation
```

Choose a returned `ref` according to your own policy. Do not hard-code a model from an example: each deployment controls its catalog, credentials and visibility. An empty list means no text model is available.

## 3. Declare the agent

One atomic replacement of the configuration and the agent's own prompt documents. For a text-only agent:

::: code-group

```http [HTTP]
PUT /agent_api/v1/profile/configuration

{
  "configuration": {
    "tool_definitions": [],
    "approval_mode": "ask",
    "approval_rules": null,
    "prompt_mechanism": "default",
    "compaction_policy": { "mode": "kernel" }
  },
  "prompt_documents": {
    "system_prompt": { "content": "Give clear, accurate answers and state uncertainty." },
    "summarizer": null
  }
}
```

```ruby [Ruby SDK]
client = CybrosAgent::Client.new(
  base_url: "https://nexus.example",
  credential: member_credential
)
client.profile.declare_configuration(
  tool_definitions: [],
  approval_mode: "ask",
  approval_rules: nil,
  prompt_mechanism: "default",
  compaction_policy: { mode: "kernel" },
  prompt_documents: {
    system_prompt: { content: "Give clear, accurate answers and state uncertainty." },
    summarizer: nil
  }
)
```

:::

An API key can stay in `credential:`. For OAuth, a long-running application owns
credential persistence and rotation and passes a `credential_provider:` instead;
see [SDKs](sdks.md).

Omitted configuration fields clear; send the complete declaration when updating. New turns capture the declaration when they start; a running turn keeps the tools and policy it started with. `default` assembles the system prompt, workspace character, human persona, memory, skills, history and the new input; see [Agents and configuration](agents-and-configuration.md).

## 4. Create a workspace and a conversation

A workspace is required; Nexus creates none. Reuse one of this application's dedicated workspaces or create one:

::: code-group

```http [HTTP]
GET  /agent_api/v1/workspaces?dedicated_to_current_agent=true

POST /agent_api/v1/workspaces
Idempotency-Key: workspace-onboarding-1

{ "workspace": { "name": "Assistant workspace" } }

POST /agent_api/v1/workspaces/{workspace_id}/conversations
Idempotency-Key: conversation-onboarding-1

{ "conversation": { "title": "First conversation" } }
```

```ruby [Ruby SDK]
created = client.workspaces.create(name: "Assistant workspace", idempotency_key: SecureRandom.uuid)
handle = client.workspace(created.workspace.public_id)
conversation = handle.conversations.create(title: "First conversation", idempotency_key: SecureRandom.uuid)
chat = handle.conversation(conversation.public_id)
```

:::

Both answer `201` with the resource's `public_id`. The creating agent is the conversation's default answerer. Generate and persist a fresh idempotency key per intended operation; reuse the original key and body after a lost response, and the receipt replays for 24 hours.

## 5. Submit a reply request

::: code-group

```http [HTTP]
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/inputs
Idempotency-Key: input-onboarding-1

{
  "input": {
    "kind": "direct_reply",
    "role": "user",
    "text": "Explain what this assistant can help with.",
    "delivery_mode": "queue",
    "model": { "model": "<model ref>" }
  }
}
```

```ruby [Ruby SDK]
accepted = chat.inputs.create(
  kind: "direct_reply", model: "<model ref>",
  text: "Explain what this assistant can help with.",
  idempotency_key: SecureRandom.uuid
)
```

:::

`202` means the input was accepted, not that a reply finished. The input's words become the reply turn's prompt; do not post a separate message with the same text. Use `kind: "message"` to record speech without a reply, `delivery_mode: "steer"` for the next model boundary of running work, and `steer_now` to insert a boundary while long tools keep running.

## 6. Follow it to the answer

The smallest client recovers entirely over HTTP:

1. Read the conversation's `inputs` while the input waits. A `blocked` input carries `blocked_reason`; fix or remove it instead of submitting duplicates.
2. Read `inputs/{input_id}/materialization` for the `turn_public_id`, `variant_public_id` and nullable `run_public_id`. A pending input has no materialization yet.
3. Read `turns/{turn_public_id}` and follow its `active_variant`. A `running_variant` is a separate regeneration. A `source: "fallback"` candidate whose `origin_variant_public_id` matches continues the same request. A failed or canceled candidate is terminal, not an answer.

::: code-group

```ruby [Ruby SDK]
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 120
materialized = nil
loop do
  raise "Still waiting; keep input #{accepted.public_id} to resume observation." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  materialized ||= chat.inputs.materialization(accepted.public_id)
  if materialized
    turn = chat.turns.fetch(materialized.turn_public_id)
    case turn.status
    when "completed"
      puts turn.text
      break
    when "failed", "canceled"
      raise "Reply #{turn.public_id} ended as #{turn.status}."
    else
      # This text-only example has no tools or approval decisions to resolve.
    end
  else
    input = chat.inputs.list.items.find { |row| row.public_id == accepted.public_id }
    raise "Input blocked: #{input.blocked_reason}" if input&.blocked?
  end
  sleep 1
end
```

:::

For realtime updates subscribe to the conversation's feeds and keep the HTTP path for recovery; see [Events and streaming](events-and-streaming.md). A run-backed turn exposes `run_public_id`: inspect its tasks for an approval, a question or a repairable failure. Never create a standalone run to drive a conversation reply; Nexus creates and drives it.

## What happened

1. The input was accepted and queued behind any running turn.
2. At the turn boundary Nexus materialized a turn, a candidate variant and — when tools or hooks are declared — a run.
3. The round driver assembled the prompt from your documents, memory and history, called the model, expanded any tool calls into tasks, and continued until a round produced an answer with no outstanding work.
4. Events and transcript deltas streamed as it ran; the settled answer is readable on the turn.

## Add capabilities

| Need | Where |
| --- | --- |
| Tools | Declare schemas on the configuration; announce executor tools on their executor; see [Agents and configuration](agents-and-configuration.md) and [Runners](../runners/index.md) |
| HTTP service tools without an executor loop | [Build an Agent with HTTP MCP tools](http-mcp-agent.md) |
| Human decisions | [Approvals and rules](approvals-and-rules.md) |
| Delegation and parallel work | [Orchestration](orchestration.md) |
| Later or recurring work | A queued input with `deliver_at`, or [Schedules](schedules.md) |
| Model calls without a conversation | [Direct model calls](direct-model-calls.md) |
| Durable state | [Memory, store and uploads](memory-store-and-uploads.md) |
| External speakers (chat channels) | Ingress speakers in the [Agent API reference](../reference/agent-api.md) |
