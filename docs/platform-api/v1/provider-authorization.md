# Provider subscription authorization

All routes below require a live Human owner/admin through the Platform API.
An API Session works; Agent/member and executor credentials do not. Provider
OAuth is separate from Nexus's device connection ceremony and never creates a
Nexus principal. The current adapter is `codex_subscription`; API-key and
credentialless lanes return `409 authorization_not_supported`.

The [Nexus browser settings](../../nexus-model-settings.md#codex-subscription-authorization)
consume the same authorization services through Human-session HTML forms. The
JSON routes below keep their existing credential requirements.

## Read current authorization

```http
GET /api/v1/admin/model_providers/{id}/authorization
```

Returns `200`:

```json
{"authorization":{"provider_id":"codex_subscription","state":"pending","expires_at":null,"session":{"public_id":"<uuid>","kind":"device_start","state":"pending","progress":"awaiting_user","outcome":null,"expires_at":"2026-09-29T00:15:00Z","verification_uri":"https://auth.openai.com/codex/device","user_code":"TEST-CODE","owned_by_current_user":true}}}
```

`session` is the latest retained session, or null. Top-level `state` is
`missing | pending | authorized | reauthorization_required`; `expires_at` is
the installed credential's expiry, or null. Existing credentials can remain
`authorized` during a new ceremony. Wait for that ceremony's own session to
complete rather than treating the top-level state as its outcome.

A session exposes `public_id`, `kind` (`device_start | token_refresh`), `state`
(`pending | completed | failed | revoked | expired`), recorded `progress` and
nullable `outcome`. Its `expires_at` is the device authorization deadline, or
null before a code exists / for a refresh. `owned_by_current_user` identifies
the issuer without disclosing another member's identity.

The bounded user code and reviewed verification URI appear only for the issuing
Human's pending device start. All other projections carry null for these two
fields. No device handle, token, authorization code, PKCE material, provider
account identity, private task or raw provider response is exposed. Terminal
sessions clear their secrets and are collected after 30 days; exact reads then
return 404. Both current and exact reads are side-effect-free: no locks, jobs or
provider IO.

## Start or resume

```http
POST /api/v1/admin/model_providers/{id}/authorization
```

```json
{"command":{"restart":false}}
```

Returns `202 {"authorization_session": <session above>}` and `Location` pointing
to `/api/v1/admin/model_providers/{id}/authorization/sessions/{public_id}`.

```http
GET /api/v1/admin/model_providers/{id}/authorization/sessions/{public_id}
```

This exact session read returns `200` with the same envelope. A missing session
or one under another provider is 404.

The lane may be disabled or have no policy row yet. POST creates a disabled
policy anchor when needed; successful authorization enables the provider in the
same transaction that installs its credentials. A pending or failed ceremony
does not enable it. With no pending session, POST creates a device start. A pending device
start issued by the current Human is resumed without replacing its code or
resetting its deadline. A pending refresh or another issuer's pending session
returns `409 authorization_in_progress`. `restart: true` explicitly supersedes
any pending session and creates a new device start. Omitted `restart` is false.

Nexus's workers advance the session; the POST itself performs no provider IO.
Precise job wakes shorten the ceremony and existing recurring jobs recover lost
wakes and interrupted work. Poll timing is checked again at the claim boundary.
GET never drives the authorization. There is no public refresh, poll, exchange,
or credential-import command. Internal refresh requires an enabled provider and
never changes its availability setting. Disabling the provider cancels pending
authorization, so a late response cannot enable it again. Issuer endpoints are
fixed by the adapter.

This is start/resume semantics, not exact response replay or a command receipt.
Do not automatically retry a failed POST. Recover with GET, then deliberately
resume or restart if needed. The SDK sends each POST once. Creation is limited
to 10 requests per authenticated Human per three minutes.

## Clear

```http
DELETE /api/v1/admin/model_providers/{id}/authorization
```

Clears local OAuth
credentials and revokes pending authorization work in the existing transaction.
It returns `200 {"authorization": <current projection>}`, including when already
empty. The policy row and lane enablement remain. This has no provider IO and
never imports or shares a Codex CLI refresh token.
