# OpenAPI description

Nexus publishes its HTTP API description as OpenAPI 3.2 JSON. Download it to
inspect request and response schemas or import it into an OpenAPI client.

## Routes

```http
GET /openapi.json
```

## Read the description

### Endpoint

`GET /openapi.json`

### Request

No authentication, parameters, or request body are required.

### Response

`200 application/json` returns an OpenAPI document with `openapi: "3.2.0"`.
Its relative server URL points to the same installation and includes the
configured deployment prefix.

The document covers the [Agent API](agent-api.md), including executor transport,
the [Platform API](platform-api.md), and the machine endpoints of
[OAuth](oauth.md). Each operation declares its accepted credential plane.
The description itself grants no access to those operations.

Browser pages and WebSocket messages are described in their owning references.
Downloads and streams carry their actual media types in the HTTP description.

### Status codes

`200` returns the description. A server failure may return a non-JSON response.

## Maintain the description

OasRails reads Rails routes and YARD declarations beside controller actions.
Every HTTP API action has `@oas_include`, a summary, resource tags, and explicit
request and response declarations. Concrete controller class comments declare
`@auth`; public actions use `@no_auth`. Shared concerns retain their action
schemas while the concrete controller supplies the credential plane.

Reusable schemas, parameters, request bodies, and responses live in
`nexus/config/openapi/components.json`. Action declarations reference them:

```ruby
# @oas_include
# @summary Read a workspace
# @tags Member, Workspaces
# @parameter public_id(path) [!String] Public UUIDv7. format: (uuid)
# @response_ref (200) #/components/responses/AgentApiV1WorkspacesShow
def show
  # Render the existing resource projection.
end
```

Update declarations when fields, required values, status codes, or accepted
credentials change. Schemas describe public projections, including conditional
and nullable fields; database columns are not a public response contract.
Caller-authored JSON and tool-provided JSON Schemas retain their opaque shapes.

From the `nexus` directory, run:

```sh
bin/rails openapi:check
bin/rails test test/controllers/openapi_test.rb
```

The check generates `tmp/openapi.json` and validates it with Redocly CLI under
Bun. Request tests validate response schemas with `json_schemer`. Route coverage
tests detect missing operations and path parameters. The existing manual and
SDK contract fixtures continue to describe and verify behavior.

Production memoizes the description in each process. Development rebuilds it
for each read, so controller declarations and component edits appear without
an export command. Production generation uses deployed source and authored
schemas, without reading account data or requiring test support.
