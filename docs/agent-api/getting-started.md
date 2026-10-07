# Build an Agent API client

This guide takes a new Agent application from a connected Profile to a completed
conversation reply. It uses the current HTTP API. The [Ruby SDK](../../sdks/ruby/README.md)
provides clients for these same resources, credential rotation, and durable
event following.

## Connect and choose the right credential

Start with a running Nexus deployment whose Human administrator has configured
at least one usable text model. An Agent application connects through the
[device flow](../oauth/device-flow.md), with the person completing the browser
connection. The application supplies its stable installation identifier; the
person does not choose an existing Profile by ID.

An Agent connection returns a member credential and an executor transport
credential. Store and refresh them through their respective credential
lineages. Use the member credential for every request in the conversation
walkthrough below. Use the transport credential only when serving that
application's executor inbox. A separate Runner or tools provider holds its own
transport credential.

Send these headers on JSON requests, replacing `<member credential>` with the
live member bearer:

```http
Authorization: Bearer <member credential>
Accept: application/json
Content-Type: application/json
```

`GET /agent_api/v1/profile` identifies the acting User and its current
configuration. Cookies and Platform credentials cannot substitute for this
member credential. See the [common API contract](v1.md) for errors, rate limits,
and credential-plane behavior.

## Discover a model and declare the application

Read `GET /agent_api/v1/models?workload=text_generation` and choose a returned
`ref` according to your application's policy. Do not hard-code a model from an
example: each deployment controls its own catalog, credentials, and visibility.
An empty list means that no text model is currently available. A Human
administrator configures providers and models through Nexus settings or the
[Platform API](../platform-api/v1/admin-models.md).

For a new application that only needs text replies, declare:

```http
PUT /agent_api/v1/profile/configuration

{
  "configuration": {
    "tool_definitions": [],
    "prompt_mechanism": "default",
    "compaction_policy": { "mode": "kernel" }
  },
  "prompt_documents": {
    "system_prompt": { "content": "Give clear, accurate answers and state uncertainty." },
    "summarizer": null
  }
}
```

This is one atomic replacement of configuration and the Profile's owned prompt
documents. Omitted configuration fields clear; an omitted or null
`prompt_documents` root clears both owned slots, and an omitted or null slot
clears that slot. Send the complete configuration and prompt set when updating
an existing application. Empty prompt content remains an empty document.
A validation refusal changes none of these values. A lost response can be
followed by the same complete PUT; it converges on the same content, though
document versions advance for another accepted rewrite. Named Agent definitions
remain separate declarations. New turns
capture the declaration when they materialize; a running turn keeps its frozen
tools and execution policy. The [`fallback_model`](v1/profile.md#declare-the-configuration)
has its own live-read contract when an eligible fallback is attempted.

`default` assembles the Profile's system prompt, Workspace character, Human
persona, memory, skills, history, and the new input. Use the existing
[prompt-document resources](v1/profile.md#prompt-documents--the-acting-users-own-slots)
to read text or edit an individual slot. Choose `assembly` for an explicit block order,
or `raw` when the application supplies the complete request and owns its context.

## Create a workspace and conversation

A Workspace is required; Nexus does not create a default one. To discover this
application's dedicated Workspaces, use:

```http
GET /agent_api/v1/workspaces?dedicated_to_current_agent=true
```

The default list instead returns ordinarily accessible, undedicated Workspaces.
Reuse a suitable active Workspace or create one:

```http
POST /agent_api/v1/workspaces
Idempotency-Key: workspace-onboarding-1

{ "workspace": { "name": "Assistant workspace" } }
```

Read `workspace.public_id` from the `201` response. An Agent-created Workspace
is private, owned by its Human steward, and dedicated to that Profile's
identifier. Dedication does not grant access or allow the Agent to perform
Human-owner management.

Create a conversation in that Workspace:

```http
POST /agent_api/v1/workspaces/{workspace_id}/conversations
Idempotency-Key: conversation-onboarding-1

{ "conversation": { "title": "First conversation" } }
```

Read `conversation.public_id` from the `201` response. The creating Agent is
the default answerer. No Runner is required for this text-only example. If
the application will use Runner tools, discover an eligible Runner through
`GET /agent_api/v1/executors` and set `default_runner_executor_public_id` at creation;
later changes use the explicit [Runner binding operation](v1/executor.md#where-a-tool-call-goes).

The example idempotency keys identify one creation each. Generate and persist
a fresh key for each new intended operation; reuse its original key and body
after a lost response. The Workspace and Conversation contracts retain those
receipts for 24 hours and recheck current access before replaying them.

## Submit one reply request

Replace `<model ref>` with the discovered text model's exact `ref`:

```http
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

The `202` response means the input was accepted. Save `input.public_id` and its
idempotency key; acceptance does not mean a turn or model request has finished.
The input's words become the reply turn's retained prompt. There is no need to
post a separate `message` containing the same text.

Use `kind: "message"` when you want to record speech without starting a model
reply. Use `delivery_mode: "steer"` for text intended for the next model boundary
of a running loop; an ordinary steer can fall back to the queue if that loop
ends. Add `expected_steering_run_public_id` when the instruction must apply
only to that exact execution. Attachments use queued inputs and the
[upload resource](v1/uploads.md).

## Follow acceptance through final content

The smallest client can recover entirely over HTTP:

1. Read the Conversation's `inputs` collection while the accepted input is
   waiting. A `blocked` input includes `blocked_reason`; correct or remove it
   through the input resource instead of submitting duplicates.
2. Read `inputs/{input_public_id}/materialization` to recover the original
   `turn_public_id`, `variant_public_id`, and nullable `run_public_id`.
   This read survives input consumption and event retention. A pending input
   has no materialization yet; absence from the queue alone is not success.
3. Read `turns/{turn_public_id}` and follow the saved candidate. Its
   `active_variant` is the displayed answer; an optional `running_variant`
   names a different candidate currently running. If a later edit or
   regeneration replaced both, use the variant deck to read the saved UUID.
   A `source: "fallback"` candidate whose `origin_variant_public_id` matches
   the saved candidate continues that request; follow its result instead.
   Read the settled content even if a streamed draft looked complete.
   A failed or canceled candidate is a terminal outcome, not a successful answer.

For realtime updates, use the [Conversation feeds](v1/conversations.md#events--the-replay-window-and-the-cable)
and keep the HTTP recovery path. Durable events have replay cursors; transcript
deltas do not. `input_materialized` carries the original turn, variant, and
loop identities together. The Ruby SDK's `CybrosAgent::InputMaterialization`
tracks that input through replay and accepts an HTTP recovery callback.
The materialization read follows turn visibility and does not recover a
consumed steer whose event has expired. A terminal status can arrive without a final text frame. A
loop-backed turn also identifies `run_public_id`; inspect its tasks for
an approval, human question, or repairable failure. Do not create another
standalone loop to drive a conversation reply: Nexus creates and drives its
backing execution.

## Add capabilities at their owning resource

| Need | Integration |
| --- | --- |
| Tools | Declare authorized tool schemas on the Profile; `defer_loading` can expose them through tool search. Separately announce external tools on their executor and implement claim/result handling. Fetch kernel tools from the [kernel tool catalog](v1/runs.md#the-kernel-tool-catalog--the-bytes-a-task-must-send); do not invent their schema bytes. |
| Human decisions | Configure approval mode and rules, then expose the loop's approval and question resolution operations in the application. These waits keep their ordinary task states and deadlines. |
| Delegation or parallel work | Use [orchestration](../orchestration.md) to choose `task`, Agent code, `spawn`, `send`, and `wait`, including the independent waiting, lifetime, and wake options. |
| A later instruction in the same conversation | Use a queued input with `deliver_at`. Use an absolute time when the request must replay after a lost response. |
| Independent one-time or recurring work | Create a [scheduled job](v1/schedules.md). Its `once`, `interval`, or `daily` rule creates child executions and returns their results through the parent conversation. |
| A direct model operation without conversation history | Create a [InferenceRequest](v1/inference-requests.md), including the supported image, speech, transcription, and embedding workloads. |
| Durable application state | Use [store entries](v1/store-entries.md) for opaque JSON, memory for model-readable text, and uploads for file bytes. Memory paths name database-backed documents. |
| External speakers | Register [ingress speakers](v1/ingress.md) and post through the input door. The application owns external transport, consent, routing, and delivery. |
| Historical context | Use [history search](v1/conversation-history.md). Read the [retention contract](v1/execution-retention.md) before depending on old tool results or sealed requests. |

An executor announcement controls delivery, while a Profile declaration controls
what a model may call. Both are necessary for external model-invoked tools.
Hooks use the same executor transport but need not be visible to the model.
Nexus keeps execution and durable state; the application chooses models, prompt
meaning, user experience, and external communication policy.
