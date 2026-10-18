# cmctl

cmctl is the human operator command line for Nexus. It drives the same settings operations as the browser's administration pages through the Platform API: provider connections, model definitions and credentials, subscription authorization, visibility, retention, the cost unit and budgets. It runs on Ruby on Linux and macOS and needs no JavaScript runtime. The Docker stack bundles it as `./cybros cmctl`.

## Log in

```sh
cmctl login --url http://localhost:3300 --email operator@example.com
cmctl status
cmctl providers
cmctl models --workload text_generation
```

Login prompts for the password without echo and saves only the API session and server URL in `~/.cmctl/session.json` (mode `0600`). `CMCTL_HOME` or `--home DIR` selects another connection; each home holds one login. A temporary password must first be changed in the Nexus browser.

## Guided setup

```sh
cmctl setup --url http://localhost:3300
```

The wizard — also included in `rho setup` and the stack's `./cybros setup` — signs in as an owner or administrator for this command only, preserves the separate saved cmctl login, and revokes its own API session on exit. It walks through selecting or adding a provider, installing or rotating a key or following the Codex subscription's browser flow, discovering or entering models, setting context limits and tool support, and optional prices. It runs no paid inference.

## Providers, keys and models

```sh
cmctl account cost-unit USD
cmctl provider key set openai_api        # prompts without echo; also rotates
cmctl provider enable openai_api
cmctl provider disable openai_api
cmctl models --available --workload text_generation

cmctl provider add local --base-url http://127.0.0.1:11434/v1 \
  --api-format openai_compatible_chat --credentials none --display-name "Local models"
cmctl provider discover local
cmctl model add local/my-model --input-tokens 32768 --output-tokens 8192 --tools
cmctl provider show local

cmctl model hide openrouter/vendor/model
cmctl model unhide openrouter/vendor/model
cmctl model test REF
cmctl model invalidate REF
cmctl model restore REF
cmctl model edit REF --input-price 1.50 --output-price 6.00
cmctl model remove REF
cmctl model reset REF
cmctl provider reset ID
```

- `models` returns the full administrative catalog, including unavailable models with their reason; agents see only available ones. Availability is a configuration check, not a network test.
- `provider discover` lists IDs from the provider's directory without inferring capabilities or prices; failures leave configuration unchanged.
- Every write reads the provider's current version first and returns `stale_object` on a concurrent change rather than retrying blindly.
- `model test` sends the fixed connection test with the saved human session; `rho run --model REF '...'` verifies an agent's real request.

## Retention and budgets

```sh
cmctl account retention
cmctl account retention 180
cmctl account retention off
```

Budget operations are described in [Retention, usage and budgets](retention-usage-budgets.md) and the [Platform API](../reference/platform-api.md).
