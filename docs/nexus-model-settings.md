# Model settings in Nexus

First boot is a single page for creating the first owner. On success Nexus opens
the Dashboard. Its **To do** cards link to model settings and Agent connection;
a completed task disappears automatically, without a saved onboarding flag.

The model-provider card is visible only to owners and administrators, until an
available text model is ready. Pricing is optional. The Agent card belongs to the signed-in
Human: another person's Agent, a Runner or an unconnected Agent definition does
not complete it. A connected Agent can be offline without making the task
reappear. Revoked or expired credentials without a usable refresh token restore
the task.

First-owner setup uses USD for cost tracking. To use another unit, expand
**Advanced options** on that initial form before creating the owner. An omitted
or blank unit uses USD. Once configured, the unit cannot be changed; Nexus does
not convert between units, so an alternative must match the deployment's pricing.

For separate settings, open **System settings** from Settings, or use
**Model providers** in the administration navigation (`/admin/model_providers`)
and **Cost unit** (`/admin/cost_unit`).

These are Account-wide settings. Ordinary members cannot change them; an Agent
discovers the models that are currently available and chooses a model through
its own application. rho's terminal alternative is [rho setup](getting-started.md).

## First usable provider

From the Dashboard, choose **Configure model providers**, then a provider. These
are the same administration pages available through Settings at any time; there
is no separate setup guide. When model access is ready, its Dashboard card
disappears. Start the connection from your Agent application, then use the
remaining **Connect an agent** card to enter its code.

The provider overview brings credentials, availability and models together:

1. **Cost unit** shows the unit already configured, normally USD. An advanced
   Account can configure one to enable cost estimates in that unit. An unset
   unit does not block model use. A configured unit cannot be changed.
2. Open a provider. For a provider that needs no credential, choose **Enabled**
   under **Provider availability**.
3. For an API-key provider, enter the key and choose **Save**. A successful save
   enables the provider. For Codex subscription access, complete the authorization
   flow below; successful connection also enables it.
4. Under **Models**, choose **Visible** or **Hidden** for each model. The selected
   pill shows the saved setting. A visible model also needs an enabled provider
   and usable credentials before an Agent can select it.
5. Choose **Test** beside a model, then **Run connection test** to verify its
   saved connection. This sends a fixed request and may incur provider charges.
   A normal request in your connected Agent verifies that application's workflow.
   Saving configuration alone does not make a paid call or validate a credential.

## Custom providers and models

Choose **Add provider** to configure a connection without editing the deployment
catalog. Supply its identifier, display name, supported protocol, base URL and
credential mode. Local and private endpoints are supported. Save the connection,
install its API key if needed, or enable a credentialless provider. Credentials remain in
the existing write-only key settings, separate from connection definitions.

The **Models** section contains **Add model** for manual entry and
**Discover model IDs** for an explicit provider directory request. A complete
fetch updates existing models: missing IDs become invalid and hidden from Agents,
and listed IDs have their invalid marks cleared. It compares each model's
configured upstream `model_id`, or its reference after the provider prefix when
no separate ID is set. Manual hiding is always kept. A complete empty directory
marks every configured model missing; failed, unsupported or incomplete directory
requests leave configuration unchanged.

Directory results show **Added** and an **Edit model** link for IDs already
configured, including upstream IDs used by local aliases. Only new IDs offer
**Add model**. Removed entries link to their existing settings for review and
restoration; an ID already used by a different local definition links to that
definition instead of offering a duplicate addition.

Discovery reads every page within its limits before saving the result. A concurrent
settings edit prevents that save and requires reviewing the current configuration.
It does not create models, make an inference call or establish context limits,
supported capabilities or prices. Manual entry remains available, and an unlisted
alias can use **Clear invalid mark**. Set the model's context and output limits
and capabilities to match its server.

**Context and capabilities** is always visible on the model form. For a local
server, enter the window actually loaded by the serving process, rather than the
maximum advertised by the model. For example, with a 32768-token shared window,
set **Combined context window** to `32768` and leave **Input token limit** blank.
These are alternative window contracts and cannot both be set. An **Advisory
input threshold** below that window can leave room for generation and chat-template
overhead; it drives planning, not a change to the server's allocation.

If the provider rejects a request for context length, Nexus attempts the existing
compaction repair when the run allows it. A repair is bounded: the same round
does not keep summarizing on repeated rejection. A misconfigured window can make
the summary itself too large, and instructions or a large new input may not be
removable history. Correct the model settings and shorten the input or start a
new conversation if the request still cannot fit.

Also check the requested output budget. **Output token limit** declares the
model's limit; it does not set the provider's `max_tokens` request field. An
explicit `configuration.max_output_tokens`, or the model's
`generation_parameters.max_output_tokens.default`, can make even a short prompt
exceed a shared window. Lower that requested budget as needed. Model directory
discovery does not overwrite any of these settings.

Pricing is optional advanced configuration for spending estimates. Missing
prices or an unset cost unit do not block an otherwise available model. Usage
quantities continue to be recorded; an unknown monetary amount remains absent,
while a complete explicit zero-price schedule produces a zero estimate.

Saved definitions persist in Nexus and apply to later reads and requests
without a restart. Deployment files remain the base. Resetting a file-backed
definition restores that base; removing a custom definition removes its
configuration. Disabling a provider instead preserves its definitions and keys.
Changing Nexus configuration does not change an Agent application's default
model; select the new model there and send an ordinary request to verify it.

## Thinking and effort

Thinking uses two independent request options: `reasoning_enabled` is a boolean,
and `reasoning_effort` chooses a model's declared effort. A reasoning declaration
defaults to enabled unless `default_enabled: false` is set. The catalog accepts
that false default only with `disable_supported: true`. A request to disable a
model that cannot turn thinking off is ignored, and the effective selection stays
enabled. A model with no reasoning declaration has no reasoning selection.

Effort applies while thinking is enabled. Turning thinking off sends no active
effort to the provider; `none` is not a public effort value. A switch-only model
needs no effort vocabulary. When an effort is omitted, `default_effort` applies;
if no default is declared, the provider chooses its effort.

The shipped catalog defaults Anthropic models to `high`, OpenAI models to
`medium`, and open-weight models to `low` where their declared vocabulary allows
it. GLM 5.2 exposes only `high` and `xhigh`, so its default remains `high`. Closed
Qwen Max keeps `xhigh`, and Gemini and xAI keep their explicit catalog defaults.
These are row settings, with no model-family inference in the request path.

## Local Qwen examples

The three existing deployment samples in `nexus/config.d` include the following
local selection policy. These intended uses describe one deployment's choices;
they are not benchmark results or protocol capabilities inferred from a model name.

| Nexus reference | Upstream weights | Intended use in this example | Thinking default |
| --- | --- | --- | --- |
| `local/qwen3.8-flash-next` | [Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) | Conversation; the local counterpart of the `qwen/qwen3.8-flash` choice. | On, `low` effort |
| `local/qwen3.8-27b` | [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) | A limited alternative for conversation. | On, `low` effort |
| `local/qwen3.6-35b-a3b` | [Qwen/Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) | Simple agent-driven scheduled work. | On, switch only |
| `local/qwen3.5-9b` | [Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) | Low-cost visual recognition. | Off, switch only |

Copy `providers.yml.sample`, `models.yml.sample` and
`model_selectors.yml.sample` to their `.yml` names only if those files do not
already exist; otherwise edit the existing overlays. A verbatim copy changes
nothing because every example below `schema_version` is commented out. Uncomment
the `local` provider, the models your server serves and only the selectors you
want. The `example-*` model rows and the fully expanded `example` provider teach
the configuration grammar; they are invented names, not additional deployments.

The provider sample uses `http://127.0.0.1:13305/v1`, a
[Lemonade API example](https://lemonade-server.ai/docs/api/lemonade/), and one
concurrent request. Set the URL to the API base reachable from the Nexus process;
inside a container, `127.0.0.1` addresses that container. Use the actual serving
port and path. `credentials: none` applies only when the server requires no API
key; otherwise select `api_key` and install it through Nexus settings.

`model_id` must match an ID returned by the configured server's `GET /v1/models`
(the `models` resource under its API base). The samples show full Hugging Face
IDs for servers exposing those names. Lemonade or a GGUF installation may expose
a registered alias for a particular quantization instead. Copy that exact ID
into `model_id`; the Nexus reference can remain unchanged. A nickname such as
`flash-next3bit` does not identify the actual GGUF, quantization or loaded chat
template. Directory discovery identifies names, not supported features.

All four rows explicitly assume a **32768-token shared input/output window** and
a **4096-token output limit**. These are example server settings, not claims about
the models' maximum context. Match `combined_input_output_tokens` to the effective
per-request context configured in the serving process, such as llama.cpp's
`--ctx-size`, and set the output limit accordingly. Do not copy a cloud provider's
million-token window into a smaller local server. Nexus configuration neither
allocates KV cache nor changes the server's context size. The 9B row enables image
input only for a server loading the required vision components, including a
matching projector where its GGUF backend requires one; remove that declaration
for a text-only deployment.

All four rows bind `wire_options.reasoning_control: chat_template_kwargs`.
Nexus sends the independent switch as `chat_template_kwargs.enable_thinking`,
including `false` for the 9B default. Confirm that the deployed server forwards
this option to its chat template; a Lemonade URL or a model ID alone does not
establish that behavior. The two Qwen3.8 weight releases declare `low`, `medium`
and `xhigh` effort; the 35B and 9B examples declare only an on/off switch. The
closed OpenRouter Qwen3.8 Flash row has its own switch-only contract and does not
inherit the weight releases' effort vocabulary. The linked official model cards
describe these template controls.

The four samples explicitly select the instruction-role adaptation described
below. They do not establish full rho compatibility: verify instruction retention,
tools, multi-turn replay and images on the deployed model. Quantization packages
can ship different templates, including ones that silently omit later instructions.
An HTTP success alone does not prove that all context reached the model.

The four local examples explicitly select the official tokenizers preloaded by
`nexus/bin/download-tokenizers` and included in the Nexus image. Flash-Next and
27B share the identical Qwen3.8 tokenizer artifact; the 35B-A3B and 9B examples
share the identical earlier artifact. These count text for planning and
compaction. Provider chat-template framing and media can still change the actual
input usage, so the count is not an exact prediction of provider billing.

## Model prompt adaptation

Declare a model's instruction layout in its definition, independently of its
provider or inference framework:

```yaml
wire_options:
  prompt_format: qwen3_5
```

`qwen3_5` names the single-leading-system instruction layout shared by the checked
official templates for [Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B/blob/main/chat_template.jinja),
[Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/blob/main/chat_template.jinja),
[Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/chat_template.jinja)
and [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/chat_template.jinja).
These templates have no developer role and accept system only at the beginning.
The setting describes instruction roles, not their whole chat templates, thinking
behavior, tool syntax or multimodal support. The closed Max and Flash models do
not inherit it from their names.

For each outgoing request, Nexus combines any separate `instructions` with the
leading run of system/developer messages into one system message, preserving text
order and separating the original messages with two newlines. Later system or
developer messages become user messages at the same positions. No instruction is
hoisted across earlier conversation, and user content, assistant responses,
tool calls/results and reasoning retain their order. This is an explicit loss of
instruction-role priority on models whose templates cannot represent those roles;
it is not a claim that the roles are semantically equivalent. The official system
content is text-only; put images in user messages.

The transformation runs after prompt assembly, during request compilation and
before cache markers are placed. Accepted input, history, per-turn prefaces and
sealed requests keep their original roles. A retry recompiles that source, and a
model change uses the new model's format; it never inherits the previous model's
projected roles. The same path serves assembled conversations, raw inputs, loop
continuations and InferenceRequests. An undeclared format leaves the existing protocol
lowering unchanged. This option is not transmitted as a provider parameter.

For a temporary deployment workaround, put this supported format on that model's
existing definition and keep rho's input model-neutral. A raw caller still owns
the complete supplied message list: if it changes roles before submitting them,
those changes are its input and cannot be reversed by switching models. This
adaptation does not infer a format from endpoint behavior, execute arbitrary
client prompt transforms, or add retry or model-fallback policy.

## Keys, enablement and model visibility

Keys are write-only. Nexus shows whether a key is configured, never its bytes,
prefix or fingerprint. To rotate a key, enter the replacement and choose
**Update**; **Remove** sits beside it in the same card. Saving a key also enables
the provider, including when the key has not changed. Removing a key
removes that credential; it does not change the provider's enabled setting.
A failed form does not refill the key field.

Choose **Disabled** to make a provider unavailable for new work while keeping its
credentials and model configuration; it also cancels pending subscription
sign-in so a late response cannot turn it back on. Choosing **Enabled** again restores
eligibility subject to the remaining credential and model checks.

Model visibility can be configured before enabling a provider or saving credentials.
The first visibility change creates its saved settings without enabling the provider.
Provider access and credential status appear above the model list; individual rows
show only model details, visibility and any invalid mark.

**Hidden** is the manual choice to opt a model out of Agent use. It removes it
from Agent discovery and rejects new calls to that model. It preserves the
definition and pricing, so showing it again restores
the same model. Visibility and availability are separate: a shown model can
still be unavailable because its provider is disabled or needs authorization.

An invalid model shows **Invalid · hidden from agents**, while its definition
and pricing are kept. This mark blocks new requests and removes the model from
Agent discovery. Its **Clear invalid mark** action clears only that mark; any
manual hiding remains. Discovery or a connection test sets invalid status;
use **Hidden** for a manual opt-out.

**Test** opens the model's connection test. **Run connection test** sends one
fixed small request for its workload using the saved credentials. It may incur
provider charges, has a maximum 30-second provider deadline and does not add
usage to Agent statistics. The result includes elapsed time and an HTTP status
when available, without exposing generated content or raw provider errors.
Success checks that request, not all declared capabilities.

A successful test clears the invalid mark and preserves manual hiding. Only
unambiguous structured evidence that the model does not exist or was retired
automatically marks it invalid. A generic 404, ambiguous upstream
`model_not_found`, authentication failure, rate/quota limit, timeout or uncertain
response leaves it unchanged. If another administrator edits the settings
during the request, the page reports that the result was not applied; review the
current settings before another test. Each Human may run 10 tests in three minutes.

If another administrator changed the same policy since the page loaded, reload
the form and review the current values before submitting again. A stale form
does not silently overwrite the other change.

## Codex subscription authorization

Open **OpenAI Codex**, then choose **Connect** inside the
**No subscription connected** card. The authorization code, progress and any
error appear in that same card. Use **Open authorization page** to continue in
your browser with the displayed **Authorization code**. Nexus's background
workers complete the exchange, save the subscription credentials and enable the provider;
no CLI refresh token is imported.

Progress follows that exact authorization session. **Refresh status** reads
recorded progress without starting another authorization or contacting the
provider. Reloading the overview shows the current subscription status.
**Connect** resumes your pending sign-in. If another administrator owns the
pending sign-in, its code stays private; connecting asks for confirmation before
replacing it. After a failed or expired attempt, choose **Connect** to try again.

Once connected, the card shows **Subscription connected** with **Disconnect**
as its credential action. There is no second subscription or reconnect action. Disconnect
removes Nexus's local OAuth credentials and cancels pending authorization work;
it leaves provider enablement unchanged. A separate pending or failed attempt
can still be shown while a previously installed credential remains connected.
Use the page's parent navigation to return to the provider list. When shown,
**Manage models** in the subscription card opens that provider's model settings.

Only the issuing Human can see the verification link and user code while their
device authorization is pending. No page reveals device handles, access/refresh
tokens, OAuth exchange codes, PKCE values or provider account headers.

## Browser and CLI boundaries

The browser uses the existing Human login and normal CSRF-protected forms. It
does not create an API bearer or lend administration authority to rho's daemon.
The forms and [Platform API](platform-api/v1/admin-models.md) use the same
underlying settings operations. Platform JSON writes still require the API's
documented bearer credentials; browser cookie authentication there is read-only.

The fixed administrative connection test is also available through
`cmctl model test REF`; `model invalidate REF` and `model restore REF` manage
the same invalid mark. Arbitrary conversation execution remains on the member plane.
Telegram setup and the default model remain the Agent application's settings;
see [Getting started](getting-started.md) for the terminal flow.
