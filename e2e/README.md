# E2E diagnostics

Run the deterministic harness and product journeys with `bundle exec rake` from
this directory. Real model calls are separate, explicit development diagnostics.
The journey manifest uses seven isolated worlds, with two or three running at once
according to PostgreSQL's connection ceiling. Splitting suites adds worlds without
increasing concurrent worlds or the default 880-second journey deadline.

## Local evaluation artifacts

Generated records, provider captures and temporary analysis stay under the ignored
`artifacts/` directory. They may contain private environment or provider output and
are not regression fixtures. The local layout is:

| Directory | Contents |
|---|---|
| `artifacts/evals/<label>/` | Traces, requests, logs and run diagnostics |
| `artifacts/evals/runs/` | Run records, generated scorecards and ledger |
| `artifacts/evals/analysis/` | Retired one-off analyzers, counts and report fragments |
| `artifacts/bench/captures/` | Scripts and manifest from the compose matrix probe |
| `artifacts/compose-probe/` | Captures from the single compose probe |
| `artifacts/fixtures/` | Previously captured evaluation fixtures, kept locally |
| `artifacts/screen-history/` | Retired experiment definitions and their batch-specific tests |
| `artifacts/screen-readouts/` | Generated readouts for new screen runs |

Reviewed historical conclusions remain in [`evals/analysis/`](evals/analysis/README.md).
Ordinary tests use small authored inputs, including the synthetic model policy in
`support/fixtures/evals/bench.yml`. Real model targets belong to the explicit manual
evaluation configuration in `evals/bench.yml` or the documented environment options.
Tests of model-specific adaptation or provider protocols may name the models whose
behavior they exercise.

## GitHub smoke and local acceptance

GitHub Actions runs key harness tests, RuboCop and a single smoke world:

```sh
E2E_WORLDS=1 E2E_DEADLINE_SECONDS=300 E2E_TEARDOWN_DEADLINE_SECONDS=60 \
  bundle exec rake smoke_harness_test smoke rubocop
```

The smoke task reuses all tests in `device_connection_test.rb`, `rho_run_test.rb`
and `rho_core_only_test.rb`: browser pairing, SDK credential rotation/revocation,
runner re-pairing, CLI conversations and streaming, questions/approval/timeout,
and an actual runner file write. It uses one isolated Nexus with the local fake
provider and requires the Nexus, rho and E2E bundles, PostgreSQL, Bun and Chrome.
It needs no Docker image or separate cmctl bundle. CI saves the complete smoke
log and any failure diagnostics, and bounds the job at ten minutes.

The smoke harness checks product contract fixtures, tool declarations and rule
grammar, fake-provider wire behavior, process deadlines/cleanup, isolated boot
configuration, failure capture and the test-world manifest. Benchmark, evaluation
and reporting harness tests remain in the complete local `harness_test` task.

The full `bundle exec rake` remains the local acceptance gate. Run it before
integrating cross-project behavior changes, with the installation image built
locally when validating the container and Compose journeys:

```sh
# From the repository root:
docker build -f install/docker/Dockerfile --target rho -t rho-install-test:rho .
cd e2e
bundle exec rake
```

Full coverage includes the other conversation, recovery, Telegram, memory,
scheduling, tool and installation journeys. A green smoke run does not cover
those cases. The host installation lane remains an explicit local opt-in;
an installation skip never establishes that installation works.

Product journey logs include the actual Ruby command, the Minitest seed, and each
test's elapsed time. Preserve a failed group's `tmp/e2e_groups/<group>.log` before
another full run overwrites it. The command matters for reproduction: Minitest's
Rake task randomly orders file loading before the reported seed takes effect.
Repeating a seed alone does not restore that load order, and invoking `:cmd`
afterward generates a new order. The original command and seed together identify
the class and method order that ran.

## Agent API parallel load

`E2E_AGENT_API_LOAD=1 bundle exec rake agent_api_load` runs 16 and 32 parallel
clients against an isolated Nexus using the public member and executor APIs. It
creates short tool tasks, claims and commits them, and exercises events and Store
CAS without model calls. This measurement is excluded from the default gates.
Each width completes 128 tool tasks and 24 event reads per worker. Results in
`artifacts/agent_api_load/last.json` include request counts, HTTP statuses,
per-route latency percentiles, Rails query counts and worker failures. The test
requires no worker failure or HTTP 429 response. Its timings include the isolated
development server, logging, scheduling and loopback HTTP; they do not establish
production capacity or model inference performance.

## Docker stack installation

[StackInstallationTest](test/stack_installation_test.rb) is an opt-in journey
against an already running, fresh disposable stack from the
[joint installer](../install/stack/README.md). Use a separate installation
directory, Compose project name and ports; the account must not have been
created yet. For example, from the repository root:

```sh
CYBROS_PROJECT_NAME=cybros-stack-check \
CYBROS_NEXUS_PORT=13300 CYBROS_RHO_PORT=17777 \
sh install/stack/install.sh --dir "$HOME/cybros-stack-check"

cd e2e
bundle install
E2E_STACK_DIR="$HOME/cybros-stack-check" \
E2E_BASE_URL=http://localhost:13300 \
bundle exec ruby -Itest test/stack_installation_test.rb
```

The browser harness needs Chrome and its matching driver. Optional
`E2E_CHROME_BINARY` and `E2E_CHROMEDRIVER` select local binaries. The Ruby bundle
and browser are developer test dependencies, not installation prerequisites.

The journey creates the account through the setup page, configures models with
the container's `cmctl`, pairs full-mode rho through browser approval, checks
model discovery, and unlocks/reloads the shipped WebUI. It uses a synthetic
provider key, clears that key afterwards, and performs no inference or real
provider IO. It is excluded from the default journey groups and skips unless
both `E2E_STACK_DIR` and `E2E_BASE_URL` are supplied.

The test closes its browser and owned pairing process, but does not start or
tear down the supplied stack. Inspect diagnostics under
`e2e/artifacts/stack_installation/`, then stop the disposable stack with its
`./cybros stop` command. Do not point this journey at an existing personal
installation or delete its data as part of test cleanup.

## Model management

Install each participating Ruby bundle first: run `bundle install` in `nexus/`,
`agents/rho/rho/`, `cmctl/`, and `e2e/` from the repository root. The journey launches
cmctl and rho with their own frozen Gemfiles and lockfiles.

`bundle exec ruby -Itest test/model_management_test.rb` boots an isolated Nexus,
local fake provider and rho daemon. It configures a catalog API-key lane through
`cmctl`, discovers available models with `rho models`, and completes a real
`rho run` conversation. The fake provider requires the synthetic key supplied
through the CLI. The journey also checks denied member-plane administration,
non-admin login, model hide/unhide, explicit-reference refusal while hidden,
disable, key removal and logout. It uses no real provider key.

The custom-model journey creates a provider connection and model through the
same CLI, discovers upstream IDs, then executes an unpriced model without
restarting Nexus or rho. It edits the model to explicit zero pricing and runs
it again, checks the report's exact token quantities and incomplete money, and
removes/recreates the custom provider using its retained Policy version.

## Telegram ingress

`bundle exec ruby -Itest test/rho_setup_test.rb` runs the onboarding wizard against
the same isolated Nexus and keyed fake provider. Only terminal answers and
Telegram `getMe` are substituted. It uses the real Human settings API, existing
browser account/device ceremony, saved default model and a restarted rho daemon;
a normal `rho run` omits `--model` to prove that the default is used. It also
checks private bot-token storage, secret-free output, rerun preservation and
revocation of each temporary Human setup session. The daemon's Telegram network
poller is disabled by the existing E2E prelude; no bot or paid provider is called.
Failure logs are retained under `artifacts/rho_setup/`. The journey removes its
synthetic provider key and disables its lane before and after use.

From this directory, `bundle exec ruby -Itest test/rho_telegram_test.rb` runs the
conversation-control and media suite; `test/rho_telegram_group_test.rb` runs the
group observation, memory, authority and active-participation suite with the same
command. Each boots an isolated Nexus world, pairs a real rho daemon, and drives the shipped Telegram
Runtime and Bridge with a recording Bot API client. The daemon loads the real
plugin and declares its group profile; a test prelude disables its network poll.
All model requests use the local fake provider. No real bot or provider token is
needed, and no Telegram request is sent.

The suites cover explicit allow, external speaker attribution, accepted-input
replay after a lost acknowledgement, shared group observation without inference,
group exclusion of personal memory and skills, exact question answers, and
separate original and asynchronous supplementary outbound messages. Busy-input
coverage proves that `/steer` reaches the existing turn while ordinary input
waits, `/btw` answers in the original topic without executing tools or interrupting
the parent, and `/stop` cuts the current parent/side while preserving earlier work.
It does not
claim acceptance against Telegram's live API. Diagnostics are written under
`artifacts/rho_telegram/` on failure; the owned daemon, Nexus world and database
are stopped and removed by teardown. Browser binary overrides are the same as
the other pairing journeys above.

## Manual Codex authorization

The manual OAuth commands live here and run with Nexus's bundle against its
existing development database. They call the same authorization and credential
commands as the product, and are never loaded by Nexus or the default E2E tasks.
Run from `nexus/`:

```sh
RAILS_ENV=development bundle exec rake -f ../e2e/manual/codex_authorization.rake codex_authorization:manual:status
RAILS_ENV=development bundle exec rake -f ../e2e/manual/codex_authorization.rake codex_authorization:manual:start
RAILS_ENV=development bundle exec rake -f ../e2e/manual/codex_authorization.rake 'codex_authorization:manual:step[SESSION_PUBLIC_ID]'
RAILS_ENV=development bundle exec rake -f ../e2e/manual/codex_authorization.rake codex_authorization:manual:refresh
```

Enable the `codex_subscription` provider lane before `start` or `refresh`. These
commands create ordinary OAuth sessions, which development workers may advance
automatically. `step` explicitly advances one recorded session, makes at most one provider call, and prints
the user code and verification URL when human approval is needed. Every command
refuses CI and non-development environments.
Keep the same database between commands so the session remains available.

For a local seed, set `CODEX_AUTH_FILE` to a Codex auth.json file and run
`codex_authorization:manual:dev_import` with the same Rake file. It enables the
lane if necessary and installs the access/refresh pair through the ordinary
credential command, but refuses while an OAuth session is pending. Output
contains only the credential's public locator, expiry and account-identity
presence, never token values. The file is a seed: Nexus owns subsequent token
rotation and does not synchronize it back to the CLI. Do not keep the CLI
independently rotating that same seed. Production uses the device-start flow.

The offline regression tests also use the Nexus bundle; from `nexus/` run:

```sh
RAILS_ENV=test bin/rails test ../e2e/manual/codex_authorization/dev_import_test.rb ../e2e/manual/codex_authorization/commands_test.rb
```

## Result-driven DAG

`live_result_dag` asks a real model to author its own compose program for five
scenarios: shared dependencies, dynamic filter/fan/reduce, per-item pipelines,
empty selection, and a failed source. It starts an isolated Nexus world and rho
daemon, executes actual runner commands, and inspects their public task graph and
sealed requests. The prompt supplies the command interface and objective, not a
successful program.

Set the provider key in the process environment, then run from `e2e/`:

```sh
RAILS_ENV=development E2E_LIVE=1 \
  E2E_LIVE_MODEL=deepseek/deepseek-flash \
  E2E_LIVE_COST_STOP_USD=0.25 \
  bundle exec rake live_result_dag
```

Choose a configured tool-capable model with `E2E_LIVE_MODEL`; it is not limited
to the historical evaluation roster. With no override, text journeys use the
first model in `evals/bench.yml`'s floor tier. The provider segment determines
the required key. For example:

| Model | Provider key |
| --- | --- |
| `deepseek/deepseek-flash` | `DEEPSEEK_API_KEY` |
| `openrouter/z-ai/glm-5.3-flash` | `OPENROUTER_API_KEY` |

Image journeys require an explicit `E2E_VISION_MODEL` with image input. The ACP
client diagnostic also requires `E2E_ACP_CODEX_MODEL` to select an available
delegate model. These are local paid measurements; ordinary regression tests
use synthetic models and never depend on these selections.

`E2E_RESULT_DAG_ONLY=dynamic,pipeline` selects named scenarios; the full set is
`dependencies,dynamic,pipeline,empty,failure`. The diagnostic refuses CI and any
Rails environment other than development. It does not load `nexus/.env` itself.

The cost stop is per scenario and best effort: polling and metering can lag an
in-flight request, so it is not a hard spending cap. Each scenario also has a
420-second patience bound. A scenario failure does not suppress the remaining
scenarios.

For a separate GLM retry, `E2E_RESULT_DAG_EFFORT=low` installs the shipped model
row with only `reasoning.default_effort` changed in that world's temporary
catalog overlay. It preserves rho's entry point and the tool declarations;
it never edits the shipped catalog. Omit the variable for provider defaults.
`E2E_RESULT_DAG_ONLY=pipeline E2E_RESULT_DAG_PIPELINE_CORRECTION=1` runs a separate
correction diagnostic with feedback about serialized discoveries. The exact
feedback is recorded beside the request; it supplies no successful program.
The prompt permits the model to validate JavaScript in its own scratch files.
All fixture business commands must still execute inside the authored workflow;
reading or changing the fixture implementation or private data is prohibited.

Each invocation retains a distinct directory under `artifacts/result-dag/`, with
every task and compose attempt, model request, fixture event, cost reading, final
verdict, and sanitized execution logs. Failed invocations are not overwritten by
retries. Artifacts are local diagnostics, not release qualifications; classify
authoring errors, provider failures and kernel failures separately.
The strict verdict retains all attempt failures. Separate assessment fields
record whether the final workflow passed every behavior check, whether the first
generation passed, and whether a later correction passed. Earlier fixture effects
still count, so correction cannot conceal repeated work. An interrupted request
without a usage receipt has unknown cost, even when the current ledger totals are
zero.

The strict scenarios also check requested concurrency and failure-handling
shapes. They measure more than the baseline ability to generate usable
JavaScript: a program may execute and return the correct isolated result while
failing a parallel-placement assertion. Report these dimensions separately;
retain the original strict verdict rather than changing captured failures into
passes. Model tool exposure is the Agent application's policy, including rho's
compose switch.
