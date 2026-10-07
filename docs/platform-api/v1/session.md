# Platform API Session

Status: live Platform API resource.

The singleton `/api/v1/session` resource creates an API-kind Session, inspects
the currently presented Session, and revokes it. API Sessions are interactive
login credentials for clients such as `cmctl`. Human administration automation
can use a personal access token minted for the `platform` plane; its owner must
remain an active Human, and admin resources additionally require the current owner/admin
role. [Application OAuth](../../oauth/application-login.md) supplies a renewable Human
platform credential. Inspect it through `/api/v1/profile`; `/api/v1/session` describes
Session credentials only. A `member`-plane token cannot
call this API family.

An API Session has a fixed 30-day absolute lifetime from issuance. Activity and
reads never extend that lifetime. At or after `expires_at`, the Session no
longer authenticates or appears in the active-session list; storage cleanup
need not have run yet.

## Create an API Session

### Endpoint

```http
POST /api/v1/session
```

This endpoint is unauthenticated. It verifies an active human member's email
and current password and, on success, creates an API-kind Session.

### Body parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `email` | string | Required login email address. |
| `password` | string | Required current password. |

Unknown email addresses, incorrect passwords, non-active members, and missing
credential values all return the same `401 invalid_credentials` response. The
same response covers malformed credential strings, including values containing
a null byte. Clients must send both fields in the JSON request body and must not
rely on finer request-shape distinctions. This is safe client guidance, not a
second parameter stack: Nexus retains Rails' standard merged request parameters,
so clients are responsible for never placing credentials in the query string or
sending conflicting query/body copies.

### Success response

`201 Created` reveals the bearer secret exactly once:

```json
{
  "session": {
    "public_id": "01900000-0000-7000-8000-000000000001",
    "kind": "api",
    "expires_at": "2026-08-21T12:00:00Z"
  },
  "token": "sk-cybros-session-v1-lookup.secret",
  "token_type": "Bearer"
}
```

Only the token's lookup identifier and salted digest are retained. The raw
`token` cannot be retrieved after this response. Keep `session.public_id` with
the credential record. If the token is lost, create a replacement if needed,
then use the matching Session ID shown under **Settings → Sessions** to revoke
the lost Session without revoking its replacement. This singleton API can
revoke only the bearer presented to `DELETE /api/v1/session`. Clients must treat
the complete response as credential material and must never log it.

| Field | Type | Description |
| --- | --- | --- |
| `session.public_id` | UUIDv7 string | Public identifier of the created Session. |
| `session.kind` | string | Always `api` for this create endpoint. |
| `session.expires_at` | ISO8601 string | Fixed absolute expiry, 30 days after issuance. |
| `token` | string | Show-once bearer secret. It is never returned by a later read. |
| `token_type` | string | Always `Bearer`. |

### Rate limit

Session creation uses Rails' native fixed-window limiter: the first attempt
starts a three-minute window allowing 10 attempts from that source IP. The next
attempt inside an exhausted window returns:

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 180
Content-Type: application/json
```

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Too many requests"
  }
}
```

`Retry-After` is the number of whole seconds the client must wait before
retrying. The sample value is illustrative; clients must use the received
header.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `201 Created` | — | API Session created and its bearer revealed once. |
| `400 Bad Request` | `bad_request` | Malformed JSON handled at the controller boundary. |
| `401 Unauthorized` | `invalid_credentials` | Email/password authentication failed or the member is not active. |
| `403 Forbidden` | `local_recovery_required` | The otherwise-valid Identity is fenced pending deployment-local recovery. No Session is created. |
| `403 Forbidden` | `password_change_required` | The temporary password must first be changed in the web console. No Session is created. |
| `429 Too Many Requests` | `rate_limited` | The login limit was exhausted. The response includes `Retry-After`. |

## Get the current Session

### Endpoint

```http
GET /api/v1/session
```

Authenticate with an API Session bearer or a same-origin browser Session
cookie. A present `Authorization` header is authoritative: failure returns
`401` without falling back to the cookie. The response is `200 OK`:

```json
{
  "session": {
    "public_id": "01900000-0000-7000-8000-000000000001",
    "kind": "api",
    "expires_at": "2026-08-21T12:00:00Z"
  }
}
```

For a browser cookie, `kind` is `browser`. The resource read does not update
Session activity, extend expiry, rotate the bearer, reap Sessions, or perform
external I/O. Successful member access-token authentication may still perform
the bounded `last_used_at` sample described by the API index before this
resource returns `404`. The endpoint has no resource-specific rate limit.

A browser Session whose Identity still requires a password change returns
`401`; Platform JSON responses never redirect to the web password-change page.

There are no query or body parameters.

An otherwise-valid platform-plane member access token authenticates the Platform
API family but does not represent a Session, so this resource returns
`404 not_found` for that principal.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | Current Session returned. |
| `401 Unauthorized` | `unauthorized` | The Session credential is missing, invalid, expired, revoked, fenced, or belongs to another API family. |
| `404 Not Found` | `not_found` | The authenticated Platform API principal is a member access token rather than a Session. |

## Revoke the current API Session

### Endpoint

```http
DELETE /api/v1/session
```

Authenticate with the API Session bearer being revoked. Browser cookies are
not accepted for this mutation. Success deletes that Session and returns
`200 OK`:

```json
{
  "revoked": true
}
```

The bearer stops authenticating immediately. Repeating the request with the
same bearer therefore returns `401 unauthorized`. An otherwise-valid
platform-plane member access token does not represent a Session and receives
`404 not_found`.

There are no query or body parameters.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | Current API Session revoked. |
| `401 Unauthorized` | `unauthorized` | The API Session bearer is missing or unusable; a browser cookie cannot authorize this mutation. |
| `404 Not Found` | `not_found` | The authenticated Platform API principal is a member access token rather than a Session. |
