# Models and providers

Model access is an account-wide setting in Nexus. Owners and administrators configure providers and models; agents discover what is available and choose through their own application. The browser pages are **Settings → System settings → Model providers** (`/admin/model_providers`) and **Cost unit** (`/admin/cost_unit`); [cmctl](cmctl.md) and the [Platform API](../reference/platform-api.md) offer the same operations.

## First usable provider

After first boot, **Overview** offers **Connect an Agent** and **Create Workspace**. An administrator also sees **Configure models** while no text model is available.

1. **Cost unit** shows the unit configured at owner creation, normally USD. It enables cost estimates and cannot be changed later; an unset unit does not block model use.
2. Open a provider. For one that needs no credential, choose **Enabled** under **Provider availability**.
3. For an API-key provider, enter the key and **Save**. A successful save enables the provider. For Codex subscription access, complete the authorization below.
4. Under **Models**, choose **Visible** or **Hidden** for each model. A visible model also needs an enabled provider and usable credentials before an agent can select it.
5. Choose **Test** beside a model and **Run connection test**. This sends one fixed request with the saved credentials and may incur charges. Saving configuration alone makes no call.

Changing Nexus configuration does not change an agent's default model; select it there and send a request to verify.

### From rho

rho's browser has a **Nexus** page beside its own Settings, with the same operations as the pages above, every provider laid flat with its models under it: add a provider or edit its connection, enable or disable it, save, replace or remove its API key from the field on its card, discover its model IDs, add or edit a model, show or hide one for every agent, clear an invalid mark, remove a model and configure it again, and run a model's connection test. It acts with the signed-in human's own Nexus session (an owner or administrator; a page let in by rho's unlock password is asked to sign in with Nexus first), and nothing it does is rho's alone — these are account facts. Subscription authorization, members and budgets stay in Nexus's pages; the page links to them.

## Keys, enablement and visibility

- Keys are **write-only**. Nexus shows whether a key is configured, never its bytes. Enter a replacement and **Update** to rotate; **Remove** deletes the credential without changing enablement. Saving a key also enables the provider.
- **Disabled** makes a provider unavailable for new work while keeping its credentials and models; it also cancels a pending subscription sign-in.
- **Hidden** opts a model out of agent use: it disappears from agent discovery and new calls are refused, while the definition and pricing stay. Visibility and availability are separate; a shown model can still be unavailable because its provider is disabled or needs authorization.
- An **invalid** mark (set by discovery or a failed test with unambiguous evidence) hides a model until **Clear invalid mark**. Only structured evidence that a model does not exist or was retired sets it automatically.
- Each human may run 10 connection tests in three minutes. A stale form never silently overwrites another administrator's change.

## Custom providers and models

**Add provider** configures a connection without editing deployment files: identifier, display name, protocol, base URL and credential mode. Local and private endpoints are supported. Under **Models**, **Add model** lets you [choose a shared model definition](model-definitions.md) and enter only deployment differences, or author a custom definition. **Discover model IDs** reads the provider's directory: missing IDs become invalid and hidden, listed IDs have their invalid marks cleared, manual hiding is kept. Discovery identifies names only; it does not establish context limits, capabilities or prices.

**Context and capabilities** on the model form declare what the server actually provides. For a local server, enter the window the serving process loaded (for example a 32768-token **Combined context window**) rather than the model's advertised maximum. **Output token limit** declares the model's limit; it does not set the provider's `max_tokens`. If a provider rejects a request for length, Nexus attempts a bounded compaction repair; correct the settings and shorten the input if it still cannot fit.

Pricing is optional. Missing prices do not block a model; usage quantities are recorded and unknown monetary amounts stay absent.

Saved definitions apply to later requests without a restart. Deployment files remain the base: resetting a file-backed definition restores it, removing a custom definition removes its configuration, and disabling a provider preserves everything.

## Thinking and effort

Reasoning uses two independent request options: `reasoning_enabled` (a switch) and `reasoning_effort` (a value from the model's declared vocabulary). A reasoning declaration defaults to enabled; a model that cannot turn thinking off ignores a disable request. When effort is omitted, the model's `default_effort` applies; without one, the provider chooses. The shipped catalog defaults Anthropic models to `high`, OpenAI models to `medium` and open-weight models to `low` where their vocabulary allows.

## Prompt-format adaptation

A model definition can declare its instruction layout independently of its provider, for templates that accept a single leading system message and have no developer role:

```yaml
wire_options:
  prompt_format: qwen3_5
```

Nexus then combines separate instructions with the leading run of system and developer messages into one system message and turns later system or developer messages into user messages at their positions. This is an explicit, per-model adaptation applied during request compilation; it infers nothing from endpoint behavior and adds no retry or fallback policy.

For an OpenAI-compatible chat endpoint that accepts system messages throughout
the conversation but rejects developer messages, set `wire_options:
{developer_role: system}` on the provider or model definition instead. This keeps
each instruction's position and content. The shipped Kimi Code provider uses
this mapping. See the [wire-option reference](../reference/platform-api/admin-models.md)
for accepted values.

## Codex subscription authorization

Open **OpenAI Codex** and choose **Connect**. The authorization code and progress appear in the same card; **Open authorization page** continues in your browser. Nexus's background workers complete the exchange, store the credentials and enable the provider — no CLI refresh token is imported. **Disconnect** removes the stored OAuth credentials and leaves enablement unchanged. Only the issuing human sees the verification link and code while an authorization is pending.

## Local models

Nexus talks to local OpenAI-compatible servers through a custom provider with `credentials: none` and the server's API base. Set `model_id` to an ID the server's `GET /v1/models` returns, match the context window to the server's loaded context, and declare image input only when the server loads the required vision components. For Qwen-family servers, the thinking switch is sent as `chat_template_kwargs.enable_thinking`; confirm that your server forwards it to its chat template. An HTTP success alone does not prove that all context reached the model: verify instruction retention, tools, multi-turn replay and images on the deployed model.
