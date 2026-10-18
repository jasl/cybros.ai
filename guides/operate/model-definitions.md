# Reuse a model definition

A shared model definition supplies a model's context limits, capabilities and optional tokenizer without tying it to a provider or a price. Use one when adding a local deployment or another provider for a model already in the catalog.

## Choose a definition in settings

1. Open a provider in **Nexus → Model providers**, or in rho's **Nexus** page, and choose **Add model**.
2. Under **Model definition**, select the model. **Custom definition** keeps manual authoring available.
3. Enter the exact **Model ID** accepted by your server. It may differ from the shared definition's name.
4. Leave context and capability fields blank to inherit their defaults. If your server loads a smaller context, enter its actual limit. For a 32K local deployment, enter **32768** as the **Combined context window**.
5. Leave **Pricing** as **No cost estimate**, or supply that provider's prices, then save.

In Nexus settings and rho's WebUI, selecting a definition shows its declared context limits and capabilities. Empty context fields show inherited values as hints; the fields themselves remain blank. Tool-call and streaming controls show the model's declared default, or say that the protocol supplies it when the definition leaves it unspecified. Switching definitions refreshes these defaults and preserves your explicit overrides.

Under **Input media**, keep inheritance or choose a custom set of supported media. For a text-only local deployment, choose the custom option and clear every media checkbox. This saves an explicit empty list. Other capabilities, including reasoning, remain visible in the definition summary; this form preserves any existing overrides for fields it does not edit.

The saved configuration retains the reference and your overrides. It does not copy all inherited values into the custom model. Changing a shared definition therefore reaches its inheriting models when Nexus loads the new catalog.

Context limits form one complete deployment contract. Leaving every limit blank inherits that contract; entering any limit replaces the whole set. A shared input/output window and a separate input window must not be combined. Capability controls left at their default inherit the selected model's value, then the protocol default where the model leaves it unspecified.

While any context limit is overridden, the other model limits are shown for reference and are not inherited. **Use model limits** clears the complete limits override, including a previously saved empty limits block, and restores inheritance. An unchanged empty block remains an explicit override when the form is saved.

## Reference a definition in YAML

The shipped definitions live in `nexus/config/model_catalog/00_models_*.yml`. Provider files contain model references and any differences for that provider. Operator files in `nexus/config.d` use the same grammar; `MODEL_CATALOG_OVERRIDE_DIR` selects another directory.

This example uses the shipped Qwen Flash Next definition with a local server that has a 32K context:

```yaml
schema_version: cybros.model_catalog.v1
providers:
  local:
    api_format: openai_compatible_chat
    base_url: http://your-model-server:8000/v1
    credentials: none
models:
  local/qwen-flash:
    inherit: qwen3.8-flash-next
    model_id: Qwen/Qwen3.8-Flash-Next
    limits:
      combined_input_output_tokens: 32768
```

Use the model ID returned by your server. The catalog does not contact the endpoint or infer its loaded context. If that deployment accepts text only, add `input_modalities: []` to override the model's media capability. See [local models](models-and-providers.md#local-models) for the server's thinking switch and verification steps.

Restart Nexus and its workers after editing deployment files. A malformed file or unknown `inherit` reference refuses catalog loading. Changes saved through the browser or API apply to subsequent requests without restarting.

## Add a shared definition

A fragment may contain a `model_definitions` mapping beside `providers`, `models` and `selectors`. Each name identifies a reusable definition; it is not a provider route or an upstream request ID.

```yaml
schema_version: cybros.model_catalog.v1
model_definitions:
  example-text-model:
    display_name: Example text model
    limits:
      combined_input_output_tokens: 131072
      output_tokens: 8192
    reasoning:
      disable_supported: true
      default_enabled: true
```

Shared definitions accept model capabilities, `display_name`, `token_counter` and explicit `model_identity`. They cannot inherit another definition. They contain no pricing, native cost contract, provider request ID, protocol, deadline or wire options. Provider-specific media rules, service tiers and reasoning replay formats stay on the provider's model entry. Defining shared model facts does not establish that two provider routes serve an identical version for fallback.

Every definition is validated, including definitions that no route currently uses. Duplicate names in the shipped catalog are rejected. In the operator directory, generic files load first and `<name>.<environment>.yml` files load afterward; a later definition replaces the earlier definition with that name as a whole.

## Override inherited values

| Value | Override behavior |
| --- | --- |
| Omitted field | Keep the shared definition's value. |
| Object | Merge named members recursively. |
| `limits` object | Replace the complete limits object. |
| Array | Replace the array; `[]` clears it. |
| Scalar, `false`, or `null` | Replace the value, subject to that field's validation. |

An empty object normally changes nothing; `limits: {}` clears the inherited window and falls back to the protocol's existing defaults. It does not create an unlimited window. `null` is a value, not a deletion operator: for example, `token_counter: null` selects the byte estimate, while a null token limit is invalid. Flat capability fields and fields nested under `capabilities` have the same meaning; if both spellings appear in one entry, the nested value takes precedence.

These rules apply only to a model's explicit `inherit` reference. File overlays and database model upserts still replace an entire model entry. A database upsert saves its authored reference and overrides; resetting that upsert restores the file entry.

Pricing is authored separately on each provider's model entry. Omitted pricing leaves cost unknown and does not prevent model use. The [model definition API](../reference/platform-api/admin-models.md#author-model-definitions) accepts the same inheritance grammar.

## Next

- [Configure providers and models](models-and-providers.md)
- [Author models through the API](../reference/platform-api/admin-models.md)
