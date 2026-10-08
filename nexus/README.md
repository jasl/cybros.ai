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
- libvips (image variants; see [File previews](#file-previews) for PDF/video dependencies)

## Development

```bash
bin/setup            # installs dependencies/tokenizers, prepares Rails credentials and databases
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

## Local tokenizers

`bin/setup` preloads the official text tokenizers used by the shipped open-weight
models and local Qwen examples. The Docker build runs the same command:

```bash
bin/download-tokenizers          # download missing or changed pinned assets
bin/download-tokenizers --check  # verify all installed assets without network access
```

The [manifest](config/tokenizers.json) fixes each source revision, tokenizer
checksum and license checksum. Only `tokenizer.json` and `LICENSE` are downloaded,
about 68 MB in total; no model weights or remote Python code are loaded. Verified
files are reused, and a failed download preserves the previous file. Run the
command before starting a bare-metal installation and restart running processes
after replacing tokenizer assets; their loaded vocabularies are cached locally.

Model definitions explicitly select a counter. These counters feed input
estimates, history fitting and compaction planning. Exact text tokenization does
not include the provider's chat template or media processing: Nexus adds its own
chat allowance, while provider usage remains authoritative. Models without a
matching local tokenizer retain their declared estimate behavior. Missing or
invalid files report counter unavailability, never trigger a runtime download.
See the [asset notes](vendor/tokenizers/README.md) for model mappings and licenses.

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

## Provider catalog source

The `80_pi_*.yml` fragments import chat-model metadata from the immutable
`@earendil-works/pi-ai@1.1.0` package. The generator checks its SHA-512 integrity;
adapter behavior is compared with Pi source revision
`6fb2e7815167e6b19006fc526d1a5d0f5f998787`. Pi is a generation-time reference,
not a Nexus runtime dependency. Its [MIT notice](vendor/licenses/pi-ai-MIT.txt)
is included. Run `ruby script/import_pi_catalog.rb --check` to verify the
checked-in generated files, or omit `--check` to regenerate them. An already
extracted provider-data object can be supplied with `--source-json PATH`.

Pi supplies only new providers. The seven authored providers—OpenAI API,
Anthropic, Gemini, Codex subscription, OpenRouter, DeepSeek and xAI—keep their
complete Nexus definitions and model sets; Pi adds no models or metadata to
them. The import report records the 499 excluded source entries and the 1,064
chat models imported under 34 new providers. Regeneration removes obsolete
`80_pi_*.yml` fragments, and `--check` rejects them.

Every imported provider/model pair keeps its own context and output limits,
modalities, reasoning controls, endpoint and declared prices; identical model
names do not share metadata across providers. Unknown prices and schedules
that cannot be represented exactly remain unpriced.

New providers use the ordinary encrypted API-key credential lane. Their wire
format and authentication header are independent, so a gateway can carry
Messages or Gemini bodies while authenticating with its own bearer credential.
Static model headers cannot contain credentials. The following setup details
matter before using the imported providers:

| Provider | Required setup |
| --- | --- |
| Azure | Configure the resource endpoint and API key; Responses uses `/openai/v1/responses?api-version=v1`, Chat uses `/openai/v1/chat/completions`. |
| Cloudflare AI Gateway | Configure `https://gateway.ai.cloudflare.com/v1/ACCOUNT/GATEWAY` and its gateway bearer key. |
| Cloudflare Workers AI | Configure the account endpoint ending in `/ai`; the Chat route adds `/v1/chat/completions`. |
| Google Vertex | The imported route supports express-mode API keys at `https://aiplatform.googleapis.com`; project/location ADC credentials are not imported. |
| Amazon Bedrock | Supply a Bedrock bearer API key for the declared regional endpoint; SigV4 and ambient AWS credential discovery are not implemented. Regional model endpoints remain independent. |
| GitHub Copilot | Supply an already-issued Copilot API token; a GitHub PAT or device-login token is not exchanged automatically. |

Entries without a configured endpoint are unavailable before network I/O.
The existing Codex subscription authorization remains its own credential lane;
no Anthropic/Claude Code subscription authorization is imported. New OAuth
login/refresh workflows are outside this import.

Qualification is offline: source-shaped request, stream, tool replay and
credential-isolation fixtures plus complete catalog compilation. No paid
provider account has been exercised. Image generation and classifier entries
from Pi are outside this chat import, and Pi-specific image resizing, routing,
session-affinity and cache-placement policies are not imported. Existing Nexus
non-chat models remain available under their authored contracts.

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
`http://localhost:3300` (`NEXUS_PORT`). First boot opens the setup page and lets a
visitor create the first owner directly by default. An operator may explicitly
configure `NEXUS_SETUP_SECRET` to require a private secret for that step. Every
variable — client-facing URL, database, SMTP, concurrency — is documented in
`env.sample`. Uploaded files and PostgreSQL data live in the Compose-managed
`storage` and `postgres` volumes. The commented bind-mount examples are opt-in;
operators using them must prepare the host directory ownership and permissions.
TLS termination, reverse proxying, and backups are deployment concerns.

## File previews

Nexus generates upload thumbnails and previews through Active Storage in the
Nexus process. Its default image processor needs **libvips**. PDF previews need
**Poppler** (`pdftoppm`; Rails also supports MuPDF's `mutool`), and video previews
need **FFmpeg** (`ffmpeg`). PDF/video previews also use the image processor to
resize the rendered page or frame. Text and audio files have no thumbnail or
preview; their original bytes remain available through the ordinary upload read.

The Nexus Dockerfile includes libvips, but does not install Poppler or FFmpeg.
For PDF/video previews, add `poppler-utils` and `ffmpeg` to your Nexus image's
Debian packages, or install the corresponding packages on a bare-metal Nexus
host. Install them wherever Nexus web and background processes run. Packages
on a separate rho or Runner host do not give Nexus those capabilities.

Check the deployment's default preview dependencies with its normal Rails
environment and service user:

```bash
RAILS_ENV=production bin/rails uploads:check_preview_dependencies
# For the Nexus Compose deployment, run inside each relevant service:
docker compose --env-file .env.docker exec app bin/rails uploads:check_preview_dependencies
docker compose --env-file .env.docker exec jobs bin/rails uploads:check_preview_dependencies
```

The command reports whether libvips loads and whether the configured Rails
previewers accept PDF/video types, using Rails' own native-tool checks. It exits
nonzero if any dependency is missing. It creates no upload or rendered preview;
availability does not prove that an individual file or codec can render. Restart
Nexus processes after installing dependencies because Rails caches previewer
availability. `rho doctor` checks rho's environment and cannot replace this check.
