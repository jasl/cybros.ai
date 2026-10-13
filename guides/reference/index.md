# Reference

Lookup tables for the contracts the guides describe. Guides explain how to do something; these pages list what exists.

| Page | Contents |
| --- | --- |
| [Agent API](agent-api.md) | The `/agent_api/v1` common contract — requests, planes, errors, retries, HTTP and realtime, rate limits, read semantics — and one page per resource on the member and executor planes |
| [Platform API](platform-api.md) | The `/api/v1` common contract and one page per resource for human settings and administration |
| [OAuth and device flow](oauth.md) | An overview, then the [application login](oauth/application-login.md) and [device flow](oauth/device-flow.md) contracts |
| [Events](events.md) | The event vocabulary shared by conversations and runs, and the feed envelopes |
| [Statuses](statuses.md) | Task, run, turn, input and schedule states, failure keys and attention reasons |
| [Rate limits](rate-limits.md) | Per-resource budgets and the source-IP backstop |
| [Kernel tools](kernel-tools.md) | The tools the kernel serves, their canonical names and wire aliases |
| [Command line](cli.md) | `rho`, `./cybros` and `cmctl` commands |
| [Glossary](glossary.md) | Every term with its one meaning |

## Conventions

- Public identifiers are UUIDv7 strings. Model references, provider identifiers, tool names and task keys use their resource's own vocabulary.
- Timestamps ending in `_at` are whole-second ISO 8601 UTC unless a resource says otherwise; authored schedule rules keep six fractional digits.
- Requests send `Authorization: Bearer <credential>` and `Accept: application/json`; JSON bodies add `Content-Type: application/json`. `Token` is accepted as an alternative scheme.
- Errors use one JSON envelope: `{ "error": { "code": "…", "message": "…" } }`. A `5xx` body may be JSON, non-JSON or empty; classify by status.
- `limit` parameters use each resource's documented default when omitted; malformed, nonpositive or above-maximum values return `400 parameter_invalid` and are never clamped.
- Lists use opaque keyset cursors; hand `next_after` back to the same call with the same filters.
