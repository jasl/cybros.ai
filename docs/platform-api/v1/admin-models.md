# Admin Models and Model Providers

Status: live Platform API resources.

These routes let a Human operator inspect model availability, enable or disable
a provider lane, author connection and model definitions, control individual
model visibility, and install, rotate, or clear its API key. They use the same
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
OneShot. Verify a configured model by making an ordinary request through the
paired agent.

## Read models

```http
GET /api/v1/admin/models?workload=text_generation&available=true
```

Returns `200 {"models": [...]}` with the same model row shape, capabilities,
and pricing as [member model discovery](../../agent-api/v1/models.md#list-the-models-this-account-can-run).
`workload` selects a workload; `available=true` returns only available models.
Omitting the filters returns the whole account-effective catalog, ordered by
`ref`, including unavailable models. Their `unavailable_reason` names the first
refusal: `provider_disabled`, `model_hidden`, `missing_credential`,
`reauthorization_required`, or `credential_unusable`. The Agent API always
filters these rows out. The independent `visible` boolean records the
administrator's model-visibility setting; a visible model can still be
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

No body. The saved connection and configured credential are used for one
bounded model-directory request. Success returns
`200 {"models": [{"id": "upstream/model", "display_name": null}]}`. The request
does not follow redirects, retry, save models or call inference. A directory
error leaves all configuration intact; clients must retain manual model entry.
The directory does not establish capabilities, context limits or prices.

Discovery accepts at most 1,024 entries and a 2 MiB response. OAuth credential
lanes and the Codex protocol do not support it. An unsupported directory,
missing required credential, oversized or invalid response, or upstream failure
returns `422 validation_failed`; enter the model manually when needed.

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
It uses the provider policy's existing `lock_version`, obtained from the
provider read. Success returns `200 {"model_provider": {...}}` with the current
version; a stale version returns `409 stale_object`. A same-value request
leaves the version unchanged.

The provider policy must already exist: an untouched lane returns `404` and
is never enabled implicitly. A disabled lane can still have its models'
visibility configured. Unknown models and references outside the named provider
return `404 not_found`; a non-boolean `visible` returns `400 parameter_invalid`.
Version syntax follows the lane command: omission or `null` conflicts with an
existing policy, and an invalid non-null version returns `400 parameter_invalid`.
Exceeding the provider policy document's shared limits (256 distinct references
across definition entries and hidden models, or 2 MiB canonical JSON) returns
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
There is no per-Agent visibility list.

The operator commands are `cmctl model hide REF` and `cmctl model unhide REF`.
They read the provider version before the mutation and return a conflict
without retrying if it changed.

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
they do not create adapters, change Agent routing policy, or introduce a
model-test execution endpoint.
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
