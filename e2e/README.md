# E2E diagnostics

Run the deterministic harness and product journeys with `bundle exec rake` from
this directory. Real model calls are separate, explicit development diagnostics.
The journey manifest uses seven isolated worlds, with two or three running at once
according to PostgreSQL's connection ceiling. Splitting suites adds worlds without
increasing concurrent worlds or the default 1,080-second journey deadline.

## Local evaluation artifacts

Generated records, provider captures and temporary analysis stay under the ignored
`artifacts/` directory. They may contain private environment or provider output and
are not regression fixtures. The local layout is:

| Directory | Contents |
|---|---|
| `artifacts/evals/<label>/invocation-*/` | Traces, requests, logs and run diagnostics retained separately for each invocation |
| `artifacts/evals/runs/` | Run records, generated scorecards and ledger |
| `artifacts/evals/analysis/` | Retired one-off analyzers, counts and report fragments |
| `artifacts/bench/captures/` | Historical captures from the retired compose matrix probe |
| `artifacts/compose-probe/` | Historical captures from the retired single compose probe |
| `artifacts/fixtures/` | Previously captured evaluation fixtures, kept locally |
| `artifacts/screen-history/` | Retired experiment definitions and their batch-specific tests |
| `artifacts/screen-readouts/` | Historical readouts from the retired screen experiment |

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

Each world drops its own primary, queue and cable databases after a successful
run, a failed journey or a failed startup. Cleanup also runs on `Ctrl-C` and
`TERM`: the parent allows both the journey's nested worlds and its outer world
to finish cleanup before forcing a stuck process to exit. A failed drop fails
the run and receives one bounded retry at process exit. These paths use the
world's exact generated database names and never sweep other runs or development
databases. Failed runs keep redacted diagnostics under `artifacts/failures/`;
database dumps require `E2E_DATABASE_DUMPS=1` and do not keep the live databases.
`SIGKILL` or a host crash cannot run exit cleanup; any resulting leftovers need
explicit cleanup after confirming that their run has ended.

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
CYBROS_NEXUS_URL=http://127.0.0.1:13300 CYBROS_RHO_URL=http://127.0.0.1:17777 \
sh install/stack/install.sh --dir "$HOME/cybros-stack-check"

cd e2e
bundle install
E2E_STACK_DIR="$HOME/cybros-stack-check" \
E2E_BASE_URL=http://127.0.0.1:13300 \
bundle exec ruby -Itest test/stack_installation_test.rb
```

The browser harness needs Chrome and its matching driver. Optional
`E2E_CHROME_BINARY` and `E2E_CHROMEDRIVER` select local binaries. The Ruby bundle
and browser are developer test dependencies, not installation prerequisites.

The journey starts from rho's ordinary public URL and chooses **Connect to
Nexus**. The first-boot page retains the authorization request and creates the
first owner without requiring a Setup secret. Creating the owner establishes
the Nexus browser session, resumes authorization and returns to rho without a
separate password or pairing screen. The optional `NEXUS_SETUP_SECRET` guard is
covered separately by [ApplicationLoginTest](test/application_login_test.rb),
which explicitly configures a secret and checks rejected and accepted values.

The test signs out and exercises both Code and Device login while checking that
the existing Agent and Runner identities and credential epochs remain unchanged.
The original browser tab also retains a valid Human session across a rho restart.
The container's `cmctl` configures a fictional provider and model. An E2E-owned
fake provider container on the stack's private Docker network supplies a WebUI
conversation; no external model provider is called. The test checks model
discovery, clears the synthetic key, preserves identities and credential epochs
on repeated startup, and verifies that starting services cannot reverse explicit
revocation. Desktop and narrow screenshots are captured. The journey is excluded
from default groups and skips unless both `E2E_STACK_DIR` and `E2E_BASE_URL` are
supplied.

The test closes its browser and removes its fake-provider container, but does not
start or tear down the supplied stack. Inspect diagnostics under
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
the same isolated Nexus and keyed fake provider. Terminal answers are deterministic;
a loopback HTTP service replaces Telegram while its real Client and polling worker
run unchanged. It uses the real Human settings API, existing browser account/device
ceremony, saved default model and live settings updates without restarting rho;
a normal `rho run` omits `--model` to prove that the default is used. It also
checks private bot-token storage, secret-free output, rerun preservation and
revocation of each temporary Human setup session. A synthetic `/start` proves the
worker reveals the sender ID and preserves its consumed update across configuration.
No external bot or paid provider is called.
Failure logs are retained under `artifacts/rho_setup/`. The journey removes its
synthetic provider key and disables its lane before and after use.

`bundle exec ruby -Itest test/rho_settings_test.rb` drives the GUI journey: connect
Nexus, verify a bot, obtain the owner ID from `/start`, bind it, edit access lists,
configure a model on Nexus, and return to rho. It changes working-directory and
shell-timeout defaults live, executes a command in the changed directory, and
receives a Telegram reply using the selected model. Desktop and narrow screenshots
and browser-console output are retained under `artifacts/rho_settings/`. The same
local Telegram HTTP service and fake model provider keep all external IO synthetic.

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
waits, unsupported `/side` and `/btw` commands create no fork or input and leave
the selected conversation unchanged, and `/stop` cuts the current conversation
while preserving earlier work. It does not
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

## Manual OpenRouter smoke

`live_openrouter` runs directly through the vendored `simple_inference` client. It starts no
Nexus, rho, browser or database. Select OpenRouter's own model IDs, without the catalog's
`openrouter/` prefix; this diagnostic does not change the shipped model definitions.

With `OPENROUTER_API_KEY` supplied privately in the process environment, run from `e2e/`:

```sh
RAILS_ENV=development E2E_LIVE=1 \
  E2E_OPENROUTER_CHAT_MODELS=qwen/qwen3.8-max-0902,qwen/qwen3.8-flash,qwen/qwen3.8-27b \
  E2E_OPENROUTER_TOOL_MODELS=qwen/qwen3.6-35b-a3b \
  E2E_OPENROUTER_VISION_MODELS=qwen/qwen3.6-35b-a3b,qwen/qwen3.5-9b \
  bundle exec rake live_openrouter
```

Each chat model gets three streamed requests: remember a marker, call one declared lookup tool
using that marker, and consume its result. The first request includes leading system and developer
messages; the second deliberately adds a changed developer message after assistant history.
That shape is an explicit compatibility probe, not rho's ordinary unchanged-lead replay. The tool is a local
diagnostic lookup, not a rho Runner. Tool selection is `auto`: the model must choose the declared
tool from the task, rather than relying on a provider supporting forced tool selection.
Assistant messages, including native reasoning, are replayed
unchanged. Each vision model gets two requests: name a generated picture's colour, then name its
shape from history without another attachment. A tool-only model gets a two-request lookup and
result-consumption case, without the conversational memory check. Chat and tool cases enable
reasoning; vision disables it. A
missing reasoning trace is recorded as an observation, not invented as a success.

For an explicit follow-up at one serving endpoint, set `E2E_OPENROUTER_PROVIDER` to its
OpenRouter provider slug (including any endpoint suffix). This diagnostic-only override sends
`provider.only` and `allow_fallbacks: false`, preserving `require_parameters: true`; it applies
to every selected case in that invocation. Omit it for ordinary broker routing. The actual
request and reported serving provider remain in the capture.

`E2E_OPENROUTER_REASONING_MODELS` adds a two-request off/on comparison for each selected
model and requires that provider pin. It asks the same picture question twice without history,
changing only `reasoning.enabled` from `false` to `true`, with a 1024-token output ceiling.
It never sets `exclude`. The off case requires no returned reasoning and zero reported
reasoning tokens; the on case requires returned reasoning or positive reported reasoning tokens.
Missing token usage stays unknown. These two cases are independent, so both run even if one
fails. For example, run this comparison by itself:

```sh
RAILS_ENV=development E2E_LIVE=1 \
  E2E_OPENROUTER_REASONING_MODELS=qwen/qwen3.5-9b \
  E2E_OPENROUTER_PROVIDER=together \
  bundle exec rake live_openrouter
```

The first, combined chat/tool/vision example plans 15 requests with a 4096-token output ceiling;
the reasoning comparison example plans two requests with a 1024-token ceiling. Every request has
a 120-second timeout.
There are no automatic retries. A failed prerequisite skips its dependent requests and does not
stop other models. The command refuses CI, missing opt-in, missing credentials and any environment
other than development; it never loads a dotenv file itself.

Standard output names the counts and a fresh, ignored `tmp/openrouter-smoke-*.jsonl` capture.
Each record keeps the actual request role sequence, serving provider when reported, stream events,
finish, usage, reasoning bytes/blocks and reported reasoning tokens, outcome and request/response
bodies; HTTP headers and credentials are excluded.
Failures remain in that capture and return a nonzero exit. These small observations demonstrate
wire behavior for the selected request shapes, not model quality, uniform provider-pool limits,
or full Nexus/rho acceptance. Normal harness tests use synthetic responses and make no paid calls.

## Deferred tool discovery

`live_deferred_tools` compares eager declarations with rho's default deferred
declarations through ordinary conversations on `deepseek/deepseek-flash`. Each
arm reads a file in a cold turn, repeats in the same conversation, then reads
through a newly paired second Runner. The eager control changes only the
declaration's `defer_loading` flags through the public profile API. The real
read result and its accepted/claimed Runner are checked through public APIs;
the final reply must exactly match the file's sentence.

```sh
RAILS_ENV=development E2E_LIVE=1 bundle exec rake live_deferred_tools
```

Set `DEEPSEEK_API_KEY` in the process environment first. The task refuses CI,
missing opt-in, missing credentials and other Rails environments before boot;
it does not load dotenv files. Its isolated catalog disables reasoning and caps
each response at 2048 output tokens. Six turns share a USD 2 soft cost stop;
metering can lag in-flight requests, so this is not a hard provider cap.

The ignored `artifacts/deferred-tools/` report retains every observed attempt's
input, output, cache-read, cache-write and cost receipt, including first misses
and failures. It also retains provider-shaped requests rebuilt from accepted
invocations against the unchanged isolated catalog, with tool counts and bytes.
These are reconstructed request diagnostics, not intercepted wire captures.
DeepSeek reports token/cache usage; recorded monetary costs use the configured
catalog rates and are not its actual invoice. The two Runner processes use the
same machine and test file path; this validates routing, not a remote deployment.
The `cold` label means the first turn of a fresh conversation. The task cannot
purge the provider's shared cache, so the observed counters determine whether
that first turn was actually a cache miss.
Compare cache counters together with total input and cost: a smaller reusable
prefix can reduce cache-read tokens while still reducing uncached input.
Review the saved final reply as well as the tool receipt. Earlier local records
with a marker-shaped file body include replies that mistook that text for an
opaque result handle; those records are retained with failed answer checks.
The current fixture uses a natural-language sentence and requires exact reply
equality. An aborted harness run and every successful or failed provider
attempt still count toward campaign spending; do not remove initial misses or
restart the budget when rerunning a corrected diagnostic.
The deterministic `multi_environment` journey independently pins exact schemas,
frozen routes, code-mode exclusion and stable provider tool declarations.

`RAILS_ENV=development E2E_LIVE=1 bundle exec rake live_tool_discovery_smoke`
is a separate, small diagnostic: one eager-direct/deferred read pair per reference
model in `evals/bench.yml`, then one small Python repair pair on DeepSeek Flash.
The eager control removes both discovery accessors, every defer flag and the
discovery guideline paragraph. The normal arm preserves rho's full declaration.
Reads use code mode off; the coding pair enables it without requiring the model
to choose code. Both arms use fresh conversations and the same initial files.

It requires the selected providers' keys in the process environment, retains
catalog reasoning settings, caps each response at 4096 tokens, waits at most
300 seconds per turn and applies a USD 3 campaign soft stop. Each failed receipt
with unknown cost reserves USD 1 of that budget without claiming a charge;
other unpriced receipts stop later cells. Failures remain and are not rerun.
The public tests must remain unchanged; a separate verifier checks the actual
Python result. Reports under `artifacts/tool-discovery-smoke/` separate model
requests, provider attempts, model function calls and expanded Runner tasks.
Counts use the last sealed history by occurrence because provider call ids can
repeat across rounds; interrupted tails are marked incomplete. This is a smoke,
with no repeated samples or cache/latency qualification. It is excluded from
the default gate and `live_sweep`. After a harness interruption,
`E2E_TOOL_SMOKE_RESUME=/absolute/report.json` retains the prior records and spend
while skipping cells that already accepted a Run or have an explicit recorded skip.

## Result-driven DAG

`live_result_dag` asks a real model to author its own async JavaScript code program for five
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
every task and code attempt, model request, fixture event, cost reading, final
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
passes. Model tool exposure is the Agent application's policy; rho loads its
agent-side code extension by default.
