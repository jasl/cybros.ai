# Platform API Admin Users

Status: live Platform API resource.

Administration is Human-owned. This resource exposes Human-authorized member
removal. It currently has no `cmctl` command or `CybrosAgent::PlatformClient`
method; callers use the HTTP endpoint with a Human administration credential.
For browser member management, open **Administration → Members**.

## Remove a member

### Endpoint

```http
POST /api/v1/admin/users/{user_id}/removal
```

`{user_id}` is the target member's UUIDv7 public id. The target may be a
Human or Agent User in the authenticated Human's Account; the synthetic
system User is never reachable.

### Authentication

Accepts an API-kind Session bearer (`sk-cybros-session-v1-*`) or a Human
platform-plane AccessToken. The authenticated principal must be a live Human
`owner` or `admin`. Agent members, executor/task credentials, member-plane
tokens, and demoted platform-token bearers are `401`; unsafe requests never
fall back to a browser cookie.

### Behavior

The endpoint maps HTTP only; lifecycle policy stays in the domain command,
including the Workspace ownership guard — removal waits until
every non-tombstoned Workspace the target owns is transferred or tombstoned.
Suspension never consults ownership and is not part of this route.

### Status mapping

| Condition | HTTP |
| --- | --- |
| removed | `200` with `{"user": {public_id, kind, role, status, display_name}}` |
| non-Human, executor, member-plane, or demoted bearer | `401 unauthorized` |
| authenticated Human without a live owner/admin role | `403 administrator_required` |
| non-owner administrator targets themself | `403 user_not_administrable` |
| another administrator targets the Account owner | `403 installation_owner_protected` |
| Account owner targets themself | `409 installation_owner` |
| target still owns a non-tombstoned Workspace | `409 workspace_ownership_transfer_required` |
| removal would strand administration | `409 last_active_admin` |
| target already removed | `409 user_not_active` |
| target outside the scoped Account | `404 not_found` |

The command takes no `Idempotency-Key`: it is a state-based lifecycle command
whose typed outcomes define retry behavior.
