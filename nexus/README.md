# Nexus

Nexus is the Cybros kernel and gateway: a Rails application that owns accounts
and membership, workspaces, conversations and agent loops, the task inbox that
delivers work to agent applications, runners and tools providers, usage
accounting, and the human console. Every general agent mechanism is kernel;
product policy lives in agent applications built on its APIs. The
[technical manual](../docs/README.md) introduces the components and API families.

## Requirements

- Ruby (see `.ruby-version`)
- PostgreSQL 18+ (UUIDv7 defaults)
- Bun (CSS/JS builds)

## Development

```bash
bin/setup            # installs dependencies, prepares Rails credentials and databases
bin/setup --reset    # prepare, then drop and rebuild a development database
bin/dev              # Procfile.dev: web (debugger-ready), jobs, js/css watchers
```

`bin/setup` runs `db:prepare` to create a fresh database or apply pending
migrations to an existing one. Before release, schema changes may also be
folded into the initial migration. If a development database predates such
a fold, run `bin/rails db:reset` before `bin/setup`: `bin/setup --reset`
tries `db:prepare` first, which can fail against the old schema before it
reaches the reset. Reset deletes the development data; it is not an upgrade
procedure for an installation whose data must be retained.

Normal database preparation, reset and seeding create no administrator and choose
no Account cost unit. Open Nexus to create the first owner through `/setup`, then
continue to the Dashboard and its remaining setup tasks. Browser setup uses USD
for cost tracking; expand **Advanced options** before creating the owner to choose another unit.

For an empty local development installation, the explicit shortcut is:

```bash
bin/rails development:seed
```

It creates the shared local-only account `admin@example.com` / `Passw0rd!` and
does not replace an existing installation or choose a cost unit. It runs only in
development; never use that account in a production or publicly accessible
installation. Sign in to the Dashboard, then open `/admin/model_providers` to configure model access.

Local development uses Rails encrypted credentials by default. Environment
variables are documented in [`env.sample`](env.sample) for deployments and
advanced local overrides:

- `.env` is an optional, manually created file for advanced local use or
  bare-metal deployment; Rails loads it through dotenv when it boots.
- `.env.docker` is for Docker Compose and stays independent from any
  bare-metal configuration on the same host.

`bin/setup` never creates either environment file.

## Import provider API keys

An operator may import provider API keys from the process environment or a local
`.env` file. After founding the installation through the setup page, run:

```bash
RAILS_ENV=production bin/rails db:seed
```

The supported variables are `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `XAI_API_KEY`, and `OPENROUTER_API_KEY`.
The import stores credentials through the ordinary encrypted credential writer
and enables a provider lane only when its policy row is missing. Existing
disabled lanes stay disabled. Running it again replaces changed keys; absent
variables leave stored credentials intact. Only catalog-declared providers are
imported, and no provider request is made.

Normal seeds never create a demonstration account or choose an Account cost unit,
including in development. Browser setup normally configures USD. For an Account
founded through an advanced path with no unit, configure the unit explicitly at
`/admin/cost_unit` to use cost estimates and budgets. Models can run without a
unit or complete pricing; usage quantities are recorded and unknown monetary
amounts remain absent. Test seeds never import provider keys from the environment.
Codex subscription OAuth uses its own authorization flow and is not part of
API-key import.

## First provider

After the one-page first-owner form, Nexus opens the Dashboard. Its **To do**
cards link to **Configure model providers** and **Connect an agent**. The provider
card is visible to owners and administrators until a text model is available;
pricing is optional. The Agent card disappears when the current Human has
connected an Agent. Temporary offline status does not bring back the Agent task.

Model settings use the ordinary `/admin/model_providers` pages. Saving an API key
or completing subscription authorization also enables the provider. Enable a
credentialless provider with its availability control. Settings remain available
after the Dashboard task is complete. Configuration does not make a model call
or select an Agent's default model; verify inference with an ordinary request
from the connected Agent.
See [model settings](../docs/nexus-model-settings.md) for the complete flow.

## Tests and checks

```bash
bin/ci               # full local pipeline, including system tests
bin/test-smoke       # CI contract checks; accepts Rails test arguments
```

The smoke suite covers browser and API authentication, credential rotation and
revocation, workspace access, executor claims and commits, and the shipped model
catalog samples. It defaults to one worker; `PARALLEL_WORKERS` can override that.
The entry point prepares the test databases and builds assets before running these checks.

When running focused suites directly, run `bin/rails test` and
`bin/rails test:system` sequentially because both can trigger Bun asset work.

Test database names use `RAILS_TEST_APP_DB_NAME` and
`RAILS_TEST_CABLE_DB_NAME`. The development/production overrides
`RAILS_APP_DB_NAME` and `RAILS_CABLE_DB_NAME` do not affect tests. Rails also
prepares test schemas during development `db:prepare` and `db:reset`, so keep
the test names distinct even when development overrides live in
`.env.development.local`.

For a separate local test run:

```bash
RAILS_TEST_APP_DB_NAME=cybros_nexus_local_test \
RAILS_TEST_CABLE_DB_NAME=cybros_nexus_local_cable_test bin/rails test
```

## Deployment (docker compose)

```bash
install -m 600 env.sample .env.docker   # then fill in the production secrets
docker compose --env-file .env.docker up --build -d
```

The explicit `--env-file` supplies Compose interpolation while `compose.yaml`
injects the same file into the Nexus containers. Rails reads deployment
secrets through `Rails.app.creds`, which checks the environment before
encrypted credentials:
set `SECRET_KEY_BASE` (`bin/rails secret`) and the
`ACTIVE_RECORD_ENCRYPTION__*` keys documented in `env.sample`. Deployments that
prefer encrypted credentials can instead supply `RAILS_MASTER_KEY` for their
own untracked `config/credentials.yml.enc`.

Localhost and LAN-IP deployments do not need `BASE_URL`; request-bound Device
Flow and copyable Invitation links use the address through which the client
reached Nexus. Set `BASE_URL` only when the deployment binds a stable internal
or public domain, such as `http://nexus.internal:3300` or
`https://nexus.example.com`. It then becomes the canonical origin for those
links and for outbound mail. Public deployments should use HTTPS; absent
explicit overrides, the Rails SSL defaults follow that configured scheme and
otherwise remain off in direct mode.

The stack runs PostgreSQL 18, a one-shot database migrator, the app image
(Thruster in front of Puma), and a separate Solid Queue worker. It publishes
`http://localhost:3300` (`NEXUS_PORT`). First boot opens the setup page; configure
`NEXUS_SETUP_SECRET` before exposing an uninitialized installation. Every
variable — client-facing URL, database, SMTP, concurrency — is documented in
`env.sample`. Uploaded files and PostgreSQL data live in the Compose-managed
`storage` and `postgres` volumes. The commented bind-mount examples are opt-in;
operators using them must prepare the host directory ownership and permissions.
TLS termination, reverse proxying, and backups are deployment concerns.
