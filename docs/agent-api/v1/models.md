# Agent API Models and Model Providers

Status: live, read-only Agent API resources.

The deployment catalog supplies the base provider and model definitions.
Human administrators can add or override definitions through Nexus settings
and the Platform API; saved changes apply to subsequent reads and requests
without restarting the services. The account's provider enablement and credentials
determine whether each model is available. Every authenticated member-plane
agent can discover the models currently available to the Account here; no
administrator role or per-agent model allowlist is required. Human
administrators manage the configuration through the
[Platform model management API](../../platform-api/v1/admin-models.md).

## List the models this account can run

### Endpoint

```http
GET /agent_api/v1/models
```

### Authentication

Member plane only; a transport credential is refused with `401`.

### Query parameters

| Name | Type | Meaning |
| --- | --- | --- |
| `workload` | string | Only models serving this workload (`text_generation`, `image_generation`, `speech_generation`, `transcription`, `embedding`). |

This endpoint always returns only available models. There is no query option
to include unavailable models; administrators use `GET /api/v1/admin/models`
for the complete catalog and diagnostic reasons. An empty array means no
configured model is currently available. Rows are ordered by `ref`.

### Response

```json
{
  "models": [
    {
      "ref": "openrouter/deepseek/deepseek-v4.1-flash",
      "provider": "openrouter",
      "workload": "text_generation",
      "visible": true,
      "available": true,
      "unavailable_reason": null,
      "capabilities": {
        "tool_calls": true,
        "streaming": true,
        "prompt_caching": true,
        "input_modalities": ["text"],
        "output_modalities": ["text"],
        "reasoning_modes": []
      },
      "pricing": {
        "state": "priced",
        "unit": "USD",
        "input_per_mtok": "0.3",
        "output_per_mtok": "1.2"
      }
    }
  ]
}
```

`ref` is exactly what a task's `model` field takes.

The shipped Codex subscription text models (`gpt-6-astra`, `gpt-6.1-sol`,
`gpt-6-luna`) accept PNG, JPEG and WebP image attachments. Nexus prepares images
with a longest edge of 2048 pixels before sending them; larger uploads are resized,
and the original upload is retained. This is a local preparation bound, not a
provider image-size limit. Image generation uses the separate `image_generation`
workload and model row. Codex subscription credentials do not enable the OpenAI
API transcription or speech lanes.

`capabilities.tool_calls` is the boolean a tool-driven loop depends on. It is
the wire's property: a catalog row silent on it has function tools on every
text wire, `false` is the one opt-out, and nothing further is stated about the
calls — every wire answers several calls in one response, so an agent that
would rather call one tool at a time says so in its own prompt.

Member rows have `visible: true`, `available: true` and
`unavailable_reason: null`. The admin
endpoint uses the same row shape and retains unavailable rows with the reason
the authoring door would refuse them. Availability reflects configuration and
credential readiness at the time of the read; it does not validate a key with
the remote provider or guarantee that a later request succeeds.

Model visibility is Account-wide, managed through the admin API. A hidden model
is absent here and cannot be selected by explicit reference or through a
selector for new work. An Agent does not gain a visibility-management route.

`pricing.state` is one of `priced` (rates given), `known_free_candidate` (the
complete formula is exact zero), `unmetered` (this deployment does not compute
this lane's cost) and `cost_unknown` (nothing can be quoted yet — most often
because the account has configured no cost unit). Rates are decimal **strings**
in the account's unit, per million tokens, and are absent unless the state is
`priced` or `known_free_candidate`.

Pricing estimates are optional and do not determine model availability. An
unpriced or `cost_unknown` model can still run. Its provider-reported usage is
recorded normally; uncomputable monetary amounts remain absent rather than zero.

A server whose catalog never compiled answers `503` with
`model_plane_unavailable` rather than an empty list: "there are none" and "this
server cannot tell you" are different problems with different fixes.

## List the provider lanes

### Endpoint

```http
GET /agent_api/v1/model_providers
```

### Response

```json
{
  "model_providers": [
    {
      "id": "openrouter",
      "display_name": null,
      "credentials": "api_key",
      "enabled": true,
      "lock_version": 3,
      "configured": true,
      "material_kind": "api_key",
      "reauthorization_required": false,
      "unavailable_until": null,
      "models": 12
    }
  ]
}
```

`credentials` says how the lane authenticates: `api_key`, `oauth_tokens`, or
`none` for a lane that honestly needs no secret (which is therefore always
`configured`).

`display_name` is the operator's optional label; `id` remains the stable
provider identifier used in model references and configuration commands.

`unavailable_until` is the provider's own clock: when this lane last answered an
overloaded status with `Retry-After`, the time it named (ISO 8601, UTC); `null`
once that time has passed or when it never said one. A DELAY, not a readiness
fact — queued work on the lane waits for it and then runs; `enabled` and
`configured` say whether the lane runs at all. Written from the header, never
computed.

`models` counts configured model references: deployment entries plus model
overrides, excluding removal entries. It does not assert that every definition
is valid or available; the model listing is the authority for runnable models.

`lock_version` is the optimistic version the serving command must echo. It is
`null` for a lane nobody has touched; enabling a lane or saving a provider/model
definition creates its policy row. A first interactive model removal also creates
the disabled policy that owns its tombstone.

**No secret is ever served here, in any shape**: not a preview, not a length,
not a fingerprint. `configured` is the whole of what a caller may learn.

## Administration

The member plane has no provider or model mutation routes. Provider connections,
model definitions, visibility, provider enablement and API-key installation, rotation, and removal
belong exclusively to the Human-admin
[Platform model management API](../../platform-api/v1/admin-models.md).
A member or executor bearer cannot authenticate to that API, including when
its Human owner is an administrator.

An administrator chooses supported wire adapters and may optionally configure
prices. These writes do not create adapters or change Agent-owned model routing.
