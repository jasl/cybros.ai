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
5. Select the model in your connected Agent and send a normal request to verify
   inference. Saving configuration does not make a paid model call or prove that
   a provider accepts the credential.

## Custom providers and models

Choose **Add provider** to configure a connection without editing the deployment
catalog. Supply its identifier, display name, supported protocol, base URL and
credential mode. Local and private endpoints are supported. Save the connection,
install its API key if needed, or enable a credentialless provider. Credentials remain in
the existing write-only key settings, separate from connection definitions.

Choose **Add model** on a provider to enter an upstream model ID, or explicitly
load the provider's model directory. Directory discovery lists IDs; it does not
make an inference call or establish context limits, supported capabilities or
prices. Manual entry remains available when discovery fails or omits a model.
Set the model's context and output limits and capabilities to match its server.

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

Before a provider has a policy, **Models** links to
**Enable this provider** and disables the **Visible** and **Hidden** pills. Once initialized,
model visibility remains editable even while the provider is disabled.

Hiding a model removes it from Agent discovery and rejects new calls to that
model. It preserves the definition and pricing, so showing it again restores
the same model. Visibility and availability are separate: a shown model can
still be unavailable because its provider is disabled or needs authorization.

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

Once connected, the card shows **Subscription connected** and only
**Disconnect**. There is no second subscription or reconnect action. Disconnect
removes Nexus's local OAuth credentials and cancels pending authorization work;
it leaves provider enablement unchanged. A separate pending or failed attempt
can still be shown while a previously installed credential remains connected.
**Back to dashboard** returns to the installation's remaining setup tasks.

Only the issuing Human can see the verification link and user code while their
device authorization is pending. No page reveals device handles, access/refresh
tokens, OAuth exchange codes, PKCE values or provider account headers.

## Browser and CLI boundaries

The browser uses the existing Human login and normal CSRF-protected forms. It
does not create an API bearer or lend administration authority to rho's daemon.
The forms and [Platform API](platform-api/v1/admin-models.md) use the same
underlying settings operations. Platform JSON writes still require the API's
documented bearer credentials; browser cookie authentication there is read-only.

There is no provider-test inference endpoint on the administration plane.
Telegram setup and the default model remain the Agent application's settings;
see [Getting started](getting-started.md) for the terminal flow.
