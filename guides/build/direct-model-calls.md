# Direct model calls

An **InferenceRequest** is a bounded, sealed model call outside any conversation: no history, no tools, no turn. Use it for classification, extraction, embeddings, speech and image work, or any model operation where your application owns the whole request.

```http
POST /agent_api/v1/workspaces/{workspace_id}/inference_requests
GET  /agent_api/v1/workspaces/{workspace_id}/inference_requests
GET  /agent_api/v1/workspaces/{workspace_id}/inference_requests/{id}
POST /agent_api/v1/workspaces/{workspace_id}/inference_requests/{id}/cancellation
GET  /agent_api/v1/workspaces/{workspace_id}/inference_requests/{id}/events
POST /agent_api/v1/workspaces/{workspace_id}/inference_requests/input_estimate
```

## Workloads

Discover usable models per workload with `GET /agent_api/v1/models?workload=…`:

| Workload | Purpose |
| --- | --- |
| `text_generation` | Text replies, with optional reasoning controls and image or PDF inputs on capable models |
| `image_generation` | Generate or edit images |
| `speech_generation` | Text to speech |
| `transcription` | Speech to text |
| `embedding` | Vector embeddings |

Each model's definition declares its capabilities, limits and optional pricing; a workload lists only models whose provider is enabled, credentialed and visible.

## Lifecycle

1. Create with the model reference, the request body for that workload and an `Idempotency-Key`. The request is sealed as submitted; later model changes never rewrite it. Creation has its own documented replay response.
2. Follow execution state over HTTP or the request's events feed; the events replay with the same cursor and watermark contract as conversations.
3. Read the result and recorded usage. A classifier refusal or exhausted retryable transport/server failure may advance through the captured ordered fallback list, within the request's model/provider constraints and finite attempt budget. The request reports the model that actually answered; see [model recovery](../reference/agent-api/models.md#model-selection-and-recovery).
4. Cancel through `…/cancellation` when the result is no longer needed.

`input_estimate` is a write-free advisory that counts the request's input against the model's limits before you spend on it.

## Gateway behavior

The same catalog, credential, reasoning, prompt-format adaptation and pricing rules apply as for conversation replies: the request compiles against the model's definition, reasoning uses `reasoning_enabled` and `reasoning_effort`, and usage is recorded with known cost in the account's unit. Rate limits are per resource (6,000 requests per minute by default, shared by create, list and read).

## When to use a conversation instead

If the call should remember earlier exchanges, use tools, ask a person, run in the background or report back later, it belongs in a conversation turn or a standalone run. See [Orchestration](orchestration.md).

Request and response bodies for each workload, the replay contract and status codes are in the [InferenceRequests reference](../reference/agent-api/inference-requests.md); model discovery and reasoning selection are in [Models and providers](../reference/agent-api/models.md).
