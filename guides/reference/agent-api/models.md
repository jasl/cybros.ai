# Agent API Models and Model Providers

Status: live, read-only Agent API resources.

The deployment catalog supplies the base provider and model definitions.
Human administrators can add or override definitions through Nexus settings
and the Platform API; saved changes apply to subsequent reads and requests
without restarting the services. The account's model visibility, invalid marks,
provider enablement and credentials
determine whether each model is available. Every authenticated member-plane
agent can discover the models currently available to the Account here; no
administrator role or per-agent model allowlist is required. Human
administrators manage the configuration through the
[Platform model management API](../platform-api/admin-models.md).

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
      "ref": "example/text",
      "provider": "example",
      "model_identity": null,
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
        "reasoning_modes": [],
        "reasoning": {
          "supported": true,
          "default_enabled": false,
          "disable_supported": true,
          "efforts": ["low", "high"],
          "default_effort": "low"
        },
        "generation_parameters": {
          "max_output_tokens": {
            "kind": "integer",
            "default": null,
            "minimum": 1,
            "maximum": null,
            "allowed_values": null
          },
          "output_format": {
            "kind": "output_format",
            "default": null,
            "minimum": null,
            "maximum": null,
            "allowed_values": ["text", "json_object", "json_schema"]
          }
        },
        "service_tiers": ["default", "priority"],
        "limits": {
          "input_tokens": 64000,
          "effective_input_tokens": 48000
        }
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

`model_identity` is the catalog's optional exact model-and-version identity,
or `null` when undeclared. Matching nonempty identities allow recovery
between provider routes under a `model` constraint; names, suffixes and
families do not establish equivalence. See [Model selection and recovery](#model-selection-and-recovery).

Capability descriptors come from the effective Account catalog and the same
compiled profile used by model selection, including saved definition overrides.
They describe semantic request controls, without provider wire keys or adapter
configuration:

- `reasoning.supported` says whether the model declares reasoning.
  `default_enabled` is its effective default (`null` when unsupported),
  `disable_supported` says whether an off request can take effect, and `efforts`
  lists the accepted intensity values. `default_effort` is nullable and remains
  independent of enablement. A switch-only model has an empty effort list; a
  model without reasoning has `supported: false`, `disable_supported: false`,
  empty efforts and null defaults.
- `generation_parameters` maps each supported semantic parameter name to its
  descriptor. `kind` is `integer`, `number`, `string` or `output_format`;
  `default`, `minimum`, `maximum` and `allowed_values` are always present and
  nullable. A null default means Nexus supplies no default for that control.
  Null bounds mean no corresponding local range check; null `allowed_values`
  means the control is not enumerated. An absent parameter is unsupported.
  `output_format` lists semantic format kinds, never provider payload keys.
- `prompt_cache_ttl`, when declared in `generation_parameters`, is a string
  supplied through `configuration`, for example
  `{"configuration":{"prompt_cache_ttl":"12h"}}`. Use the model's
  `allowed_values`; unsupported durations are rejected before provider IO.
  A null catalog default preserves omission. The shipped OpenAI GPT-6 and
  OpenRouter OpenAI rows offer `30m` (recommended) and `12h`; 12-hour cache
  writes cost more. Responses and compatible Chat lower these to
  `prompt_cache_options.ttl`. Models explicitly declaring the older `24h`
  option use `prompt_cache_retention` instead; it is not a GPT-6 option.
  Native Anthropic rows offer `5m` and `1h`. Without an override, mainline
  requests retain one-hour markers and other marked requests five-minute
  markers. An override changes only their lifetime: stable/tail placement,
  thinking-block exclusions, and marker-free summaries remain unchanged.
  Other rows, including OpenRouter Anthropic, do not advertise configurable
  TTL. This setting is a provider cache lifetime, not a deletion deadline.
- `service_tiers` lists the declared tier values. No tier is selected by this
  listing; omitting a tier, or requesting `default`, leaves the provider's
  default in effect.
- `limits` contains only the effective bounds that are known. These can include
  `input_tokens`, `output_tokens`, `combined_input_output_tokens`,
  `effective_input_tokens`, `input_bytes`, `input_characters`,
  `audio_duration_seconds`, `result_count` and `embedding_dimensions`.
  `effective_input_tokens` is the advisory planning threshold; it is separate
  from a hard input or combined input/output window. Missing limits are absent,
  never zero. Generation parameter bounds remain separate from these limits.

#### Reasoning effort by row

The native Gemini Flash row is `gemini/gemini-3.8-flash`. It accepts
`low`, `medium`, and `high` reasoning effort; `minimal` is rejected.
OpenRouter's separately pinned Gemini row retains its own model reference.

The shipped OpenAI API, Gemini, DeepSeek, xAI, and OpenRouter text models
accept an optional positive integer `max_output_tokens`. Omitting it sends
no output cap and keeps the provider default. OpenAI API Responses requires
at least 16 tokens; the other shipped API rows require at least 1.
A declared maximum is validated
at selection; `maximum: null` means the catalog has no universal upper bound
to validate locally, and the routed provider still judges the requested
value. Anthropic keeps its required default cap. Codex subscription text
models reject `max_output_tokens` as an unsupported generation parameter.
Input context limits and advisory planning thresholds are separate from this
output control.

#### Attachments

The shipped Codex subscription text models (`gpt-6-astra`, `gpt-6.1-sol`,
`gpt-6-luna`) accept PNG, JPEG and WebP image attachments. Nexus prepares images
with a longest edge of 2048 pixels before sending them; larger uploads are resized,
and the original upload is retained. This is a local preparation bound, not a
provider image-size limit. Image generation uses the separate `image_generation`
workload and model row. Codex subscription credentials do not enable the OpenAI
API transcription or speech lanes.

Native PDF input is the `file` input modality, restricted to
`application/pdf`. It requires both a model row declaring that modality and
an adapted wire that supports PDF bytes. OpenAI API Responses and Chat,
Anthropic Messages, and Gemini GenerateContent have PDF adapters; using one
of those wire formats does not automatically grant every model PDF support.
Conversation attachments on a row without PDF support remain readable through
file tools. A text-generation InferenceRequest with an unsupported PDF is refused.
Other document types are not native inputs.

#### Tool calls

`capabilities.tool_calls` is the boolean a tool-driven run depends on. It is
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
An administrator's complete upstream directory fetch marks configured models
missing from that directory invalid and clears the marks for listed models.
Matching uses the effective upstream `model_id`, falling back to the reference
after the provider prefix. A complete empty directory marks all configured models
missing; failed, unsupported or incomplete fetches change nothing. Administrators
can also manage the mark explicitly through the Platform API, or run a connection
test that marks a model invalid only on unambiguous evidence that it no longer exists.
Invalid models are hidden here and refuse new work through the same checks.
The admin row retains its definition and pricing and reports `model_unavailable`
when its provider is enabled. Restoring that mark does not clear manual hiding.
Directory synchronization creates no model definitions or capabilities; uncertain
connection failures leave invalid marks unchanged. These member `GET` resources
read saved state and never contact the provider.

#### Pricing

`pricing.state` is one of `priced` (rates given), `known_free_candidate` (the
complete formula is exact zero), `unmetered` (this deployment does not compute
this lane's cost) and `cost_unknown` (nothing can be quoted yet — most often
because the account has configured no cost unit). Rates are decimal **strings**
in the account's unit, per million tokens, and are absent unless the state is
`priced` or `known_free_candidate`.

Pricing estimates are optional and do not determine model availability. An
unpriced or `cost_unknown` model can still run. Its provider-reported usage is
recorded normally; uncomputable monetary amounts remain absent rather than zero.

#### An uncompiled catalog

A server whose catalog never compiled answers `503` with
`model_plane_unavailable` rather than an empty list: "there are none" and "this
server cannot tell you" are different problems with different fixes.

## Model selection and recovery

`model` names the requested initial route and its reasoning controls.
The separate `model_selection` object records why that route was chosen
and which automatic substitutions are allowed. A model argument alone
does not establish an explicit Human choice, even when it equals a saved
default. Applications must send that intent explicitly.

```json
{
  "model": { "model": "openai_api/gpt-6.1-sol" },
  "model_selection": {
    "source": "explicit",
    "model": "openai_api/gpt-6.1-sol",
    "constraint": "route",
    "alternatives": ["anthropic/claude-sonnet-4-5"]
  },
  "fallback_models": ["anthropic/claude-sonnet-4-5"]
}
```

| Intent field | Meaning |
| --- | --- |
| `source` | `default`, `inherited` or `explicit`. |
| `model` | The complete initial `provider/model` reference, at most 193 characters. |
| `constraint` | `any`, `model`, `provider` or `route`. |
| `alternatives` | Complete routes explicitly allowed as exceptions to the constraint; `[]` by default. |

`any` permits the declared candidates. `model` requires the same exact
model and version; it may use a different provider only when both Catalog
entries have the same nonempty `model_identity`. A matching display name,
family, alias or reference suffix establishes no equivalence. `provider`
keeps the initial provider while permitting another model there. `route`
keeps both the provider and exact model identity. Naming an alternative
authorizes that route alone; it neither releases constraints for other
candidates nor inserts a route into the fallback list.

An omitted intent is `source: default, constraint: any` for the resolved
initial model. To preserve a user's explicit route selection, send
`source: explicit, constraint: route`; to allow a known equivalent model
on another provider, use `constraint: model`. No automatic fallback is
`fallback_models: []`, which remains effective even when alternatives
are authorized. Ordinary bounded retries on the initial route are separate.

Conversation input create/update, context estimate and regeneration accept
`model_selection` and `fallback_models`. InferenceRequest create/input
estimate, standalone Run create and authored model steps accept them too.
The fallback array is ordered and replaces the inherited list whole.
Omission or null uses the selected declaration's list; for an
InferenceRequest it uses the creator Agent's captured list, or `[]` without
one. A supplied `[]` disables automatic fallback. References and the whole
array have the same bounds as [Agent configuration](profile-configuration.md#fallback-models).

### Captured intent and live availability

The accepted execution retains its initial route, intent and effective
ordered list. Changing a profile or Preset cannot rewrite that chain.
At each selection and before sending, Nexus checks the existing Catalog,
provider configuration and authorization gates. An unknown or disabled
provider/model, hidden model, missing credential, required reauthorization
or unusable credential is skipped without provider IO. A skipped candidate
adds no failed attempt or usage receipt, consumes no retry allowance and
starts no polling loop. Exhausting the permissible available candidates
returns the selection or execution failure instead of guessing a route.

### Bounded recovery

A provider classifier refusal can advance directly. Retryable transport,
stream, timeout and typed server failures first use the route's existing
bounded attempt budget; exhausting it may advance with
`provider_transient_exhausted`. An all-overload budget retains
`provider_overloaded`. Rate limits keep their existing cooldown and
`Retry-After` behavior within that budget. Text requests have at most
three actual attempts per route. Availability skips are not attempts.

Each resolved route enters the chain at most once. The captured finite
candidate list and existing execution deadline bound the whole recovery;
a switch or restart does not reset that deadline. A task's authored retry
count and a manual task retry cannot renew an exhausted provider route.
Retrying a route already refused or exhausted returns `model_route_spent`.
An explicit repair may name a different unspent route only when the
captured constraints permit it.

Content protection (`finish_quality: blocked`), abnormal generation
finishes, actual provider authentication/request errors and unknown errors
are terminal rather than permission to switch. Stop and cancellation
remain final. An execution whose deadline passed before provider work
started is not revived by another candidate.

Recovery replaces the failed model request, preserving completed tools
and accepted results. Run tasks return to `waiting`; a tool-less reply
creates a `source: fallback` sibling candidate; an InferenceRequest starts
its next execution. Existing `model_change` facts report the switch and
reason, and `model_skips: [{model, reason}]` reports candidates skipped
when present on the task, turn or run event. Cumulative usage includes the
actual attempts across the chain. Kernel result mail uses its source's
captured list and constraints; it has no extra switch to the recipient's
current default model.

## Reasoning selection

Text model selections accept two independent controls:

```json
{"model": "provider/model", "reasoning_enabled": false, "reasoning_effort": "low"}
```

`reasoning_enabled` is a nullable boolean. On creation, omission or `null`
uses the model's declared default: reasoning models default to enabled unless
their catalog entry explicitly defaults it off. `false` requests disabled
reasoning. If the model cannot disable reasoning, Nexus ignores that request
and the effective selection remains enabled. A model without a declared
reasoning capability has no effective reasoning selection.

`reasoning_effort` selects intensity from that model's supported vocabulary;
omission or `null` uses its declared effort default. It does not turn reasoning
on or off. In particular, `none` is not a public spelling for disabling
reasoning; use `reasoning_enabled: false`. A model may support the enablement
switch without an effort control, and an unsupported effort is refused as
`unsupported_reasoning_effort` even when the enablement request is false.

Updates and retries can submit only a control, for example
`{"model": {"reasoning_enabled": false}}`, while retaining the current model.
For the same model, omitted or `null` controls preserve their existing values.
Naming a different model starts from that model's defaults for omitted or
`null` controls. Regeneration follows the same selection rules.

Queued inputs, schedules and model tasks store caller intent. Once a
selection is resolved, InferenceRequest, input-estimate, invocation and reply-variant
model projections report effective `reasoning_enabled` and `reasoning_effort`.
For example, a scheduled job can retain a request to disable reasoning while
its resulting reply variant reports `reasoning_enabled: true` on a model that
cannot disable it. Reasoning history replay is a separate control.

Selectors declare these controls on their candidates. A caller selecting a
selector cannot override them: explicit effort or enablement is refused as
`unexpected_reasoning_effort` or `unexpected_reasoning_enabled`. Non-text
workloads refuse these controls with the same respective errors.

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

`lock_version` is the optimistic version administrator settings commands,
including upstream directory synchronization, must echo. It is
`null` for a lane nobody has touched; enabling a lane or saving a provider/model
definition creates its policy row. A first interactive model removal creates
the disabled policy that owns its tombstone; a complete directory fetch can also
create a disabled policy when it needs to save invalid marks.

**No secret is ever served here, in any shape**: not a preview, not a length,
not a fingerprint. `configured` is the whole of what a caller may learn.

## Administration

The member plane has no provider or model mutation routes. Provider connections,
model definitions, visibility, invalid marks, fixed connection tests, provider
enablement and API-key installation, rotation, and removal
belong exclusively to the Human-admin
[Platform model management API](../platform-api/admin-models.md).
A member or executor bearer cannot authenticate to that API, including when
its Human owner is an administrator.

An administrator chooses supported wire adapters and may optionally configure
prices. These writes do not create adapters or change Agent-owned model routing.
