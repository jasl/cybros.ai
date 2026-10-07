# Platform API Profile

Status: live Platform API resource.

The Platform API profile identifies the acting Account member and names the
presented credential's plane. It does not expose email
addresses, internal database ids, raw credentials, digests, or Session ids.

## Get the current profile

### Endpoint

```http
GET /api/v1/profile
```

### Authentication

This endpoint accepts:

- an API-kind Session bearer;
- a same-origin browser Session cookie; or
- a platform-plane member access token, while its owning member remains an
  active Human.

A member-plane access token belongs to the Agent API family and returns
`401`. Demotion removes administrator authority but preserves ordinary Human
profile access. A suspended, removed, revoked, expired, or
authority-fenced credential returns `401` on its next request.
A present `Authorization` header is authoritative: if that credential fails,
the endpoint returns `401` and never falls back to a browser cookie. The cookie
is considered only when the header is absent.
A browser Session whose Identity still requires a password change also returns
`401`; Platform JSON responses never redirect to the web password-change page.

There are no query or body parameters.

### Response

For a Session principal, `credential_plane` is `null`:

```json
{
  "member": {
    "public_id": "01900000-0000-7000-8000-000000000002",
    "kind": "human",
    "role": "member"
  },
  "credential_plane": null
}
```

For a platform-plane member access token:

```json
{
  "member": {
    "public_id": "01900000-0000-7000-8000-000000000003",
    "kind": "human",
    "role": "admin"
  },
  "credential_plane": "platform"
}
```

| Field | Type | Description |
| --- | --- | --- |
| `member.public_id` | UUIDv7 string | Public identifier of the acting member. |
| `member.kind` | string | `human`; this API family accepts only Human principals. |
| `member.role` | string | Current member role: `owner`, `admin`, or `member`. |
| `credential_plane` | string or `null` | The mint-frozen plane for an access-token principal (`platform` here); `null` for a Session principal. |

This `GET` has no endpoint-specific rate limit. Its resource action is
observational, but successful member access-token authentication may refresh
that token's non-authoritative `last_used_at` sample at most once per hour. It
does not extend or rotate the credential, contact an external service, refresh
any other projection, or drive background work. No write may use this composed
response as a current-state precondition; the command endpoint must evaluate
its own authority.

### HTTP response status codes

| Status | Code | Description |
| --- | --- | --- |
| `200 OK` | — | Profile returned. |
| `401 Unauthorized` | `unauthorized` | The credential is missing, invalid, unusable, or not accepted by the Platform API family. |
