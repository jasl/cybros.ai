# Admin Models and Model Providers

Status: live Platform API resources.

These routes let a Human operator inspect model availability, enable or disable
a provider lane, author connection and model definitions, control individual
model visibility and invalid status, test a model's connection, and install,
rotate, or clear its API key. They use the same
catalog, policy commands, credential commands, and projections as member
model discovery. Changes are visible to the next member read and the existing
model admission path.

For the Human browser workflow, see [Model settings in Nexus](../../nexus-model-settings.md).
Its CSRF-protected HTML forms use the same settings operations; they do not change
the JSON API's bearer requirement for mutations below.

## Authentication

Every route requires a currently active Human owner or administrator using the
[Platform API authentication](../v1.md#authentication). An API Session bearer
comes from [Session creation](session.md); a platform-plane access token is
also accepted. A non-admin Human Session receives `403 administrator_required`.
Member-plane and executor tokens receive `401 unauthorized`, even when the
Human behind them is an administrator. Revocation, removal, or demotion takes
effect on subsequent requests.

A browser Session cookie permits `GET` and `HEAD` only. Mutations require a
bearer; an invalid or wrong-plane Authorization header never falls back to a
cookie. Platform credentials do not authorize Agent API execution, including
InferenceRequest. The administrative model test below sends only a fixed diagnostic
request; ordinary conversation execution remains on the member plane.

## Read models

```http
GET /api/v1/admin/models?workload=text_generation&available=true
```

Returns `200 {"models": [...]}` with the same model row shape, capabilities,
and pricing as [member model discovery](../../agent-api/v1/models.md#list-the-models-this-account-can-run).
`workload` selects a workload; `available=true` returns only available models.
Omitting the filters returns the whole account-effective catalog, ordered by
`ref`, including unavailable models. Their `unavailable_reason` names the first
refusal: `provider_disabled`, `model_unavailable`, `model_hidden`, `missing_credential`,
`reauthorization_required`, or `credential_unusable`. The Agent API always
filters these rows out. The independent `visible` boolean is false when a model
is manually hidden or marked invalid; a visible model can still be
unavailable because its provider is disabled or lacks a usable credential.

## Read provider lanes

```http
GET /api/v1/admin/model_providers
GET /api/v1/admin/model_providers/{provider_id}
```

The collection returns `200 {"model_providers": [...]}`. The singular route
returns `200 {"model_provider": {...}, "configuration": {...}}`. Both use the same
[provider row](../../agent-api/v1/models.md#list-the-provider-lanes):

```json
{
  "model_provider": {
    "id": "openrouter",
    "display_name": null,
    "credentials": "api_key",
    "enabled": false,
    "lock_version": null,
    "configured": false,
    "material_kind": null,
    "reauthorization_required": false,
    "unavailable_until": null,
    "models": 12
  }
}
```

`enabled` and `configured` are independent. `unavailable_until` is the
provider's admission-delay floor, not an enablement or credential fact. Reads
perform no provider network request. No API returns credential material, a
preview, a length, or a fingerprint.

The singular read also returns `configuration`: `definition` is the provider
declaration, `source` is `catalog`, `override` or `custom`, and `models` contains
`model`, `definition`, `source` and `removed` for each model entry. Removed model
entries remain visible here so an administrator can restore them. Connection
definitions never contain API keys or OAuth material.

A removed custom provider is absent from the collection, but its policy and
version remain addressable by ID. Its singular read returns a disabled lane
with `configuration.definition: null` and `source: "removed"`. Read that
version before recreating the same provider ID.

## Author a provider connection

```http
PUT /api/v1/admin/model_providers/{provider_id}/definition
DELETE /api/v1/admin/model_providers/{provider_id}/definition
```

PUT takes a complete declaration, using the same grammar as the deployment
provider catalog. For example:

```json
{
  "command": {
    "definition": {
      "display_name": "Local models",
      "base_url": "http://127.0.0.1:11434/v1",
      "api_format": "openai_compatible_chat",
      "credentials": "none"
    },
    "expected_lock_version": null
  }
}
```

A new provider ID is allowed and starts disabled. Credential modes and wire
adapters must already be supported; the declaration does not define executable
adapters or a new OAuth ceremony. Keys use the separate credential route below.
Subsequent catalog reads, selection, admission and execution use the saved
definition without a process restart.

DELETE takes `command: {expected_lock_version: ...}`. For a file-backed provider
it restores file inheritance. For a custom provider it removes the declaration
and disables the retained policy. It does not delete credentials or the policy
row. Both writes return the same envelope as the singular provider read.

## Author model definitions

```http
PUT /api/v1/admin/model_providers/{provider_id}/model_definition
DELETE /api/v1/admin/model_providers/{provider_id}/model_definition
POST /api/v1/admin/model_providers/{provider_id}/model_definition/reset
```

Every command takes `model` (the complete `provider/upstream-id` reference) and
`expected_lock_version`. PUT also takes `definition`, a complete model mapping
in the deployment catalog's model grammar. A model ID can contain `/`; the
reference is carried in the body, never split into URL path segments.

Model definitions use the same defaults in the deployment YAML and this API.
Author only fields that differ. `input_modalities` defaults to `[]`, meaning
no media input beyond text. `output_modalities` follows the adapted wire:
`[text]` for text generation and transcription, `[image]` for image generation,
`[audio]` for speech, and `[embedding]` for embeddings. `tool_calls`, `streaming`,
and `prompt_caching` inherit the wire's capabilities; a model can explicitly
disable a capability with `false`. Reasoning support still requires a declaration.

A model can declare `wire_options: {prompt_format: qwen3_5}` for the supported
single-leading-system instruction layout. The compiler merges leading system
and developer instructions, then carries later ones as user messages in their
original positions. This changes instruction priority on that send; stored
messages retain their original roles. Omission adds no prompt transformation.
The setting belongs to the model definition, not a per-call generation parameter;
see [model prompt adaptation](../../nexus-model-settings.md#model-prompt-adaptation)
for its scope and limitations.

Generation-parameter descriptors have named presets:

| Parameter | `kind` | `default` | `minimum` | `maximum` | `allowed_values` |
| --- | --- | --- | --- | --- | --- |
| `max_output_tokens` | `integer` | `null` | `1` | `null` | `null` |
| `verbosity` | `string` | `low` | `null` | `null` | `[low, medium, high]` |

Declare a supported parameter with `{}` to use its preset, or supply only its
differences. For example, a model with an output ceiling of 32,768 tokens needs:

```yaml
generation_parameters:
  max_output_tokens:
    maximum: 32768
```

Other supported generation parameters require `kind`; omitted `default`,
`minimum`, `maximum`, and `allowed_values` are `null`. Presets fill declared
descriptors only; they do not add unsupported parameters or infer model limits.
Omitting `generation_parameters` inherits the wire's parameter table, while an
explicit `generation_parameters: {}` replaces that inherited table. Structured
output is derived separately on wires that support it; use
`generation_parameters: {output_format: false}` to disable that control.
Explicit `null`, `false`, and `[]` retain their meaning wherever the field
permits them; only omission selects a default.

PUT replaces that model definition, DELETE writes a removal entry, and reset
removes the entry to restore file inheritance. A custom model without a file
definition disappears on reset. These operations preserve visibility settings
and sibling models. Success returns the provider read envelope with its current
configuration and Policy version.

Prices are optional spending estimates. Missing prices and `cost_unknown` do
not make a model unavailable or prevent execution. Provider-reported usage is
still recorded; unknown monetary values remain absent. An explicitly complete
zero-price formula is allowed. Supplied prices retain decimal, non-negative
and formula validation; no commercial price assessment is performed.

Policy writes require the current version and return `409 stale_object` on a
conflict, without automatic retry. Invalid declarations return `422` without
mutation. Saving a definition does not enable a provider or make an inference
call. Already-started calls may finish using their starting configuration.

## Discover upstream model IDs

```http
POST /api/v1/admin/model_providers/{provider_id}/model_discovery
```

```json
{ "command": { "expected_lock_version": 3 } }
```

Read the provider first and submit its observed `lock_version`.
`expected_lock_version` is required; use an explicit `null` when no policy exists.
Non-null versions must be integers from 0 through 2147483647. A missing field
returns `400 parameter_missing`; an invalid version returns `400 parameter_invalid`
before provider IO.

The saved connection and configured credential are used for a bounded directory
fetch. A complete directory contains all pages fetched successfully within the
discovery limits. Each configured model reference is matched by its effective
upstream ID: the model declaration's `model_id`, or the reference after the
provider's first `/` when omitted. Missing models are marked invalid and hidden
from Agents; listed models have their invalid marks cleared. A complete empty
directory marks every configured model missing. Manual hiding, definitions,
prices, credentials and provider enablement are preserved.

The policy update occurs only after a complete fetch, using the submitted
version without holding a database lock during network IO. A stale version
returns `409 stale_object` without applying the result or retrying. When a
change needs a policy for an untouched provider, it creates a disabled policy
under the submitted `null` precondition. Success still returns only
`200 {"models": [{"id": "upstream/model", "display_name": null}]}`; read the
provider again before the next edit to obtain its current version.

Discovery does not follow redirects, retry, create model definitions or call
inference. It does not infer capabilities, context limits or prices. Manual
model entry remains available; an unlisted alias can have its invalid mark
cleared explicitly through `model_availability`.

The complete fetch has a 20-second total deadline across at most 16 pages,
1,024 model rows before deduplication and 2 MiB of aggregate response data. OAuth
credential lanes and the Codex protocol do not support it. An unsupported
directory, missing required credential, incomplete pagination, oversized or
invalid response, or upstream failure returns `422 validation_failed` and leaves
configuration unchanged. A policy validation failure likewise applies no partial
update. Ordinary provider and model `GET` reads never fetch the upstream directory.

## Enable or disable a lane

```http
PUT /api/v1/admin/model_providers/{provider_id}/lane
```

```json
{ "command": { "enabled": true, "expected_lock_version": null } }
```

`enabled` is a JSON boolean. `expected_lock_version` echoes the provider row's
version, or `null` when enabling an untouched lane; omission also means `null`. Non-null versions must be
integers from 0 through 2147483647. Success returns `200 {"model_provider": {...}}`
with the current version. A stale version returns `409 stale_object`; reread
the lane before deciding whether to repeat the change.

Enabling creates the policy row if definition authoring or model removal has not
already created it. Disabling retains that row and all credential
material; disabling a lane with no policy row returns `404 not_found`.

## Set one model's visibility

```http
PUT /api/v1/admin/model_providers/{provider_id}/model_visibility
```

```json
{
  "command": {
    "model": "openrouter/deepseek/deepseek-v4.1-flash",
    "visible": false,
    "expected_lock_version": 3
  }
}
```

`model` is the complete catalog reference within the named provider.
`visible` is a JSON boolean; `true` restores visibility. The command replaces
the visibility of that one model, preserving every other model's setting.
It uses the provider's current `lock_version`, obtained from the
provider read. Success returns `200 {"model_provider": {...}}` with the current
version; a stale version returns `409 stale_object`. Once a policy exists, a
same-value request leaves the version unchanged.

An untouched provider accepts a `null` version and creates a disabled policy
with the requested visibility and version `0`, including an initial `visible: true`
request. No credential is created or changed. Visibility is editable before
provider enablement or credential setup. Unknown models and references outside the named provider
return `404 not_found`; a non-boolean `visible` returns `400 parameter_invalid`.
Version syntax follows the lane command: omission is treated as `null`; `null`
conflicts with an existing policy, while a non-null version conflicts with an
absent policy. An invalid non-null version returns `400 parameter_invalid`.
Exceeding the provider policy document's shared limits (256 distinct references
across definition entries, hidden models and invalid models, or 2 MiB canonical JSON) returns
`422` without changing the policy.

Visibility applies to every Agent in the Account. Hidden models stay in the
admin catalog with `visible: false` and `available: false`; they disappear
from Agent discovery and refuse new selection, including explicit references
and selector candidates. Queued work and provider starts also recheck this
setting. A call that has already started is allowed to finish; hiding does
not cancel it or alter its usage settlement.

Hiding preserves model definitions, prices, file inheritance, database
overrides and credentials. Restoring visibility does not enable the provider
or install a key. It only removes the model's visibility restriction.
It does not clear a separate invalid-model mark.
There is no per-Agent visibility list.

The operator commands are `cmctl model hide REF` and `cmctl model unhide REF`.
They read the provider version before the mutation and return a conflict
without retrying if it changed.

## Mark a model invalid or restore it

```http
PUT /api/v1/admin/model_providers/{provider_id}/model_availability
```

```json
{
  "command": {
    "model": "openrouter/deepseek/deepseek-v4.1-flash",
    "available": false,
    "expected_lock_version": 3
  }
}
```

`available: false` marks this configured model invalid; `true` clears that mark.
The command preserves its definition, pricing, credentials and any separate
manual hide. Restoring it does not enable the provider, supply credentials or
clear a manual hide. The mark is Account-wide and takes effect through the same
discovery, selection, admission and provider-start checks as model visibility.
Already-started requests may finish.

The administrator's catalog retains an invalid model with `visible: false` and
`available: false`. Its reason is `model_unavailable`, after the higher-priority
`provider_disabled` check and before `model_hidden`. Members do not see it.

This command requires an existing provider policy, allows disabled providers,
and returns `200 {"model_provider": {...}}`. `expected_lock_version` must be
present and may be `null`; null conflicts with an existing policy. Non-null
version syntax, no-op behavior, shared document limits and refusal conditions
match the visibility command. `available` must be a JSON boolean. The operator
commands are `cmctl model invalidate REF` and `cmctl model restore REF`.

## Test one model's connection

```http
POST /api/v1/admin/model_providers/{provider_id}/model_test
```

```json
{
  "command": {
    "model": "openrouter/deepseek/deepseek-v4.1-flash",
    "expected_lock_version": 3
  }
}
```

The command uses the saved connection, model definition and credentials for one
fixed small inference request matching the model's workload. It accepts no
caller prompt, media, tools or generation options. It can incur provider charges;
diagnostic usage is outside Agent usage statistics. The provider request has a
maximum 30-second deadline and no automatic retry. Clients should allow extra
time for the HTTP response, for example a 45-second request timeout.

A completed diagnostic returns HTTP `200`, including when the provider refused
or could not complete the probe:

```json
{
  "model_test": {
    "outcome": "succeeded",
    "duration_ms": 320,
    "http_status": 200,
    "availability_update": "noop"
  },
  "model_provider": { "id": "openrouter", "lock_version": 3 }
}
```

The abbreviated `model_provider` above is the complete provider lane in a real
response. `http_status` is nullable when no status is available. No generated
content, raw provider error or credential material is returned or persisted.
Success establishes this request's connection only, not every declared model
capability or the success of future requests.

`outcome` is `succeeded`, `not_found`, `provider_disabled`, `missing_credential`,
`reauthorization_required`, `credential_unusable`, `model_plane_unavailable`,
`test_input_unavailable`, `request_invalid`, `authentication_failed`,
`quota_exceeded`, `rate_limited`, `model_not_found`, `provider_error`, `timed_out`,
`connection_failed`, `invalid_response` or `request_rejected`.
`test_input_unavailable` means the definition lacks the input required for the
fixed workload probe, such as a supported speech voice or WAV transcription.

Success clears the invalid mark while preserving manual hiding. The diagnostic
outcome `model_not_found` marks it invalid only for unambiguous structured
upstream codes: `model_not_exist`, `model_retired` or `model_decommissioned`.
A generic HTTP 404 or an upstream `model_not_found` code alone can mean lack of
access and is insufficient. Authentication/permission failures, quota/rate limits,
timeouts and all other uncertain probe results leave the mark unchanged.
The separate complete-directory command applies its own availability sync above.

The update occurs after the network request and checks the submitted policy
version without holding a database lock during inference. `availability_update`
is `unchanged` when the outcome calls for no change, `applied` or `noop` on a
successful write, `stale` when another edit won, or `not_found`/`invalid` when the
write could not be made. A successful probe with `stale` is still a successful
probe, but its state change was not saved. Clients must check both fields and
never retry a potentially paid probe automatically. The response carries the
current provider lane; use a new read before a subsequent explicit change.

Unknown models and references outside the provider return `404 not_found` before
the probe. `expected_lock_version` must be present and may be `null`; non-null
version syntax follows the lane command. A missing field is rejected before
provider IO. Disabled providers and
missing credentials produce diagnostic outcomes without inference. Hidden or
invalid models can be tested so a repaired connection can restore them. The
endpoint allows 10 tests per Human within three minutes; excess requests return
HTTP `429`. The operator command is `cmctl model test REF`.

## Install or rotate an API key

```http
PUT /api/v1/admin/model_providers/{provider_id}/api_key
```

```json
{ "command": { "api_key": "sk-…" } }
```

Success returns `200 {"model_provider": {...}}` without the key. Installation
and rotation share one verb: repeating the same normalized material leaves the
credential generation unchanged, while a changed key advances it. Every
successful save enables the provider, including saving the same key again.
Credential and availability changes commit together, preserving model settings.
A blank key returns `400 parameter_invalid` without changing availability.
A provider whose credential lane is `oauth_tokens` or `none`, or whose stored
material is not an API key, returns `409 material_kind_conflict`.

## Clear an API key

```http
DELETE /api/v1/admin/model_providers/{provider_id}/api_key
```

No request body. Success returns `200 {"model_provider": {...}}` with
`configured: false`. The policy row and its enabled state remain unchanged.
An absent key returns `404 not_found`; non-API-key lanes or stored material
return `409 material_kind_conflict`.

## Errors and scope

Failures use the platform `{ "error": { "code": "...", "message": "..." } }`
envelope. An unknown provider returns `404 not_found`. Missing command roots
return `400 parameter_missing`; malformed lane fields or a blank key return
`400 parameter_invalid`. An unavailable catalog returns
`503 model_plane_unavailable`, including on reads, rather than an empty list.

These routes manage supported provider connections and model declarations;
they do not create adapters or change Agent routing policy. The fixed model test
is an administrator diagnostic, not a general execution endpoint.
The member `/agent_api/v1/models` and `/agent_api/v1/model_providers` routes
remain read-only; provider writes have no member-plane alias.

Subscription credentials use [provider authorization](provider-authorization.md),
with Human-owned start/resume, explicit restart and local clear.

```http
GET /api/v1/admin/account/cost_unit
```

Reads `200 {"account":{"cost_unit":"USD"}}` for an ordinary browser-founded
Account, or its configured alternative. An advanced Account that has not
configured a unit returns `null`. It uses the same
Human owner/admin boundary as the configure-once PUT. Read before configuring:
an existing unit cannot be replaced.
